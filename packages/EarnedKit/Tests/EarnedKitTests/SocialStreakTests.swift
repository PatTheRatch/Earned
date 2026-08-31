import XCTest
@testable import EarnedKit

/// The two numbers the social layer may present (docs/social-architecture.md
/// §8, settled semantics): consecutive on-time completions, and completions
/// since the most recent Override. Two figures, never one score — an Override
/// annotates the second without erasing the first.
final class SocialStreakTests: XCTestCase {

    /// A ledger holding one commitment per (deadline, createdAt) pair given,
    /// each eligible only from midnight of its own deadline day — like plan
    /// occurrences, so one workout cannot satisfy the whole week at once and
    /// each day's outcome is its own.
    private func ledger(commitments: [(id: UUID, deadline: Date, createdAt: Date)]) -> Ledger {
        var ledger = Ledger()
        for entry in commitments {
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: entry.id,
                                                  eligibleFrom: entry.deadline.addingTimeInterval(-10 * 3600),
                                                  deadline: entry.deadline,
                                                  createdAt: entry.createdAt)),
                at: entry.createdAt)
        }
        return ledger
    }

    func testOnTimeCompletionsAccumulate() throws {
        let a = UUID(), b = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8)), (b, d(23, 10), d(21, 8))])
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))
        ledger.expectAppend(.workoutRecorded(workout(start: d(23, 8), minutes: 30)), at: d(23, 9))

        let streaks = ledger.state.socialStreaks(now: d(23, 12))
        XCTAssertEqual(streaks.commitmentsKept, 2)
        XCTAssertNil(streaks.sinceLastOverride, "no Override ever — nil, not zero")
    }

    func testLateCompletionBreaksTheOnTimeStreak() throws {
        let a = UUID(), b = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8)), (b, d(23, 10), d(21, 8))])
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))
        // B is completed six hours past its deadline: the debt clears, the
        // on-time streak does not survive. Both facts, both recorded.
        ledger.expectAppend(.workoutRecorded(workout(start: d(23, 15), minutes: 30)), at: d(23, 16))

        XCTAssertEqual(ledger.state.socialStreaks(now: d(23, 18)).commitmentsKept, 0)
    }

    func testAMissedDeadlineStillOpenBreaksIt() throws {
        let a = UUID(), b = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8)), (b, d(23, 10), d(21, 8))])
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))

        XCTAssertEqual(ledger.state.socialStreaks(now: d(22, 12)).commitmentsKept, 1,
                       "before B's deadline the streak stands")
        XCTAssertEqual(ledger.state.socialStreaks(now: d(23, 12)).commitmentsKept, 0,
                       "past it, unresolved, the streak is gone")
    }

    func testAnOverrideDoesNotEraseTheCommitmentStreak() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8)),
                                          (b, d(23, 10), d(21, 8)),
                                          (c, d(24, 10), d(21, 8))])
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 99, maxStored: 2)), at: d(21, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))
        // B is resolved through a Free Override — a route the contract
        // contains, used legitimately, before its deadline passes.
        ledger.expectAppend(.freeOverrideEarned(id: UUID(), source: .migration), at: d(22, 10))
        ledger.expectAppend(.freeOverrideSpent(commitmentID: b), at: d(22, 11))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 8), minutes: 30)), at: d(24, 9))

        let streaks = ledger.state.socialStreaks(now: d(24, 12))
        XCTAssertEqual(streaks.commitmentsKept, 2,
                       "the Override neither advances nor resets the kept count")
        XCTAssertEqual(streaks.sinceLastOverride, 1,
                       "and the second figure counts completions since it: C only")
    }

    func testSinceLastOverrideCountsLateCompletionsToo() throws {
        let a = UUID(), b = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8)), (b, d(23, 10), d(21, 8))])
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 99, maxStored: 2)), at: d(21, 8))
        ledger.expectAppend(.freeOverrideEarned(id: UUID(), source: .migration), at: d(21, 9))
        ledger.expectAppend(.freeOverrideSpent(commitmentID: a), at: d(22, 9))
        // B completed late: breaks the on-time streak, still a completion
        // "since last Override" — the promise was kept, just not on time.
        ledger.expectAppend(.workoutRecorded(workout(start: d(23, 15), minutes: 30)), at: d(23, 16))

        let streaks = ledger.state.socialStreaks(now: d(23, 18))
        XCTAssertEqual(streaks.commitmentsKept, 0)
        XCTAssertEqual(streaks.sinceLastOverride, 1)
    }

    func testABypassBreaksKeptButIsNotAnOverride() throws {
        let a = UUID(), b = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.enforcementRestored, at: d(21, 7))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: a, eligibleFrom: d(22, 0), deadline: d(22, 10),
                                              createdAt: d(21, 8))), at: d(21, 8))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: b, eligibleFrom: d(24, 0), deadline: d(24, 10),
                                              createdAt: d(21, 8))), at: d(21, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))
        // Enforcement goes away while the hardened B is still unresolved — a
        // recorded lapse, and a streak is a claim about honouring commitments
        // (NORTHSTAR §33).
        ledger.expectAppend(.enforcementUnavailableDetected, at: d(23, 9))

        let streaks = ledger.state.socialStreaks(now: d(23, 12))
        XCTAssertEqual(streaks.commitmentsKept, 0, "a bypass breaks the kept count")
        XCTAssertNil(streaks.sinceLastOverride,
                     "and it is not an Override — the override clock never started")
    }

    func testEarningARewardDoesNotResetTheSocialCount() throws {
        // The reward streak resets when a Free Override is earned, because the
        // reward consumes it. The social figure owes nobody a reset for being
        // rewarded — that is why it is a separate query.
        let ids = (0..<3).map { _ in UUID() }
        var ledger = ledger(commitments: [(ids[0], d(22, 10), d(21, 8)),
                                          (ids[1], d(23, 10), d(21, 8)),
                                          (ids[2], d(24, 10), d(21, 8))])
        ledger.expectAppend(
            .rewardPolicyConfigured(RewardPolicy(streakThreshold: 2, maxStored: 2)), at: d(21, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))
        ledger.expectAppend(.workoutRecorded(workout(start: d(23, 8), minutes: 30)), at: d(23, 9))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 8), minutes: 30)), at: d(24, 9))

        XCTAssertEqual(ledger.state.socialStreaks(now: d(24, 12)).commitmentsKept, 3)
        XCTAssertLessThan(ledger.state.completionStreak(now: d(24, 12)), 3,
                          "while the reward streak did reset at the threshold")
    }

    func testCancelledCommitmentsAreInvisibleToBothFigures() throws {
        let a = UUID(), b = UUID()
        var ledger = ledger(commitments: [(a, d(22, 10), d(21, 8))])
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: b, deadline: d(23, 10), createdAt: d(21, 8),
                                              correctionWindow: 48 * 3600)), at: d(21, 8))
        ledger.expectAppend(.commitmentCancelled(id: b), at: d(21, 9))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8), minutes: 30)), at: d(22, 9))

        XCTAssertEqual(ledger.state.socialStreaks(now: d(23, 12)).commitmentsKept, 1,
                       "a cancellation inside the correction window never counts as a miss")
    }
}
