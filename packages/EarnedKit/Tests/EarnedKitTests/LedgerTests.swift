import Foundation
import XCTest
@testable import EarnedKit

final class LedgerTests: XCTestCase {

    func testEventsMustBeChronological() throws {
        var ledger = Ledger()
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))
        expectThrows(.eventOutOfOrder(eventDate: d(22, 9), lastEventDate: d(22, 10))) {
            try ledger.append(.waterAcknowledged, at: d(22, 9))
        }
        // Equal timestamps are allowed (two events in the same instant).
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))
    }

    func testRejectedEventsLeaveNoTrace() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        let before = ledger

        XCTAssertThrowsError(
            try ledger.append(.commitmentCancelled(id: id), at: d(24, 11)))
        XCTAssertEqual(ledger, before)
    }

    func testCodableRoundTrip() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(warningLead: 600)), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 8))
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id, requirement: .totalDuration(30 * 60),
                deadline: d(22, 20), createdAt: d(22, 8, 30))),
            at: d(22, 8, 30))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 9), minutes: 18)), at: d(22, 9, 30))
        ledger.expectAppend(.restrictedAppsChanged(added: ["instagram"], removed: []), at: d(22, 9, 45))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(ledger)
        let decoded = try decoder.decode(Ledger.self, from: data)

        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.state.progress(for: id)?.achieved, 18 * 60)
    }

    // A persisted history that violates the rules must fail to load rather than
    // produce a state the rules would never have allowed.
    func testInvalidHistoryFailsReplay() {
        let entries = [
            LedgerEntry(date: d(22, 10), event: .waterAcknowledged),
            LedgerEntry(date: d(22, 9), event: .waterAcknowledged),
        ]
        XCTAssertThrowsError(try Ledger(replaying: entries))
    }
}
