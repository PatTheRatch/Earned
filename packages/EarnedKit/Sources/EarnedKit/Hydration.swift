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
    /// What the Hydration Gate takes away while it is unsatisfied. This is
    /// deliberately its own profile, separate from any exercise commitment's:
    /// the first-user intent is that an unmet Hydration Gate is the most severe
    /// state the phone can be in (NORTHSTAR §6).
    public var restrictions: RestrictionProfile
    /// Optional warning lead time before expiry, in seconds.
    public var warningLead: TimeInterval?

    public init(enabled: Bool = true,
                interval: TimeInterval,
                activeHours: ActiveHours,
                restrictions: RestrictionProfile = .none,
                warningLead: TimeInterval? = nil) {
        self.enabled = enabled
        self.interval = interval
        self.activeHours = activeHours
        self.restrictions = restrictions
        self.warningLead = warningLead
    }

    /// Whether adopting `self` in place of `other` makes the gate at least as hard.
    /// Harder means: enabled where it wasn't, a shorter interval, wider active
    /// hours, or a stricter restriction profile.
    /// (Warning lead is informational and never affects hardness.)
    func isAtLeastAsHard(as other: HydrationConfig) -> Bool {
        guard enabled else { return !other.enabled }
        guard other.enabled else { return true }
        return interval <= other.interval
            && activeHours.startMinuteOfDay <= other.activeHours.startMinuteOfDay
            && activeHours.endMinuteOfDay >= other.activeHours.endMinuteOfDay
            && restrictions.isAtLeastAsStrict(as: other.restrictions)
    }
}

// MARK: - Backward-compatible decoding

extension HydrationConfig {
    private enum CodingKeys: String, CodingKey {
        case enabled, interval, activeHours, restrictions, warningLead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        interval = try container.decode(TimeInterval.self, forKey: .interval)
        activeHours = try container.decode(ActiveHours.self, forKey: .activeHours)
        warningLead = try container.decodeIfPresent(TimeInterval.self, forKey: .warningLead)
        restrictions = try container.decodeIfPresent(RestrictionProfile.self, forKey: .restrictions) ?? .none
    }
}

/// The Hydration Gate's status at a moment in time.
public enum HydrationStatus: Equatable, Sendable {
    /// Outside active hours or gate disabled/unconfigured — treated as satisfied.
    case dormant
    /// Acknowledged within the current window, with time left on the rolling timer.
    case satisfied(expiresAt: Date)
    /// Inside active hours with no live acknowledgment. `since` is when the gate
    /// became unsatisfied: the window opening, or the last timer's expiry.
    case unsatisfied(since: Date)

    public var isSatisfied: Bool {
        if case .unsatisfied = self { return false }
        return true
    }
}

extension HydrationConfig {
    /// Pure status computation.
    ///
    /// **The window opens unsatisfied.** There is no free interval at the start
    /// of the day: from the moment active hours begin, the Hydration Gate is
    /// closed until water is acknowledged, and its restriction profile applies
    /// immediately. Acknowledging starts the rolling interval; when that expires
    /// the gate closes again. Only an acknowledgment made *within the current
    /// window* counts — yesterday's water does not open today.
    func status(lastAcknowledgment: Date?, now: Date) -> HydrationStatus {
        guard enabled else { return .dormant }
        guard activeHours.contains(now) else { return .dormant }
        let windowOpen = activeHours.window(containing: now).open

        guard let acknowledged = lastAcknowledgment, acknowledged >= windowOpen else {
            return .unsatisfied(since: windowOpen)
        }
        let expiry = acknowledged.addingTimeInterval(interval)
        return now < expiry ? .satisfied(expiresAt: expiry) : .unsatisfied(since: expiry)
    }

    /// The next moment the gate's satisfaction could change without any new event.
    func nextTransition(lastAcknowledgment: Date?, now: Date) -> Date? {
        guard enabled else { return nil }
        let window = activeHours.window(containing: now)
        switch status(lastAcknowledgment: lastAcknowledgment, now: now) {
        case .satisfied(let expiresAt):
            // Expiry may fall past window close, in which case the gate goes
            // dormant (still satisfied) and nothing observable changes today.
            if expiresAt < window.close { return expiresAt }
            return activeHours.nextOpen(after: now)
        case .unsatisfied:
            // Nothing changes on its own until the window closes and the gate
            // goes dormant; only an acknowledgment reopens it sooner.
            return window.close
        case .dormant:
            // The next window opening closes the gate immediately.
            return activeHours.nextOpen(after: now)
        }
    }
}
