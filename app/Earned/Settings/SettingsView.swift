import SwiftUI
import UIKit
import AuthenticationServices
import FamilyControls
import EarnedKit

/// You: identity first, then clear destinations. Configuration recedes into
/// screens of its own — the app is a living system, not a control panel
/// (docs/design-language.md v2). Every group here is a human job, not a
/// database noun.
struct YouView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var health: HealthImporter
    @State private var reportingProblem = false

    var body: some View {
        NavigationStack {
            PosterPage {
                PageHeader(title: "YOU")
                identity
                destinations
                beta
            }
            .toolbar(.hidden, for: .navigationBar)
            .rejectionAlert()
            .sheet(isPresented: $reportingProblem) { ReportProblemView() }
        }
    }

    // MARK: - Beta

    /// The private-beta block: which build this is, and how to complain about
    /// it. Both are the same problem — a report nobody can tie to a binary is
    /// a report nobody can act on — so they sit together and stay obvious
    /// rather than hiding under Advanced.
    @ViewBuilder
    private var beta: some View {
        SectionLabel(text: "Beta").padding(.top, Theme.blockSpacing)
        Button { reportingProblem = true } label: {
            DestinationRow(title: "Report a problem")
        }
        .buttonStyle(.plain)
        NavigationLink { AboutView() } label: {
            DestinationRow(title: "About", detail: AppBuild.current.short)
        }
        .buttonStyle(.plain)
        HairRule()
        Text("Earned Beta \(AppBuild.current.short)")
            .font(Theme.footnote)
            .foregroundStyle(Theme.muted)
            .padding(.top, 12)
    }

    // MARK: - Identity

    @ViewBuilder
    private var identity: some View {
        switch account.session {
        case .notConfigured:
            Text("No backend is configured for this build. Everything local works as normal.")
                .font(Theme.body).foregroundStyle(Theme.muted)
                .padding(.top, 16)

        case .signedOut, .failed:
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in to use accountability partners and the social layer. "
                     + "Everything else already works.")
                    .font(Theme.body).foregroundStyle(Theme.muted)
                SignInWithAppleButton(.signIn,
                                      onRequest: account.prepareRequest,
                                      onCompletion: { account.completeSignIn($0) })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 46)
                if case .failed(let message) = account.session {
                    Text(message).font(Theme.footnote).foregroundStyle(Theme.signal)
                }
            }
            .padding(.top, 16)

        case .signingIn:
            HStack(spacing: 10) { ProgressView(); Text("Signing in…") }
                .padding(.top, 16)

        case .signedIn(let name):
            HStack(spacing: 14) {
                AvatarView(avatarPath: social.profileState.profile?.avatarPath,
                           displayName: social.profileState.profile?.displayName ?? name,
                           size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(social.profileState.profile?.displayName ?? name)
                        .font(Theme.blocker(18))
                        .foregroundStyle(Theme.ink)
                    if let profile = social.profileState.profile {
                        Text("@\(profile.handle)")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private var destinations: some View {
        if case .signedIn = account.session {
            SectionLabel(text: "You").padding(.top, Theme.blockSpacing)
            Group {
                if let profile = social.profileState.profile {
                    NavigationLink { EditProfileView(profile: profile) } label: {
                        DestinationRow(title: "Profile", detail: "@\(profile.handle)")
                    }
                } else if social.needsSetup {
                    NavigationLink { ProfileSetupView() } label: {
                        DestinationRow(title: "Set up your profile")
                    }
                }
                NavigationLink { PartnersView() } label: {
                    DestinationRow(title: "Accountability partners",
                                   detail: partnerSummary,
                                   detailColor: account.partnerRequests.isEmpty
                                       ? Theme.muted : Theme.ink)
                }
                NavigationLink { AccountDetailView() } label: {
                    DestinationRow(title: "Account")
                }
            }
            .buttonStyle(.plain)
        }

        SectionLabel(text: "Gates").padding(.top, Theme.blockSpacing)
        Group {
            NavigationLink { HydrationSettingsView() } label: {
                DestinationRow(title: "Hydration", detail: hydrationSummary)
            }
            NavigationLink { RestrictionsHomeView() } label: {
                DestinationRow(title: "Restrictions",
                               detail: restrictionsSummary,
                               detailColor: store.shielding == .denied
                                   ? Theme.signal : Theme.muted)
            }
            if !store.activePlans.isEmpty {
                NavigationLink { PlansSettingsView() } label: {
                    DestinationRow(title: "Repeating plans",
                                   detail: "\(store.activePlans.count)")
                }
            }
        }
        .buttonStyle(.plain)

        SectionLabel(text: "Escapes").padding(.top, Theme.blockSpacing)
        NavigationLink { RewardSettingsView() } label: {
            DestinationRow(title: "Free Overrides",
                           detail: store.freeOverrides > 0
                               ? "\(store.freeOverrides) banked" : nil)
        }
        .buttonStyle(.plain)

        SectionLabel(text: "System").padding(.top, Theme.blockSpacing)
        Group {
            NavigationLink { WarningSettingsView() } label: {
                DestinationRow(title: "Warnings", detail: warningsSummary,
                               detailColor: store.warningDelivery == .denied
                                   ? Theme.signal : Theme.muted)
            }
            NavigationLink { AdvancedView() } label: {
                DestinationRow(title: "Advanced")
            }
        }
        .buttonStyle(.plain)
        HairRule()
    }

    private var partnerSummary: String {
        if !account.partnerRequests.isEmpty {
            return "\(account.partnerRequests.count) waiting on you"
        }
        let active = account.eligiblePartners.count
        return active == 0 ? "None yet" : "\(active) active"
    }

    private var hydrationSummary: String {
        guard let config = store.state.hydration, config.enabled else { return "Off" }
        return "Every \(Int(config.interval / 60)) min"
    }

    private var restrictionsSummary: String {
        if store.shielding == .denied { return "Screen Time off" }
        let count = store.effectiveRestrictions.count
        return count == 0 ? "Nothing blocked now" : "\(count) blocked now"
    }

    private var warningsSummary: String {
        switch store.warningDelivery {
        case .granted: return "On"
        case .notDetermined: return "Will ask"
        case .denied: return "Notifications off"
        }
    }
}

// MARK: - Account

/// The account itself: what the server holds, and the way out.
struct AccountDetailView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        List {
            Section {
                if case .signedIn(let name) = account.session {
                    LabeledContent("Signed in", value: name)
                }
                registrationSummary
            } header: {
                Text("Account")
            } footer: {
                Text("Earned registers only a commitment's terms — what's due, when it "
                     + "hardens, how many approvals. Never your workouts, never which "
                     + "apps you block.")
            }
            if let failure = account.syncFailure {
                Section { Text(failure).font(.footnote).foregroundStyle(Theme.signal) }
            }
            Section {
                Button("Sign out", role: .destructive) { account.signOut() }
            }
        }
        .paperList()
        .navigationTitle("Account")
    }

    @ViewBuilder
    private var registrationSummary: some View {
        let live = store.allCommitments.filter { $0.resolution == nil }
        let states = live.map { account.registration(of: $0.commitment) }
        let registered = states.filter { $0 == .registered }.count
        let late = states.filter { $0 == .late }.count

        LabeledContent("Commitments registered", value: "\(registered) of \(states.count)")
        if late > 0 {
            Text("\(late) registered too late to use accountability partners. "
                 + "The Solo Override still works for those.")
                .font(.footnote).foregroundStyle(Theme.signal)
        }
    }
}

// MARK: - Hydration

struct HydrationSettingsView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
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
            } footer: {
                Text("Loosening this is only allowed while the Gate is satisfied. "
                     + "Tightening is always allowed.")
            }
        }
        .paperList()
        .navigationTitle("Hydration")
        .rejectionAlert()
    }

    private func adjustInterval(_ config: HydrationConfig, by minutes: Double) {
        var updated = config
        updated.interval = max(15 * 60, config.interval + minutes * 60)
        store.configureHydration(updated)
    }
}

// MARK: - Warnings

struct WarningSettingsView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
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
            } footer: {
                Text("A warning is information only — it never delays a deadline. "
                     + "Turning notifications off makes Earned quieter, not more forgiving.")
            }
        }
        .paperList()
        .navigationTitle("Warnings")
    }
}

// MARK: - Free Overrides

struct RewardSettingsView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
            Section {
                let policy = store.state.rewardPolicy
                Stepper("Earn one per \(policy.streakThreshold) completions",
                        onIncrement: { updateRewards(streak: policy.streakThreshold + 1) },
                        onDecrement: { updateRewards(streak: max(1, policy.streakThreshold - 1)) })
                Stepper("Store at most \(policy.maxStored)",
                        onIncrement: { updateRewards(maxStored: policy.maxStored + 1) },
                        onDecrement: { updateRewards(maxStored: max(0, policy.maxStored - 1)) })
                LabeledContent("Available now", value: "\(store.freeOverrides)")
            } footer: {
                Text("Which commitments count toward the streak is chosen per commitment, "
                     + "at creation. Easing these rules needs Full Access and nothing "
                     + "hardened outstanding — an easier reward policy is itself an escape "
                     + "route.")
            }
        }
        .paperList()
        .navigationTitle("Free Overrides")
        .rejectionAlert()
    }

    private func updateRewards(streak: Int? = nil, maxStored: Int? = nil) {
        let current = store.state.rewardPolicy
        store.configureRewards(RewardPolicy(streakThreshold: streak ?? current.streakThreshold,
                                            maxStored: maxStored ?? current.maxStored))
    }
}

// MARK: - Plans

struct PlansSettingsView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
            Section {
                ForEach(store.activePlans, id: \.plan.id) { record in
                    NavigationLink {
                        PlanDetailView(planID: record.plan.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.plan.title).font(.subheadline.weight(.medium))
                            Text("\(Format.weekdays(record.plan.weekdays)) · "
                                 + "\(store.state.occurrences(ofPlan: record.plan.id).count) commitments")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.cancelPlan(store.activePlans[index].plan.id) }
                }
            } footer: {
                Text("A plan hardens as one thing shortly after you make it. Cancelling "
                     + "withdraws the days that haven't started; days underway stand.")
            }
        }
        .paperList()
        .navigationTitle("Repeating plans")
        .rejectionAlert()
    }
}

// MARK: - Restrictions

struct RestrictionsHomeView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
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
            } footer: {
                Text("Each Gate takes away its own things; what's blocked at any moment is "
                     + "the union across every unsatisfied Gate. Each commitment's own "
                     + "profile lives on that commitment.")
            }

            Section {
                switch store.shielding {
                case .approved:
                    LabeledContent("Enforcement", value: "On")
                case .notDetermined:
                    Button("Grant Screen Time access") {
                        Task { await store.requestShieldingAuthorization() }
                    }
                case .denied:
                    Text("Screen Time is off — nothing is actually being blocked.")
                        .foregroundStyle(Theme.signal)
                    Button("Open iOS Settings") { openSystemSettings() }
                }
                if let failure = store.shieldingFailure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                }
            } header: {
                Text("Screen Time")
            } footer: {
                Text("Without Screen Time access Earned still tracks every Gate — "
                     + "it just can't take anything away.")
            }
        }
        .paperList()
        .navigationTitle("Restrictions")
        .rejectionAlert()
    }
}

// MARK: - Advanced

/// Diagnostics, and — in development builds only — the testing tools.
/// Production never ships a "Testing" section (docs/design-language.md v2).
struct AdvancedView: View {
    @EnvironmentObject private var store: EarnedStore
    #if DEBUG
    @State private var showingWorkoutSheet = false
    #endif

    var body: some View {
        List {
            Section {
                NavigationLink { DiagnosticsView() } label: {
                    LabeledContent("Diagnostics", value: "Version, permissions, sync")
                }
            } footer: {
                Text("One screen with everything a bug report needs, and a button that "
                     + "copies it.")
            }

            // Enforcement while Earned is closed depends on two processes
            // agreeing through a shared container, and every way that can fail
            // fails silently: the monitor wakes on time and shields nothing.
            // These lines are the difference between noticing that and
            // discovering it weeks later.
            Section {
                LabeledContent("Shared container",
                               value: SharedContainer.isAvailable ? "Reachable" : "Missing")
                let plan = SharedContainer.loadPlan()
                LabeledContent("Scheduled changes", value: "\(plan?.windows.count ?? 0)")
                if let next = plan?.windows.first {
                    LabeledContent("Next", value: Format.deadline(next.opensAt, from: store.now))
                }
            } header: {
                Text("Closed-app enforcement")
            } footer: {
                if SharedContainer.isAvailable {
                    Text("Deadlines that fall while Earned is closed are applied by the "
                         + "monitor extension from this plan.")
                } else {
                    Text("The App Group is not reachable, so nothing can be shielded while "
                         + "Earned is closed. Deadlines will apply at next launch instead.")
                }
            }
            #if DEBUG
            Section {
                Button("Log a workout by hand") { showingWorkoutSheet = true }
            } header: {
                Text("Testing (debug builds only)")
            } footer: {
                Text("Logged by hand counts as your word: it moves honor-system "
                     + "commitments fully and app-verified ones not at all.")
            }
            #endif
        }
        .paperList()
        .navigationTitle("Advanced")
        #if DEBUG
        .sheet(isPresented: $showingWorkoutSheet) { LogWorkoutView() }
        .rejectionAlert()
        #endif
    }
}

func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

/// Editing one Gate's own restriction profile, using Apple's system picker.
///
/// The picker runs in a separate process and hands back opaque tokens: Earned
/// learns *that* something is blocked, never *what* (NORTHSTAR §34).
struct GateRestrictionsView: View {
    @EnvironmentObject private var store: EarnedStore
    let gate: GateID
    let title: String
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()

    private var profile: RestrictionProfile { store.state.restrictions(of: gate) }

    var body: some View {
        RestrictionEditor(
            title: title,
            heading: "Blocked while this Gate is unsatisfied",
            profile: profile,
            picking: $picking,
            selection: $selection,
            onCommit: { store.setRestrictions($0, of: gate) })
    }
}

/// The profile new commitments inherit. Not a Gate itself, so it can be edited
/// freely — changing it restricts nothing currently in force.
struct DefaultRestrictionsView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()

    private var profile: RestrictionProfile { store.state.defaultCommitmentRestrictions }

    var body: some View {
        RestrictionEditor(
            title: "New commitments",
            heading: "Applied to new commitments",
            profile: profile,
            picking: $picking,
            selection: $selection,
            onCommit: { store.setDefaultRestrictions($0) })
    }
}

/// Shared editor for a restriction profile.
private struct RestrictionEditor: View {
    @EnvironmentObject private var store: EarnedStore
    let title: String
    let heading: String
    let profile: RestrictionProfile
    @Binding var picking: Bool
    @Binding var selection: FamilyActivitySelection
    let onCommit: (RestrictionProfile) -> Void

    private var legacy: [RestrictionToken] { RestrictionBridge.legacyPlaceholders(in: profile) }
    private var shieldable: Int { RestrictionBridge.shieldableCount(in: profile) }

    var body: some View {
        List {
            Section {
                if store.shielding.canShield {
                    Button("Choose apps and websites") { beginPicking() }
                } else {
                    Text(store.shielding == .denied
                         ? "Screen Time is off, so nothing here can be blocked."
                         : "Screen Time permission is needed before Earned can block anything.")
                        .foregroundStyle(Theme.signal)
                    if store.shielding == .denied {
                        Button("Open iOS Settings") { openSystemSettings() }
                    } else {
                        Button("Grant Screen Time access") {
                            Task { await store.requestShieldingAuthorization() }
                        }
                    }
                    if let failure = store.shieldingFailure {
                        Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                    }
                }
            } header: {
                Text(heading)
            } footer: {
                Text(shieldable == 0
                     ? "Nothing is blocked yet."
                     : "\(shieldable) blocked. Apple's picker keeps the choices private — "
                       + "Earned can shield them without ever learning which apps they are.")
            }

            if !legacy.isEmpty {
                Section {
                    ForEach(legacy, id: \.self) { token in
                        HStack {
                            Text(token.rawValue).foregroundStyle(Theme.muted)
                            Spacer()
                            StatusTag(text: "NOT BLOCKING", color: Theme.signal)
                        }
                    }
                    .onDelete { offsets in
                        onCommit(profile.removing(Set(offsets.map { legacy[$0] })))
                    }
                } header: {
                    Text("Typed before app picking existed")
                } footer: {
                    Text("These were placeholders and never blocked anything. Pick the "
                         + "real apps above, then delete these.")
                }
            }
        }
        .paperList()
        .navigationTitle(title)
        .rejectionAlert()
        .familyActivityPicker(isPresented: $picking, selection: $selection)
        .onChange(of: picking) { wasPicking, isPicking in
            // Commit when the picker closes, not on every tap inside it.
            if wasPicking && !isPicking { commit(selection) }
        }
    }

    private func beginPicking() {
        selection = RestrictionBridge.selection(from: profile)
        picking = true
    }

    /// Keeps any legacy placeholders, so picking real apps doesn't silently
    /// delete the record of what the user originally asked for.
    private func commit(_ new: FamilyActivitySelection) {
        let picked = RestrictionBridge.profile(from: new)
        onCommit(RestrictionProfile(picked.tokens.union(legacy)))
    }
}

#if DEBUG
/// Manual workout entry — debug builds only. Everything logged here is
/// `.selfReported` evidence: it moves honor-system commitments fully and
/// app-verified ones not at all (NORTHSTAR §15).
private struct LogWorkoutView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30.0
    @State private var kilometers = 5.0
    @State private var includeDistance = false
    @State private var calories = 200.0
    @State private var includeCalories = false
    @State private var endedMinutesAgo = 0.0
    @State private var activity: ActivityType = .running
    @State private var logged: [Workout] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Logged by hand, so it counts as your word. Commitments set "
                         + "to \u{201C}an app has to vouch\u{201D} only move when a workout "
                         + "arrives through Apple Health.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                    Toggle("Include active calories", isOn: $includeCalories)
                    if includeCalories {
                        Text("\(Int(calories)) cal")
                        Slider(value: $calories, in: 25...1000, step: 25)
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
                              distanceMeters: includeDistance ? kilometers * 1000 : nil,
                              activeEnergyKilocalories: includeCalories ? calories : nil)
        guard store.recordWorkout(workout) else { return }
        logged.append(workout)
        endedMinutesAgo = 0
    }
}
#endif
