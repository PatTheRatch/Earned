import SwiftUI
import UIKit
import EarnedKit

/// Gate configuration and system controls (NORTHSTAR §30).
struct SettingsView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var showingWorkoutSheet = false

    var body: some View {
        NavigationStack {
            List {
                hydrationSection
                warningsSection
                rewardsSection
                restrictedSection
                plansSection
                testingSection
                aboutSection
            }
            .paperList()
            .navigationTitle("Settings")
            .rejectionAlert()
            .sheet(isPresented: $showingWorkoutSheet) { LogWorkoutView() }
        }
    }

    // MARK: - Hydration

    @ViewBuilder
    private var hydrationSection: some View {
        Section {
            if let config = store.state.hydration {
                Toggle("Hydration Gate", isOn: Binding(
                    get: { config.enabled },
                    set: { enabled in
                        var updated = config
                        updated.enabled = enabled
                        store.configureHydration(updated)
                    }))

                Stepper("Every \(Int(config.interval / 60)) min",
                        onIncrement: { adjustInterval(config, by: 15) },
                        onDecrement: { adjustInterval(config, by: -15) })

                LabeledContent("Active hours",
                               value: "\(Format.timeOfDay(config.activeHours.startMinuteOfDay)) – "
                                    + "\(Format.timeOfDay(config.activeHours.endMinuteOfDay))")
            } else {
                Text("Not configured").foregroundStyle(.secondary)
            }
        } header: {
            Text("Hydration")
        } footer: {
            Text("Loosening this — a longer interval, narrower hours, turning it off — is only "
                 + "allowed while the Gate is satisfied. Tightening is always allowed.")
        }
    }

    private func adjustInterval(_ config: HydrationConfig, by minutes: Double) {
        var updated = config
        updated.interval = max(15 * 60, config.interval + minutes * 60)
        store.configureHydration(updated)
    }

    // MARK: - Warnings

    /// Warnings are the one part of Earned that depends on a permission the
    /// user can revoke elsewhere. Say so plainly rather than letting a
    /// configured warning quietly never arrive.
    @ViewBuilder
    private var warningsSection: some View {
        Section {
            switch store.warningDelivery {
            case .granted:
                LabeledContent("Notifications", value: "On")
                LabeledContent("Scheduled", value: "\(store.scheduledWarningCount)")
            case .notDetermined:
                Text("Earned will ask for permission the first time a warning is due.")
                    .foregroundStyle(.secondary)
            case .denied:
                Text("Notifications are off, so no warning will arrive.")
                    .foregroundStyle(Theme.signal)
                Button("Open iOS Settings") { openSystemSettings() }
            }
        } header: {
            Text("Warnings")
        } footer: {
            Text("A warning says a Gate is about to close. It is information only — it never "
                 + "delays the deadline, and there is nothing to tap to buy more time. "
                 + "Turning notifications off makes Earned quieter, not more forgiving.")
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Rewards

    private var rewardsSection: some View {
        Section {
            let policy = store.state.rewardPolicy
            Stepper("Earn one per \(policy.streakThreshold) completions",
                    onIncrement: { updateRewards(streak: policy.streakThreshold + 1) },
                    onDecrement: { updateRewards(streak: max(1, policy.streakThreshold - 1)) })
            Stepper("Store at most \(policy.maxStored)",
                    onIncrement: { updateRewards(maxStored: policy.maxStored + 1) },
                    onDecrement: { updateRewards(maxStored: max(0, policy.maxStored - 1)) })
            LabeledContent("Available now", value: "\(store.freeOverrides)")
            LabeledContent("Eligible commitments", value: "\(eligibleCommitmentCount)")
        } header: {
            Text("Free Overrides")
        } footer: {
            Text("These numbers set the shared earning mechanics — how large a streak earns one, "
                 + "and how many can be banked. Which commitments count toward that streak is "
                 + "chosen per commitment, when you create it (not all commitments need to be "
                 + "able to earn one) — Patrick's Hydration Gate, for instance, never has.")
        }
    }

    private var eligibleCommitmentCount: Int {
        store.allCommitments.filter { $0.commitment.rewardEligible }.count
    }

    private func updateRewards(streak: Int? = nil, maxStored: Int? = nil) {
        let current = store.state.rewardPolicy
        store.configureRewards(RewardPolicy(streakThreshold: streak ?? current.streakThreshold,
                                            maxStored: maxStored ?? current.maxStored))
    }

    // MARK: - Restricted apps

    private var restrictedSection: some View {
        Section {
            NavigationLink {
                GateRestrictionsView(gate: .hydration, title: "Hydration Gate")
            } label: {
                LabeledContent("Hydration Gate",
                               value: "\(store.state.restrictions(of: .hydration).count) blocked")
            }
            NavigationLink {
                DefaultRestrictionsView()
            } label: {
                LabeledContent("New commitments",
                               value: "\(store.state.defaultCommitmentRestrictions.count) blocked")
            }
            LabeledContent("Blocked right now", value: "\(store.effectiveRestrictions.count)")
        } header: {
            Text("Restrictions")
        } footer: {
            Text("Each Gate takes away its own things. What's actually blocked at any moment is "
                 + "the union across every Gate that's currently unsatisfied — so an unmet "
                 + "Hydration Gate can be far more severe than an unmet workout. Each "
                 + "commitment's own profile lives on that commitment.\n\nReal app shielding "
                 + "needs Apple's Screen Time permissions, which arrive with the next build; "
                 + "these placeholders exercise the rules.")
        }
    }

    // MARK: - Testing

    private var plansSection: some View {
        Section {
            if store.activePlans.isEmpty {
                Text("No repeating plans").foregroundStyle(.secondary)
            }
            ForEach(store.activePlans, id: \.plan.id) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.plan.title).font(.subheadline.weight(.medium))
                    Text("\(Format.weekdays(record.plan.weekdays)) · "
                         + "\(store.state.occurrences(ofPlan: record.plan.id).count) commitments")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for index in offsets { store.cancelPlan(store.activePlans[index].plan.id) }
            }
        } header: {
            Text("Repeating plans")
        } footer: {
            Text("Cancelling a plan withdraws the commitments still inside their correction "
                 + "window. Anything already hardened is a contract in its own right and stays.")
        }
    }

    private var testingSection: some View {
        Section {
            Button("Log a workout by hand") { showingWorkoutSheet = true }
        } header: {
            Text("Testing")
        } footer: {
            Text("Until Apple Health verification lands, this stands in for a real workout so the "
                 + "loop can be exercised end to end.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Events recorded", value: "\(store.ledger.entries.count)")
            LabeledContent("Commitments", value: "\(store.state.commitments.count)")
            LabeledContent("Workouts", value: "\(store.state.workouts.count)")
        }
    }
}

/// Placeholder tokens, standing in for FamilyControls tokens. Editing one Gate's
/// own profile.
struct GateRestrictionsView: View {
    @EnvironmentObject private var store: EarnedStore
    let gate: GateID
    let title: String
    @State private var name = ""

    static let suggestions = ["Instagram", "YouTube", "Safari", "Chrome",
                              "ChatGPT", "Balatro", "Deliveroo", "TikTok",
                              "Email", "Spotify", "Maps"]

    private var profile: RestrictionProfile { store.state.restrictions(of: gate) }

    var body: some View {
        List {
            Section("Blocked while this Gate is unsatisfied") {
                if profile.isEmpty { Text("Nothing").foregroundStyle(.secondary) }
                ForEach(profile.sortedTokens, id: \.self) { token in
                    Text(token.rawValue)
                }
                .onDelete { offsets in
                    let sorted = profile.sortedTokens
                    let removed = Set(offsets.map { sorted[$0] })
                    store.setRestrictions(profile.removing(removed), of: gate)
                }
            }
            Section {
                HStack {
                    TextField("App name", text: $name)
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        store.setRestrictions(profile.adding([RestrictionToken(trimmed)]), of: gate)
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Suggestions") {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        store.setRestrictions(profile.adding([RestrictionToken(suggestion)]), of: gate)
                    }
                    .disabled(profile.tokens.contains(RestrictionToken(suggestion)))
                }
            }
        }
        .paperList()
        .navigationTitle(title)
        .rejectionAlert()
    }
}

/// The profile new commitments inherit. Not a Gate itself, so it can be edited
/// freely.
struct DefaultRestrictionsView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var name = ""

    private var profile: RestrictionProfile { store.state.defaultCommitmentRestrictions }

    var body: some View {
        List {
            Section("Applied to new commitments") {
                if profile.isEmpty { Text("Nothing").foregroundStyle(.secondary) }
                ForEach(profile.sortedTokens, id: \.self) { Text($0.rawValue) }
                    .onDelete { offsets in
                        let sorted = profile.sortedTokens
                        store.setDefaultRestrictions(
                            profile.removing(Set(offsets.map { sorted[$0] })))
                    }
            }
            Section {
                HStack {
                    TextField("App name", text: $name)
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        store.setDefaultRestrictions(profile.adding([RestrictionToken(trimmed)]))
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Suggestions") {
                ForEach(GateRestrictionsView.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        store.setDefaultRestrictions(profile.adding([RestrictionToken(suggestion)]))
                    }
                    .disabled(profile.tokens.contains(RestrictionToken(suggestion)))
                }
            }
        }
        .paperList()
        .navigationTitle("New commitments")
        .rejectionAlert()
    }
}

/// Manual workout entry, standing in for HealthKit until step 4.
///
/// Stays open across entries — testing usually means backfilling several
/// sessions at once (a missed week, say), not one workout per visit to this
/// screen. Each record resets the inputs and adds to a running list rather
/// than dismissing.
private struct LogWorkoutView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30.0
    @State private var kilometers = 5.0
    @State private var includeDistance = false
    @State private var endedMinutesAgo = 0.0
    @State private var activity: ActivityType = .running
    @State private var logged: [Workout] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Activity") {
                    Picker("Activity", selection: $activity) {
                        ForEach(ActivityType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Section("Duration") {
                    Text("\(Int(minutes)) minutes")
                    Slider(value: $minutes, in: 5...180, step: 5)
                }
                Section("Distance") {
                    Toggle("Include distance", isOn: $includeDistance)
                    if includeDistance {
                        Text(String(format: "%.1f km", kilometers))
                        Slider(value: $kilometers, in: 0.5...42, step: 0.5)
                    }
                }
                Section("Finished") {
                    Text(endedMinutesAgo == 0 ? "Just now" : "\(Int(endedMinutesAgo)) min ago")
                    Slider(value: $endedMinutesAgo, in: 0...720, step: 15)
                }
                Section {
                    Button("Record workout") { record() }
                } footer: {
                    Text("Stays open so you can log several — add another right after this one.")
                }
                if !logged.isEmpty {
                    Section("Logged this session") {
                        ForEach(logged) { workout in
                            HStack {
                                Text(Format.duration(workout.duration))
                                if let distance = workout.distanceMeters {
                                    Text("·")
                                    Text(String(format: "%.1f km", distance / 1000))
                                }
                                Spacer()
                                Text(Format.relative(workout.end, from: Date()))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .paperList()
            .navigationTitle("Log a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(logged.isEmpty ? "Cancel" : "Done") { dismiss() }
                }
            }
            .rejectionAlert()
        }
    }

    private func record() {
        let end = Date().addingTimeInterval(-endedMinutesAgo * 60)
        let workout = Workout(activity: activity,
                              start: end.addingTimeInterval(-minutes * 60),
                              end: end,
                              distanceMeters: includeDistance ? kilometers * 1000 : nil)
        guard store.recordWorkout(workout) else { return }
        logged.append(workout)
        endedMinutesAgo = 0
    }
}
