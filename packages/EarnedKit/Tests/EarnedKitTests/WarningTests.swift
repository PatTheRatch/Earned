import XCTest
@testable import EarnedKit

/// Pre-enforcement warnings (NORTHSTAR §20). Warnings are informational: they
/// say a Gate is about to change state, and they never move the moment it does.
final class WarningTests: XCTestCase {

    func testCommitmentWarningFiresItsLeadBeforeTheDeadline() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, title: "Run 30 minutes",
                                              deadline: d(24, 10), createdAt: d(24, 6),
                                              warningLead: 30 * 60)),
            at: d(24, 6))

        let warnings = ledger.state.upcomingWarnings(now: d(24, 7))
        XCTAssertEqual(warnings.map(\.date), [d(24, 9, 30)])
        XCTAssertEqual(warnings.first?.gate, .commitment(id))
    }

    func testNoLeadMeansNoWarning() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6))),
            at: d(24, 6))
        XCTAssertTrue(ledger.state.upcomingWarnings(now: d(24, 7)).isEmpty)
    }

    /// Once the warning moment has passed there is nothing left to schedule —
    /// the deadline itself is what happens next.
    func testWarningDropsOutOnceItsMomentHasPassed() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6),
                                              warningLead: 30 * 60)),
            at: d(24, 6))
        XCTAssertEqual(ledger.state.upcomingWarnings(now: d(24, 9, 29)).count, 1)
        XCTAssertTrue(ledger.state.upcomingWarnings(now: d(24, 9, 31)).isEmpty)
    }

    /// A commitment that is already done, or already overdue, has nothing to
    /// warn about: in the first case there is no obligation left, and in the
    /// second the Gate has already closed.
    func testResolvedAndOverdueCommitmentsAreNotWarnedAbout() throws {
        var completed = Ledger()
        let id = UUID()
        completed.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(24, 10), createdAt: d(24, 6),
                                              warningLead: 30 * 60)),
            at: d(24, 6))
        completed.expectAppend(.workoutRecorded(workout(start: d(24, 7), minutes: 30)), at: d(24, 8))
        XCTAssertNotNil(completed.state.commitments[id]?.resolution)
        XCTAssertTrue(completed.state.upcomingWarnings(now: d(24, 9)).isEmpty)

        var overdue = Ledger()
        overdue.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6),
                                              warningLead: 30 * 60)),
            at: d(24, 6))
        XCTAssertTrue(overdue.state.upcomingWarnings(now: d(24, 11)).isEmpty,
                      "an overdue commitment's Gate is already closed")
    }

    /// Hydration warns before the rolling timer expires, and only while the
    /// Gate is actually satisfied — an already-closed Gate has nothing pending.
    func testHydrationWarnsOnlyWhileSatisfied() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(warningLead: 600)), at: d(24, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(24, 10))

        XCTAssertEqual(ledger.state.upcomingWarnings(now: d(24, 10, 5)).map(\.date), [d(24, 10, 50)])
        // Timer expired at 11:00; the Gate is closed and there is nothing to warn about.
        XCTAssertTrue(ledger.state.upcomingWarnings(now: d(24, 11, 5)).isEmpty)
    }

    /// Warnings across different Gates come back in the order they will fire,
    /// which is the order the scheduling layer wants to read them in.
    func testWarningsFromAllGatesAreSortedByTime() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(warningLead: 600)), at: d(24, 7))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(title: "Run", deadline: d(24, 12), createdAt: d(24, 8),
                                              warningLead: 30 * 60)),
            at: d(24, 8))
        ledger.expectAppend(.waterAcknowledged, at: d(24, 10))

        let warnings = ledger.state.upcomingWarnings(now: d(24, 10, 5))
        XCTAssertEqual(warnings.map(\.date), [d(24, 10, 50), d(24, 11, 30)])
        XCTAssertEqual(warnings.map(\.gate.isHydration), [true, false])
    }

    /// A warning is not a grace period (NORTHSTAR §20): the moment the Gate
    /// changes state is identical whether or not one was configured.
    func testWarningDoesNotMoveTheDeadline() throws {
        var warned = Ledger()
        warned.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6),
                                              warningLead: 30 * 60)),
            at: d(24, 6))
        var silent = Ledger()
        silent.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6))),
            at: d(24, 6))

        for at in [d(24, 9, 59), d(24, 10), d(24, 10, 1)] {
            XCTAssertEqual(warned.state.accessState(now: at).isRestricted,
                           silent.state.accessState(now: at).isRestricted,
                           "a configured warning changed when the Gate closed")
        }
        XCTAssertTrue(warned.state.accessState(now: d(24, 10, 1)).isRestricted)
    }
}

private extension GateID {
    var isHydration: Bool { self == .hydration }
}
