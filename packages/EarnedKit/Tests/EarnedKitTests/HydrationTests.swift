import XCTest
@testable import EarnedKit

final class HydrationTests: XCTestCase {

    // NORTHSTAR §18: 08:00 ack → satisfied; 09:00 expiry → unsatisfied;
    // 09:17 ack → satisfied; next expiry 10:17.
    func testRollingTimerTimeline() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 8))

        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 8, 30)),
                       .satisfied(expiresAt: d(22, 9)))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 9)),
                       .unsatisfied(expiredAt: d(22, 9)))
        XCTAssertFalse(ledger.state.accessState(now: d(22, 9, 5)).isFull)

        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 17))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 9, 18)),
                       .satisfied(expiresAt: d(22, 10, 17)))
        XCTAssertTrue(ledger.state.accessState(now: d(22, 9, 18)).isFull)
    }

    // Active hours: dormant overnight, and the morning starts satisfied with a
    // fresh interval rather than locked (NORTHSTAR §18, Active hours).
    func testActiveHoursMorningStartsSatisfied() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 21, 30))

        // 03:00 — dormant, no 3 AM nagging.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(23, 3)), .dormant)
        XCTAssertTrue(ledger.state.accessState(now: d(23, 3)).isFull)

        // Window opens 08:00 with a fresh interval: satisfied until 09:00.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(23, 8, 30)),
                       .satisfied(expiresAt: d(23, 9)))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(23, 9, 1)),
                       .unsatisfied(expiredAt: d(23, 9)))
    }

    // An expired gate goes dormant (satisfied) when the window closes.
    func testUnsatisfiedGateReleasesAtWindowClose() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        // Never acknowledged: expires 09:00, unsatisfied all day.
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 21, 59)),
                       .unsatisfied(expiredAt: d(22, 9)))
        XCTAssertEqual(ledger.state.hydrationStatus(now: d(22, 22)), .dormant)
        // Its next transition is the window close.
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 21)), d(22, 22))
    }

    // Easier config changes are rejected while the gate is unsatisfied.
    func testEasierConfigRequiresSatisfiedGate() throws {
        var ledger = Ledger()
        ledger.expectAppend(.hydrationConfigured(patrickHydration(interval: 3600)), at: d(22, 7))

        // 09:30, never acknowledged since window open at 08:00 → unsatisfied.
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

    func testNextTransitionAndWarnings() throws {
        var ledger = Ledger()
        ledger.expectAppend(
            .hydrationConfigured(patrickHydration(warningLead: 600)), at: d(22, 7))
        ledger.expectAppend(.waterAcknowledged, at: d(22, 10))

        // Satisfied: next transition is expiry at 11:00, warning at 10:50.
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 10, 5)), d(22, 11))
        let warnings = ledger.state.upcomingWarnings(now: d(22, 10, 5))
        XCTAssertEqual(warnings.map(\.date), [d(22, 10, 50)])

        // Dormant overnight: next transition is tomorrow's open + interval.
        XCTAssertEqual(ledger.state.nextTransition(after: d(22, 23)), d(23, 9))
    }
}
