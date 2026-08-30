import Foundation
import FamilyControls
import ManagedSettings
import EarnedKit

/// Applies the restrictions EarnedKit computes, using Apple's Screen Time API.
///
/// This is where Earned stops describing a lock and starts being one. EarnedKit
/// decides *what* is restricted (`accessState.effectiveRestrictions`, the union
/// across every unsatisfied Gate); this type only puts that into force.
///
/// **It fails closed, deliberately.** A shield written to `ManagedSettingsStore`
/// persists in the system until something changes it, so if Earned is never
/// opened again the restriction stays. That is the right direction to fail for
/// a commitment app: the failure mode is being locked out slightly too long,
/// never being let off early.
@MainActor
final class ScreenTimeController: ObservableObject {

    enum Authorization: Equatable {
        case notDetermined
        case approved
        /// Refused, or revoked later in Settings. Nothing can be shielded.
        case denied

        var canShield: Bool { self == .approved }
    }

    @Published private(set) var authorization: Authorization = .notDetermined

    private let store = ManagedSettingsStore()
    /// What is currently in force, so a one-second UI tick doesn't rewrite the
    /// system's settings sixty times a minute.
    private var applied: RestrictionProfile?

    func refreshAuthorization() {
        authorization = Self.authorization(from: AuthorizationCenter.shared.authorizationStatus)
    }

    private static func authorization(from status: AuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .approved: return .approved
        // Recent iOS grants Screen Time *with* usage-data access, and on some
        // versions that is the only "yes" the user can give. It is an approval,
        // and treating it as anything else silently breaks every shield.
        case .approvedWithDataAccess: return .approved
        @unknown default:
            // A future status we don't recognise. Assume it is not permission
            // to restrict — the shield should never be applied on a guess.
            return .denied
        }
    }

    /// Why the last authorization attempt failed, if it did.
    ///
    /// This is surfaced rather than swallowed: Screen Time can refuse for
    /// reasons the user can act on (not signed in to iCloud, a managed or child
    /// account) and a button that silently does nothing is the worst possible
    /// version of that.
    @Published private(set) var failure: String?

    /// Asks for Screen Time permission. `.individual` is the right scope:
    /// Earned is a deal with yourself, not a parent restricting a child.
    func requestAuthorization() async {
        failure = nil
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authorization = Self.authorization(from: AuthorizationCenter.shared.authorizationStatus)
            // Belt and braces: the request succeeded, so treat it as approval
            // even if the status hasn't settled yet.
            if authorization == .notDetermined { authorization = .approved }
        } catch {
            // FamilyControlsError is an enum, so this yields the case name
            // (`invalidAccountType`, `networkError`, …) which is far more use
            // than its localizedDescription.
            let name = String(describing: error)
            authorization = Self.authorization(from: AuthorizationCenter.shared.authorizationStatus)
            // Dismissing the sheet is a choice, not a fault.
            if !name.localizedCaseInsensitiveContains("cancel") {
                failure = Self.explain(name)
            }
        }
    }

    private static func explain(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("invalidAccountType") {
            return "Screen Time needs an Apple Account signed in to iCloud on this device, "
                + "and one that isn't managed by someone else. (\(name))"
        }
        if name.localizedCaseInsensitiveContains("network") {
            return "Screen Time couldn't reach Apple to set this up. Check your connection "
                + "and try again. (\(name))"
        }
        if name.localizedCaseInsensitiveContains("unavailable")
            || name.localizedCaseInsensitiveContains("restricted") {
            return "Screen Time isn't available on this device. (\(name))"
        }
        return "Screen Time refused: \(name)"
    }

    /// Puts `profile` into force, replacing whatever was in force before.
    /// A no-op when nothing changed, so this is safe to call on every tick.
    func apply(_ profile: RestrictionProfile) {
        guard authorization.canShield else { return }
        guard applied != profile else { return }
        applied = profile

        let applications = RestrictionBridge.applications(in: profile)
        let categories = RestrictionBridge.categories(in: profile)
        let webDomains = RestrictionBridge.webDomains(in: profile)

        // nil clears a shield; an empty set is not the same thing.
        store.shield.applications = applications.isEmpty ? nil : applications
        store.shield.applicationCategories = categories.isEmpty
            ? nil : .specific(categories)
        store.shield.webDomains = webDomains.isEmpty ? nil : webDomains
    }

    /// Drops every shield. Used when authorization goes away — continuing to
    /// hold restrictions the user can no longer see or manage would be a trap.
    func clear() {
        applied = nil  // so the next apply always runs, even for an empty profile
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
    }
}
