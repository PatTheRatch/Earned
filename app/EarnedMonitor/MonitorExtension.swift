import DeviceActivity
import Foundation
import ManagedSettings

/// The half of enforcement that runs when Earned does not.
///
/// Until this existed, a shield was applied only while the app was open, so a
/// deadline passing with Earned closed shielded nothing until it was next
/// launched — and since there is no reason to open the app except to make
/// commitments, simply not opening it was a complete bypass.
///
/// The system wakes this at each moment the app registered, under the name it
/// registered it with. All it does is look that name up in the shared plan and
/// write the settings. **Every decision was made before it ran** — what closes
/// when, and what that closes — because this process has a small memory
/// budget, no user interface, and no opportunity to ask anyone anything.
///
/// It is deliberately almost empty. Everything that could be wrong here is
/// instead wrong somewhere it can be tested: `EarnedState.shieldWindows`
/// decides the moments, and the app decides the tokens.
final class MonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        apply(named: activity.rawValue)
    }

    /// Not a mirror of `intervalDidStart`, on purpose.
    ///
    /// An interval ending means this window's schedule has run out, not that
    /// the obligation behind it was met — nothing here can know whether the
    /// user ran. Clearing the shield on that signal would let anyone out by
    /// waiting, which is the one failure this whole product is built to
    /// prevent. Shields are lifted by the app, when the ledger says the Gate
    /// opened, and by nothing else.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
    }

    private func apply(named id: String) {
        guard let window = SharedContainer.loadPlan()?.window(named: id) else {
            // No plan, or a name from a build that has since been replaced.
            // Leaving the current shield alone is the safe reading: a stale
            // wake-up must never *lift* a restriction it cannot account for.
            return
        }

        let applications = window.applications.compactMap(decode(ApplicationToken.self))
        let categories = window.categories.compactMap(decode(ActivityCategoryToken.self))
        let webDomains = window.webDomains.compactMap(decode(WebDomainToken.self))

        // nil clears a shield; an empty set does not mean the same thing —
        // the same distinction the app's own shielding path depends on.
        store.shield.applications = applications.isEmpty ? nil : Set(applications)
        store.shield.applicationCategories = categories.isEmpty
            ? nil : .specific(Set(categories))
        store.shield.webDomains = webDomains.isEmpty ? nil : Set(webDomains)
    }

    private func decode<T: Decodable>(_ type: T.Type) -> (Data) -> T? {
        { try? JSONDecoder().decode(type, from: $0) }
    }
}
