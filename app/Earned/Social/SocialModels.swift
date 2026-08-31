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

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
        self.timezone = json["timezone"] as? String
        self.discoverable = json["discoverable"] as? Bool ?? true
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

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
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

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.city = json["city"] as? String
        self.relationship = (json["relationship"] as? String)
            .flatMap(Relationship.init(rawValue:)) ?? .none
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
