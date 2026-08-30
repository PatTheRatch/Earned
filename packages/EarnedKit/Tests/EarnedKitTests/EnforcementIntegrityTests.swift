import XCTest
@testable import EarnedKit

/// Enforcement integrity (NORTHSTAR §33).
///
/// Whether a Gate is satisfied and whether Earned can enforce it are two
/// different questions. Losing OS authority changes only the second. Every test
/// here exists to stop those collapsing back into one binary.
final class EnforcementIntegrityTests: XCTestCase {

    /// A commitment created 08:00, due 10:00, hardened from 08:15.
    private func overdueLedger(id: UUID = UUID()) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(.enforcementRestored, at: d(24, 7))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, title: "Run 30 minutes",
                                              deadline: d(24, 10), createdAt: d(24, 8))),
            at: d(24, 8))
        return ledger
    }

    // MARK: - Losing enforcement resolves nothing

    func testEnforcementLossDoesNotSatisfyAGate() throws {
        let id = UUID()
        var ledger = overdueLedger(id: id)
        XCTAssertTrue(ledger.state.accessState(now: d(24, 11)).isRestricted)

        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))

        XCTAssertNil(ledger.state.commitments[id]?.resolution,
                     "losing authority is not a resolution")
        XCTAssertTrue(ledger.state.accessState(now: d(24, 11)).isRestricted,
                      "the Gate is still unsatisfied; only enforcement changed")
        XCTAssertFalse(ledger.state.canEnforce)
        XCTAssertEqual(ledger.state.unenforceableGates(now: d(24, 11)).count, 1,
                       "still owed, and Earned knows it cannot act on it")
    }

    func testEnforcementLossDoesNotClearDebt() throws {
        var ledger = overdueLedger()
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 11)), 1)
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))
        XCTAssertEqual(ledger.state.workoutDebt(now: d(24, 11)), 1,
                       "debt survives the loss of the means to enforce it")
    }

    func testBypassNeitherAwardsNorSpendsAFreeOverride() throws {
        var ledger = overdueLedger()
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 1, maxStored: 2)), at: d(24, 9))
        let grantsBefore = ledger.state.freeOverrideGrants
        let balanceBefore = ledger.state.freeOverrideBalance

        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))

        XCTAssertEqual(ledger.state.freeOverrideGrants, grantsBefore)
        XCTAssertEqual(ledger.state.freeOverrideBalance, balanceBefore)
    }

    // MARK: - A bypass is not an Override

    /// The two exits must stay legible as different things: one resolved the
    /// obligation, the other left it standing.
    func testOverrideAndBypassRemainDistinctHistories() throws {
        let overriddenID = UUID()
        var overridden = Ledger()
        overridden.expectAppend(.enforcementRestored, at: d(24, 7))
        overridden.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 1, maxStored: 2)), at: d(24, 7, 30))
        overridden.expectAppend(
            .commitmentCreated(makeCommitment(id: overriddenID, deadline: d(24, 10),
                                              createdAt: d(24, 8))), at: d(24, 8))
        overridden.expectAppend(.freeOverrideEarned(id: UUID(), source: .migration), at: d(24, 10, 30))
        overridden.expectAppend(.freeOverrideSpent(commitmentID: overriddenID), at: d(24, 11))

        let bypassedID = UUID()
        var bypassed = overdueLedger(id: bypassedID)
        bypassed.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))

        // The override resolved the obligation and spent a grant.
        XCTAssertEqual(overridden.state.commitments[overriddenID]?.resolution,
                       .overridden(.free, at: d(24, 11)))
        XCTAssertEqual(overridden.state.workoutDebt(now: d(24, 12)), 0)
        XCTAssertTrue(overridden.state.enforcementBypasses.isEmpty)

        // The bypass resolved nothing and spent nothing.
        XCTAssertNil(bypassed.state.commitments[bypassedID]?.resolution)
        XCTAssertEqual(bypassed.state.workoutDebt(now: d(24, 12)), 1)
        XCTAssertEqual(bypassed.state.enforcementBypasses.count, 1)
        XCTAssertEqual(bypassed.state.enforcementBypasses.first?.outstandingCommitmentIDs,
                       [bypassedID])

        // And the trend metrics keep them apart.
        XCTAssertEqual(overridden.state.reliability(now: d(24, 12)).enforcementBypasses, 0)
        XCTAssertEqual(bypassed.state.reliability(now: d(24, 12)).enforcementBypasses, 1)
    }

    // MARK: - Streak

    func testDetectedBypassBreaksTheStreak() throws {
        var ledger = Ledger()
        ledger.expectAppend(.enforcementRestored, at: d(1))
        // Two on-time completions build a streak.
        for day in 2...3 {
            let id = UUID()
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: id, deadline: d(day, 20),
                                                  createdAt: d(day, 8))), at: d(day, 8))
            ledger.expectAppend(
                .workoutRecorded(workout(start: d(day, 9), minutes: 30)), at: d(day, 10))
        }
        XCTAssertEqual(ledger.state.rewardStreak(at: d(3, 12)), 2)

        // A hardened obligation outstanding, then enforcement disappears.
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(4, 10), createdAt: d(4, 8))), at: d(4, 8))
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(4, 11))

        XCTAssertEqual(ledger.state.rewardStreak(at: d(4, 12)), 0,
                       "a bypass breaks the streak even though it resolves nothing")
    }

    // MARK: - The guards the design turns on

    /// Losing authority with nothing hardened outstanding is not a failure —
    /// there was nothing to escape.
    func testLosingEnforcementWhileEverySatisfiedGateIsFineIsNotABypass() throws {
        var ledger = Ledger()
        ledger.expectAppend(.enforcementRestored, at: d(24, 7))
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(24, 7, 30))
        ledger.expectAppend(.waterAcknowledged, at: d(24, 9))
        XCTAssertTrue(ledger.state.accessState(now: d(24, 9, 30)).isFullAccess)

        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 9, 30))

        XCTAssertTrue(ledger.state.enforcementBypasses.isEmpty,
                      "no obligation was outstanding, so nothing was bypassed")
        XCTAssertEqual(ledger.state.rewardStreak(at: d(24, 9, 30)), 0)
        XCTAssertFalse(ledger.state.canEnforce, "but Earned still cannot enforce")
    }

    /// A user who never granted Screen Time has not taken anything away.
    func testNeverHavingEnforcementIsNotABypass() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(deadline: d(24, 10), createdAt: d(24, 8))), at: d(24, 8))
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))

        XCTAssertTrue(ledger.state.enforcementBypasses.isEmpty)
        XCTAssertEqual(ledger.state.enforcementStatus, .unavailable)
    }

    /// The app polls on every launch and foreground. One revocation must not
    /// mint a bypass per launch.
    func testRepeatedDetectionRecordsOneBypass() throws {
        var ledger = overdueLedger()
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 12))
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 13))
        XCTAssertEqual(ledger.state.enforcementBypasses.count, 1)
        XCTAssertEqual(ledger.state.enforcementBypasses.first?.detectedAt, d(24, 11))
    }

    // MARK: - Restoring

    func testRestoringEnforcementReappliesWhatIsStillUnsatisfied() throws {
        let id = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.enforcementRestored, at: d(24, 7))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(24, 10), createdAt: d(24, 8),
                                              restrictions: exerciseProfile)), at: d(24, 8))
        let owed = ledger.state.accessState(now: d(24, 11)).effectiveRestrictions

        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))
        ledger.expectAppend(.enforcementRestored, at: d(24, 13))

        XCTAssertTrue(ledger.state.canEnforce)
        XCTAssertNil(ledger.state.commitments[id]?.resolution, "still owed")
        XCTAssertEqual(ledger.state.accessState(now: d(24, 13)).effectiveRestrictions, owed,
                       "the same restrictions are implied again, unchanged by the gap")
        XCTAssertEqual(ledger.state.enforcementBypasses.first?.resolvedAt, d(24, 13),
                       "the gap is closed in history, not erased from it")
        XCTAssertNil(ledger.state.ongoingEnforcementBypass)
        XCTAssertEqual(ledger.state.rewardStreak(at: d(24, 13)), 0,
                       "restoring enforcement does not un-break the streak")
    }

    /// Replay must reach the same conclusion — a bypass is derived from prior
    /// state during `applying`, so it has to survive a round trip.
    func testBypassSurvivesReplay() throws {
        var ledger = overdueLedger()
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(24, 11))
        let replayed = try Ledger(replaying: ledger.entries)
        XCTAssertEqual(replayed.state, ledger.state)
        XCTAssertEqual(replayed.state.enforcementBypasses.count, 1)
    }
}
