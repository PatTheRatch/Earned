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
        var label: String { self == .sms ? "Text message" : "Email" }
        var placeholder: String { self == .sms ? "+1 415 555 0100" : "name@example.com" }
    }

    let id: UUID
    let displayName: String
    let channel: Channel
    let state: State
    let askedAt: Date?
    let consentedAt: Date?
    /// Whether a reminder can still be sent: one only, and not for 72 hours.
    let canResend: Bool
}

extension Partner {
    /// Built from the row PostgREST returns. Tolerant on purpose: an unknown
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
        self.state = state
        self.askedAt = asked
        self.consentedAt = Partner.date(row["consented_at"])
        // Mirrors the server's rule so the button isn't offered and then
        // refused. The server is still the one enforcing it.
        self.canResend = state == .invited
            && row["consent_resent_at"] == nil
            && (asked.map { Date().timeIntervalSince($0) >= 72 * 3600 } ?? false)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}
