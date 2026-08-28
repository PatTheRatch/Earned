import Foundation

/// What must be achieved for a commitment to be satisfied. Quantitative
/// requirements accumulate across qualifying workouts (NORTHSTAR §14).
public enum Requirement: Codable, Equatable, Sendable {
    case anyWorkout
    /// Total workout time in seconds.
    case totalDuration(TimeInterval)
    /// Total distance in meters.
    case totalDistance(Double)

    /// Whether `self` is at least as hard as `other`. Cross-dimension changes
    /// (duration ↔ distance) are incomparable and therefore never allowed after
    /// hardening; anything is at least as hard as `.anyWorkout`.
    func isAtLeastAsHard(as other: Requirement) -> Bool {
        switch (self, other) {
        case (_, .anyWorkout):
            return true
        case (.totalDuration(let new), .totalDuration(let old)):
            return new >= old
        case (.totalDistance(let new), .totalDistance(let old)):
            return new >= old
        default:
            return false
        }
    }
}

/// Escalating friction for repeated Solo Emergency Overrides (NORTHSTAR §25).
public struct SoloEscalation: Codable, Equatable, Sendable {
    /// How far back completed solo overrides count as "recent".
    public var recentWindow: TimeInterval
    /// Friction durations by number of recent solo overrides; the last entry
    /// applies to all further repetitions.
    public var frictionSteps: [TimeInterval]

    public init(recentWindow: TimeInterval = 30 * 24 * 3600,
                frictionSteps: [TimeInterval] = [10 * 60, 30 * 60, 60 * 60]) {
        self.recentWindow = recentWindow
        self.frictionSteps = frictionSteps
    }

    func friction(recentSoloCount: Int) -> TimeInterval {
        guard let last = frictionSteps.last else { return 0 }
        guard recentSoloCount < frictionSteps.count else { return last }
        return frictionSteps[max(0, recentSoloCount)]
    }

    func isAtLeastAsHard(as other: SoloEscalation) -> Bool {
        guard recentWindow >= other.recentWindow else { return false }
        guard frictionSteps.count >= other.frictionSteps.count else { return false }
        return zip(frictionSteps, other.frictionSteps).allSatisfy { $0 >= $1 }
    }
}

/// The escape rules attached to a commitment. These harden with it (NORTHSTAR §26).
public struct OverridePolicy: Codable, Equatable, Sendable {
    /// Accountability approvals needed for an Accountability Override.
    public var approvalsRequired: Int
    /// How long the accountability request must wait, unsatisfied, before the
    /// Solo Override becomes available, in seconds.
    public var accountabilityWindow: TimeInterval
    public var soloEscalation: SoloEscalation

    public init(approvalsRequired: Int,
                accountabilityWindow: TimeInterval,
                soloEscalation: SoloEscalation = SoloEscalation()) {
        self.approvalsRequired = approvalsRequired
        self.accountabilityWindow = accountabilityWindow
        self.soloEscalation = soloEscalation
    }

    func isAtLeastAsHard(as other: OverridePolicy) -> Bool {
        approvalsRequired >= other.approvalsRequired
            && accountabilityWindow >= other.accountabilityWindow
            && soloEscalation.isAtLeastAsHard(as: other.soloEscalation)
    }
}

/// An exercise commitment: the contract itself.
public struct Commitment: Codable, Equatable, Identifiable, Sendable {
    /// Fraction of the time-to-deadline that caps the correction window for
    /// short-fuse commitments (NORTHSTAR §11): a 2-hour-away commitment with a
    /// 2-hour configured window hardens after 2h × 1/8 = 15 minutes.
    public static let hardeningFraction = 0.125

    public let id: UUID
    public var title: String
    public var requirement: Requirement
    public var deadline: Date
    public let createdAt: Date
    public var configuredCorrectionWindow: TimeInterval
    public var overridePolicy: OverridePolicy
    public var rewardEligible: Bool
    /// Optional warning lead time before the deadline, in seconds.
    public var warningLead: TimeInterval?

    public init(id: UUID = UUID(),
                title: String,
                requirement: Requirement,
                deadline: Date,
                createdAt: Date,
                configuredCorrectionWindow: TimeInterval,
                overridePolicy: OverridePolicy,
                rewardEligible: Bool = true,
                warningLead: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.deadline = deadline
        self.createdAt = createdAt
        self.configuredCorrectionWindow = configuredCorrectionWindow
        self.overridePolicy = overridePolicy
        self.rewardEligible = rewardEligible
        self.warningLead = warningLead
    }

    /// When the correction window ends and the contract hardens.
    public var hardensAt: Date {
        let timeToDeadline = max(0, deadline.timeIntervalSince(createdAt))
        let window = min(configuredCorrectionWindow, timeToDeadline * Self.hardeningFraction)
        return createdAt.addingTimeInterval(window)
    }

    public func isHardened(at date: Date) -> Bool { date >= hardensAt }

    /// Whether `self` is at least as hard as `other` in every hardened dimension.
    /// An earlier deadline is harder; reward eligibility is neutral and must not change.
    func isAtLeastAsHard(as other: Commitment) -> Bool {
        requirement.isAtLeastAsHard(as: other.requirement)
            && deadline <= other.deadline
            && overridePolicy.isAtLeastAsHard(as: other.overridePolicy)
            && rewardEligible == other.rewardEligible
    }
}

/// A partial edit to a commitment. `nil` fields are left unchanged.
public struct CommitmentEdit: Codable, Equatable, Sendable {
    public var title: String?
    public var requirement: Requirement?
    public var deadline: Date?
    public var overridePolicy: OverridePolicy?
    public var rewardEligible: Bool?
    public var warningLead: TimeInterval??

    public init(title: String? = nil,
                requirement: Requirement? = nil,
                deadline: Date? = nil,
                overridePolicy: OverridePolicy? = nil,
                rewardEligible: Bool? = nil,
                warningLead: TimeInterval?? = nil) {
        self.title = title
        self.requirement = requirement
        self.deadline = deadline
        self.overridePolicy = overridePolicy
        self.rewardEligible = rewardEligible
        self.warningLead = warningLead
    }

    func applied(to commitment: Commitment) -> Commitment {
        var result = commitment
        if let title { result.title = title }
        if let requirement { result.requirement = requirement }
        if let deadline { result.deadline = deadline }
        if let overridePolicy { result.overridePolicy = overridePolicy }
        if let rewardEligible { result.rewardEligible = rewardEligible }
        if let warningLead { result.warningLead = warningLead }
        return result
    }
}

public enum OverrideKind: String, Codable, Equatable, Sendable {
    case free
    case accountability
    case solo
}

/// Terminal states of a commitment. An unresolved commitment past its deadline
/// is *overdue* — a derived condition, not a resolution (NORTHSTAR §16: passing
/// the deadline does not eliminate the obligation).
public enum CommitmentResolution: Codable, Equatable, Sendable {
    case completed(at: Date)
    case overridden(OverrideKind, at: Date)
    case cancelled(at: Date)
}
