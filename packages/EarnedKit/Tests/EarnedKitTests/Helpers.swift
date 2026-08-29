import Foundation
import XCTest
@testable import EarnedKit

/// UTC date builder for deterministic tests. August 2026: the 22nd is a
/// Saturday, the 23rd a Sunday, the 24th a Monday, 26th Wednesday, 28th Friday.
func d(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(
        year: 2026, month: 8, day: day, hour: hour, minute: minute, second: second))!
}

let utcActiveHours = ActiveHours(
    startMinuteOfDay: 8 * 60, endMinuteOfDay: 22 * 60, timeZoneIdentifier: "UTC")

// Restriction profiles standing in for the first user's two severities
// (NORTHSTAR §6). The tokens are opaque to EarnedKit.
let hydrationProfile = RestrictionProfile(["instagram", "youtube", "safari", "email", "spotify", "maps"])
let exerciseProfile = RestrictionProfile(["instagram", "youtube", "safari", "balatro"])

/// Patrick's initial hydration configuration: 60-minute rolling timer,
/// active 08:00–22:00.
func patrickHydration(interval: TimeInterval = 3600,
                      restrictions: RestrictionProfile = hydrationProfile,
                      warningLead: TimeInterval? = nil) -> HydrationConfig {
    HydrationConfig(enabled: true, interval: interval, activeHours: utcActiveHours,
                    restrictions: restrictions, warningLead: warningLead)
}

/// Patrick's likely override policy: 2 approvals, 30-minute accountability window.
func patrickPolicy(approvals: Int = 2, window: TimeInterval = 1800) -> OverridePolicy {
    OverridePolicy(approvalsRequired: approvals, accountabilityWindow: window)
}

func makeCommitment(id: UUID = UUID(),
                    title: String = "Workout",
                    requirement: Requirement = .anyWorkout,
                    eligibleFrom: Date? = nil,
                    deadline: Date,
                    createdAt: Date,
                    correctionWindow: TimeInterval = 2 * 3600,
                    policy: OverridePolicy = patrickPolicy(),
                    restrictions: RestrictionProfile = exerciseProfile,
                    rewardEligible: Bool = true,
                    warningLead: TimeInterval? = nil,
                    planID: UUID? = nil) -> Commitment {
    Commitment(id: id,
               title: title,
               requirement: requirement,
               eligibleFrom: eligibleFrom,
               deadline: deadline,
               createdAt: createdAt,
               configuredCorrectionWindow: correctionWindow,
               overridePolicy: policy,
               restrictions: restrictions,
               rewardEligible: rewardEligible,
               warningLead: warningLead,
               planID: planID)
}

func workout(start: Date,
             minutes: Double,
             activity: ActivityType = .running,
             distanceMeters: Double? = nil,
             id: UUID = UUID()) -> Workout {
    Workout(id: id, activity: activity, start: start,
            end: start.addingTimeInterval(minutes * 60), distanceMeters: distanceMeters)
}

extension Ledger {
    /// Appends and fails the test on error, for happy-path setup.
    @discardableResult
    mutating func expectAppend(_ event: Event, at date: Date,
                               file: StaticString = #filePath, line: UInt = #line) -> [LedgerEntry] {
        do {
            return try append(event, at: date)
        } catch {
            XCTFail("Unexpected append failure: \(error)", file: file, line: line)
            return []
        }
    }

    /// Drives an active-friction challenge to completion, recording effort in
    /// realistic increments rather than one lump.
    mutating func completeSoloFriction(requestID: UUID, startedAt: Date,
                                       file: StaticString = #filePath, line: UInt = #line) {
        guard let requirement = state.overrideRequests[requestID]?.soloRequirement else {
            XCTFail("Solo override not started", file: file, line: line)
            return
        }
        var recorded = 0
        var at = startedAt
        while recorded < requirement.effortUnits {
            let chunk = min(10, requirement.effortUnits - recorded)
            at = at.addingTimeInterval(10)
            expectAppend(.soloOverrideProgressRecorded(requestID: requestID, units: chunk),
                         at: at, file: file, line: line)
            recorded += chunk
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
