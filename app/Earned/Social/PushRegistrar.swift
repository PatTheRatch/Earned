import SwiftUI
import UIKit
import UserNotifications

/// Where a tapped notification should land.
///
/// Deliberately small: three kinds, because `push_outbox` has three kinds, and
/// its check constraint is the allow-list. A route carries the row the
/// recipient is already a party to — an agreement, an override request — and
/// never an account identifier.
enum PushRoute: Equatable {
    case sharedInvitation(id: UUID?)
    case partnerRequest
    case overrideApproval(id: UUID?)

    init?(userInfo: [AnyHashable: Any]) {
        let route = (userInfo["route"] as? String).flatMap(UUID.init(uuidString:))
        switch userInfo["kind"] as? String {
        case "shared_invitation":          self = .sharedInvitation(id: route)
        case "partner_request":            self = .partnerRequest
        case "override_approval_request":  self = .overrideApproval(id: route)
        default:                           return nil
        }
    }
}

/// Registers this device for the three asks that are worth a buzz, and carries
/// a tapped notification to the screen that answers it.
///
/// **Push is delivery, not authority.** Every ask it can carry already exists
/// as a row the app fetches on its own; this only means a person finds out
/// while it still matters. Nothing here is required for anything to work, and
/// refusing notifications costs timeliness rather than function — which is why
/// the permission is asked for late, once, in a place where the user can see
/// what it buys them.
@MainActor
final class PushRegistrar: NSObject, ObservableObject {

    enum Registration: Equatable {
        case notRegistered
        case registered(at: Date)
        /// APNs or our own backend refused. Kept for Diagnostics rather than
        /// shown as an error: a device that cannot register is a device that
        /// checks in-app, which is the normal state for a refused permission.
        case failed(String)

        var isRegistered: Bool { if case .registered = self { return true }; return false }
    }

    @Published private(set) var registration: Registration = .notRegistered
    /// Set when a notification is tapped, cleared once a screen has acted on
    /// it. Survives a cold start, because a launch from a notification is
    /// exactly the case where routing matters most.
    @Published var pendingRoute: PushRoute?

    /// The shared instance exists because `UIApplicationDelegate` callbacks
    /// arrive outside SwiftUI's environment. Nothing else reaches for it.
    static let shared = PushRegistrar()

    private weak var account: AccountStore?
    private var lastToken: String?

    func attach(account: AccountStore) { self.account = account }

    /// Ask iOS for the token, but only when there is already permission —
    /// registering without it silently yields nothing and looks like a bug.
    func registerIfPermitted(authorization: NotificationScheduler.Authorization) {
        guard authorization == .granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Delegate callbacks

    func received(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // A token that has not moved is not news. APNs re-issues the same one
        // on most launches, and re-registering it every time would be a write
        // per launch per device for nothing.
        guard token != lastToken else { return }
        lastToken = token
        Task { [weak self] in
            guard let self, let account = self.account else { return }
            do {
                try await account.registerPushToken(token)
                self.registration = .registered(at: Date())
            } catch {
                self.registration = .failed(Self.describe(error))
            }
        }
    }

    func failedToRegister(_ error: Error) {
        registration = .failed(Self.describe(error))
    }

    /// Sign-out gives the token back, so a shared phone does not keep buzzing
    /// for an account that is no longer on it.
    func surrenderToken() {
        guard let token = lastToken else { return }
        lastToken = nil
        registration = .notRegistered
        Task { [weak self] in try? await self?.account?.removePushToken(token) }
    }

    private static func describe(_ error: Error) -> String {
        // Trimmed and generic: this reaches Diagnostics, which a tester
        // screenshots, and an APNs error string is not for a person to read.
        String(describing: error).prefix(120).description
    }
}

// MARK: - Taps

extension PushRegistrar: UNUserNotificationCenterDelegate {

    /// A notification that arrives while Earned is open is not shown as a
    /// banner: the app is already the better surface, and the row it refers to
    /// is on screen or one refresh away.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            guard let route = PushRoute(userInfo: userInfo) else { return }
            PushRegistrar.shared.pendingRoute = route
        }
    }
}

/// The three `UIApplicationDelegate` callbacks SwiftUI has no equivalent for.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushRegistrar.shared
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { PushRegistrar.shared.received(deviceToken: token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRegistrar.shared.failedToRegister(error) }
    }
}
