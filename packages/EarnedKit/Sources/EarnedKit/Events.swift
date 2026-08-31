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
    /// A single partner's vote, counted *here* against the local policy.
    ///
    /// Superseded by `accountabilityOverrideGranted` and kept because ledgers
    /// containing it are on real phones and must keep replaying identically.
    /// Nothing appends these any more: counting approvals on the device was
    /// the thing the Contract Envelope exists to stop, since a modified client
    /// could simply decide it had enough.
    case overrideApprovalRecorded(requestID: UUID, partnerID: String)
    case overrideDenialRecorded(requestID: UUID, partnerID: String)
    /// The server granted an accountability override, verified before it got
    /// here (docs/accountability-architecture.md §9.2).
    ///
    /// The semantic fact only: *an override was granted at this time, by these
    /// people, under server grant X*. No signature, no key id, no algorithm —
    /// permanent history must be a pure function of what happened, and
    /// cryptography has a lifecycle that permanence cannot accommodate. By the
    /// time this is appended the signature has already been checked against
    /// the trusted key set; a caller that skipped that step has not been let
    /// down by this type, it has broken the rule this type is written around.
    case accountabilityOverrideGranted(requestID: UUID,
                                       decidedAt: Date,
                                       roster: [PartnerVote],
                                       serverGrantID: UUID)
    case soloOverrideStarted(requestID: UUID)
    /// Measurable progress through the active-friction challenge. Elapsed time
    /// alone never completes a solo override.
    case soloOverrideProgressRecorded(requestID: UUID, units: Int)
    case soloOverrideCompleted(requestID: UUID)

    // Enforcement integrity. Reported by the app layer, which owns the Screen
    // Time adapter; EarnedKit decides what it *means*. Deliberately named for
    // detection rather than revocation: iOS never tells a backgrounded app that
    // authorization went away, so the app can only report what it observes when
    // it next runs (NORTHSTAR §33).
    case enforcementUnavailableDetected
    case enforcementRestored

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
