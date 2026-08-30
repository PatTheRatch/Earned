import SwiftUI
import EarnedKit

/// Deliberate without being bureaucratic: one decision per screen (NORTHSTAR §9).
struct NewCommitmentView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case what, completion, when, escape, review

        var question: String {
            switch self {
            case .what: return "What will you do?"
            case .completion: return "What counts as completion?"
            case .when: return "By when?"
            case .escape: return "What are the override rules?"
            case .review: return "The deal"
            }
        }
    }

    private enum Kind: String, CaseIterable, Identifiable {
        case any = "Just show up"
        case duration = "A total time"
        case distance = "A total distance"
        var id: String { rawValue }
    }

    /// Which workouts count. Separate from how much is required, so "Run 30
    /// minutes" cannot be satisfied by half an hour on a bike.
    private enum ActivityChoice: String, CaseIterable, Identifiable {
        case any = "Any workout"
        case running = "Running"
        case walking = "Walking"
        case cycling = "Cycling"
        case strength = "Strength"
        var id: String { rawValue }
        var filter: ActivityFilter {
            switch self {
            case .any: return .any
            case .running: return .only(.running)
            case .walking: return .only(.walking)
            case .cycling: return .only(.cycling)
            case .strength: return .only(.strength)
            }
        }
    }

    private enum Repeat: String, CaseIterable, Identifiable {
        case once = "Just once"
        case weekly = "Repeat weekly"
        var id: String { rawValue }
    }

    private enum TimePreset: String, CaseIterable, Identifiable {
        case morning = "Morning", afternoon = "Afternoon", evening = "Evening", custom = "Custom"
        var id: String { rawValue }
        var hour: Int? {
            switch self {
            case .morning: return 8
            case .afternoon: return 14
            case .evening: return 20
            case .custom: return nil
            }
        }
    }

    @State private var step: Step = .what
    @State private var title = ""
    @State private var kind: Kind = .any
    @State private var activity: ActivityChoice = .any
    @State private var repeats: Repeat = .once
    @State private var weekdays: Set<Int> = []
    @State private var weeks = 4.0
    @State private var minutes = 30.0
    @State private var kilometers = 5.0
    @State private var day = Date()
    @State private var preset: TimePreset = .morning
    @State private var customTime = Date()
    @State private var approvals = 2
    @State private var accountabilityMinutes = 30.0
    @State private var correctionHours = 2.0
    @State private var warnBefore = true
    @State private var rewardEligible = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text(step.question.uppercased())
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 8)

                content

                Spacer()
                controls
            }
            .padding(24)
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .what:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Go for a run", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .background(Theme.field)
                Text("Name it the way you'd say it to yourself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        case .completion:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "What counts")
                    Picker("Counts", selection: $activity) {
                        ForEach(ActivityChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "How much")
                    Picker("Requirement", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                switch kind {
                case .any:
                    Text(activity == .any
                         ? "Any workout recorded in Apple Health will satisfy this."
                         : "One \(activity.rawValue.lowercased()) workout will satisfy this.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .duration:
                    VStack(alignment: .leading) {
                        Text("\(Int(minutes)) minutes").font(.headline)
                        Slider(value: $minutes, in: 5...180, step: 5)
                        Text("Time adds up across workouts — 18 minutes now and 12 later counts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .distance:
                    VStack(alignment: .leading) {
                        Text(String(format: "%.1f km", kilometers)).font(.headline)
                        Slider(value: $kilometers, in: 0.5...42, step: 0.5)
                        Text("Distance adds up across workouts too.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

        case .when:
            VStack(alignment: .leading, spacing: 16) {
                DatePicker("Day", selection: $day, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                Picker("Time", selection: $preset) {
                    ForEach(TimePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if preset == .custom {
                    DatePicker("Deadline", selection: $customTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                }
                Picker("Repeat", selection: $repeats) {
                    ForEach(Repeat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if repeats == .weekly {
                    VStack(alignment: .leading, spacing: 8) {
                        WeekdayPicker(selection: $weekdays)
                        Text("For \(Int(weeks)) week\(Int(weeks) == 1 ? "" : "s")")
                        Slider(value: $weeks, in: 1...12, step: 1)
                        Text("One commitment per scheduled day, each with its own deadline. "
                             + "A workout only counts toward the day it belongs to.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("The whole plan hardens together, shortly after you commit — "
                             + "not one day at a time as each day arrives. You shouldn't make "
                             + "a plan you're not ready to follow through on.")
                            .font(.footnote).foregroundStyle(Theme.signal)
                    }
                } else {
                    Text("A deadline, not an appointment: anything qualifying you do before "
                         + "\(Format.deadline(deadline, from: store.now)) counts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if repeats == .once, deadline <= store.now {
                    Text("That deadline has already passed.")
                        .font(.footnote).foregroundStyle(Theme.signal)
                }
                if repeats == .weekly, weekdays.isEmpty {
                    Text("Pick at least one day.")
                        .font(.footnote).foregroundStyle(Theme.signal)
                }
            }

        case .escape:
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Approvals required: \(approvals)", value: $approvals, in: 1...5)
                    Text("How many accountability partners must agree before an override succeeds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wait before a solo override: \(Int(accountabilityMinutes)) min")
                    Slider(value: $accountabilityMinutes, in: 0...120, step: 5)
                    Text("The solo escape only opens after partners have had this long.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Correction window: \(Format.duration(correctionHours * 3600))")
                    Slider(value: $correctionHours, in: 0...6, step: 0.5)
                    Text("Time to fix mistakes before this hardens. After that it can only get harder.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Warn me 30 minutes before", isOn: $warnBefore)
                    if warnBefore, store.warningDelivery == .denied {
                        Text("Notifications are off, so this warning won't arrive. The deadline "
                             + "still stands — turn them on in Settings.")
                            .font(.footnote).foregroundStyle(Theme.signal)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Eligible for Free Overrides", isOn: $rewardEligible)
                    Text("Whether repeated on-time completions of this commitment count toward "
                         + "earning a Free Override. Fixed once committed — not all commitments "
                         + "need to be able to earn one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

        case .review:
            VStack(alignment: .leading, spacing: 14) {
                ReviewLine(label: "Do", value: title.isEmpty ? "Any workout" : title)
                ReviewLine(label: "Counts as done", value: Format.requirement(requirement))
                ReviewLine(label: "By", value: repeats == .weekly
                           ? "\(Format.weekdays(weekdays)) at \(timeLabel), \(Int(weeks)) weeks"
                           : Format.deadline(deadline, from: store.now))
                ReviewLine(label: "Verified by", value: "Apple Health workout record")
                ReviewLine(label: "Escape", value: "\(approvals) approvals, or solo after "
                           + "\(Int(accountabilityMinutes)) min")
                ReviewLine(label: "Free Overrides", value: rewardEligible ? "Eligible" : "Not eligible")
                ReviewLine(label: repeats == .weekly ? "Fully hardens" : "Hardens",
                           value: Format.relative(hardensAt, from: store.now))
                if repeats == .weekly {
                    Text("Every occurrence in this plan — including the last week — hardens by "
                         + "then. There's no editing week three once week one has started; "
                         + "cancelling later only spares days that haven't opened yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    Text("Until it hardens you can change anything. After that it can only get harder — "
                         + "and missing the deadline doesn't clear it.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Navigation

    private var controls: some View {
        HStack(spacing: 12) {
            if step != .what {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .what } }
                    .font(.headline)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
            }
            if step == .review {
                Button("COMMIT") { commit() }
                    .buttonStyle(PosterButtonStyle())
            } else {
                Button("Next") {
                    withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .review }
                }
                .buttonStyle(PosterButtonStyle())
                .disabled(!canAdvance)
                .opacity(canAdvance ? 1 : 0.4)
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .what: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .when: return repeats == .weekly ? !weekdays.isEmpty : deadline > store.now
        default: return true
        }
    }

    private var timeLabel: String {
        Format.timeOfDay(deadlineMinuteOfDay)
    }

    private var deadlineMinuteOfDay: Int {
        let cal = Calendar.current
        let components = cal.dateComponents([.hour, .minute], from: deadline)
        return (components.hour ?? 8) * 60 + (components.minute ?? 0)
    }

    // MARK: - Derived values

    private var requirement: Requirement {
        switch kind {
        case .any: return Requirement(activity: activity.filter, metric: .anyQualifyingWorkout)
        case .duration: return Requirement(activity: activity.filter, metric: .totalDuration(minutes * 60))
        case .distance: return Requirement(activity: activity.filter, metric: .totalDistance(kilometers * 1000))
        }
    }

    private var deadline: Date {
        let calendar = Calendar.current
        if let hour = preset.hour {
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        let time = calendar.dateComponents([.hour, .minute], from: customTime)
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                             second: 0, of: day) ?? day
    }

    /// For a one-off, mirrors Commitment.hardensAt so the review screen can
    /// promise it before the commitment exists.
    ///
    /// For a plan, every occurrence hardens independently but all from the
    /// same creation moment, so the plan as a whole isn't fully hardened
    /// until its *last* occurrence's window closes — normally the one with
    /// the most time to its deadline, so its window sits at the configured
    /// cap rather than the short-fuse fraction. Built from real occurrences
    /// rather than re-deriving the formula, so this can't drift from what
    /// `commit()` actually creates.
    private var hardensAt: Date {
        guard repeats == .weekly else {
            let window = min(correctionHours * 3600,
                             deadline.timeIntervalSince(store.now) * Commitment.hardeningFraction)
            return store.now.addingTimeInterval(max(0, window))
        }
        let start = Calendar.current.startOfDay(for: day)
        let preview = CommitmentPlan(title: title, requirement: requirement, weekdays: weekdays,
                                     deadlineMinuteOfDay: deadlineMinuteOfDay, startDate: start,
                                     endDate: CommitmentPlan.weeks(Int(weeks), from: start),
                                     configuredCorrectionWindow: correctionHours * 3600,
                                     overridePolicy: OverridePolicy(approvalsRequired: approvals,
                                                                    accountabilityWindow: accountabilityMinutes * 60),
                                     rewardEligible: rewardEligible, createdAt: store.now)
        let hardenTimes = preview.occurrences().map(\.hardensAt)
        return hardenTimes.max() ?? store.now
    }

    private func commit() {
        if repeats == .weekly {
            let start = Calendar.current.startOfDay(for: day)
            let created = store.createPlan(
                title: title.trimmingCharacters(in: .whitespaces),
                requirement: requirement,
                weekdays: weekdays,
                deadlineMinuteOfDay: deadlineMinuteOfDay,
                startDate: start,
                endDate: CommitmentPlan.weeks(Int(weeks), from: start),
                correctionWindow: correctionHours * 3600,
                overridePolicy: OverridePolicy(approvalsRequired: approvals,
                                               accountabilityWindow: accountabilityMinutes * 60),
                rewardEligible: rewardEligible,
                warningLead: warnBefore ? 30 * 60 : nil)
            if created { registerEnvelopes(); dismiss() }
            return
        }
        let created = store.createCommitment(
            title: title.trimmingCharacters(in: .whitespaces),
            requirement: requirement,
            deadline: deadline,
            correctionWindow: correctionHours * 3600,
            overridePolicy: OverridePolicy(approvalsRequired: approvals,
                                           accountabilityWindow: accountabilityMinutes * 60),
            rewardEligible: rewardEligible,
            warningLead: warnBefore ? 30 * 60 : nil)
        if created { registerEnvelopes(); dismiss() }
    }

    /// Registers the new commitment's terms with the server immediately.
    ///
    /// Now rather than at the next launch, because the window closes: an
    /// envelope that does not arrive before the commitment hardens loses the
    /// accountability route for good (S13), and a short-fuse commitment can
    /// harden within minutes. A no-op when there is no backend or nobody is
    /// signed in — the commitment itself is already saved either way.
    private func registerEnvelopes() {
        Task { await account.syncEnvelopes(for: store.allCommitments, now: store.now) }
    }
}

struct ReviewLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value).font(.subheadline)
            Spacer()
        }
    }
}


/// Mon–Sun toggles, in Calendar weekday numbering (1 = Sunday).
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    private static let days: [(Int, String)] = [
        (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.days, id: \.0) { number, label in
                let isOn = selection.contains(number)
                Button {
                    if isOn { selection.remove(number) } else { selection.insert(number) }
                } label: {
                    Text(label)
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isOn ? Theme.ink : Theme.field)
                        .foregroundStyle(isOn ? Theme.paper : Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
