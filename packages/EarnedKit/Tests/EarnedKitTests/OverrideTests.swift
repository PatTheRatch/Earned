import XCTest
@testable import EarnedKit

final class OverrideTests: XCTestCase {

    private func ledgerWithOverdueCommitment(
        id: UUID, policy: OverridePolicy = patrickPolicy()) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(22),
                                              deadline: d(22, 10),
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

        ledger.expectAppend(
            .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 11, 5))
        XCTAssertNil(ledger.state.commitments[commitmentID]?.resolution)
        XCTAssertTrue(ledger.state.accessState(now: d(22, 11, 6)).isRestricted)

        expectThrows(.partnerAlreadyVoted(partnerID: "alice")) {
            try ledger.append(
                .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 11, 6))
        }

        ledger.expectAppend(
            .overrideApprovalRecorded(requestID: requestID, partnerID: "bob"), at: d(22, 11, 10))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .overridden(.accountability, at: d(22, 11, 10)))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 11, 11)).isFullAccess)
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

    // MARK: - Solo Emergency Override: ACTIVE friction (NORTHSTAR §25)

    func testSoloUnavailableUntilAccountabilityWindowElapses() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))

        expectThrows(.soloOverrideNotYetAvailable(availableAt: d(22, 11, 30))) {
            try ledger.append(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 20))
        }
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))
    }

    /// **The correction.** Waiting out the clock is not enough: without recorded
    /// effort the override does not complete, however long the user waits.
    func testElapsedTimeAloneDoesNotCompleteSolo() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))

        // Hours later, with no effort recorded at all.
        expectThrows {
            try ledger.append(.soloOverrideCompleted(requestID: requestID), at: d(22, 18))
        }
        XCTAssertNil(ledger.state.commitments[commitmentID]?.resolution)
        XCTAssertTrue(ledger.state.accessState(now: d(22, 18)).isRestricted)
    }

    /// Effort alone is not enough either: the elapsed floor still applies, so
    /// the challenge cannot be spammed through in seconds.
    func testEffortAloneDoesNotCompleteSoloBeforeTheFloor() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))

        let requirement = ledger.state.overrideRequests[requestID]!.soloRequirement!
        ledger.expectAppend(
            .soloOverrideProgressRecorded(requestID: requestID, units: requirement.effortUnits),
            at: d(22, 11, 31))

        expectThrows {
            try ledger.append(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 32))
        }
        // Once the floor has passed too, it completes.
        ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 41))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution,
                       .overridden(.solo, at: d(22, 11, 41)))
    }

    func testSoloCompletesWithBothEffortAndTime() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))
        ledger.completeSoloFriction(requestID: requestID, startedAt: d(22, 11, 30))

        let request = ledger.state.overrideRequests[requestID]!
        XCTAssertEqual(request.soloUnitsRemaining, 0)
        ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: d(22, 11, 45))
        XCTAssertNotNil(ledger.state.commitments[commitmentID]?.resolution)
    }

    /// Repeated escapes get materially more expensive, in effort and in time.
    func testSoloEscalation() throws {
        var ledger = Ledger()
        let expected = FrictionRequirement.defaultEscalation

        for (index, requirement) in expected.enumerated() {
            let day = 22 + index
            let commitmentID = UUID(), requestID = UUID()
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: commitmentID, eligibleFrom: d(day),
                                                  deadline: d(day, 10), createdAt: d(day, 6))),
                at: d(day, 6))
            ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(day, 11))
            ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(day, 11, 30))

            let frozen = ledger.state.overrideRequests[requestID]!.soloRequirement!
            XCTAssertEqual(frozen, requirement, "escalation step \(index)")

            ledger.completeSoloFriction(requestID: requestID, startedAt: d(day, 11, 30))
            let completable = d(day, 11, 30).addingTimeInterval(requirement.minimumElapsed)
            ledger.expectAppend(.soloOverrideCompleted(requestID: requestID), at: completable)
        }
    }

    /// The requirement is frozen when the challenge starts, so an edit made
    /// mid-challenge cannot make an in-flight escape cheaper.
    func testFrictionRequirementIsFrozenAtStart() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.soloOverrideStarted(requestID: requestID), at: d(22, 11, 30))
        let frozen = ledger.state.overrideRequests[requestID]!.soloRequirement
        XCTAssertEqual(frozen, FrictionRequirement.defaultEscalation[0])
        XCTAssertEqual(ledger.state.soloFriction(forRequest: requestID, ifStartedAt: d(22, 12)), frozen)
    }

    func testProgressBeforeStartIsRejected() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        expectThrows(.soloOverrideNotStarted(requestID)) {
            try ledger.append(.soloOverrideProgressRecorded(requestID: requestID, units: 10), at: d(22, 11, 5))
        }
    }

    // MARK: - Free Overrides as immutable events (NORTHSTAR §22)

    private func completeCommitment(_ ledger: inout Ledger, day: Int) {
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(day),
                                              deadline: d(day, 20), createdAt: d(day, 6))),
            at: d(day, 6))
        ledger.expectAppend(.workoutRecorded(workout(start: d(day, 9), minutes: 30)), at: d(day, 10))
    }

    func testEarningSpendingAndTheCap() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 3, maxStored: 2)), at: d(1))
        XCTAssertEqual(ledger.state.freeOverrideBalance, 0)

        // Spending with no balance is refused.
        var probe = ledger
        let probeID = UUID()
        probe.expectAppend(
            .commitmentCreated(makeCommitment(id: probeID, deadline: d(2, 20), createdAt: d(1, 6))),
            at: d(1, 6))
        expectThrows(.insufficientFreeOverrides) {
            try probe.append(.freeOverrideSpent(commitmentID: probeID), at: d(1, 7))
        }

        // Three consecutive on-time completions mint exactly one grant, as a
        // real ledger event.
        for day in 2...4 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 1)
        let earned = ledger.entries.filter {
            if case .freeOverrideEarned = $0.event { return true }
            return false
        }
        XCTAssertEqual(earned.count, 1)

        for day in 5...7 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 2)

        // Earning at the cap is forfeited, not banked.
        for day in 8...10 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 2)

        // Spending clears an obligation instantly.
        let overdueID = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: overdueID, eligibleFrom: d(11),
                                              deadline: d(11, 10), createdAt: d(11, 6))),
            at: d(11, 6))
        XCTAssertTrue(ledger.state.accessState(now: d(11, 12)).isRestricted)
        ledger.expectAppend(.freeOverrideSpent(commitmentID: overdueID), at: d(11, 12))
        XCTAssertEqual(ledger.state.commitments[overdueID]?.resolution,
                       .overridden(.free, at: d(11, 12)))
        XCTAssertTrue(ledger.state.accessState(now: d(11, 12, 1)).isFullAccess)
        XCTAssertEqual(ledger.state.freeOverrideBalance, 1)
    }

    /// **The loophole this closes.** Lowering the streak threshold later must
    /// not retroactively mint rewards for completions already in the past.
    func testPolicyChangeCannotMintRetroactively() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 10, maxStored: 5)), at: d(1))
        for day in 2...5 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 0, "streak of 4 < threshold of 10")

        // Full access, nothing hardened outstanding → easing is permitted.
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 2, maxStored: 5)), at: d(6))
        XCTAssertEqual(ledger.state.freeOverrideBalance, 0,
                       "past completions must not retroactively earn under the new threshold")

        // It governs future earning only.
        for day in 7...8 { completeCommitment(&ledger, day: day) }
        XCTAssertEqual(ledger.state.freeOverrideBalance, 1)
    }

    /// Easing the reward policy is blocked while restricted — otherwise a locked
    /// user could lower the threshold to manufacture an escape.
    func testEasingRewardPolicyBlockedWhileRestricted() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 5, maxStored: 2)), at: d(1))
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(22),
                                              deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))

        // Overdue → restricted.
        expectThrows {
            try ledger.append(.rewardPolicyConfigured(
                RewardPolicy(streakThreshold: 1, maxStored: 2)), at: d(22, 11))
        }
        // Stricter is always allowed, even while locked.
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 8, maxStored: 1)), at: d(22, 11))
    }

    /// A hardened unresolved commitment blocks easing even at full access.
    func testEasingBlockedByHardenedOutstandingCommitment() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 5, maxStored: 2)), at: d(1))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(29, 10), createdAt: d(24, 8))), at: d(24, 8))
        // Hardened at 10:00, not yet due → full access but a contract is live.
        XCTAssertTrue(ledger.state.accessState(now: d(24, 11)).isFullAccess)
        expectThrows {
            try ledger.append(.rewardPolicyConfigured(
                RewardPolicy(streakThreshold: 2, maxStored: 2)), at: d(24, 11))
        }
    }

    func testMissResetsStreak() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 3, maxStored: 2)), at: d(1))
        for day in 2...3 { completeCommitment(&ledger, day: day) }
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(eligibleFrom: d(4), deadline: d(4, 20), createdAt: d(4, 6))),
            at: d(4, 6))
        for day in 5...6 { completeCommitment(&ledger, day: day) }

        XCTAssertEqual(ledger.state.freeOverrideBalance, 0)
        XCTAssertEqual(ledger.state.completionStreak(now: d(7)), 2)
    }

    func testRewardIneligibleCommitmentsDoNotCount() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 2, maxStored: 2)), at: d(1))
        completeCommitment(&ledger, day: 2)
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, eligibleFrom: d(3), deadline: d(3, 20),
                                              createdAt: d(3, 6), rewardEligible: false)),
            at: d(3, 6))
        ledger.expectAppend(.workoutRecorded(workout(start: d(3, 9), minutes: 30)), at: d(3, 10))
        XCTAssertEqual(ledger.state.freeOverrideBalance, 0)
        XCTAssertEqual(ledger.state.completionStreak(now: d(4)), 1)
    }

    func testWorkoutMootsOpenRequest() throws {
        let commitmentID = UUID()
        var ledger = ledgerWithOverdueCommitment(id: commitmentID)
        let requestID = UUID()
        ledger.expectAppend(.overrideRequested(id: requestID, commitmentID: commitmentID), at: d(22, 11))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 11, 30), minutes: 30)), at: d(22, 12, 30))
        XCTAssertEqual(ledger.state.commitments[commitmentID]?.resolution, .completed(at: d(22, 12)))
        XCTAssertNil(ledger.state.activeOverrideRequest(forCommitment: commitmentID))
        expectThrows(.overrideRequestAlreadyResolved(requestID)) {
            try ledger.append(
                .overrideApprovalRecorded(requestID: requestID, partnerID: "alice"), at: d(22, 13))
        }
    }
}
