import Foundation
import UserNotifications

/// One warning, already rendered into the words the user will read.
///
/// EarnedKit decides *what* to warn about and *when* (`upcomingWarnings`); the
/// app decides the wording, so the voice can change without touching the engine.
struct WarningNotification: Equatable {
    let id: String
    let fireAt: Date
    let title: String
    let body: String
}

/// Delivers the pre-deadline warnings the user asked for (NORTHSTAR §20).
///
/// **A warning is information, never a reprieve.** These notifications carry no
/// actions, no snooze and no "give me ten more minutes", because anything that
/// could buy time would be the grace period §7 and §20 both rule out. Gate state
/// is computed from the ledger and is completely unaffected by whether a
/// notification was delivered, tapped, ignored, or never authorized at all.
/// Turning notifications off makes Earned quieter, not more permissive.
///
/// These are local notifications only — no entitlement, no APNs, no server.
@MainActor
final class NotificationScheduler: ObservableObject {

    enum Authorization: Equatable {
        /// Never asked. Warnings are configured but nothing can be delivered yet.
        case notDetermined
        case granted
        /// Asked and refused, or switched off later in iOS Settings.
        case denied

        var allowsDelivery: Bool { self == .granted }
    }

    @Published private(set) var authorization: Authorization = .notDetermined

    /// Every request this app schedules is namespaced, so cleanup can never
    /// touch a notification some future part of Earned owns.
    private static let identifierPrefix = "earned.warning."

    /// Identifiers are stable per Gate, so re-registering a warning whose time
    /// moved replaces the old request instead of stacking a second one.
    static let hydrationIdentifier = identifierPrefix + "hydration"
    static func identifier(forCommitment id: UUID) -> String {
        identifierPrefix + "commitment." + id.uuidString
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = Self.authorization(from: settings.authorizationStatus)
    }

    private static func authorization(from status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default: return .denied
        }
    }

    /// Asks once, at the first moment there is actually something to deliver —
    /// a permission prompt with no warning behind it is a prompt the user has
    /// no way to evaluate.
    private func requestAuthorization() async {
        // Queued behind any other system prompt. This one is reached
        // indirectly — a ledger append reschedules warnings — so it can arrive
        // at the same instant as a prompt the user *did* ask for, and iOS
        // stacks rather than queues them (`SystemPrompts`).
        await SystemPrompts.serialized { [weak self] in
            guard let self else { return }
            do {
                let granted = try await self.center
                    .requestAuthorization(options: [.alert, .sound])
                self.authorization = granted ? .granted : .denied
            } catch {
                self.authorization = .denied
            }
        }
    }

    /// The most recent set asked for, and whether a run is already working
    /// through one. Together these coalesce bursts: creating a four-week plan
    /// appends thirteen events in a row, and each one asks for a reschedule.
    /// Running those concurrently would let one pass compute what is stale
    /// while another is still adding, so instead the in-flight pass picks up
    /// the newest set and later callers return immediately.
    private var requested: [WarningNotification] = []
    private var isRescheduling = false

    /// Makes the scheduled warnings exactly `warnings` — adds what is new,
    /// updates what moved, and removes what no longer applies.
    ///
    /// Safe to call on every ledger change: identifiers are stable per Gate, so
    /// re-registering replaces rather than duplicates.
    func reschedule(_ warnings: [WarningNotification]) async {
        requested = warnings
        guard !isRescheduling else { return }
        isRescheduling = true
        defer { isRescheduling = false }

        // Inside the guard, so a burst of callers cannot each reach the
        // permission prompt.
        if authorization == .notDetermined && !warnings.isEmpty {
            await requestAuthorization()
        }

        while true {
            let batch = requested
            await apply(batch)
            // Anything that arrived while that ran supersedes it.
            if batch == requested { return }
        }
    }

    private func apply(_ warnings: [WarningNotification]) async {
        guard authorization.allowsDelivery else {
            // Nothing can be delivered; leave no stale requests behind in case
            // permission is granted again later.
            await removeAll()
            return
        }

        let now = Date()
        let due = warnings.filter { $0.fireAt > now }
        let wanted = Set(due.map(\.id))

        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter {
            $0.hasPrefix(Self.identifierPrefix) && !wanted.contains($0)
        }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for warning in due {
            try? await center.add(request(for: warning))
        }
    }

    private func removeAll() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private func request(for warning: WarningNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = warning.title
        content.body = warning.body
        content.sound = .default
        // Deliberately no `categoryIdentifier`: no actions, no snooze. See the
        // note on this type.

        // A calendar trigger rather than an interval one, so the fire time
        // survives the app being suspended between now and then.
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let components = Calendar.current.dateComponents(fields, from: warning.fireAt)
        return UNNotificationRequest(
            identifier: warning.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}
