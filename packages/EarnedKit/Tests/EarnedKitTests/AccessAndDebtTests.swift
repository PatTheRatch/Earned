import XCTest
@testable import EarnedKit

final class AccessAndDebtTests: XCTestCase {

    // NORTHSTAR §19: the multi-gate timeline. Every gate evaluates
    // independently; Full Access requires all of them.
    func testMultipleGatesTimeline() throws {
        var ledger = Ledger()
        let id = UUID()
        // Workout due Saturday 10:00; commitment made Friday evening.
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        // Water at 09:30 → hydration holds until 10:30, matching the §19 table.
        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 30))

        // 09:30 — hydration ✓, exercise incomplete but not yet due ✓ → Full Access.
        XCTAssertTrue(ledger.state.accessState(now: d(22, 9, 30)).isFullAccess)

        // 10:00 — deadline passes. Hydration ✓, exercise ✗ → restricted.
        let atTen = ledger.state.accessState(now: d(22, 10, 0, 1))
        XCTAssertEqual(atTen.lockReasons.map(\.gate), [.commitment(id)])

        // 10:15 — workout completed → Full Access.
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 9, 40), minutes: 30)), at: d(22, 10, 15))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 10, 16)).isFullAccess)

        // 10:30 — hydration timer (09:30 + 60 min) expires → restricted.
        let atHalfTen = ledger.state.accessState(now: d(22, 10, 30))
        XCTAssertEqual(atHalfTen.lockReasons.map(\.gate), [.hydration])
    }

    // NORTHSTAR §16: debt persists across days, does not compound, and one
    // qualifying workout clears the outstanding obligation and the day's own.
    func testWorkoutDebt() throws {
        var ledger = Ledger()
        let saturday = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: saturday, title: "Saturday workout",
                                              deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))

        // Saturday missed; Sunday the obligation still exists.
        XCTAssertFalse(ledger.state.accessState(now: d(23, 12)).isFullAccess)
        XCTAssertEqual(ledger.state.workoutDebt(now: d(23, 12)), 1)

        // Monday also contains a scheduled workout. Debt remains 1.
        let monday = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: monday, title: "Monday workout",
                                              deadline: d(24, 20), createdAt: d(23, 18))),
            at: d(23, 18))
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 8)), 1)

        // One qualifying Monday workout satisfies both obligations.
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 30)), at: d(24, 9, 45))
        XCTAssertNotNil(ledger.state.commitments[saturday]?.resolution)
        XCTAssertNotNil(ledger.state.commitments[monday]?.resolution)
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 10)), 0)
        XCTAssertTrue(ledger.state.accessState(now: d(24, 10)).isFullAccess)
    }

    // NORTHSTAR §19: the system always explains exactly what is locking access.
    func testLockReasonsExplainEverything() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id, title: "Run 30 minutes",
                requirement: .anyWorkout(minimumDuration: 30 * 60),
                deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 18)), at: d(22, 8, 30))

        // 10:30: hydration never acknowledged (expired 09:00) and run overdue at 18/30.
        let reasons = ledger.state.accessState(now: d(22, 10, 30)).lockReasons
        guard reasons.count == 2 else {
            return XCTFail("Expected 2 lock reasons, got \(reasons.count)")
        }
        XCTAssertEqual(reasons[0].gate, .hydration)
        XCTAssertEqual(reasons[1].gate, .commitment(id))
        XCTAssertEqual(reasons[1].headline, "Run 30 minutes")
        XCTAssertEqual(reasons[1].progress?.achieved, 18 * 60)
        XCTAssertEqual(reasons[1].progress?.required, 30 * 60)
    }


    // Deadlines of pending commitments drive nextTransition for enforcement
    // scheduling.
    func testNextTransitionIncludesDeadlines() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 9)), d(22, 10))
    }
}
