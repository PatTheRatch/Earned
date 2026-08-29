import XCTest
@testable import EarnedKit

/// `eligibleFrom` is what stops a workout reaching *forward* into a commitment
/// whose day has not arrived, while still letting a late workout reach *back* to
/// clear debt (NORTHSTAR §10, §16).
final class EligibilityTests: XCTestCase {

    /// The bug this field exists to fix: three commitments created on Sunday for
    /// Monday, Wednesday and Friday. Monday's run must satisfy Monday only.
    func testOneWorkoutCannotSatisfyTheWholeWeek() throws {
        var ledger = Ledger()
        let mon = UUID(), wed = UUID(), fri = UUID()
        let created = d(23, 18) // Sunday evening

        for (id, day) in [(mon, 24), (wed, 26), (fri, 28)] {
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: id, title: "Run",
                                                  eligibleFrom: d(day),       // midnight that day
                                                  deadline: d(day, 10),
                                                  createdAt: created)),
                at: created)
        }

        // Monday morning run.
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 8), minutes: 30)), at: d(24, 9))

        XCTAssertNotNil(ledger.state.commitments[mon]?.resolution, "Monday is satisfied")
        XCTAssertNil(ledger.state.commitments[wed]?.resolution, "Wednesday must not be satisfied early")
        XCTAssertNil(ledger.state.commitments[fri]?.resolution, "Friday must not be satisfied early")
        XCTAssertEqual(ledger.state.progress(for: wed)?.achieved, 0)
    }

    /// A future commitment cannot be completed before its window opens, however
    /// much exercise happens first.
    func testFutureCommitmentCannotBeCompletedEarly() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, requirement: .run(minutes: 30),
                                              eligibleFrom: d(28),
                                              deadline: d(28, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 60)), at: d(24, 10))
        ledger.expectAppend(.workoutRecorded(workout(start: d(26, 9), minutes: 60)), at: d(26, 10))

        XCTAssertNil(ledger.state.commitments[id]?.resolution)
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 0)

        // Friday's own run does satisfy it.
        ledger.expectAppend(.workoutRecorded(workout(start: d(28, 8), minutes: 30)), at: d(28, 9))
        XCTAssertEqual(ledger.state.commitments[id]?.resolution, .completed(at: d(28, 8, 30)))
    }

    /// No upper bound: an overdue commitment is still completable late, which is
    /// what makes debt work at all.
    func testOverdueCommitmentCompletesLate() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(22),
                                              deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))

        XCTAssertTrue(ledger.state.accessState(now: d(23, 12)).isRestricted)

        // Sunday afternoon, two days late.
        ledger.expectAppend(.workoutRecorded(workout(start: d(23, 14), minutes: 30)), at: d(23, 15))
        XCTAssertEqual(ledger.state.commitments[id]?.resolution, .completed(at: d(23, 14, 30)))
        XCTAssertTrue(ledger.state.accessState(now: d(23, 16)).isFullAccess)
    }

    /// NORTHSTAR §16's worked example: one Monday workout clears Saturday's debt
    /// *and* Monday's own requirement. Debt never compounds beyond one.
    func testOneWorkoutClearsDebtAndTheCurrentDay() throws {
        var ledger = Ledger()
        let saturday = UUID(), monday = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: saturday, title: "Saturday workout",
                                              eligibleFrom: d(22),
                                              deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))

        XCTAssertEqual(ledger.state.workoutDebt(now: d(23, 12)), 1)

        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: monday, title: "Monday workout",
                                              eligibleFrom: d(24),
                                              deadline: d(24, 20), createdAt: d(23, 18))),
            at: d(23, 18))
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 8)), 1, "debt does not compound")

        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 30)), at: d(24, 9, 45))
        XCTAssertNotNil(ledger.state.commitments[saturday]?.resolution, "old debt cleared")
        XCTAssertNotNil(ledger.state.commitments[monday]?.resolution, "today's requirement cleared")
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 10)), 0)
        XCTAssertTrue(ledger.state.accessState(now: d(24, 10)).isFullAccess)
    }

    /// A one-off created by hand still cannot be satisfied by a workout that
    /// already happened — the default `eligibleFrom` is creation time.
    func testWorkoutBeforeCreationIsIneligible() throws {
        var ledger = Ledger()
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 7), minutes: 30)), at: d(24, 7, 30))
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        XCTAssertNil(ledger.state.commitments[id]?.resolution)
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 0)
    }

    /// Eligibility is judged on when the workout happened, not when it synced.
    func testLateSyncedWorkoutCounts() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(24, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        // Ran 09:00–09:30 but HealthKit delivered it at 11:00, after the deadline.
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 30)), at: d(24, 11))
        XCTAssertEqual(ledger.state.commitments[id]?.resolution, .completed(at: d(24, 9, 30)))
    }

    /// A later `eligibleFrom` is a harder contract; an earlier one is easier and
    /// is refused after hardening.
    func testEligibleFromIsMonotonic() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(26),
                                              deadline: d(28, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        // Hardened at 10:00. Narrowing the window is allowed.
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(eligibleFrom: d(27))), at: d(24, 11))
        // Widening it is not.
        expectThrows {
            try ledger.append(.commitmentEdited(id: id, edit: CommitmentEdit(eligibleFrom: d(25))),
                              at: d(24, 12))
        }
    }

    func testEligibleFromAfterDeadlineIsRejected() {
        var ledger = Ledger()
        expectThrows {
            try ledger.append(.commitmentCreated(makeCommitment(
                eligibleFrom: d(29), deadline: d(28, 10), createdAt: d(24, 8))), at: d(24, 8))
        }
    }
}
