import Foundation

/// Daily window during which the Hydration Gate is live. Outside it the gate is
/// dormant (treated as satisfied). Minutes are measured from midnight in the
/// configured time zone; overnight windows (end <= start) are not supported.
public struct ActiveHours: Codable, Equatable, Sendable {
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int
    public var timeZoneIdentifier: String

    public init(startMinuteOfDay: Int, endMinuteOfDay: Int, timeZoneIdentifier: String) {
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var isValid: Bool {
        startMinuteOfDay >= 0 && endMinuteOfDay <= 24 * 60
            && startMinuteOfDay < endMinuteOfDay
            && TimeZone(identifier: timeZoneIdentifier) != nil
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)! }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// The window containing or most recently preceding `date`'s day.
    func window(containing date: Date) -> (open: Date, close: Date) {
        let startOfDay = calendar.startOfDay(for: date)
        let open = startOfDay.addingTimeInterval(TimeInterval(startMinuteOfDay * 60))
        let close = startOfDay.addingTimeInterval(TimeInterval(endMinuteOfDay * 60))
        return (open, close)
    }

    func contains(_ date: Date) -> Bool {
        let w = window(containing: date)
        return date >= w.open && date < w.close
    }

    /// The next window open strictly after `date`.
    func nextOpen(after date: Date) -> Date {
        let today = window(containing: date)
        if date < today.open { return today.open }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return tomorrow.addingTimeInterval(TimeInterval(startMinuteOfDay * 60))
    }
}

public struct HydrationConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Rolling interval between acknowledgments, in seconds.
    public var interval: TimeInterval
    public var activeHours: ActiveHours
    /// Optional warning lead time before expiry, in seconds.
    public var warningLead: TimeInterval?

    public init(enabled: Bool = true, interval: TimeInterval, activeHours: ActiveHours, warningLead: TimeInterval? = nil) {
        self.enabled = enabled
        self.interval = interval
        self.activeHours = activeHours
        self.warningLead = warningLead
    }

    /// Whether adopting `self` in place of `other` makes the gate at least as hard.
    /// Harder means: enabled where it wasn't, a shorter interval, or wider active hours.
    /// (Warning lead is informational and never affects hardness.)
    func isAtLeastAsHard(as other: HydrationConfig) -> Bool {
        guard enabled else { return !other.enabled }
        guard other.enabled else { return true }
        return interval <= other.interval
            && activeHours.startMinuteOfDay <= other.activeHours.startMinuteOfDay
            && activeHours.endMinuteOfDay >= other.activeHours.endMinuteOfDay
    }
}

/// The Hydration Gate's status at a moment in time.
public enum HydrationStatus: Equatable, Sendable {
    /// Outside active hours or gate disabled/unconfigured — treated as satisfied.
    case dormant
    /// Inside active hours with time left on the rolling timer.
    case satisfied(expiresAt: Date)
    /// Timer expired inside active hours; unsatisfied until water is acknowledged.
    case unsatisfied(expiredAt: Date)

    public var isSatisfied: Bool {
        if case .unsatisfied = self { return false }
        return true
    }
}

extension HydrationConfig {
    /// Pure status computation. The timer anchors on the later of the last
    /// acknowledgment and the current window's open — so each day starts
    /// satisfied with a fresh interval (NORTHSTAR §18, Active hours).
    func status(lastAcknowledgment: Date?, now: Date) -> HydrationStatus {
        guard enabled else { return .dormant }
        guard activeHours.contains(now) else { return .dormant }
        let windowOpen = activeHours.window(containing: now).open
        let anchor = max(lastAcknowledgment ?? .distantPast, windowOpen)
        let expiry = anchor.addingTimeInterval(interval)
        return now < expiry ? .satisfied(expiresAt: expiry) : .unsatisfied(expiredAt: expiry)
    }

    /// The next moment the gate's satisfaction could change without any new event.
    func nextTransition(lastAcknowledgment: Date?, now: Date) -> Date? {
        guard enabled else { return nil }
        switch status(lastAcknowledgment: lastAcknowledgment, now: now) {
        case .satisfied(let expiresAt):
            // Expiry may fall past window close, in which case the gate goes
            // dormant (still satisfied) and nothing observable changes today.
            let close = activeHours.window(containing: now).close
            if expiresAt < close { return expiresAt }
            return nextOpenExpiry(after: now)
        case .unsatisfied:
            // Window close returns the gate to dormant-satisfied.
            return activeHours.window(containing: now).close
        case .dormant:
            return nextOpenExpiry(after: now)
        }
    }

    /// Earliest possible expiry in the next window: open + interval (bounded by close).
    private func nextOpenExpiry(after date: Date) -> Date? {
        let open = activeHours.nextOpen(after: date)
        let close = open.addingTimeInterval(TimeInterval((activeHours.endMinuteOfDay - activeHours.startMinuteOfDay) * 60))
        let expiry = open.addingTimeInterval(interval)
        return expiry < close ? expiry : nil
    }
}
