import Foundation

/// A recurring commitment plan: "Run 30 min · Mon/Wed/Fri · next 4 weeks".
///
/// A plan is **not** the source of truth for gate state. It is a template that
/// expands, once, into ordinary `Commitment` occurrences which are appended to
/// the ledger as ordinary `commitmentCreated` events. Every gate query, every
/// hardening clock and every override runs against those occurrences exactly as
/// it does for a hand-made commitment, so ledger replay stays deterministic and
/// nothing has to re-derive a schedule at read time.
public struct CommitmentPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var requirement: Requirement
    /// Weekdays in `Calendar` numbering: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    /// Deadline time on each scheduled day, as minutes from midnight.
    public var deadlineMinuteOfDay: Int
    /// First calendar day the plan may schedule (inclusive).
    public var startDate: Date
    /// Last calendar day the plan may schedule (inclusive).
    public var endDate: Date
    public var timeZoneIdentifier: String
    public var configuredCorrectionWindow: TimeInterval
    public var overridePolicy: OverridePolicy
    public var restrictions: RestrictionProfile
    public var rewardEligible: Bool
    public var warningLead: TimeInterval?
    public let createdAt: Date

    public init(id: UUID = UUID(),
                title: String,
                requirement: Requirement,
                weekdays: Set<Int>,
                deadlineMinuteOfDay: Int,
                startDate: Date,
                endDate: Date,
                timeZoneIdentifier: String = TimeZone.current.identifier,
                configuredCorrectionWindow: TimeInterval,
                overridePolicy: OverridePolicy,
                restrictions: RestrictionProfile = .none,
                rewardEligible: Bool = true,
                warningLead: TimeInterval? = nil,
                createdAt: Date) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.weekdays = weekdays
        self.deadlineMinuteOfDay = deadlineMinuteOfDay
        self.startDate = startDate
        self.endDate = endDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.configuredCorrectionWindow = configuredCorrectionWindow
        self.overridePolicy = overridePolicy
        self.restrictions = restrictions
        self.rewardEligible = rewardEligible
        self.warningLead = warningLead
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        !weekdays.isEmpty
            && weekdays.allSatisfy { (1...7).contains($0) }
            && (0..<(24 * 60)).contains(deadlineMinuteOfDay)
            && endDate >= startDate
            && requirement.isValid
            && TimeZone(identifier: timeZoneIdentifier) != nil
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// Expands the plan into its occurrences.
    ///
    /// Each occurrence gets:
    /// - `eligibleFrom` = midnight at the start of its own calendar day, clamped
    ///   to never precede the plan's creation. The clamp preserves the rule that
    ///   you cannot commit to a workout you have already done: a plan made at
    ///   noon on Wednesday cannot be satisfied by Wednesday's 7am run.
    /// - `deadline` = that day at `deadlineMinuteOfDay`.
    /// - its own hardening clock, progress and resolution, because it is an
    ///   ordinary commitment in every other respect.
    ///
    /// Days whose deadline has already passed at `createdAt` are skipped — a
    /// commitment cannot be created already overdue.
    public func occurrences(idProvider: () -> UUID = { UUID() }) -> [Commitment] {
        guard isValid else { return [] }
        let cal = calendar
        var result: [Commitment] = []
        var day = cal.startOfDay(for: startDate)
        let lastDay = cal.startOfDay(for: endDate)

        while day <= lastDay {
            defer { day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            guard weekdays.contains(cal.component(.weekday, from: day)) else { continue }

            let deadline = day.addingTimeInterval(TimeInterval(deadlineMinuteOfDay * 60))
            guard deadline > createdAt else { continue }

            result.append(Commitment(id: idProvider(),
                                     title: title,
                                     requirement: requirement,
                                     eligibleFrom: max(day, createdAt),
                                     deadline: deadline,
                                     createdAt: createdAt,
                                     configuredCorrectionWindow: configuredCorrectionWindow,
                                     overridePolicy: overridePolicy,
                                     restrictions: restrictions,
                                     rewardEligible: rewardEligible,
                                     warningLead: warningLead,
                                     planID: id))
        }
        return result
    }

    /// Convenience: a plan running for a whole number of weeks from `startDate`.
    public static func weeks(_ count: Int, from startDate: Date, timeZoneIdentifier: String = TimeZone.current.identifier) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return cal.date(byAdding: .day, value: count * 7 - 1, to: cal.startOfDay(for: startDate)) ?? startDate
    }
}

/// A plan and what became of it.
public struct PlanRecord: Codable, Equatable, Sendable {
    public internal(set) var plan: CommitmentPlan
    /// Set when the plan was cancelled. Cancelling a plan does not retroactively
    /// clear occurrences that have already hardened — those are contracts in
    /// their own right.
    public internal(set) var cancelledAt: Date?

    public var isCancelled: Bool { cancelledAt != nil }
}
