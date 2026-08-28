import Foundation

/// Everything that can happen in Earned. State is a pure function of the event
/// history; events that would violate an invariant are rejected at append time
/// and never enter the ledger.
public enum Event: Codable, Equatable, Sendable {
    // Configuration
    case hydrationConfigured(HydrationConfig)
    case rewardPolicyConfigured(RewardPolicy)
    case restrictedAppsChanged(added: Set<String>, removed: Set<String>)

    // Hydration
    case waterAcknowledged

    // Commitments
    case commitmentCreated(Commitment)
    case commitmentEdited(id: UUID, edit: CommitmentEdit)
    case commitmentCancelled(id: UUID)

    // Verification
    case workoutRecorded(Workout)

    // Overrides
    case freeOverrideSpent(commitmentID: UUID)
    case overrideRequested(id: UUID, commitmentID: UUID)
    case overrideApprovalRecorded(requestID: UUID, partnerID: String)
    case overrideDenialRecorded(requestID: UUID, partnerID: String)
    case soloOverrideStarted(requestID: UUID)
    case soloOverrideCompleted(requestID: UUID)
}

/// One appended, validated event.
public struct LedgerEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// When the event happened. Entries are strictly non-decreasing in date.
    /// Late-arriving facts (a HealthKit workout synced hours later) are appended
    /// at sync time; the workout payload carries its own start/end for
    /// eligibility purposes.
    public let date: Date
    public let event: Event

    public init(id: UUID = UUID(), date: Date, event: Event) {
        self.id = id
        self.date = date
        self.event = event
    }
}
