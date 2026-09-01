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
    /// The windows last handed to the system, so a ticking clock does not
    /// re-register them sixty times a minute.
    ///
    /// `ScreenTimeController.apply` has had the equivalent guard since it was
    /// written, and this function needed it more: applying a shield is one
    /// write to a settings store, while rescheduling is a stop plus up to eight
    /// starts, each a synchronous round trip to the DeviceActivity daemon. Run
    /// from the one-second ticker that is exactly ten of those per second, on
    /// the main thread, forever.
    ///
    /// Nothing caught it because none of this code could run at all until
    /// somebody granted Screen Time on a real device — the caller returns at
    /// `canShield` — and until that happened the whole path was dead.
    private static var registered: [ShieldWindow]?

    /// Forget what is registered, so the next `reschedule` genuinely
    /// re-registers. For the foreground pass: schedules can be dropped by the
    /// system, or by an authorization that went away and came back, and the
    /// cache above would otherwise report everything fine forever.
    static func invalidate() { registered = nil }

    static func reschedule(for state: EarnedState, now: Date = Date()) {
        let windows = state.shieldWindows(from: now, limit: maximumWindows)
        // The windows are deadlines, so a second passing does not move them:
        // the common case by far is that this is the same answer as last time
        // and there is nothing to do — including nothing to undo.
        guard windows != registered else { return }
        // Recorded before the work, not after. A window that fails to register
        // must not be retried on the next tick — that is the storm again, in
        // the one case where it also never succeeds.
        registered = windows

        let center = DeviceActivityCenter()
        // Clear ours and only ours. `stopMonitoring()` with no argument would
        // also stop activities another feature might register later.
        let existing = center.activities.filter { $0.rawValue.hasPrefix(prefix) }
        if !existing.isEmpty { center.stopMonitoring(existing) }

        guard SharedContainer.isAvailable else { return }

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

    /// Write what the shield should say about the Gates that are closed *now*.
    ///
    /// Separate from `reschedule` on purpose. The plan describes the future and
    /// only changes when the ledger does; this describes the present and is
    /// rewritten on every pass, because it is what a stranger process will read
    /// at an hour of the user's choosing.
    ///
    /// Nothing here counts down. Progress figures are safe to state because the
    /// only route by which they can change is a Health import, which happens
    /// inside the app — so while the app is closed these numbers are frozen and
    /// still true. A remaining-time figure would not be: it would keep shrinking
    /// in the user's head while the file said otherwise.
    /// The lines last written, for the same reason `registered` exists: this is
    /// also on the one-second path, and rewriting an identical file sixty times
    /// a minute is disk traffic in exchange for nothing.
    private static var published: [String]?

    static func publishCopy(for access: AccessState) {
        guard SharedContainer.isAvailable else { return }
        let lines = access.lockReasons.map(line(for:))
        guard lines != published else { return }
        published = lines
        SharedContainer.save(ShieldCopy(generatedAt: Date(), lines: lines))
    }

    private static func line(for reason: LockReason) -> String {
        switch reason.gate {
        case .hydration:
            // No progress figure and no negotiation: a glass of water is the
            // only way out of hydration, so the line is the instruction.
            return "Drink some water."
        case .commitment:
            guard let progress = reason.progress, progress.required > 0 else {
                return "\(reason.headline)."
            }
            return "\(reason.headline) — \(measure(progress))."
        }
    }

    /// The same arithmetic the locked notice shows, in sentence case: this
    /// screen is a sentence, not a row in a table.
    private static func measure(_ progress: CommitmentProgress) -> String {
        switch progress.unit {
        case .workouts:
            return progress.achieved >= progress.required ? "done" : "still owed"
        case .seconds:
            return "\(Int(progress.achieved / 60)) of \(Int(progress.required / 60)) min"
        case .meters:
            return String(format: "%.1f of %.1f km", progress.achieved / 1000,
                          progress.required / 1000)
        case .kilocalories:
            return "\(Int(progress.achieved)) of \(Int(progress.required)) cal"
        }
    }

    /// Give up every scheduled wake-up and empty the plan.
    ///
    /// For when Screen Time authorization has gone away. The app's own shield
    /// is dropped in that case (`ScreenTimeController.clear()`) on the grounds
    /// that holding restrictions the user can no longer manage is a trap — and
    /// the same argument applies to restrictions scheduled for later, which
    /// were simply invisible. Leaving them registered also left a plan
    /// describing a state that may be months stale by the time authorization
    /// returns; `reschedule` rebuilds both from scratch, so there is nothing
    /// to preserve.
    static func clear() {
        let center = DeviceActivityCenter()
        let existing = center.activities.filter { $0.rawValue.hasPrefix(prefix) }
        if !existing.isEmpty { center.stopMonitoring(existing) }
        SharedContainer.save(ShieldPlan(generatedAt: Date(), windows: []))
        // And the copy with it. Authorization is gone, so nothing of Earned's
        // is shielding anything; leaving lines behind would mean a shield
        // raised by some other app one day could show Earned's obligations.
        SharedContainer.save(ShieldCopy(generatedAt: Date(), lines: []))
        // Both caches too, or the next `reschedule` after authorization comes
        // back would compare against windows that are no longer registered and
        // decide there is nothing to do.
        registered = nil
        published = []
    }

    private static func encode<T: Encodable>(_ token: T) -> Data? {
        try? JSONEncoder().encode(token)
    }
}
