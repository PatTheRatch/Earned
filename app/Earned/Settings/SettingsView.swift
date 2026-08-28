import SwiftUI
import EarnedKit

/// Gate configuration and system controls (NORTHSTAR §30).
struct SettingsView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var showingWorkoutSheet = false

    var body: some View {
        NavigationStack {
            List {
                hydrationSection
                rewardsSection
                restrictedSection
                testingSection
                aboutSection
            }
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
            if store.state.restrictedApps.isEmpty {
                Text("Nothing listed yet").foregroundStyle(.secondary)
            }
            ForEach(store.state.restrictedApps.sorted(), id: \.self) { app in
                Text(app)
            }
            .onDelete { offsets in
                let sorted = store.state.restrictedApps.sorted()
                let removed = Set(offsets.map { sorted[$0] })
                store.changeRestrictedApps(added: [], removed: removed)
            }
            NavigationLink("Add placeholders") { AddRestrictedView() }
        } header: {
            Text("Earned Access")
        } footer: {
            Text("Real app shielding needs Apple's Screen Time permissions, which arrive with the "
                 + "next build. These placeholders exercise the rules: adding is always allowed, "
                 + "removing needs full access and no hardened commitment outstanding.")
        }
    }

    // MARK: - Testing

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

/// Placeholder app names, standing in for FamilyControls tokens.
private struct AddRestrictedView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var name = ""

    private static let suggestions = ["Instagram", "YouTube", "Safari", "Chrome",
                                      "ChatGPT", "Balatro", "Deliveroo", "TikTok"]

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("App name", text: $name)
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        store.changeRestrictedApps(added: [trimmed], removed: [])
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Suggestions") {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        store.changeRestrictedApps(added: [suggestion], removed: [])
                    }
                    .disabled(store.state.restrictedApps.contains(suggestion))
                }
            }
        }
        .navigationTitle("Add")
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
    @State private var logged: [Workout] = []

    var body: some View {
        NavigationStack {
            List {
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
        let workout = Workout(activityType: "manual",
                              start: end.addingTimeInterval(-minutes * 60),
                              end: end,
                              distanceMeters: includeDistance ? kilometers * 1000 : nil)
        guard store.recordWorkout(workout) else { return }
        logged.append(workout)
        endedMinutesAgo = 0
    }
}
