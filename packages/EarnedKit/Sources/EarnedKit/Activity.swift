import Foundation

/// The kind of activity a workout was. Deliberately a small closed set with an
/// `other` escape hatch, so HealthKit's much larger `HKWorkoutActivityType`
/// enumeration can map onto it in the adapter layer without EarnedKit growing a
/// dependency or a hundred cases (NORTHSTAR §13: verification rules are
/// configurable, not hard-coded).
public enum ActivityType: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case running
    case walking
    case cycling
    case strength
    case swimming
    case other

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .strength: return "Strength"
        case .swimming: return "Swimming"
        case .other: return "Other"
        }
    }
}

/// Which workouts count toward a commitment.
///
/// This is deliberately separate from *how much* is required: "Run 30 minutes"
/// is an activity filter (running) plus a completion metric (30 minutes), so a
/// half-hour on a bike cannot quietly satisfy it.
public enum ActivityFilter: Codable, Equatable, Sendable {
    /// Anything recorded counts.
    case any
    /// Only these activity types count. Never empty in a valid commitment.
    case types(Set<ActivityType>)

    public static func only(_ type: ActivityType) -> ActivityFilter { .types([type]) }

    public func accepts(_ activity: ActivityType) -> Bool {
        switch self {
        case .any: return true
        case .types(let allowed): return allowed.contains(activity)
        }
    }

    public var isValid: Bool {
        switch self {
        case .any: return true
        case .types(let allowed): return !allowed.isEmpty
        }
    }

    /// Narrowing what counts is harder; widening is easier. Two different
    /// specific sets that neither contains the other are **incomparable** — a
    /// hardened commitment may not swap "running" for "cycling", because that is
    /// neither harder nor easier, just different (NORTHSTAR §12).
    public func isAtLeastAsHard(as other: ActivityFilter) -> Bool {
        switch (self, other) {
        case (_, .any):
            return true
        case (.any, .types):
            return false
        case (.types(let new), .types(let old)):
            return new.isSubset(of: old)
        }
    }

    public var displayName: String {
        switch self {
        case .any:
            return "Any workout"
        case .types(let allowed):
            return allowed.map(\.displayName).sorted().joined(separator: " or ")
        }
    }
}

/// How much of the qualifying activity is required.
public enum CompletionMetric: Codable, Equatable, Sendable {
    /// One qualifying workout of any length.
    case anyQualifyingWorkout
    /// Accumulated seconds across qualifying workouts.
    case totalDuration(TimeInterval)
    /// Accumulated meters across qualifying workouts.
    case totalDistance(Double)
    /// Accumulated active kilocalories across qualifying workouts.
    ///
    /// The only metric here that measures *effort* rather than opportunity.
    /// A minute of standing outside with the Workout app running is a
    /// qualifying run of some duration and some distance; it is not 200
    /// kilocalories. That gap is the entire reason this case exists.
    ///
    /// It is a proxy, not a truth: active energy is estimated, and estimated
    /// far better from a watch's heart rate than from a phone's accelerometer.
    /// Same posture as §15 — this raises the cost of negotiating with
    /// yourself, and does not pretend to be unfoolable.
    case totalActiveEnergy(Double)

    public var isValid: Bool {
        switch self {
        case .anyQualifyingWorkout: return true
        case .totalDuration(let seconds): return seconds > 0
        case .totalDistance(let meters): return meters > 0
        case .totalActiveEnergy(let kilocalories): return kilocalories > 0
        }
    }

    /// Cross-dimension changes (duration ↔ distance ↔ energy) are incomparable
    /// and so are rejected after hardening; anything is at least as hard as
    /// "one workout".
    public func isAtLeastAsHard(as other: CompletionMetric) -> Bool {
        switch (self, other) {
        case (_, .anyQualifyingWorkout):
            return true
        case (.totalDuration(let new), .totalDuration(let old)):
            return new >= old
        case (.totalDistance(let new), .totalDistance(let old)):
            return new >= old
        case (.totalActiveEnergy(let new), .totalActiveEnergy(let old)):
            return new >= old
        default:
            return false
        }
    }
}

/// What must be achieved for a commitment to be satisfied: which workouts count,
/// and how much of them. Quantitative metrics accumulate across qualifying
/// workouts (NORTHSTAR §14) unless a future `singleSessionRequired` option says
/// otherwise.
public struct Requirement: Codable, Equatable, Sendable {
    public var activity: ActivityFilter
    public var metric: CompletionMetric
    /// How much evidence a workout needs before it counts (NORTHSTAR §15).
    /// Lives here rather than on the commitment because it is a third
    /// dimension of what "done" means, alongside which workouts and how much
    /// of them — and because this struct already carries the harder-only
    /// lattice that §15 requires of it.
    public var verification: WorkoutVerification

    public init(activity: ActivityFilter = .any,
                metric: CompletionMetric = .anyQualifyingWorkout,
                verification: WorkoutVerification = .selfReported) {
        self.activity = activity
        self.metric = metric
        self.verification = verification
    }


    // Convenience constructors for the shapes NORTHSTAR §13 names.
    public static let anyWorkout = Requirement()
    public static func anyWorkout(minimumDuration seconds: TimeInterval) -> Requirement {
        Requirement(activity: .any, metric: .totalDuration(seconds))
    }
    public static func run(minutes: Double) -> Requirement {
        Requirement(activity: .only(.running), metric: .totalDuration(minutes * 60))
    }
    public static func run(kilometers: Double) -> Requirement {
        Requirement(activity: .only(.running), metric: .totalDistance(kilometers * 1000))
    }
    public static func cycle(minutes: Double) -> Requirement {
        Requirement(activity: .only(.cycling), metric: .totalDuration(minutes * 60))
    }
    public static func burn(calories: Double, doing activity: ActivityFilter = .any) -> Requirement {
        Requirement(activity: activity, metric: .totalActiveEnergy(calories))
    }

    public var isValid: Bool { activity.isValid && metric.isValid }

    /// Harder in *every* dimension. A change that tightens one dimension while
    /// loosening another is not "harder" and is rejected after hardening.
    public func isAtLeastAsHard(as other: Requirement) -> Bool {
        activity.isAtLeastAsHard(as: other.activity)
            && metric.isAtLeastAsHard(as: other.metric)
            && verification.isAtLeastAsStrict(as: other.verification)
    }

    public var displayName: String {
        switch metric {
        case .anyQualifyingWorkout:
            return activity.displayName
        case .totalDuration(let seconds):
            let minutes = Int((seconds / 60).rounded())
            return "\(activity.displayName) · \(minutes) min"
        case .totalDistance(let meters):
            return String(format: "%@ · %.1f km", activity.displayName, meters / 1000)
        case .totalActiveEnergy(let kilocalories):
            return "\(activity.displayName) · \(Int(kilocalories.rounded())) cal"
        }
    }
}

// MARK: - Backward-compatible decoding

extension Requirement {
    // `verification` must appear here or the synthesized encoder silently
    // drops it: a custom CodingKeys is the whole story of what gets written,
    // and a key it omits is not "defaulted", it is gone.
    private enum CodingKeys: String, CodingKey { case activity, metric, verification }

    /// Ledger v1 stored `Requirement` as a bare enum — `anyWorkout`,
    /// `totalDuration`, `totalDistance` — with no activity dimension. Those
    /// decode as the same metric with an unrestricted activity filter, which is
    /// exactly what they meant at the time.
    ///
    /// Anything written before verification tiers existed (v1 and v3 alike)
    /// decodes `.selfReported`, because everything counted when it was
    /// written — the rule that was in force, not a guess.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.activity), container.contains(.metric) {
            activity = try container.decode(ActivityFilter.self, forKey: .activity)
            metric = try container.decode(CompletionMetric.self, forKey: .metric)
            verification = try container.decodeIfPresent(WorkoutVerification.self,
                                                         forKey: .verification) ?? .selfReported
            return
        }
        activity = .any
        metric = try LegacyRequirement(from: decoder).metric
        verification = .selfReported
    }
}

/// The v1 on-disk shape of `Requirement`, kept only so old ledgers still load.
private enum LegacyRequirement: Codable {
    case anyWorkout
    case totalDuration(TimeInterval)
    case totalDistance(Double)

    var metric: CompletionMetric {
        switch self {
        case .anyWorkout: return .anyQualifyingWorkout
        case .totalDuration(let seconds): return .totalDuration(seconds)
        case .totalDistance(let meters): return .totalDistance(meters)
        }
    }
}
