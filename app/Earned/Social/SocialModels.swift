import Foundation

/// The caller's own Earned profile, as `my_profile()` returns it.
///
/// Note what is absent: any id. Handles are the only name the social layer
/// speaks — account ids are deliberately not a discovery mechanism, so the
/// app never learns another user's, and has no reason to pass around its own.
struct SocialProfile: Equatable, Sendable {
    let handle: String
    let displayName: String
    let avatarPath: String?
    let city: String?
    let timezone: String?
    let discoverable: Bool
    /// The sharing switches, all born off (invariant 26).
    let shareStreaks: Bool
    let shareOverrideUsage: Bool
    let shareLastCheckin: Bool

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
        self.timezone = json["timezone"] as? String
        self.discoverable = json["discoverable"] as? Bool ?? true
        self.shareStreaks = json["share_streaks"] as? Bool ?? false
        self.shareOverrideUsage = json["share_override_usage"] as? Bool ?? false
        self.shareLastCheckin = json["share_last_checkin"] as? Bool ?? false
    }
}

/// Another user, as friend lists, request lists and search results carry them:
/// the minimum a human needs to recognise a person. City only ever arrives for
/// accepted friends; the server decides that, not this struct.
struct SocialPerson: Identifiable, Equatable, Sendable {
    var id: String { handle }
    let handle: String
    let displayName: String
    let avatarPath: String?
    let city: String?
    /// The quiet block (docs/social-architecture.md §10): whole days since
    /// Earned last heard from this friend, present only when they share
    /// check-ins *and* the silence has passed the server's threshold. Its
    /// absence deliberately means "recently active OR not sharing".
    let quietDays: Int?
    let openSharedCommitments: Int?

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
        self.quietDays = json["quiet_days"] as? Int
        self.openSharedCommitments = json["open_shared_commitments"] as? Int
    }
}

/// A profile as the caller is allowed to see it, with the relationship from
/// the caller's side. `get_profile` returning nothing at all — not found,
/// blocked, undiscoverable — is represented by the absence of this value.
struct PublicProfile: Equatable, Sendable {
    enum Relationship: String, Sendable {
        case none
        case friend
        case pendingOutgoing = "pending_outgoing"
        case pendingIncoming = "pending_incoming"
        /// Blocked *by the caller*. The other direction is never visible.
        case blocked
    }

    let handle: String
    let displayName: String
    let avatarPath: String?
    let city: String?
    let relationship: Relationship
    /// Present only for friends whose owner shares streaks. `sinceLastOverride`
    /// nil while kept non-nil means "no Overrides yet" — a different sentence
    /// from zero, and the server preserves the distinction.
    let commitmentsKept: Int?
    let sinceLastOverride: Int?
    /// The quiet block, friends only, same semantics as `SocialPerson`.
    let quietDays: Int?
    let openSharedCommitments: Int?

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
        self.relationship = (json["relationship"] as? String)
            .flatMap(Relationship.init(rawValue:)) ?? .none
        self.commitmentsKept = json["commitments_kept"] as? Int
        self.sinceLastOverride = json["since_last_override"] as? Int
        self.quietDays = json["quiet_days"] as? Int
        self.openSharedCommitments = json["open_shared_commitments"] as? Int
    }
}

/// One line on the Recent shelf: who, what, when. Meaningful events only —
/// the server never mints one per app-open, and hydration never appears.
struct SocialEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case commitmentShared = "commitment_shared"
        case commitmentKept = "commitment_kept"
        case commitmentKeptLate = "commitment_kept_late"
        case overrideUsed = "override_used"
        case streakMilestone = "streak_milestone"
    }

    /// The server sends no event id; the tuple is identity enough for a
    /// bounded, read-only list.
    var id: String { "\(handle)|\(kind.rawValue)|\(occurredAt.timeIntervalSince1970)|\(title ?? "")" }

    let handle: String
    let displayName: String
    let avatarPath: String?
    let kind: Kind
    let title: String?
    let milestone: Int?
    let occurredAt: Date

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String,
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let occurredString = json["occurred_at"] as? String,
              let occurred = ISO8601DateFormatter().date(from: occurredString)
        else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.kind = kind
        self.title = json["title"] as? String
        self.milestone = json["milestone"] as? Int
        self.occurredAt = occurred
    }

    /// The receipt-language line, minus the name (the row renders that).
    var phrase: String {
        switch kind {
        case .commitmentShared: return "committed: \(title ?? "a commitment")"
        case .commitmentKept: return "kept it: \(title ?? "a commitment")"
        case .commitmentKeptLate: return "kept it, late: \(title ?? "a commitment")"
        case .overrideUsed: return "used an Override on \(title ?? "a commitment")"
        case .streakMilestone:
            return "hit \(milestone ?? 0) commitments kept in a row"
        }
    }
}

/// Pending friend requests, both directions.
struct FriendRequests: Equatable, Sendable {
    var incoming: [SocialPerson] = []
    var outgoing: [SocialPerson] = []
    var isEmpty: Bool { incoming.isEmpty && outgoing.isEmpty }
}

extension String {
    /// Initials for the default avatar: the poster identity degrades to
    /// typography, never to a broken-image glyph.
    var initials: String {
        let parts = split(separator: " ").prefix(2).compactMap(\.first)
        if parts.isEmpty { return "?" }
        return String(parts).uppercased()
    }

    /// Client-side mirror of the server's handle normalisation, so what the
    /// user sees in the field is what the server will store. The server
    /// remains the one enforcing it.
    var normalizedHandle: String {
        var trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }
        return trimmed.lowercased()
    }

    var isPlausibleHandle: Bool {
        let normalized = normalizedHandle
        return normalized.count >= 3 && normalized.count <= 20
            && normalized.allSatisfy { $0.isLowercase && $0.isASCII || $0.isNumber || $0 == "_" }
    }
}
