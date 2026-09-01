import Foundation
import EarnedKit

/// The shared terms of a shared commitment, as the server holds them
/// (NORTHSTAR §46, docs/shared-commitments.md §2): an activity filter, a
/// completion metric, a target, a window. Deliberately the same two-dimension
/// shape as EarnedKit's `Requirement`, so what was agreed maps onto what each
/// participant's own Gate will enforce without interpretation.
struct SharedTerms: Equatable, Sendable {
    let activity: String
    let metric: String
    let target: Double?
    let windowStart: Date
    let deadline: Date

    init?(json: [String: Any]) {
        guard let activity = json["activity"] as? String,
              let metric = json["metric"] as? String,
              let startString = json["window_start"] as? String,
              let start = ISO8601DateFormatter().date(from: startString),
              let deadlineString = json["deadline"] as? String,
              let deadline = ISO8601DateFormatter().date(from: deadlineString)
        else { return nil }
        self.activity = activity
        self.metric = metric
        self.target = (json["target"] as? NSNumber)?.doubleValue
        self.windowStart = start
        self.deadline = deadline
    }

    init(requirement: Requirement, windowStart: Date, deadline: Date) {
        switch requirement.activity {
        case .any: activity = "any"
        case .types(let types):
            // The creation flow only builds single-type filters; a wider
            // filter (possible in EarnedKit, unreachable from that flow)
            // narrows to its first type rather than silently widening to
            // "any" — a shared promise must never be softer than the local one.
            activity = types.map(\.rawValue).sorted().first ?? "other"
        }
        switch requirement.metric {
        case .anyQualifyingWorkout:
            metric = "show_up"; target = nil
        case .totalDuration(let seconds):
            metric = "total_duration"; target = seconds
        case .totalDistance(let meters):
            metric = "total_distance"; target = meters
        case .totalActiveEnergy(let kilocalories):
            metric = "active_calories"; target = kilocalories
        }
        self.windowStart = windowStart
        self.deadline = deadline
    }

    /// The personal requirement acceptance creates, with the participant's own
    /// verification tier — the one dimension of "counts" that is theirs alone.
    /// Nil for terms this build cannot enforce (a metric from a newer version):
    /// an unenforceable promise must not be accepted as if it were one.
    func requirement(verification: WorkoutVerification) -> Requirement? {
        let filter: ActivityFilter = activity == "any"
            ? .any : .only(ActivityType(rawValue: activity) ?? .other)
        let metric: CompletionMetric?
        switch self.metric {
        case "show_up": metric = .anyQualifyingWorkout
        case "total_duration": metric = target.map { CompletionMetric.totalDuration($0) }
        case "total_distance": metric = target.map { CompletionMetric.totalDistance($0) }
        case "active_calories": metric = target.map { CompletionMetric.totalActiveEnergy($0) }
        default: metric = nil
        }
        guard let metric else { return nil }
        return Requirement(activity: filter, metric: metric, verification: verification)
    }

    /// "Running · 10.0 km", in the same words the creation flow uses.
    var label: String {
        let activityName = activity == "any" ? "Any workout" : activity.capitalized
        switch (metric, target) {
        case ("show_up", _): return activityName
        case ("sessions", .some(let n)): return "\(activityName) · \(Int(n))×"
        case ("total_duration", .some(let s)): return "\(activityName) · \(Format.duration(s))"
        case ("total_distance", .some(let m)):
            return String(format: "%@ · %.1f km", activityName, m / 1000)
        case ("active_calories", .some(let c)): return "\(activityName) · \(Int(c)) cal"
        default: return activityName
        }
    }

    /// One participant's line against the shared target: "6.2 / 10.0 km".
    func progressLine(progress: Double) -> String {
        switch (metric, target) {
        case ("show_up", _): return progress >= 1 ? "done" : "not yet"
        case ("sessions", .some(let n)): return "\(Int(progress)) / \(Int(n))"
        case ("total_duration", .some(let s)):
            return "\(Int(progress / 60)) / \(Int(s / 60)) min"
        case ("total_distance", .some(let m)):
            return String(format: "%.1f / %.1f km", progress / 1000, m / 1000)
        case ("active_calories", .some(let c)):
            return "\(Int(progress)) / \(Int(c)) cal"
        default: return ""
        }
    }
}

/// One roster line: a person, whether they are in, and their own self-reported
/// standing against the shared target. Representation, never enforcement
/// (invariant 28) — and never anyone's Gate but their own (invariant 30).
struct SharedParticipant: Identifiable, Equatable, Sendable {
    var id: String { handle }
    let handle: String
    let displayName: String
    let avatarPath: String?
    /// `invited` or `accepted` — the only states a roster shows. Declines are
    /// quiet; the withdrawn and departed simply are not lines.
    let state: String
    let verification: String?
    let progress: Double
    let progressState: String
    let resolvedAt: Date?

    var isAccepted: Bool { state == "accepted" }
    var isDone: Bool { progressState == "kept" || progressState == "kept_late" }

    init?(json: [String: Any]) {
        guard let handle = json["handle"] as? String,
              let name = json["display_name"] as? String,
              let state = json["state"] as? String else { return nil }
        self.handle = handle
        self.displayName = name
        self.avatarPath = json["avatar_path"] as? String
        self.state = state
        self.verification = json["verification"] as? String
        self.progress = (json["progress"] as? NSNumber)?.doubleValue ?? 0
        self.progressState = json["progress_state"] as? String ?? "open"
        self.resolvedAt = (json["resolved_at"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// A shared commitment the user stands on, roster and all, as
/// `my_shared_commitments()` returns it.
struct SharedCommitment: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let terms: SharedTerms
    /// open / closed — cancelled ones are never returned.
    let state: String
    let createdByMe: Bool
    /// The user's own personal commitment for this agreement — the link into
    /// their own ledger, where the only Gate that can lock their phone lives.
    let myCommitmentID: UUID?
    let participants: [SharedParticipant]

    init?(json: [String: Any]) {
        guard let idString = json["id"] as? String,
              let id = UUID(uuidString: idString),
              let title = json["title"] as? String,
              let terms = SharedTerms(json: json) else { return nil }
        self.id = id
        self.title = title
        self.terms = terms
        self.state = json["state"] as? String ?? "open"
        self.createdByMe = json["created_by_me"] as? Bool ?? false
        self.myCommitmentID = (json["my_commitment_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        self.participants = (json["participants"] as? [[String: Any]] ?? [])
            .compactMap(SharedParticipant.init(json:))
    }

    /// Whether the roster mixes verification tiers. Only then are tiers worth
    /// stating — a difference is a fact; a uniform label is noise.
    var mixedVerification: Bool {
        Set(participants.filter(\.isAccepted).compactMap(\.verification)).count > 1
    }
}

/// An invitation waiting on the user: the shared terms and who is asking.
/// It obliges nobody — no Gate exists anywhere until acceptance (invariant 31).
struct SharedInvitation: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let terms: SharedTerms
    let invitedAt: Date?
    let inviterHandle: String
    let inviterDisplayName: String
    let inviterAvatarPath: String?
    let acceptedCount: Int

    init?(json: [String: Any]) {
        guard let idString = json["id"] as? String,
              let id = UUID(uuidString: idString),
              let title = json["title"] as? String,
              let terms = SharedTerms(json: json),
              let inviterHandle = json["inviter_handle"] as? String,
              let inviterName = json["inviter_display_name"] as? String
        else { return nil }
        self.id = id
        self.title = title
        self.terms = terms
        self.invitedAt = (json["invited_at"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        self.inviterHandle = inviterHandle
        self.inviterDisplayName = inviterName
        self.inviterAvatarPath = json["inviter_avatar_path"] as? String
        self.acceptedCount = json["accepted_count"] as? Int ?? 0
    }
}

extension WorkoutVerification {
    /// The wire spelling the shared-commitment tables use.
    var sharedWireValue: String {
        switch self {
        case .selfReported: return "self_reported"
        case .appVerified: return "app_verified"
        }
    }
}
