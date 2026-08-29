import SwiftUI
import EarnedKit

/// Deliberate without being bureaucratic: one decision per screen (NORTHSTAR §9).
struct NewCommitmentView: View {
    @EnvironmentObject private var store: EarnedStore
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
        case any = "Any workout"
        case duration = "Exercise for a total time"
        case distance = "Cover a total distance"
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
                Picker("Requirement", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                switch kind {
                case .any:
                    Text("Any workout recorded in Apple Health will satisfy this.")
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
                Text("A deadline, not an appointment: anything qualifying you do before "
                     + "\(Format.deadline(deadline, from: store.now)) counts.")
                    .font(.footnote).foregroundStyle(.secondary)
                if deadline <= store.now {
                    Text("That deadline has already passed.")
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
                Toggle("Warn me 30 minutes before", isOn: $warnBefore)
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
                ReviewLine(label: "By", value: Format.deadline(deadline, from: store.now))
                ReviewLine(label: "Verified by", value: "Apple Health workout record")
                ReviewLine(label: "Escape", value: "\(approvals) approvals, or solo after "
                           + "\(Int(accountabilityMinutes)) min")
                ReviewLine(label: "Free Overrides", value: rewardEligible ? "Eligible" : "Not eligible")
                ReviewLine(label: "Hardens", value: Format.relative(hardensAt, from: store.now))
                Text("Until it hardens you can change anything. After that it can only get harder — "
                     + "and missing the deadline doesn't clear it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 4)
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
        case .when: return deadline > store.now
        default: return true
        }
    }

    // MARK: - Derived values

    private var requirement: Requirement {
        switch kind {
        case .any: return .anyWorkout
        case .duration: return .totalDuration(minutes * 60)
        case .distance: return .totalDistance(kilometers * 1000)
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

    /// Mirrors Commitment.hardensAt so the review screen can promise it before
    /// the commitment exists.
    private var hardensAt: Date {
        let window = min(correctionHours * 3600,
                         deadline.timeIntervalSince(store.now) * Commitment.hardeningFraction)
        return store.now.addingTimeInterval(max(0, window))
    }

    private func commit() {
        let created = store.createCommitment(
            title: title.trimmingCharacters(in: .whitespaces),
            requirement: requirement,
            deadline: deadline,
            correctionWindow: correctionHours * 3600,
            overridePolicy: OverridePolicy(approvalsRequired: approvals,
                                           accountabilityWindow: accountabilityMinutes * 60),
            rewardEligible: rewardEligible,
            warningLead: warnBefore ? 30 * 60 : nil)
        if created { dismiss() }
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
