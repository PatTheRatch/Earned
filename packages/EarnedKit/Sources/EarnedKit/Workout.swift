import Foundation

/// A verified workout, as reported by the platform layer (Apple Health on iOS).
/// EarnedKit does not know about HealthKit; the app maps `HKWorkout` into this,
/// including mapping `HKWorkoutActivityType` onto `ActivityType`.
/// Who vouches for a workout having happened (NORTHSTAR §15).
///
/// Recorded at ingestion and never revised: evidence is a fact about how the
/// workout entered Earned, not a judgement that can improve later. The
/// distinction this carries is honest about its limits — `appVerified` means
/// *another app wrote this into Apple Health*, with the source assigned by
/// iOS rather than claimed by the app, and iOS's own user-entered flag
/// respected. It raises the cost of lying to yourself; it does not make lying
/// impossible, and §15 is explicit that fraud detection is not the goal.
public enum WorkoutEvidence: Codable, Equatable, Sendable {
    /// The user's word: the in-app manual entry, or a workout typed directly
    /// into the Health app (which is the same word wearing a lab coat —
    /// HealthKit marks those user-entered, and ingestion honours the mark).
    case selfReported
    /// Vouched for by another app through Apple Health. `source` is the
    /// writing app's bundle identifier as HealthKit recorded it — an Apple
    /// Watch workout, a Strava run synced into Health, a Nike session. Kept
    /// so history can say *who* vouched, and so a future stricter tier could
    /// name acceptable sources (§15's "stronger evidence").
    case appVerified(source: String)
}

/// How much evidence a commitment demands before a workout counts against it
/// (NORTHSTAR §15).
///
/// Part of the requirement, therefore part of the contract: frozen at
/// hardening and only ever tightenable after, exactly like the deadline and
/// the restriction profile. The section's own words — "verification strength
/// is part of the contract. Once hardened, verification may become stricter
/// but not weaker" — and the reason is the product's whole thesis: the person
/// who chose "Strava has to confirm it" on Sunday is the one the Wednesday
/// negotiation is conducted against.
public enum WorkoutVerification: String, Codable, CaseIterable, Sendable {
    /// The honor system. Everything counts, manual entries included.
    case selfReported
    /// Only workouts another app vouched for count. Self-reported entries can
    /// still be logged — they are true things the user said — they just do
    /// not move this commitment.
    case appVerified

    public func accepts(_ evidence: WorkoutEvidence) -> Bool {
        switch self {
        case .selfReported: return true
        case .appVerified:
            guard case .appVerified = evidence else { return false }
            return true
        }
    }

    /// `appVerified` is strictly stricter. One axis today; kept as a method so
    /// §15's future tiers (heart-rate present, movement data) join a lattice
    /// rather than an ad-hoc comparison.
    public func isAtLeastAsStrict(as other: WorkoutVerification) -> Bool {
        self == other || other == .selfReported
    }
}

public struct Workout: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var activity: ActivityType
    public var start: Date
    public var end: Date
    public var distanceMeters: Double?
    public var evidence: WorkoutEvidence

    public init(id: UUID = UUID(),
                activity: ActivityType,
                start: Date,
                end: Date,
                distanceMeters: Double? = nil,
                evidence: WorkoutEvidence = .selfReported) {
        self.id = id
        self.activity = activity
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.evidence = evidence
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
        start >= commitment.eligibleFrom
            && commitment.requirement.activity.accepts(activity)
            && commitment.requirement.verification.accepts(evidence)
    }
}

// MARK: - Backward-compatible decoding

extension Workout {
    private enum CodingKeys: String, CodingKey {
        case id, activity, activityType, start, end, distanceMeters, evidence
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

        // Workouts written before evidence existed were manual entries, so
        // .selfReported is what they were rather than a guess about them.
        evidence = try container.decodeIfPresent(WorkoutEvidence.self, forKey: .evidence)
            ?? .selfReported

        if let activity = try container.decodeIfPresent(ActivityType.self, forKey: .activity) {
            self.activity = activity
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .activityType) ?? ""
            self.activity = ActivityType(rawValue: legacy.lowercased()) ?? .other
        }
    }

    /// Written explicitly because `CodingKeys` carries the legacy
    /// `activityType` key, which has no stored property to synthesize from.
    /// Only the current shape is ever written.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(activity, forKey: .activity)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encodeIfPresent(distanceMeters, forKey: .distanceMeters)
        try container.encode(evidence, forKey: .evidence)
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
