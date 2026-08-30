import XCTest
@testable import EarnedKit

/// Activity filter and completion metric are separate dimensions: "Run 30
/// minutes" must not be satisfiable by half an hour on a bike (NORTHSTAR §13).
final class ActivityTests: XCTestCase {

    func testCyclingDoesNotSatisfyARunningCommitment() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, title: "Run 30 minutes",
                                              requirement: .run(minutes: 30),
                                              deadline: d(24, 20), createdAt: d(24, 8))),
            at: d(24, 8))

        ledger.expectAppend(
            .workoutRecorded(workout(start: d(24, 9), minutes: 45, activity: .cycling)), at: d(24, 10))
        XCTAssertNil(ledger.state.commitments[id]?.resolution)
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 0)

        ledger.expectAppend(
            .workoutRecorded(workout(start: d(24, 11), minutes: 30, activity: .running)), at: d(24, 12))
        XCTAssertEqual(ledger.state.commitments[id]?.resolution, .completed(at: d(24, 11, 30)))
    }

    /// "Any workout ≥ 10 min" — an unrestricted filter with a duration metric.
    func testAnyWorkoutWithMinimumDuration() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id,
                                              requirement: .anyWorkout(minimumDuration: 600),
                                              deadline: d(24, 20), createdAt: d(24, 8))),
            at: d(24, 8))
        ledger.expectAppend(
            .workoutRecorded(workout(start: d(24, 9), minutes: 10, activity: .strength)), at: d(24, 10))
        XCTAssertNotNil(ledger.state.commitments[id]?.resolution)
    }

    /// Distance accumulates, but only across qualifying activities.
    func testDistanceAccumulatesWithinTheFilter() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, requirement: .run(kilometers: 5),
                                              deadline: d(24, 22), createdAt: d(24, 8))),
            at: d(24, 8))
        ledger.expectAppend(.workoutRecorded(
            workout(start: d(24, 9), minutes: 20, activity: .running, distanceMeters: 3200)), at: d(24, 10))
        // A 2km cycle must not top it up.
        ledger.expectAppend(.workoutRecorded(
            workout(start: d(24, 12), minutes: 10, activity: .cycling, distanceMeters: 2000)), at: d(24, 13))
        XCTAssertNil(ledger.state.commitments[id]?.resolution)

        ledger.expectAppend(.workoutRecorded(
            workout(start: d(24, 18), minutes: 12, activity: .running, distanceMeters: 1800)), at: d(24, 19))
        XCTAssertNotNil(ledger.state.commitments[id]?.resolution)
    }

    /// Narrowing the filter is harder; widening is easier; swapping one specific
    /// type for another is neither, and is refused after hardening.
    func testActivityFilterMonotonicity() throws {
        XCTAssertTrue(ActivityFilter.only(.running).isAtLeastAsHard(as: .any))
        XCTAssertFalse(ActivityFilter.any.isAtLeastAsHard(as: .only(.running)))
        XCTAssertFalse(ActivityFilter.only(.cycling).isAtLeastAsHard(as: .only(.running)))
        XCTAssertTrue(ActivityFilter.only(.running)
            .isAtLeastAsHard(as: .types([.running, .walking])))

        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, requirement: .anyWorkout(minimumDuration: 1800),
                                              deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        // Hardened at 10:00; narrowing to running only is harder → allowed.
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(requirement: .run(minutes: 30))),
            at: d(24, 11))
        // Widening back to anything is easier → refused.
        expectThrows {
            try ledger.append(.commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: .anyWorkout(minimumDuration: 1800))), at: d(24, 12))
        }
        // Swapping running for cycling is incomparable → refused.
        expectThrows {
            try ledger.append(.commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: .cycle(minutes: 30))), at: d(24, 12))
        }
    }

    func testEmptyActivityFilterIsRejected() {
        var ledger = Ledger()
        expectThrows {
            try ledger.append(.commitmentCreated(makeCommitment(
                requirement: Requirement(activity: .types([]), metric: .anyQualifyingWorkout),
                deadline: d(29), createdAt: d(24, 8))), at: d(24, 8))
        }
    }
}

/// Recurring plans generate ordinary commitments; the plan is never the source
/// of truth for gate state.
final class PlanTests: XCTestCase {

    /// Mon/Wed/Fri for one week, created Sunday.
    private func mwfPlan(createdAt: Date = d(23, 18), weeks: Int = 1) -> CommitmentPlan {
        CommitmentPlan(title: "Run 30 min",
                       requirement: .run(minutes: 30),
                       weekdays: [2, 4, 6], // Mon, Wed, Fri
                       deadlineMinuteOfDay: 10 * 60,
                       startDate: d(24),
                       endDate: CommitmentPlan.weeks(weeks, from: d(24), timeZoneIdentifier: "UTC"),
                       timeZoneIdentifier: "UTC",
                       configuredCorrectionWindow: 2 * 3600,
                       overridePolicy: patrickPolicy(),
                       restrictions: exerciseProfile,
                       createdAt: createdAt)
    }

    func testGeneratesOneOccurrencePerScheduledDay() throws {
        let occurrences = mwfPlan().occurrences()
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences.map(\.deadline), [d(24, 10), d(26, 10), d(28, 10)])
        // Each opens at midnight on its own day (NORTHSTAR: recorded decision).
        XCTAssertEqual(occurrences.map(\.eligibleFrom), [d(24), d(26), d(28)])
        XCTAssertTrue(occurrences.allSatisfy { $0.planID != nil })
        XCTAssertTrue(occurrences.allSatisfy { $0.requirement == .run(minutes: 30) })
    }

    func testFourWeeksGeneratesTwelveOccurrences() throws {
        XCTAssertEqual(mwfPlan(weeks: 4).occurrences().count, 12)
    }

    /// `eligibleFrom` is clamped to the plan's creation, so a plan made at noon
    /// cannot be satisfied by that morning's run.
    func testEligibleFromNeverPrecedesPlanCreation() throws {
        let plan = mwfPlan(createdAt: d(24, 12))  // Monday noon
        let occurrences = plan.occurrences()
        // Monday's 10:00 deadline has already passed at creation, so it is skipped.
        XCTAssertEqual(occurrences.map(\.deadline), [d(26, 10), d(28, 10)])
        XCTAssertEqual(occurrences.first?.eligibleFrom, d(26))

        let sameDay = CommitmentPlan(title: "Evening run",
                                     requirement: .run(minutes: 30),
                                     weekdays: [2],
                                     deadlineMinuteOfDay: 20 * 60,
                                     startDate: d(24), endDate: d(24),
                                     timeZoneIdentifier: "UTC",
                                     configuredCorrectionWindow: 3600,
                                     overridePolicy: patrickPolicy(),
                                     createdAt: d(24, 12))
        XCTAssertEqual(sameDay.occurrences().first?.eligibleFrom, d(24, 12),
                       "clamped to creation, not midnight")
    }

    /// Occurrences behave as ordinary commitments once in the ledger, and one
    /// day's workout does not satisfy the rest of the week.
    func testOccurrencesReplayAsOrdinaryCommitments() throws {
        var ledger = Ledger()
        let plan = mwfPlan()
        ledger.expectAppend(.planCreated(plan), at: plan.createdAt)
        let occurrences = plan.occurrences()
        for occurrence in occurrences {
            ledger.expectAppend(.commitmentCreated(occurrence), at: plan.createdAt)
        }

        XCTAssertEqual(ledger.state.occurrences(ofPlan: plan.id).count, 3)

        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 8), minutes: 30)), at: d(24, 9))
        let resolved = ledger.state.occurrences(ofPlan: plan.id).filter { $0.isResolved }
        XCTAssertEqual(resolved.count, 1, "only Monday's occurrence is satisfied")
        XCTAssertEqual(resolved.first?.commitment.deadline, d(24, 10))
    }

    /// Cancelling a plan withdraws occurrences whose window has not opened yet,
    /// and spares those already live. Every occurrence hardens two hours after
    /// *plan creation*, so without the window clause cancelling would withdraw
    /// nothing at all.
    func testCancellingAPlanSparesLiveOccurrences() throws {
        var ledger = Ledger()
        let plan = mwfPlan(weeks: 2)
        ledger.expectAppend(.planCreated(plan), at: plan.createdAt)
        for occurrence in plan.occurrences() {
            ledger.expectAppend(.commitmentCreated(occurrence), at: plan.createdAt)
        }

        // Every occurrence hardened two hours after the plan was made.
        let monday = ledger.state.occurrences(ofPlan: plan.id).first!
        XCTAssertTrue(monday.commitment.isHardened(at: d(24, 6)))
        XCTAssertEqual(monday.commitment.eligibleFrom, d(24), "Monday's window is already open")

        // Cancel Monday 06:00 — inside Monday's window, before every later one.
        ledger.expectAppend(.planCancelled(id: plan.id), at: d(24, 6))

        let records = ledger.state.occurrences(ofPlan: plan.id)
        XCTAssertNil(records.first?.resolution,
                     "Monday is live today; it survives cancellation")
        XCTAssertTrue(records.dropFirst().allSatisfy { $0.resolution != nil },
                      "occurrences whose window has not opened are withdrawn")
        XCTAssertTrue(ledger.state.plans[plan.id]?.isCancelled == true)
    }

    func testInvalidPlansAreRejected() {
        var ledger = Ledger()
        let noDays = CommitmentPlan(title: "Nothing", requirement: .anyWorkout,
                                    weekdays: [], deadlineMinuteOfDay: 600,
                                    startDate: d(24), endDate: d(28),
                                    timeZoneIdentifier: "UTC",
                                    configuredCorrectionWindow: 3600,
                                    overridePolicy: patrickPolicy(), createdAt: d(23, 18))
        expectThrows { try ledger.append(.planCreated(noDays), at: d(23, 18)) }
    }
}

/// What a workout right now would actually count toward. `eligibleFrom` makes
/// "unresolved" and "live" different questions, and the UI needs the second one.
final class LiveCommitmentTests: XCTestCase {

    func testFutureOccurrencesArePendingButNotLive() throws {
        var ledger = Ledger()
        let plan = CommitmentPlan(title: "Run 30 min", requirement: .run(minutes: 30),
                                  weekdays: [2, 4, 6], deadlineMinuteOfDay: 10 * 60,
                                  startDate: d(24),
                                  endDate: CommitmentPlan.weeks(2, from: d(24),
                                                                timeZoneIdentifier: "UTC"),
                                  timeZoneIdentifier: "UTC",
                                  configuredCorrectionWindow: 2 * 3600,
                                  overridePolicy: patrickPolicy(), createdAt: d(23, 18))
        ledger.expectAppend(.planCreated(plan), at: plan.createdAt)
        for occurrence in plan.occurrences() {
            ledger.expectAppend(.commitmentCreated(occurrence), at: plan.createdAt)
        }

        // Monday morning: six occurrences exist, but only Monday's is live.
        XCTAssertEqual(ledger.state.pendingCommitments(now: d(24, 8)).count, 6)
        let live = ledger.state.liveCommitments(now: d(24, 8))
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.commitment.deadline, d(24, 10))
    }

    /// An overdue commitment is still live: a late workout is what clears it.
    func testOverdueCommitmentsStayLive() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6))),
            at: d(24, 6))
        XCTAssertTrue(ledger.state.pendingCommitments(now: d(24, 12)).isEmpty)
        XCTAssertEqual(ledger.state.liveCommitments(now: d(24, 12)).count, 1,
                       "a workout now still clears yesterday's debt")
    }

    func testResolvedCommitmentsAreNotLive() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 6))),
            at: d(24, 6))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 7), minutes: 30)), at: d(24, 8))
        XCTAssertTrue(ledger.state.liveCommitments(now: d(24, 9)).isEmpty)
    }
}
