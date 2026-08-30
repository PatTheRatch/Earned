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
        case .approved: return .approved
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// Asks for Screen Time permission. `.individual` is the right scope:
    /// Earned is a deal with yourself, not a parent restricting a child.
    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authorization = .approved
        } catch {
            authorization = Self.authorization(from: AuthorizationCenter.shared.authorizationStatus)
        }
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
