import Foundation
import XCTest
@testable import EarnedKit

/// Grants as EarnedKit sees them (docs/accountability-architecture.md §9).
///
/// Everything cryptographic happens before an event reaches here: the app
/// layer verifies a signature against the trusted key set and only then
/// appends. These tests are about the half that lives forever — what a grant
/// means, and what a ledger holding one replays to.
final class GrantTests: XCTestCase {

    private func overdueCommitment(id: UUID) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(22),
                                              deadline: d(22, 10),
                                              createdAt: d(21, 18), policy: patrickPolicy())),
            at: d(21, 18))
        return ledger
    }

    private let mom = PartnerVote(partnerDisplayName: "Mom", vote: .approve, at: d(22, 11, 5))
    private let dave = PartnerVote(partnerDisplayName: "Dave", vote: .approve, at: d(22, 11, 9))

    // MARK: - What a grant does

    func testGrantResolvesTheCommitment() throws {
        let commitmentID = UUID()
        var ledger = overdueCommitment(id: commitmentID)
        let requestID = UUID()
        let grantID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))

        XCTAssertTrue(ledger.state.accessState(now: d(22, 11, 1)).isRestricted)

        ledger.expectAppend(
            .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 11, 9),
                                           roster: [mom, dave], serverGrantID: grantID),
            at: d(22, 11, 30))

        // Resolved at the moment the *server* decided, not the moment the phone
        // heard about it. A grant can sit undelivered while a user is offline
        // (§11); recording the poll time would misdate their own history.
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .overridden(.accountability, at: d(22, 11, 9)))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 11, 31)).isFullAccess)

        let request = try XCTUnwrap(ledger.state.overrideRequests[requestID])
        XCTAssertEqual(request.serverGrantID, grantID)
        XCTAssertEqual(request.roster, [mom, dave])
        XCTAssertEqual(request.grantedKind, .accountability)
    }

    func testGrantCarriesNoSignature() throws {
        // §9.2, asserted against the encoded form rather than against intent:
        // whatever a future author adds to this event, it must not be the
        // cryptography, because keys rotate and permanent history cannot.
        let event = Event.accountabilityOverrideGranted(
            requestID: UUID(), decidedAt: d(22, 11, 9),
            roster: [mom], serverGrantID: UUID())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(event), encoding: .utf8) ?? ""
        for forbidden in ["signature", "kid", "publicKey", "ed25519", "alg"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()),
                           "a grant event must not carry \(forbidden)")
        }
    }

    // MARK: - Idempotency (§9.4)

    func testASecondGrantForTheSameRequestIsRejected() throws {
        let commitmentID = UUID()
        var ledger = overdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))
        ledger.expectAppend(
            .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 11, 9),
                                           roster: [mom, dave], serverGrantID: UUID()),
            at: d(22, 11, 30))

        // The app checks serverGrantID against the ledger before appending, but
        // the reducer is the backstop, and a backstop nobody proved is a hope.
        XCTAssertThrowsError(
            try ledger.append(
                .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 12),
                                               roster: [mom, dave], serverGrantID: UUID()),
                at: d(22, 12, 1)))
    }

    func testAGrantForAnAlreadyCompletedCommitmentIsRejected() throws {
        // The partner approved while the user was finishing the workout. The
        // request is moot; the page they saw was stale (§12). Their tap must
        // not reopen a resolved commitment.
        let commitmentID = UUID()
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: commitmentID, requirement: .anyWorkout,
                                              eligibleFrom: d(22), deadline: d(22, 23),
                                              createdAt: d(21, 18), policy: patrickPolicy())),
            at: d(21, 18))
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 10, 40), minutes: 30)),
                            at: d(22, 11, 20))

        XCTAssertThrowsError(
            try ledger.append(
                .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 11, 25),
                                               roster: [mom, dave], serverGrantID: UUID()),
                at: d(22, 11, 30)))
    }

    // MARK: - Determinism (§19; we have been bitten by exactly this)

    func testReplayIsIdentical() throws {
        let commitmentID = UUID()
        let requestID = UUID()
        let grantID = UUID()
        var ledger = overdueCommitment(id: commitmentID)
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))
        ledger.expectAppend(
            .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 11, 9),
                                           roster: [mom, dave], serverGrantID: grantID),
            at: d(22, 11, 30))

        let replayed = try Ledger(replaying: ledger.entries)
        XCTAssertEqual(replayed.state.commitments[commitmentID]?.resolution,
                       ledger.state.commitments[commitmentID]?.resolution)
        XCTAssertEqual(replayed.state.overrideRequests[requestID]?.serverGrantID, grantID)
        XCTAssertEqual(replayed.state.overrideRequests[requestID]?.roster, [mom, dave])
    }

    func testRosterSurvivesEncodingRoundTrip() throws {
        let commitmentID = UUID()
        let requestID = UUID()
        var ledger = overdueCommitment(id: commitmentID)
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))
        ledger.expectAppend(
            .accountabilityOverrideGranted(requestID: requestID, decidedAt: d(22, 11, 9),
                                           roster: [mom, dave], serverGrantID: UUID()),
            at: d(22, 11, 30))

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(LedgerDocument.self,
                                          from: try encoder.encode(ledger))
        XCTAssertEqual(document.version, Ledger.currentSchemaVersion,
                       "a saved ledger is stamped with the current version")
        let reloaded = try Ledger(replaying: document.entries)
        XCTAssertEqual(reloaded.state.overrideRequests[requestID]?.roster, [mom, dave])
    }

    // MARK: - The route that still works without any of this

    func testSoloIsUnaffected() throws {
        // A grant never arriving must not close the Solo route, and a request
        // that has no grant has no serverGrantID to show for it (§11, S8).
        let commitmentID = UUID()
        var ledger = overdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID),
                            at: d(22, 11))
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 31))
        ledger.expectAppend(.soloOverrideProgressRecorded(requestID: requestID, units: 100),
                            at: d(22, 11, 40))
        ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 41))

        let request = try XCTUnwrap(ledger.state.overrideRequests[requestID])
        XCTAssertEqual(request.grantedKind, .solo)
        XCTAssertNil(request.serverGrantID, "the Solo route involves no server grant")
        XCTAssertTrue(request.roster.isEmpty)
    }
}
