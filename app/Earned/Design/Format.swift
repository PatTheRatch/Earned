import Foundation
import EarnedKit

/// User-facing formatting. The lock screen is a receipt: short, exact, never
/// verbose (NORTHSTAR §8).
enum Format {

    /// "45 min", "1 h 30 min", "30 s"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(0, total)) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    /// "18 / 30 min", "3.2 / 5.0 km", "0 / 1 workout", "40 / 200 cal"
    static func progress(_ progress: CommitmentProgress) -> String {
        switch progress.unit {
        case .workouts:
            let required = Int(progress.required)
            return "\(Int(progress.achieved)) / \(required) workout" + (required == 1 ? "" : "s")
        case .seconds:
            return "\(Int(progress.achieved / 60)) / \(Int(progress.required / 60)) min"
        case .meters:
            return String(format: "%.1f / %.1f km", progress.achieved / 1000, progress.required / 1000)
        case .kilocalories:
            return "\(Int(progress.achieved)) / \(Int(progress.required)) cal"
        }
    }

    /// What is still owed: "12 minutes to go.", "1.8 km to go."
    static func remaining(_ progress: CommitmentProgress) -> String? {
        let left = progress.required - progress.achieved
        guard left > 0 else { return nil }
        switch progress.unit {
        case .workouts:
            let count = Int(left.rounded(.up))
            return "\(count) workout" + (count == 1 ? "" : "s") + " to go."
        case .seconds:
            return "\(Int((left / 60).rounded(.up))) minutes to go."
        case .meters:
            return String(format: "%.1f km to go.", left / 1000)
        case .kilocalories:
            return "\(Int(left.rounded(.up))) calories to go."
        }
    }

    /// "in 42 min" / "3 min ago"
    static func relative(_ date: Date, from now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        return delta >= 0 ? "in \(duration(delta))" : "\(duration(-delta)) ago"
    }

    /// "Saturday 10:00", or "Today 20:00" / "Tomorrow 08:00" when close.
    static func deadline(_ date: Date, from now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }

    /// "08:00" from minutes since midnight.
    static func timeOfDay(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    static func requirement(_ requirement: Requirement) -> String {
        let activity = requirement.activity.displayName
        switch requirement.metric {
        case .anyQualifyingWorkout:
            return activity
        case .totalDuration(let seconds):
            return "\(activity) · \(duration(seconds))"
        case .totalDistance(let meters):
            return String(format: "%@ · %.1f km", activity, meters / 1000)
        case .totalActiveEnergy(let kilocalories):
            return "\(activity) · \(Int(kilocalories)) cal"
        case .sessionCount(let sessions):
            return "\(activity) · \(sessions)×"
        }
    }

    /// "Mon/Wed/Fri" from Calendar weekday numbers.
    static func weekdays(_ days: Set<Int>) -> String {
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return days.sorted().compactMap { names[$0] }.joined(separator: "/")
    }
}
