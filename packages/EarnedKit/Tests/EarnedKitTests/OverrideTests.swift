import XCTest
@testable import EarnedKit

final class OverrideTests: XCTestCase {

    private func ledgerWithOverdueCommitment(
        id: UUID, policy: OverridePolicy = patrickPolicy()) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(22, 10),
                                              createdAt: d(21, 18), policy: policy)),
            at: d(21, 18))
        return ledger
    }

    // MARK: - Accountability Override (NORTHSTAR §23)

    func testAccountabilityThreshold() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))

        // One approval of the required two: nothing grants.
        ledger.expectAppend(
            .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 11, 5))
        XCTAssertNil(ledger.state.commitments[commitmentID]?.resolution)
        XCTAssertFalse(ledger.state.accessState(now: d(22, 11, 6)).isFull)

        // A partner cannot vote twice.
        expectThrows(.partnerAlreadyVoted(partnerID: "alice")) {
            try ledger.append(
                .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 11, 6))
        }

        // Second approval reaches the threshold: the override succeeds.
        ledger.expectAppend(
            .overrideApprovalRecorded(requestID: requestID, partnerID: "bob"), at: d(22, 11, 10))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .overridden(.accountability, at: d(22, 11, 10)))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 11, 11)).isFull)
    }

    func testDenialsDoNotGrantAndDuplicateRequestsRejected() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(
            .overrideDenialRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 11, 5))
        XCTAssertNil(ledger.state.commitments[commitmentID]?.resolution)

        expectThrows(.duplicateOverrideRequest(commitmentID: commitmentID)) {
            try ledger.append(.overrideRequested(id: UUID(), commitmentID: commitmentID), at: d(22, 11, 6))
        }
    }

    // MARK: - Solo Emergency Override (NORTHSTAR §25)

    func testSoloUnavailableUntilAccountabilityWindowElapses() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        // Request at 11:00; 30-minute accountability window → solo from 11:30.
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))

        expectThrows(.soloOverrideNotYetAvailable(availableAt: d(22, 11, 30))) {
            try ledger.append(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 20))
        }

        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))

        // ~10 minutes of friction on the first solo override.
        expectThrows(.soloOverrideFrictionIncomplete(completableAt: d(22, 11, 40))) {
            try ledger.append(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 35))
        }
        ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 40))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .overridden(.solo, at: d(22, 11, 40)))
    }

    // Repeated solo overrides escalate: ~10 min, then ~30, then ~60 (NORTHSTAR §25).
    func testSoloEscalation() throws {
        var ledger = Ledger()
        let expectedFriction: [TimeInterval] = [600, 1800, 3600]
        // Three commitments on consecutive days, each escaped via solo override.
        for (index, friction) in expectedFriction.enumerated() {
            let day = 22 + index
            let commitmentID = UUID()
            let requestID = UUID()
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: commitmentID, deadline: d(day, 10),
                                                  createdAt: d(day, 6))),
                at: d(day, 6))
            ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(day, 11))
            ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(day, 11, 30))

            let completable = d(day, 11, 30).addingTimeInterval(friction)
            expectThrows(.soloOverrideFrictionIncomplete(completableAt: completable)) {
                try ledger.append(
                    .soloOverrideCompleted(requestID: requestID),
                    at: completable.addingTimeInterval(-1))
            }
            ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: completable)
        }
    }

    // MARK: - Free Overrides (NORTHSTAR §22)

    private func completeCommitment(_ ledger: inout Ledger, day: Int) {
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(day, 20), createdAt: d(day, 6))),
            at: d(day, 6))
        ledger.expectAppend(.workoutRecorded(workout(start: d(day, 9), minutes: 30)), at: d(day, 10))
    }

    func testFreeOverrideEarnSpendAndCap() throws {
        var ledger = Ledger()
        // Earn one Free Override per 3 consecutive completions, store at most 2.
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 3, maxStored: 2)), at: d(1))

        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(1)), 0)
        // Spending with no balance is rejected.
        var probe = ledger
        let probeID = UUID()
        probe.expectAppend(
            .commitmentCreated(makeCommitment(id: probeID, deadline: d(2, 20), createdAt: d(1, 6))),
            at: d(1, 6))
        expectThrows(.insufficientFreeOverrides) {
            try probe.append(.freeOverrideSpent(commitmentID: probeID), at: d(1, 7))
        }

        // Three consecutive on-time completions → balance 1.
        for day in 2...4 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(5)), 1)

        // Three more → balance 2 (the cap).
        for day in 5...7 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(8)), 2)

        // Three more at the cap → forfeited, still 2.
        for day in 8...10 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(11)), 2)

        // Spend one: genuinely free — clears the obligation instantly, no
        // approval, no waiting.
        let overdueID = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: overdueID, deadline: d(11, 10), createdAt: d(11, 6))),
            at: d(11, 6))
        XCTAssertFalse(ledger.state.accessState(now: d(11, 12)).isFull)
        ledger.expectAppend(.freeOverrideSpent(commitmentID: overdueID), at: d(11, 12))
        XCTAssertEqual(ledger.state.commitments[overdueID]?.resolution,
                       .overridden(.free, at: d(11, 12)))
        XCTAssertTrue(ledger.state.accessState(now: d(11, 12, 1)).isFull)
        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(11, 13)), 1)
    }

    func testMissResetsStreak() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 3, maxStored: 2)), at: d(1))

        // Two completions, then a miss, then two more: never three consecutive.
        for day in 2...3 { completeCommitment(&ledger, day: day) }
        let missed = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: missed, deadline: d(4, 20), createdAt: d(4, 6))),
            at: d(4, 6))
        for day in 5...6 { completeCommitment(&ledger, day: day) }

        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(7)), 0)
        XCTAssertEqual(ledger.state.completionStreak(now: d(7)), 2)
    }

    // Non-reward-eligible commitments are invisible to the reward system
    // (Patrick's Hydration Gate does not participate; NORTHSTAR §22).
    func testRewardIneligibleCommitmentsDoNotCount() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 2, maxStored: 2)), at: d(1))
        completeCommitment(&ledger, day: 2)
        // A completed but reward-ineligible commitment must not advance the streak.
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(3, 20), createdAt: d(3, 6),
                                              rewardEligible: false)),
            at: d(3, 6))
        ledger.expectAppend(.workoutRecorded(workout(start: d(3, 9), minutes: 30)), at: d(3, 10))
        XCTAssertEqual(ledger.state.freeOverrideBalance(now: d(4)), 0)
        XCTAssertEqual(ledger.state.completionStreak(now: d(4)), 1)
    }

    // A workout completing the commitment moots any open override request.
    func testWorkoutMootsOpenRequest() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 11, 30), minutes: 30)), at: d(22, 12, 30))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .completed(at: d(22, 12)))
        XCTAssertNil(ledger.state.activeOverrideRequest(forCommitment: commitmentID))
        // Late approvals against a moot request are rejected.
        expectThrows(.overrideRequestAlreadyResolved(requestID)) {
            try ledger.append(
                .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 13))
        }
    }
}
