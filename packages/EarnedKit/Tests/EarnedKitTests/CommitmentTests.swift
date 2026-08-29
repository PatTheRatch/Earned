import XCTest
@testable import EarnedKit

final class CommitmentTests: XCTestCase {

    // NORTHSTAR §11: correction window = min(configured, fraction of time-to-deadline).
    func testHardeningWindow() {
        // Created Monday 08:00, due Saturday 10:00, 2h window → hardens at +2h.
        let longFuse = makeCommitment(deadline: d(29, 10), createdAt: d(24, 8))
        XCTAssertEqual(longFuse.hardensAt, d(24, 10))

        // Created 08:00, due 10:00 (2h away), 2h window → 2h × 1/8 = 15 min.
        let shortFuse = makeCommitment(deadline: d(24, 10), createdAt: d(24, 8))
        XCTAssertEqual(shortFuse.hardensAt, d(24, 8, 15))
        XCTAssertFalse(shortFuse.isHardened(at: d(24, 8, 14)))
        XCTAssertTrue(shortFuse.isHardened(at: d(24, 8, 15)))
    }

    // NORTHSTAR §12: pre-hardening edits are free; hardened commitments may only
    // become harder.
    func testMonotonicity() throws {
        var ledger = Ledger()
        let id = UUID()
        let commitment = makeCommitment(
            id: id, title: "Run 30 minutes",
            requirement: .anyWorkout(minimumDuration: 30 * 60),
            deadline: d(29, 10), createdAt: d(24, 8))
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))

        // Pre-hardening (hardens at 10:00): making it easier is allowed.
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(requirement: .anyWorkout(minimumDuration: 20 * 60))),
            at: d(24, 9))

        // Post-hardening: easier edits rejected in every dimension.
        expectThrows { // decrease duration
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(requirement: .anyWorkout(minimumDuration: 10 * 60))),
                at: d(24, 11))
        }
        expectThrows { // extend deadline
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(deadline: d(30, 10))), at: d(24, 11))
        }
        expectThrows { // weaken escape rules (NORTHSTAR §26)
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(overridePolicy: patrickPolicy(approvals: 1))),
                at: d(24, 11))
        }
        expectThrows { // shorten accountability window
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(overridePolicy: patrickPolicy(window: 60))),
                at: d(24, 11))
        }
        expectThrows { // requirement dimension change is incomparable
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(requirement: .run(kilometers: 5))),
                at: d(24, 11))
        }
        expectThrows { // weaken to anyWorkout
            try ledger.append(
                .commitmentEdited(id: id, edit: CommitmentEdit(requirement: .anyWorkout)), at: d(24, 11))
        }

        // Harder edits are always allowed (NORTHSTAR §39.3).
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: .anyWorkout(minimumDuration: 40 * 60),
                deadline: d(28, 10),
                overridePolicy: patrickPolicy(approvals: 3, window: 3600))),
            at: d(24, 12))
        XCTAssertEqual(ledger.state.commitments[id]?.commitment.requirement, .anyWorkout(minimumDuration: 40 * 60))
    }

    // Cancellation only during the correction window.
    func testCancellation() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        expectThrows(.cancellationAfterHardening(id)) {
            try ledger.append(.commitmentCancelled(id: id), at: d(24, 11))
        }

        var early = Ledger()
        let id2 = UUID()
        early.expectAppend(
            .commitmentCreated(makeCommitment(id: id2, deadline: d(29, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        early.expectAppend(.commitmentCancelled(id: id2), at: d(24, 9))
        XCTAssertEqual(early.state.commitments[id2]?.resolution, .cancelled(at: d(24, 9)))
    }


    // NORTHSTAR §14: 18 morning minutes + 12 evening minutes completes a
    // 30-minute commitment; partial progress does not.
    func testProgressAccumulation() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id, title: "Run 30 minutes",
                requirement: .anyWorkout(minimumDuration: 30 * 60),
                deadline: d(24, 22), createdAt: d(24, 8))),
            at: d(24, 8))

        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 18)), at: d(24, 9, 30))
        XCTAssertNil(ledger.state.commitments[id]?.resolution)
        let progress = ledger.state.progress(for: id)
        XCTAssertEqual(progress?.achieved, 18 * 60)
        XCTAssertEqual(progress?.required, 30 * 60)

        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 18), minutes: 12)), at: d(24, 18, 30))
        XCTAssertEqual(ledger.state.commitments[id]?.resolution,
                       .completed(at: d(24, 18, 12)))
    }



    // Duplicate workout deliveries (HealthKit re-sync) are no-ops.
    func testDuplicateWorkoutIgnored() throws {
        var ledger = Ledger()
        let sameID = UUID()
        let run = workout(start: d(24, 9), minutes: 30, id: sameID)
        ledger.expectAppend(.workoutRecorded(run), at: d(24, 10))
        ledger.expectAppend(.workoutRecorded(run), at: d(24, 10, 5))
        XCTAssertEqual(ledger.state.workouts.count, 1)
    }

    func testInvalidCommitmentsRejected() {
        var ledger = Ledger()
        expectThrows { // deadline in the past
            try ledger.append(
                .commitmentCreated(makeCommitment(deadline: d(24, 7), createdAt: d(24, 8))), at: d(24, 8))
        }
        expectThrows { // zero approvals forbidden (NORTHSTAR §26)
            try ledger.append(
                .commitmentCreated(makeCommitment(
                    deadline: d(29), createdAt: d(24, 8), policy: patrickPolicy(approvals: 0))),
                at: d(24, 8))
        }
        expectThrows { // non-positive requirement
            try ledger.append(
                .commitmentCreated(makeCommitment(
                    requirement: .anyWorkout(minimumDuration: 0), deadline: d(29), createdAt: d(24, 8))),
                at: d(24, 8))
        }
    }
}
