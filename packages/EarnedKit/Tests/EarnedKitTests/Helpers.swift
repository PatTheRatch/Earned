import Foundation
import XCTest
@testable import EarnedKit

/// UTC date builder for deterministic tests. August 2026: the 22nd is a
/// Saturday, the 23rd a Sunday, the 24th a Monday.
func d(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(
        year: 2026, month: 8, day: day, hour: hour, minute: minute, second: second))!
}

let utcActiveHours = ActiveHours(
    startMinuteOfDay: 8 * 60, endMinuteOfDay: 22 * 60, timeZoneIdentifier: "UTC")

/// Patrick's initial hydration configuration: 60-minute rolling timer,
/// active 08:00–22:00.
func patrickHydration(interval: TimeInterval = 3600, warningLead: TimeInterval? = nil) -> HydrationConfig {
    HydrationConfig(enabled: true, interval: interval, activeHours: utcActiveHours, warningLead: warningLead)
}

/// Patrick's likely override policy: 2 approvals, 30-minute accountability window.
func patrickPolicy(approvals: Int = 2, window: TimeInterval = 1800) -> OverridePolicy {
    OverridePolicy(approvalsRequired: approvals, accountabilityWindow: window)
}

func makeCommitment(id: UUID = UUID(),
                    title: String = "Workout",
                    requirement: Requirement = .anyWorkout,
                    deadline: Date,
                    createdAt: Date,
                    correctionWindow: TimeInterval = 2 * 3600,
                    policy: OverridePolicy = patrickPolicy(),
                    rewardEligible: Bool = true,
                    warningLead: TimeInterval? = nil) -> Commitment {
    Commitment(id: id,
               title: title,
               requirement: requirement,
               deadline: deadline,
               createdAt: createdAt,
               configuredCorrectionWindow: correctionWindow,
               overridePolicy: policy,
               rewardEligible: rewardEligible,
               warningLead: warningLead)
}

func workout(start: Date, minutes: Double, distanceMeters: Double? = nil, id: UUID = UUID()) -> Workout {
    Workout(id: id, activityType: "running", start: start,
            end: start.addingTimeInterval(minutes * 60), distanceMeters: distanceMeters)
}

extension AccessState {
    var isFull: Bool { self == .full }
    var lockReasons: [LockReason] {
        if case .restricted(let reasons) = self { return reasons }
        return []
    }
}

extension Ledger {
    /// Appends and fails the test on error, for happy-path setup.
    @discardableResult
    mutating func expectAppend(_ event: Event, at date: Date,
                               file: StaticString = #filePath, line: UInt = #line) -> LedgerEntry? {
        do {
            return try append(event, at: date)
        } catch {
            XCTFail("Unexpected append failure: \(error)", file: file, line: line)
            return nil
        }
    }
}

func expectThrows(_ expected: EarnedError? = nil,
                  file: StaticString = #filePath, line: UInt = #line,
                  _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("Expected an error, none thrown", file: file, line: line)
    } catch let error as EarnedError {
        if let expected {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error type: \(error)", file: file, line: line)
    }
}
