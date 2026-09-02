import Foundation
import XCTest
@testable import EarnedKit

/// The windows must not move when nothing has happened.
///
/// `ShieldScheduler` caches the windows it last handed to the system and does
/// nothing when they have not changed, because re-registering DeviceActivity
/// schedules is a stop plus up to eight starts, each a synchronous round trip
/// to a system daemon — and it is driven by a one-second ticker. If the answer
/// is not stable second to second, that cache never hits and the app spends
/// every second of its life talking to the daemon on the main thread.
///
/// That is not a hypothetical: it is the shape of a freeze reported from a real
/// device, where Screen Time is granted and this path actually executes. The
/// simulator can never authorize Family Controls, so no simulator run can catch
/// it. These tests can.
final class ShieldWindowStabilityTests: XCTestCase {

    private let social = RestrictionProfile(["app:social"])

    /// A day like the reported one: hydration on with an hour's interval, one
    /// commitment due in the evening.
    private func realisticLedger(now: Date) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .hydrationConfigured(HydrationConfig(
                enabled: true,
                interval: 3600,
                activeHours: ActiveHours(startMinuteOfDay: 8 * 60,
                                         endMinuteOfDay: 22 * 60,
                                         timeZoneIdentifier: "UTC"),
                restrictions: social,
                warningLead: 600)),
            at: now)
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: UUID(),
                                              deadline: d(2, 20),
                                              createdAt: now,
                                              restrictions: social)),
            at: now)
        return ledger
    }

    /// The state a user is in the moment they finish setup without picking any
    /// apps: Hydration on, a commitment made, and every restriction profile
    /// empty. Nothing the clock does will ever change what is in force, so no
    /// window is ever appended — and the search used to have no other way to
    /// stop, because an enabled Hydration Gate always has another transition.
    ///
    /// On a device with Screen Time granted this ran on the main thread on the
    /// first ledger append and hung the app for good. It cannot be reproduced
    /// in the simulator, where Family Controls can never be authorized and the
    /// caller returns before reaching here. So it is pinned in the one place
    /// that can see it.
    func testEmptyProfilesTerminateInsteadOfWalkingIntoTheNextMillennium() {
        let now = d(2, 9)
        var ledger = Ledger()
        ledger.expectAppend(
            .hydrationConfigured(HydrationConfig(
                enabled: true,
                interval: 3600,
                activeHours: ActiveHours(startMinuteOfDay: 8 * 60,
                                         endMinuteOfDay: 22 * 60,
                                         timeZoneIdentifier: "UTC"),
                // Nothing picked — the whole point.
                restrictions: .none,
                warningLead: 600)),
            at: now)
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: UUID(), deadline: d(2, 20),
                                              createdAt: now, restrictions: .none)),
            at: now)

        // If this ever loops again the test times out rather than failing
        // fast, which is itself the signal.
        let windows = ledger.state.shieldWindows(from: now, limit: 8)
        XCTAssertTrue(windows.isEmpty,
                      "nothing is ever restricted, so there is nothing to schedule")
    }

    /// The same trap with no commitment at all — Hydration alone is enough to
    /// supply transitions forever.
    func testHydrationAloneWithNothingToBlockAlsoTerminates() {
        let now = d(2, 9)
        var ledger = Ledger()
        ledger.expectAppend(
            .hydrationConfigured(HydrationConfig(
                enabled: true,
                interval: 3600,
                activeHours: ActiveHours(startMinuteOfDay: 8 * 60,
                                         endMinuteOfDay: 22 * 60,
                                         timeZoneIdentifier: "UTC"),
                restrictions: .none,
                warningLead: nil)),
            at: now)

        XCTAssertTrue(ledger.state.shieldWindows(from: now, limit: 8).isEmpty)
    }

    /// And the bound must not cost a real schedule: a Gate that does restrict
    /// something still produces its windows.
    func testARealProfileStillProducesWindows() {
        let now = d(2, 9)
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: UUID(), deadline: d(2, 20),
                                              createdAt: now, restrictions: social)),
            at: now)

        let windows = ledger.state.shieldWindows(from: now, limit: 8)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.restrictions, social)
    }

    func testWindowsDoNotMoveAsTheClockTicks() {
        let start = d(2, 9)
        let ledger = realisticLedger(now: start)
        let reference = ledger.state.shieldWindows(from: start, limit: 8)

        // A minute of ticks, one second apart. Every one of these is a moment
        // the app recomputes and compares.
        for second in 1...60 {
            let later = start.addingTimeInterval(TimeInterval(second))
            XCTAssertEqual(ledger.state.shieldWindows(from: later, limit: 8), reference,
                           "windows changed \(second)s later with nothing having happened; "
                           + "ShieldScheduler's cache would miss on every tick")
        }
    }

    /// The same question asked where it is hardest: immediately either side of
    /// a transition. Crossing one legitimately changes the answer once — what
    /// must not happen is a different answer on every tick around it.
    func testWindowsAreStableEitherSideOfATransition() {
        let start = d(2, 9)
        let ledger = realisticLedger(now: start)
        let deadline = d(2, 20)

        let before = ledger.state.shieldWindows(from: deadline.addingTimeInterval(-120),
                                                limit: 8)
        for second in stride(from: -119, through: -1, by: 1) {
            let at = deadline.addingTimeInterval(TimeInterval(second))
            XCTAssertEqual(ledger.state.shieldWindows(from: at, limit: 8), before,
                           "windows moved \(second)s before the deadline")
        }

        let after = ledger.state.shieldWindows(from: deadline.addingTimeInterval(1), limit: 8)
        for second in stride(from: 2, through: 120, by: 1) {
            let at = deadline.addingTimeInterval(TimeInterval(second))
            XCTAssertEqual(ledger.state.shieldWindows(from: at, limit: 8), after,
                           "windows moved \(second)s after the deadline")
        }
    }
}
