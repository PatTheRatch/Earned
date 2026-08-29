import Foundation

/// Everything that can happen in Earned. State is a pure function of the event
/// history; events that would violate an invariant are rejected at append time
/// and never enter the ledger.
public enum Event: Codable, Equatable, Sendable {
    // Configuration
    case hydrationConfigured(HydrationConfig)
    case rewardPolicyConfigured(RewardPolicy)
    /// The profile applied to newly created commitments that don't specify one.
    /// A convenience default, not a Gate in its own right.
    case defaultCommitmentRestrictionsChanged(RestrictionProfile)

    // Hydration
    case waterAcknowledged

    // Commitments
    case commitmentCreated(Commitment)
    case commitmentEdited(id: UUID, edit: CommitmentEdit)
    case commitmentCancelled(id: UUID)

    // Recurring plans. The plan is recorded for display and cancellation; its
    // occurrences arrive as ordinary `commitmentCreated` events immediately
    // after, so gate state never depends on re-expanding a schedule.
    case planCreated(CommitmentPlan)
    case planCancelled(id: UUID)

    // Verification
    case workoutRecorded(Workout)

    // Overrides
    /// A Free Override coming into existence. Immutable once written: later
    /// reward-policy changes affect future earning only (NORTHSTAR §22, §27).
    case freeOverrideEarned(id: UUID, source: FreeOverrideSource)
    case freeOverrideSpent(commitmentID: UUID)
    case overrideRequested(id: UUID, commitmentID: UUID)
    case overrideApprovalRecorded(requestID: UUID, partnerID: String)
    case overrideDenialRecorded(requestID: UUID, partnerID: String)
    case soloOverrideStarted(requestID: UUID)
    /// Measurable progress through the active-friction challenge. Elapsed time
    /// alone never completes a solo override.
    case soloOverrideProgressRecorded(requestID: UUID, units: Int)
    case soloOverrideCompleted(requestID: UUID)

    // MARK: Legacy

    /// Ledger v1's single global restricted-app set, as add/remove deltas.
    /// Restrictions now belong to Gates, so on replay this applies to the
    /// *default* profile for new commitments — the closest honest reading of
    /// what it meant. Kept rather than dropped so v1 history replays literally
    /// instead of being rewritten. Never emitted by current code.
    case restrictedAppsChanged(added: Set<String>, removed: Set<String>)
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
