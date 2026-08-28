import Foundation

/// An in-flight (or resolved) override request against one commitment.
/// Free Overrides never create a request — they are spent directly.
public struct OverrideRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let commitmentID: UUID
    public let requestedAt: Date
    public internal(set) var approvals: [String: Date]
    public internal(set) var denials: [String: Date]
    public internal(set) var soloStartedAt: Date?
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
    }

    public var isResolved: Bool { grantedAt != nil }

    /// When the Solo Override becomes available: only after the accountability
    /// window has elapsed without sufficient approvals (NORTHSTAR §25).
    public func soloAvailableAt(policy: OverridePolicy) -> Date {
        requestedAt.addingTimeInterval(policy.accountabilityWindow)
    }
}

/// Reward configuration for Free Overrides (NORTHSTAR §22). Thresholds are
/// deliberately configurable rather than fixed.
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
}
