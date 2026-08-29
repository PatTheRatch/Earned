import XCTest
@testable import EarnedKit

final class HydrationTests: XCTestCase {

    /// **The window opens unsatisfied.** No free interval at the start of the
    /// day: from 08:00 the gate is closed until water is acknowledged
    /// (NORTHSTAR §18).
    func testWindowOpensUnsatisfied() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))

        // 07:59 — before the window, dormant.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 7, 59)), .dormant)

        // 08:00 — window opens closed, restrictions apply immediately.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 8)), .unsatisfied(since: d(22, 8)))
        let access = ledger.state.accessState(now: d(22, 8))
        XCTAssertTrue(access.isRestricted)
        XCTAssertEqual(access.effectiveRestrictions, hydrationProfile)

        // 08:07 — acknowledged; the rolling interval starts here.
        ledger.expectAppend(.waterAcknowledged, at: d(22, 8, 7))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 8, 8)),
                       .satisfied(expiresAt: d(22, 9, 7)))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 8, 8)).isFullAccess)

        // 09:07 — expired, closed again.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 9, 7)), .unsatisfied(since: d(22, 9, 7)))
    }

    /// Yesterday's water does not open today: an acknowledgment before the
    /// current window's open does not count.
    func testYesterdaysAcknowledgmentDoesNotCarryOver() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 21, 55))

        // Overnight: dormant.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(23, 3)), .dormant)
        XCTAssertTrue(ledger.state.accessState(now: d(23, 3)).isFullAccess)

        // Next morning opens closed, even though water was drunk five minutes
        // before last night's window shut.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(23, 8)), .unsatisfied(since: d(23, 8)))
    }

    func testRollingTimerAcrossTheDay() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 8))

        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 8, 30)), .satisfied(expiresAt: d(22, 9)))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 9)), .unsatisfied(since: d(22, 9)))

        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 17))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 9, 18)),
                       .satisfied(expiresAt: d(22, 10, 17)))
    }

    /// An expired gate goes dormant when the window closes; the day's debt does
    /// not carry over (only exercise carries debt).
    func testUnsatisfiedGateReleasesAtWindowClose() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 21, 59)), .unsatisfied(since: d(22, 8)))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 22)), .dormant)
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 21)), d(22, 22))
    }

    /// Dormant → the next window opening closes the gate, so that is the next
    /// transition worth scheduling.
    func testNextTransitionFromDormantIsTheWindowOpening() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 20))
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 23)), d(23, 8))
    }

    func testEasierConfigRequiresSatisfiedGate() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(interval: 3600)), at: d(22, 7))

        // 09:30, never acknowledged today → unsatisfied.
        expectThrows(.hydrationEasierWhileUnsatisfied) {
            try ledger.append(.hydrationConfigured(patrickHydration(interval: 7200)), at: d(22, 9, 30))
        }
        // Harder (shorter interval) is fine even while unsatisfied.
        ledger.expectAppend(.hydrationConfigured(patrickHydration(interval: 1800)), at: d(22, 9, 31))

        // After acknowledging, easier is allowed.
        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 40))
        ledger.expectAppend(.hydrationConfigured(patrickHydration(interval: 7200)), at: d(22, 9, 41))
        XCTAssertEqual(ledger.state.hydration?.interval, 7200)
    }

    /// Loosening the hydration Gate's restriction profile is an easier change too.
    func testLooseningHydrationRestrictionsNeedsSatisfiedGate() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        expectThrows(.hydrationEasierWhileUnsatisfied) {
            try ledger.append(.hydrationConfigured(
                patrickHydration(restrictions: RestrictionProfile(["instagram"]))), at: d(22, 9))
        }
        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 10))
        ledger.expectAppend(.hydrationConfigured(
            patrickHydration(restrictions: RestrictionProfile(["instagram"]))), at: d(22, 9, 11))
    }

    func testInvalidConfigRejected() {
        var ledger = Ledger()
        expectThrows {
            try ledger.append(.hydrationConfigured(HydrationConfig(
                interval: 0, activeHours: utcActiveHours)), at: d(22))
        }
        expectThrows {
            try ledger.append(.hydrationConfigured(HydrationConfig(
                interval: 3600,
                activeHours: ActiveHours(startMinuteOfDay: 900, endMinuteOfDay: 480,
                                         timeZoneIdentifier: "UTC"))), at: d(22))
        }
    }

    func testWarningsAreScheduledWhileSatisfied() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(warningLead: 600)), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))

        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 10, 5)), d(22, 11))
        XCTAssertEqual(ledger.state.upcomingWarnings(now: d(22, 10, 5)).map(\.date), [d(22, 10, 50)])
    }
}
