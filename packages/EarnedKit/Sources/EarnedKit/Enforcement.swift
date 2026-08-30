import Foundation

/// Whether Earned currently holds the OS-level authority to impose the
/// consequences its Gates imply.
///
/// **This is not gate state.** A Gate is satisfied or unsatisfied according to
/// the ledger alone; enforcement integrity is a separate axis describing only
/// whether Earned can *act* on an unsatisfied Gate. Collapsing the two into one
/// LOCKED/UNLOCKED binary is the mistake this type exists to prevent
/// (NORTHSTAR §33: Enforcement Integrity).
///
///     Gate unsatisfied + enforcement available   → restricted and enforced
///     Gate unsatisfied + enforcement unavailable → still owed, cannot enforce
///     Gate satisfied                             → no restriction from that Gate
public enum EnforcementStatus: String, Codable, Equatable, Sendable {
    /// Never established. A first-run user who has not granted Screen Time has
    /// not *lost* anything, so this is deliberately distinct from `unavailable`.
    case unknown
    case available
    /// Authority was established and is now gone.
    case unavailable

    public var canEnforce: Bool { self == .available }
}

/// Evidence that enforcement authority went away while a hardened obligation
/// was outstanding.
///
/// **A bypass is not an Override.** An Override resolves the obligation through
/// an allowed escape path and is recorded as a resolution. A bypass resolves
/// nothing: the commitment stays exactly as owed as it was, and only Earned's
/// ability to impose the consequence changed.
///
/// `detectedAt` is honest about what is knowable. iOS does not tell a
/// backgrounded app that its Screen Time authorization was revoked — the
/// `AuthorizationCenter` publisher stays silent — so the earliest Earned can
/// learn is the next time it runs. This is the moment of *detection*, never a
/// claim about when the user acted, and never a claim about intent.
public struct EnforcementBypass: Codable, Equatable, Identifiable, Sendable {
    /// Position in this history: the first bypass is 0, the second 1, and so on.
    ///
    /// Deliberately *not* a `UUID`. Bypasses are projected during replay rather
    /// than carried in an event, so minting a random identity would make
    /// `EarnedState` differ from itself across two replays of the same ledger —
    /// exactly the impurity the ledger exists to rule out. The array is
    /// append-only, so its index is stable and replays identically. Nothing
    /// else in the model refers to a bypass by identity, so an ordinal is all
    /// the identity it needs.
    public let id: Int
    /// When Earned noticed. The actual revocation happened at or before this.
    public let detectedAt: Date
    /// The hardened, unresolved commitments outstanding at detection. These are
    /// preserved untouched — listing them records what was owed, not what was
    /// forgiven.
    public let outstandingCommitmentIDs: [UUID]
    /// Set when enforcement came back, for history to show the gap's shape.
    public internal(set) var resolvedAt: Date?

    public init(id: Int,
                detectedAt: Date,
                outstandingCommitmentIDs: [UUID],
                resolvedAt: Date? = nil) {
        self.id = id
        self.detectedAt = detectedAt
        self.outstandingCommitmentIDs = outstandingCommitmentIDs
        self.resolvedAt = resolvedAt
    }

    /// Still open — enforcement has not been restored since.
    public var isOngoing: Bool { resolvedAt == nil }
}
