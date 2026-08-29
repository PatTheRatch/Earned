import Foundation
import XCTest
@testable import EarnedKit

final class LedgerTests: XCTestCase {

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testEventsMustBeChronological() throws {
        var ledger = Ledger()
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))
        expectThrows(.eventOutOfOrder(eventDate: d(22, 9), lastEventDate: d(22, 10))) {
            try ledger.append(.waterAcknowledged, at: d(22, 9))
        }
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))
    }

    func testRejectedEventsLeaveNoTrace() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        let before = ledger
        XCTAssertThrowsError(try ledger.append(.commitmentCancelled(id: id), at: d(24, 11)))
        XCTAssertEqual(ledger, before)
    }

    func testCodableRoundTrip() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(warningLead: 600)), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 8))
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id, requirement: .run(minutes: 30),
                eligibleFrom: d(22), deadline: d(22, 20), createdAt: d(22, 8, 30))),
            at: d(22, 8, 30))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 9), minutes: 18)), at: d(22, 9, 30))
        ledger.expectAppend(
            .defaultCommitmentRestrictionsChanged(RestrictionProfile(["instagram"])), at: d(22, 9, 45))

        let data = try Self.encoder.encode(ledger)
        let decoded = try Self.decoder.decode(Ledger.self, from: data)

        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.state.progress(for: id)?.achieved, 18 * 60)
        XCTAssertEqual(decoded.state.defaultCommitmentRestrictions, RestrictionProfile(["instagram"]))
    }

    /// Encoding writes the versioned envelope.
    func testEncodesCurrentSchemaVersion() throws {
        var ledger = Ledger()
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))
        let data = try Self.encoder.encode(ledger)
        let document = try Self.decoder.decode(LedgerDocument.self, from: data)
        XCTAssertEqual(document.version, Ledger.currentSchemaVersion)
    }

    /// A v1 file was a bare array with no envelope; it must still load.
    func testV1BareArrayStillLoads() throws {
        let entries = [
            LedgerEntry(date: d(22, 7), event: .hydrationConfigured(patrickHydration())),
            LedgerEntry(date: d(22, 8), event: .waterAcknowledged),
        ]
        let data = try Self.encoder.encode(entries)
        let document = try Self.decoder.decode(LedgerDocument.self, from: data)
        XCTAssertEqual(document.version, 1)

        let ledger = try Self.decoder.decode(Ledger.self, from: data)
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 8, 30)),
                       .satisfied(expiresAt: d(22, 9)))
    }

    /// v1's single global restricted-app set replays as the default profile for
    /// new commitments, rather than being dropped.
    func testV1RestrictedAppsReplayAsTheDefaultProfile() throws {
        let entries = [
            LedgerEntry(date: d(22, 7),
                        event: .restrictedAppsChanged(added: ["instagram", "youtube"], removed: [])),
            LedgerEntry(date: d(22, 8),
                        event: .restrictedAppsChanged(added: [], removed: ["youtube"])),
        ]
        let data = try Self.encoder.encode(entries)
        let ledger = try Self.decoder.decode(Ledger.self, from: data)
        XCTAssertEqual(ledger.state.defaultCommitmentRestrictions, RestrictionProfile(["instagram"]))
    }

    /// A v1 spend has no earning event funding it. Migration inserts one,
    /// attributed to migration so it is never mistaken for a streak reward.
    func testV1FreeOverrideSpendIsFunded() throws {
        let id = UUID()
        let entries = [
            LedgerEntry(date: d(21, 18), event: .commitmentCreated(makeCommitment(
                id: id, eligibleFrom: d(22), deadline: d(22, 10), createdAt: d(21, 18)))),
            LedgerEntry(date: d(22, 12), event: .freeOverrideSpent(commitmentID: id)),
        ]
        let data = try Self.encoder.encode(entries)
        let ledger = try Self.decoder.decode(Ledger.self, from: data)

        XCTAssertEqual(ledger.state.commitments[id]?.resolution, .overridden(.free, at: d(22, 12)))
        XCTAssertEqual(ledger.state.freeOverrideBalance, 0, "the grant was spent")
        XCTAssertEqual(ledger.state.freeOverrideGrants.count, 1)
        XCTAssertEqual(ledger.state.freeOverrideGrants.first?.source, .migration)
    }

    /// A ledger written by a newer build is refused rather than half-read.
    func testFutureSchemaVersionIsRefused() throws {
        let document = LedgerDocument(version: Ledger.currentSchemaVersion + 1, entries: [])
        let data = try Self.encoder.encode(document)
        XCTAssertThrowsError(try Self.decoder.decode(Ledger.self, from: data))
    }

    /// A persisted history that violates the rules must fail to load rather than
    /// produce a state the rules would never have allowed.
    func testInvalidHistoryFailsReplay() {
        let entries = [
            LedgerEntry(date: d(22, 10), event: .waterAcknowledged),
            LedgerEntry(date: d(22, 9), event: .waterAcknowledged),
        ]
        XCTAssertThrowsError(try Ledger(replaying: entries))
    }

    /// Replay must not re-derive engine events: an earned Free Override is in
    /// history, and replaying under a changed policy must not add or drop one.
    func testReplayDoesNotReDeriveRewards() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 2, maxStored: 3)), at: d(1))
        for day in 2...3 {
            let id = UUID()
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(day),
                                                  deadline: d(day, 20), createdAt: d(day, 6))),
                at: d(day, 6))
            ledger.expectAppend(.workoutRecorded(workout(start: d(day, 9), minutes: 30)), at: d(day, 10))
        }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 1)

        let replayed = try Ledger(replaying: ledger.entries)
        XCTAssertEqual(replayed.state.freeOverrideBalance, 1)
        XCTAssertEqual(replayed.entries.count, ledger.entries.count)
        XCTAssertEqual(replayed.state, ledger.state)
    }
}
