import Foundation

/// A verified workout, as reported by the platform layer (Apple Health on iOS).
/// EarnedKit does not know about HealthKit; the app maps `HKWorkout` into this.
public struct Workout: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Free-form activity identifier (e.g. "running"). Unused by MVP rules,
    /// carried so richer requirements (NORTHSTAR §13) need no schema change.
    public var activityType: String
    public var start: Date
    public var end: Date
    public var distanceMeters: Double?

    public init(id: UUID = UUID(), activityType: String, start: Date, end: Date, distanceMeters: Double? = nil) {
        self.id = id
        self.activityType = activityType
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// A workout is eligible for a commitment if it started after the commitment
    /// was created (NORTHSTAR §10: the eligible period runs creation → deadline,
    /// and the obligation persists past the deadline until resolved, so there is
    /// no upper bound here).
    func isEligible(for commitment: Commitment) -> Bool {
        start >= commitment.createdAt
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
    /// Accumulated progress over the eligible workouts (NORTHSTAR §14).
    func progress(over workouts: [Workout]) -> CommitmentProgress {
        switch self {
        case .anyWorkout:
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
