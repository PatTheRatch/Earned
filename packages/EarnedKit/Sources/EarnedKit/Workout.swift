import Foundation

/// A verified workout, as reported by the platform layer (Apple Health on iOS).
/// EarnedKit does not know about HealthKit; the app maps `HKWorkout` into this,
/// including mapping `HKWorkoutActivityType` onto `ActivityType`.
public struct Workout: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var activity: ActivityType
    public var start: Date
    public var end: Date
    public var distanceMeters: Double?

    public init(id: UUID = UUID(),
                activity: ActivityType,
                start: Date,
                end: Date,
                distanceMeters: Double? = nil) {
        self.id = id
        self.activity = activity
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// A workout counts toward a commitment when it is of a qualifying activity
    /// **and** started at or after the commitment's `eligibleFrom`.
    ///
    /// There is deliberately no upper bound at the deadline: the obligation
    /// persists past its deadline until resolved, so a late workout must still
    /// be able to clear outstanding debt (NORTHSTAR §16). The lower bound is
    /// what stops a workout from reaching *forward* into a commitment whose day
    /// has not arrived.
    func isEligible(for commitment: Commitment) -> Bool {
        start >= commitment.eligibleFrom && commitment.requirement.activity.accepts(activity)
    }
}

// MARK: - Backward-compatible decoding

extension Workout {
    private enum CodingKeys: String, CodingKey {
        case id, activity, activityType, start, end, distanceMeters
    }

    /// Ledger v1 stored a free-form `activityType` string. Known names map onto
    /// the enum; anything else (including the old manual-entry placeholder)
    /// becomes `.other`, which still satisfies an unrestricted activity filter.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters)

        if let activity = try container.decodeIfPresent(ActivityType.self, forKey: .activity) {
            self.activity = activity
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .activityType) ?? ""
            self.activity = ActivityType(rawValue: legacy.lowercased()) ?? .other
        }
    }
}

/// Progress toward a commitment's requirement, for UI and accountability context.
public struct CommitmentProgress: Equatable, Sendable {
    public enum Unit: Equatable, Sendable { case workouts, seconds, meters }
    public var achieved: Double
    public var required: Double
    public var unit: Unit

    public var isSatisfied: Bool { achieved >= required }
}

extension Requirement {
    /// Accumulated progress over workouts already filtered for eligibility
    /// (NORTHSTAR §14).
    func progress(over workouts: [Workout]) -> CommitmentProgress {
        switch metric {
        case .anyQualifyingWorkout:
            return CommitmentProgress(achieved: Double(workouts.count), required: 1, unit: .workouts)
        case .totalDuration(let required):
            let total = workouts.reduce(0) { $0 + $1.duration }
            return CommitmentProgress(achieved: total, required: required, unit: .seconds)
        case .totalDistance(let required):
            let total = workouts.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
            return CommitmentProgress(achieved: total, required: required, unit: .meters)
        }
    }
}
