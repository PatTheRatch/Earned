import Foundation

/// An accountability partner, as the app knows them.
///
/// The app never holds a contact address. It sends one to the server once, at
/// nomination, and from then on works entirely in display names and ids — the
/// number itself is normalised, encrypted and blind-indexed server-side and is
/// never returned (§14.1). So there is no `contact` property here, and adding
/// one would be a real change in what the app is trusted with.
struct Partner: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        /// Asked, no answer yet. **Not eligible for a roster** (invariant 22).
        case invited
        /// Consented. The only state that may be counted on in a contract.
        case active
        /// Said no. Globally suppressed — they cannot be asked again, by anyone.
        case declined
        /// Removed by the account holder. Not a refusal, so no suppression.
        case revoked

        var label: String {
            switch self {
            case .invited: return "Awaiting consent"
            case .active: return "Active"
            case .declined: return "Declined"
            case .revoked: return "Removed"
            }
        }

        /// The single question a contract roster asks.
        var isEligibleForRoster: Bool { self == .active }
    }

    enum Channel: String, Sendable, CaseIterable {
        case sms, email
        /// An authenticated Earned account: the ask and the consent both
        /// happen in-app, and there is no address anywhere.
        case earned
        var label: String {
            switch self {
            case .sms: return "Text message"
            case .email: return "Email"
            case .earned: return "Earned user"
            }
        }
        var placeholder: String { self == .sms ? "+1 415 555 0100" : "name@example.com" }
        /// The channels a person can be *invited through from outside* —
        /// what the external invite form offers. Earned users are nominated
        /// through a friendship instead.
        static var allCases: [Channel] { [.sms, .email] }
    }

    enum Kind: String, Sendable {
        case unverifiedContact = "unverified_contact"
        case earnedUser = "earned_user"
    }

    let id: UUID
    let displayName: String
    let channel: Channel
    let kind: Kind
    /// The partner's current handle, for `kind == .earnedUser` — read live
    /// from their account, because the authenticated identity is the
    /// authority and the display name is only a label.
    let handle: String?
    let state: State
    let askedAt: Date?
    let consentedAt: Date?
    /// Whether a reminder can still be sent: one only, and not for 72 hours.
    /// Never for earned partners — there is no message to resend.
    let canResend: Bool
}

extension Partner {
    /// Built from a `my_partners()` entry. Tolerant on purpose: an unknown
    /// status from a newer server is dropped rather than crashing an older app.
    init?(row: [String: Any]) {
        guard let idString = row["id"] as? String, let id = UUID(uuidString: idString),
              let name = row["display_name"] as? String,
              let channel = (row["channel"] as? String).flatMap(Channel.init(rawValue:)),
              let state = (row["status"] as? String).flatMap(State.init(rawValue:))
        else { return nil }

        let asked = Partner.date(row["consent_asked_at"])
        self.id = id
        self.displayName = name
        self.channel = channel
        self.kind = (row["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .unverifiedContact
        self.handle = row["handle"] as? String
        self.state = state
        self.askedAt = asked
        self.consentedAt = Partner.date(row["consented_at"])
        // Mirrors the server's rule so the button isn't offered and then
        // refused. The server is still the one enforcing it. (Cast rather
        // than nil-check: jsonb null arrives as NSNull, which is not nil.)
        self.canResend = channel != .earned
            && state == .invited
            && row["consent_resent_at"] as? String == nil
            && (asked.map { Date().timeIntervalSince($0) >= 72 * 3600 } ?? false)
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}

/// An incoming ask: another Earned user wants the current user as *their*
/// accountability partner. The id is the relationship row, not anyone's
/// account; the handle is the identity a friend already sees.
struct PartnerRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let requesterHandle: String
    let requesterDisplayName: String
    let askedAt: Date?

    init?(json: [String: Any]) {
        guard let idString = json["id"] as? String, let id = UUID(uuidString: idString),
              let handle = json["requester_handle"] as? String,
              let name = json["requester_display_name"] as? String else { return nil }
        self.id = id
        self.requesterHandle = handle
        self.requesterDisplayName = name
        self.askedAt = Partner.date(json["asked_at"])
    }
}

/// An override approval waiting on the current user, as an earned partner.
/// Rendered from the same frozen snapshot the web approval page shows — the
/// contract half is the server's own; the self-reported half came from the
/// requester's phone and is labelled accordingly (§7).
struct PendingApproval: Identifiable, Equatable, Sendable {
    var id: UUID { recipientID }
    let recipientID: UUID
    let requesterName: String
    let title: String
    let approvalsRequired: Int
    let progressAchieved: Double?
    let progressRequired: Double?
    let progressUnit: String?
    let reliabilityCompleted: Int?
    let reliabilityOf: Int?
    let reason: String?
    let expiresAt: Date?

    init?(json: [String: Any]) {
        guard json["page"] as? String == "request",
              let idString = json["recipient_id"] as? String,
              let id = UUID(uuidString: idString),
              let snapshot = json["snapshot"] as? [String: Any],
              let contract = snapshot["contract"] as? [String: Any],
              let title = contract["commitment_title"] as? String,
              let requester = contract["requester_display_name"] as? String
        else { return nil }
        let reported = snapshot["self_reported"] as? [String: Any]
        let progress = reported?["progress"] as? [String: Any]
        let reliability = reported?["reliability_30d"] as? [String: Any]
        self.recipientID = id
        self.requesterName = requester
        self.title = title
        self.approvalsRequired = contract["approvals_required"] as? Int ?? 0
        self.progressAchieved = progress?["achieved"] as? Double
        self.progressRequired = progress?["required"] as? Double
        self.progressUnit = progress?["unit"] as? String
        self.reliabilityCompleted = reliability?["completed"] as? Int
        self.reliabilityOf = reliability?["of"] as? Int
        self.reason = reported?["reason"] as? String
        self.expiresAt = Partner.date(json["expires_at"])
    }
}
