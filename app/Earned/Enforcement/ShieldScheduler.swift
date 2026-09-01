import Foundation
import DeviceActivity
import EarnedKit

/// Asks the system to wake Earned's monitor extension when a Gate closes.
///
/// The app writes the plan and registers the schedules; the extension applies
/// them. Both halves are needed and neither is sufficient: a schedule with no
/// plan wakes to nothing, and a plan with no schedule is never read.
///
/// **Rewritten from scratch every time, never patched.** Stopping all
/// monitoring and re-registering is cheap, and it means the registered
/// schedules cannot drift from the plan — the alternative is reconciling two
/// pieces of state that live in different processes, which is a bug generator
/// for no benefit.
@MainActor
enum ShieldScheduler {

    /// Prefix for every `DeviceActivityName` Earned registers, so a stale one
    /// from an older build can be recognised and cleared.
    private static let prefix = "earned.shield."

    /// The system limits how many activities may be monitored at once. The
    /// documented ceiling has moved between OS versions, so this stays well
    /// under any figure it has held rather than tracking the current one — a
    /// commitment app that stopped scheduling because it asked for one slot
    /// too many would fail exactly where it matters.
    private static let maximumWindows = 8

    /// A `DeviceActivitySchedule` interval has a minimum length. Windows are
    /// given a generous tail rather than a tight one: what matters is that the
    /// interval *starts* at the deadline, since that is when the extension is
    /// woken, and an interval that outlives its usefulness costs nothing
    /// because the next plan replaces it.
    private static let windowLength: TimeInterval = 12 * 3600

    /// Recompute, persist, and re-register. Safe to call as often as the
    /// ledger changes; the result is a pure function of the state and the
    /// clock (`shieldWindows` is tested for exactly that).
    static func reschedule(for state: EarnedState, now: Date = Date()) {
        let center = DeviceActivityCenter()
        // Clear ours and only ours. `stopMonitoring()` with no argument would
        // also stop activities another feature might register later.
        let existing = center.activities.filter { $0.rawValue.hasPrefix(prefix) }
        if !existing.isEmpty { center.stopMonitoring(existing) }

        guard SharedContainer.isAvailable else { return }

        let windows = state.shieldWindows(from: now, limit: maximumWindows)
        var planned: [ShieldPlan.Window] = []

        for (index, window) in windows.enumerated() {
            let name = DeviceActivityName("\(prefix)\(index)")
            let calendar = Calendar.current
            let start = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                from: window.opensAt)
            let end = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: window.opensAt.addingTimeInterval(windowLength))

            do {
                try center.startMonitoring(
                    name,
                    during: DeviceActivitySchedule(intervalStart: start,
                                                   intervalEnd: end,
                                                   repeats: false))
            } catch {
                // One window failing must not cost the others. A missed wake
                // means the shield lands when the app is next opened, which is
                // exactly today's behaviour — degraded, not broken.
                continue
            }

            planned.append(ShieldPlan.Window(
                id: name.rawValue,
                opensAt: window.opensAt,
                applications: RestrictionBridge.applications(in: window.restrictions)
                    .compactMap(encode),
                categories: RestrictionBridge.categories(in: window.restrictions)
                    .compactMap(encode),
                webDomains: RestrictionBridge.webDomains(in: window.restrictions)
                    .compactMap(encode)))
        }

        SharedContainer.save(ShieldPlan(generatedAt: now, windows: planned))
    }

    private static func encode<T: Encodable>(_ token: T) -> Data? {
        try? JSONEncoder().encode(token)
    }
}
