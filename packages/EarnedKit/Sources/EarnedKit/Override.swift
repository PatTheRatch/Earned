import Foundation

/// What a Solo Emergency Override costs (NORTHSTAR §25).
///
/// The product intent is *active friction*, not elapsed wall-clock time: waiting
/// ten minutes while doing something else is exactly the learned shortcut the
/// override is meant to prevent. So a requirement has two parts, and both must
/// be met:
///
/// - `effortUnits` — measurable progress the user has to actually produce,
///   recorded as `soloOverrideProgressRecorded` events. What a unit *is* on
///   screen is a product-design surface that is still open; the domain only
///   knows that units must be earned, one deliberate act at a time.
/// - `minimumElapsed` — a floor on how fast the challenge can be completed, so
///   units cannot be spammed in seconds.
///
/// Neither alone is sufficient. Elapsed time without effort does not complete an
/// override, which is the correction this type exists to make.
public struct FrictionRequirement: Codable, Equatable, Sendable {
    public var effortUnits: Int
    public var minimumElapsed: TimeInterval

    public init(effortUnits: Int, minimumElapsed: TimeInterval) {
        self.effortUnits = effortUnits
        self.minimumElapsed = minimumElapsed
    }

    /// Roughly 10 / 30 / 60 minutes of *engaged* effort. The unit counts assume
    /// a unit costs about ten seconds of deliberate action; the time floors keep
    /// the escalation honest even if the challenge is later made cheaper.
    public static let defaultEscalation: [FrictionRequirement] = [
        FrictionRequirement(effortUnits: 60, minimumElapsed: 10 * 60),
        FrictionRequirement(effortUnits: 180, minimumElapsed: 30 * 60),
        FrictionRequirement(effortUnits: 360, minimumElapsed: 60 * 60),
    ]

    public func isAtLeastAsHard(as other: FrictionRequirement) -> Bool {
        effortUnits >= other.effortUnits && minimumElapsed >= other.minimumElapsed
    }

    /// Whether a run of the challenge has met both halves of the requirement.
    public func isSatisfied(unitsCompleted: Int, elapsed: TimeInterval) -> Bool {
        unitsCompleted >= effortUnits && elapsed >= minimumElapsed
    }
}

/// An in-flight (or resolved) override request against one commitment.
/// Free Overrides never create a request — they are spent directly.
public struct OverrideRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let commitmentID: UUID
    public let requestedAt: Date
    public internal(set) var approvals: [String: Date]
    public internal(set) var denials: [String: Date]
    public internal(set) var soloStartedAt: Date?
    /// Effort accumulated in the active-friction challenge so far.
    public internal(set) var soloEffortUnits: Int
    /// Frozen when the solo challenge starts, so later policy edits cannot make
    /// an in-flight escape cheaper.
    public internal(set) var soloRequirement: FrictionRequirement?
    /// Set when the request grants (accountability threshold met, or solo
    /// friction completed). The commitment's resolution records the same moment.
    public internal(set) var grantedAt: Date?
    public internal(set) var grantedKind: OverrideKind?

    init(id: UUID, commitmentID: UUID, requestedAt: Date) {
        self.id = id
        self.commitmentID = commitmentID
        self.requestedAt = requestedAt
        self.approvals = [:]
        self.denials = [:]
        self.soloEffortUnits = 0
    }

    public var isResolved: Bool { grantedAt != nil }

    /// When the Solo Override becomes available: only after the accountability
    /// window has elapsed without sufficient approvals (NORTHSTAR §25).
    public func soloAvailableAt(policy: OverridePolicy) -> Date {
        requestedAt.addingTimeInterval(policy.accountabilityWindow)
    }

    /// Remaining effort in the active-friction challenge, or nil if not started.
    public var soloUnitsRemaining: Int? {
        guard let requirement = soloRequirement else { return nil }
        return max(0, requirement.effortUnits - soloEffortUnits)
    }
}

// MARK: - Backward-compatible decoding

extension OverrideRequest {
    private enum CodingKeys: String, CodingKey {
        case id, commitmentID, requestedAt, approvals, denials
        case soloStartedAt, soloEffortUnits, soloRequirement, grantedAt, grantedKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        commitmentID = try container.decode(UUID.self, forKey: .commitmentID)
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        approvals = try container.decode([String: Date].self, forKey: .approvals)
        denials = try container.decode([String: Date].self, forKey: .denials)
        soloStartedAt = try container.decodeIfPresent(Date.self, forKey: .soloStartedAt)
        grantedAt = try container.decodeIfPresent(Date.self, forKey: .grantedAt)
        grantedKind = try container.decodeIfPresent(OverrideKind.self, forKey: .grantedKind)
        soloEffortUnits = try container.decodeIfPresent(Int.self, forKey: .soloEffortUnits) ?? 0
        soloRequirement = try container.decodeIfPresent(FrictionRequirement.self, forKey: .soloRequirement)
    }
}

/// How a stored Free Override came to exist. Recorded on the earning event so
/// the ledger stays auditable.
public enum FreeOverrideSource: String, Codable, Equatable, Sendable {
    /// Earned by a completion streak under the reward policy in force at the time.
    case streak
    /// Created by ledger migration to fund a spend recorded before Free
    /// Overrides became explicit events. Never produced by normal operation.
    case migration
}

/// Reward configuration for Free Overrides (NORTHSTAR §22). Thresholds are
/// deliberately configurable rather than fixed.
///
/// The policy governs **future earning only**. A Free Override, once earned, is
/// an immutable ledger event; changing these numbers can never mint or unmint a
/// reward retroactively.
public struct RewardPolicy: Codable, Equatable, Sendable {
    /// Consecutive on-time completions of reward-eligible commitments needed to
    /// earn one Free Override.
    public var streakThreshold: Int
    /// Maximum stored Free Overrides; earning at the cap is forfeited.
    public var maxStored: Int

    public init(streakThreshold: Int = 5, maxStored: Int = 2) {
        self.streakThreshold = streakThreshold
        self.maxStored = maxStored
    }

    public var isValid: Bool { streakThreshold >= 1 && maxStored >= 0 }

    /// Stricter means: a longer streak required, or fewer overrides bankable.
    /// Making the policy stricter is always allowed; making it easier is gated
    /// (see `EarnedState.validateRewardPolicy`).
    public func isAtLeastAsHard(as other: RewardPolicy) -> Bool {
        streakThreshold >= other.streakThreshold && maxStored <= other.maxStored
    }
}
