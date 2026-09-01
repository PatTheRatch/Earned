import Foundation

/// When the shield must change, and to what — computed ahead of time so
/// something other than the app can apply it.
///
/// Enforcement today runs only while Earned is open: `EarnedStore` recomputes
/// the effective restrictions and writes them to `ManagedSettingsStore` on
/// every event and every foreground. That leaves one hole, and it is not a
/// small one — a deadline that passes while the app is closed shields nothing
/// until the app is next opened, and since there is no reason to open Earned
/// except to make commitments, *not opening it* is a complete bypass.
///
/// Closing that needs the system to wake something at the right moment, which
/// means knowing the right moments in advance. That is what this computes: the
/// instants at which the union of closed Gates changes, and what it changes
/// to, assuming nothing else happens in between.
///
/// **"Assuming nothing else happens" is doing real work in that sentence.** A
/// workout recorded while the app is closed is not in this projection, so a
/// commitment the user has actually satisfied can still be shielded at its
/// deadline until Earned next runs and learns about it. That is the acceptable
/// direction of the two: locked slightly too long, never let off early. The
/// reverse — predicting satisfaction that has not been recorded — would be the
/// app inventing permission, which is what the whole product exists not to do.
public struct ShieldWindow: Equatable, Sendable {
    /// The instant the restrictions below take effect.
    public let opensAt: Date
    /// What is shielded from `opensAt` until the next window opens.
    public let restrictions: RestrictionProfile

    public init(opensAt: Date, restrictions: RestrictionProfile) {
        self.opensAt = opensAt
        self.restrictions = restrictions
    }
}

extension EarnedState {

    /// A Gate closes *after* its deadline, not at it — `isOverdue` is
    /// `now > deadline`, strictly. So the restrictions belonging to a window
    /// are the ones in force an instant after it opens, and asking at the
    /// exact transition returns the state that is ending rather than the one
    /// beginning.
    ///
    /// This is not a rounding detail. Evaluated at the boundary, every window
    /// would carry the *pre-deadline* profile — usually empty — and the whole
    /// mechanism would schedule itself faithfully and then shield nothing.
    /// A second is far below the granularity anything can be scheduled at, and
    /// comfortably above zero, which is the only property required.
    static let transitionEpsilon: TimeInterval = 1

    /// The next changes to the shield, soonest first.
    ///
    /// Only *changes*: a transition that leaves the same apps blocked is
    /// dropped, because waking the device to write the settings it already has
    /// spends a scheduling slot and a battery wake-up to accomplish nothing.
    /// The first window is measured against what is in force at `now`, so a
    /// plan generated twice in a row produces the same answer.
    ///
    /// - Parameter limit: how many windows to return. The system caps how many
    ///   activities may be monitored at once, so this is bounded on purpose
    ///   rather than by exhausting the schedule.
    public func shieldWindows(from now: Date, limit: Int = 10) -> [ShieldWindow] {
        guard limit > 0 else { return [] }
        var windows: [ShieldWindow] = []
        var cursor = now
        var previous = accessState(now: now).effectiveRestrictions

        // `nextTransition` returns strictly later dates, so this terminates
        // whether or not the limit is reached.
        while windows.count < limit, let next = nextTransition(after: cursor) {
            let inForce = accessState(now: next.addingTimeInterval(Self.transitionEpsilon))
                .effectiveRestrictions
            if inForce != previous {
                windows.append(ShieldWindow(opensAt: next, restrictions: inForce))
                previous = inForce
            }
            cursor = next
        }
        return windows
    }
}
