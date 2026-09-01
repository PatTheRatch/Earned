import Foundation
import XCTest
@testable import EarnedKit

/// Knowing when the shield must change, before it has to change.
///
/// The app can only enforce while it is running, and a commitment app nobody
/// opens is a commitment app that blocks nothing. These windows are what a
/// system extension is handed so the deadline lands whether Earned is running
/// or not.
final class ShieldWindowTests: XCTestCase {

    private let social = RestrictionProfile(["app:social"])
    private let games = RestrictionProfile(["app:games"])

    private func commitment(_ id: UUID, deadline: Date,
                            restrictions: RestrictionProfile) -> Commitment {
        makeCommitment(id: id, deadline: deadline, createdAt: d(21, 18),
                       restrictions: restrictions)
    }

    // MARK: - The boundary that would have made this do nothing

    func testAWindowCarriesTheRestrictionsThatBeginAtIt() throws {
        // A Gate closes strictly *after* its deadline. Ask at the exact
        // instant and you get the state that is ending — an empty profile —
        // so every window would schedule faithfully and shield nothing.
        let id = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(commitment(id, deadline: d(22, 10),
                                                          restrictions: social)),
                            at: d(21, 18))

        let windows = ledger.state.shieldWindows(from: d(22, 8))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.opensAt, d(22, 10))
        XCTAssertEqual(windows.first?.restrictions, social,
                       "the window must carry what the deadline imposes, not what precedes it")

        // Stated directly, because it is the assumption the epsilon encodes.
        XCTAssertTrue(ledger.state.accessState(now: d(22, 10)).effectiveRestrictions.tokens.isEmpty,
                      "at the deadline exactly, nothing is overdue yet")
    }

    // MARK: - What gets scheduled, and what does not

    func testTwoDeadlinesAccumulateIntoOneUnion() throws {
        let first = UUID(), second = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(commitment(first, deadline: d(22, 10),
                                                          restrictions: social)),
                            at: d(21, 18))
        ledger.expectAppend(.commitmentCreated(commitment(second, deadline: d(22, 14),
                                                          restrictions: games)),
                            at: d(21, 18))

        let windows = ledger.state.shieldWindows(from: d(22, 8))
        XCTAssertEqual(windows.map(\.opensAt), [d(22, 10), d(22, 14)])
        XCTAssertEqual(windows[0].restrictions, social)
        // The second deadline does not replace the first: a Gate left open
        // stays shut, so the second window is the union of both.
        XCTAssertEqual(windows[1].restrictions,
                       RestrictionProfile(social.tokens.union(games.tokens)))
    }

    func testATransitionThatChangesNothingIsNotScheduled() throws {
        // Two commitments restricting exactly the same apps. The second
        // deadline changes no setting, and waking the device to rewrite what
        // is already written spends a scheduling slot to accomplish nothing.
        let first = UUID(), second = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(commitment(first, deadline: d(22, 10),
                                                          restrictions: social)),
                            at: d(21, 18))
        ledger.expectAppend(.commitmentCreated(commitment(second, deadline: d(22, 14),
                                                          restrictions: social)),
                            at: d(21, 18))

        XCTAssertEqual(ledger.state.shieldWindows(from: d(22, 8)).map(\.opensAt), [d(22, 10)])
    }

    func testAlreadyShieldedIsNotRescheduled() throws {
        // Generated after the deadline has passed: the shield is already in
        // force, and the first window must not repeat what is applied — or a
        // plan regenerated on every foreground would grow a duplicate each
        // time.
        let id = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(commitment(id, deadline: d(22, 10),
                                                          restrictions: social)),
                            at: d(21, 18))
        XCTAssertEqual(ledger.state.shieldWindows(from: d(22, 11)), [])
    }

    func testASatisfiedCommitmentSchedulesNothing() throws {
        let id = UUID()
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, requirement: .anyWorkout,
                                              deadline: d(22, 10), createdAt: d(21, 18),
                                              restrictions: social)),
            at: d(21, 18))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 7), minutes: 30)),
                            at: d(22, 7, 40))
        XCTAssertEqual(ledger.state.shieldWindows(from: d(22, 8)), [],
                       "nothing is owed, so nothing needs waking for")
    }

    // MARK: - Bounds

    func testTheListIsBoundedAndOrdered() throws {
        var ledger = Ledger()
        // Twelve distinct restriction sets, so no two windows collapse.
        for hour in 1...12 {
            ledger.expectAppend(
                .commitmentCreated(commitment(UUID(), deadline: d(22, hour),
                                              restrictions: RestrictionProfile(["app:\(hour)"]))),
                at: d(21, 18))
        }
        let windows = ledger.state.shieldWindows(from: d(22), limit: 4)
        XCTAssertEqual(windows.count, 4, "the system caps concurrent monitoring; so does this")
        XCTAssertEqual(windows.map(\.opensAt), [d(22, 1), d(22, 2), d(22, 3), d(22, 4)])
        XCTAssertEqual(ledger.state.shieldWindows(from: d(22), limit: 0), [])
    }

    func testAnEmptyLedgerNeedsNoSchedule() throws {
        XCTAssertEqual(Ledger().state.shieldWindows(from: d(22)), [])
    }

    func testGeneratingTwiceGivesTheSameAnswer() throws {
        // The plan is rewritten on every ledger change and every foreground.
        // If it were not stable, each rewrite would churn the system's
        // schedules for no reason.
        let id = UUID()
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(commitment(id, deadline: d(22, 10),
                                                          restrictions: social)),
                            at: d(21, 18))
        XCTAssertEqual(ledger.state.shieldWindows(from: d(22, 8)),
                       ledger.state.shieldWindows(from: d(22, 8)))
    }
}
