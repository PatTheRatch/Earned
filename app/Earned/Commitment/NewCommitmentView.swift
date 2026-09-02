import SwiftUI
import EarnedKit

/// Deliberate without being bureaucratic: one decision per screen (NORTHSTAR §9).
struct NewCommitmentView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var health: HealthImporter
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        // Sharing is a visibility decision, doing-it-together is an
        // invitation, and escape is a contract mechanic — three separate
        // questions (docs/design-language.md v2, NORTHSTAR §46).
        case what, completion, when, visibility, who, escape, review

        var question: String {
            switch self {
            case .what: return "What will you do?"
            case .completion: return "What counts?"
            case .when: return "By when?"
            case .visibility: return "Who sees this?"
            case .who: return "Who's doing this with you?"
            case .escape: return "How hard is escape?"
            case .review: return "The deal"
            }
        }
    }

    private enum Kind: String, CaseIterable, Identifiable {
        case any = "Just show up"
        case sessions = "A number of times"
        case duration = "A total time"
        case distance = "A total distance"
        case calories = "A total effort"
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
    @State private var verification: WorkoutVerification = .selfReported
    @State private var activity: ActivityChoice = .any
    @State private var repeats: Repeat = .once
    @State private var weekdays: Set<Int> = []
    @State private var weeks = 4.0
    @State private var sessions = 3.0
    @State private var minutes = 30.0
    @State private var kilometers = 5.0
    @State private var calories = 200.0
    @State private var day = Date()
    @State private var preset: TimePreset = .morning
    @State private var customTime = Date()
    @State private var approvals = 2
    @State private var explainingHealth = false
    /// Set by the explanation's Allow button, acted on once the sheet is gone.
    @State private var wantsHealthAccess = false
    /// Who this commitment's accountability route runs through. Only
    /// partners who have already accepted can be picked (invariant 22).
    @State private var roster: Set<UUID> = []
    @State private var accountabilityMinutes = 30.0
    @State private var correctionHours = 2.0
    @State private var warnBefore = true
    @State private var rewardEligible = true
    /// Sharing is chosen, never assumed (NORTHSTAR invariant 26): every
    /// commitment is born private, and this is the explicit choice otherwise.
    @State private var shareWithFriends = false
    /// Doing it together (NORTHSTAR §46). Never forced: the default is just
    /// me, and choosing friends only ever sends invitations — each person
    /// accepts on their own phone and gets their own Gate.
    @State private var withFriends = false
    @State private var invitees: Set<String> = []
    @State private var showingEscapeDetails = false

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
            // Who is eligible can have changed since the app last looked — a
            // partner may have accepted an hour ago, a friend request an
            // hour before that — and neither picker must offer a stale answer.
            .task {
                await account.refreshPartners()
                await social.refreshSocial()
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Which workouts")
                    Picker("Counts", selection: $activity) {
                        ForEach(ActivityChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Theme.ink)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "How much")
                    ForEach(Kind.allCases) { choice in
                        ChoiceRow(title: choice.rawValue,
                                  selected: kind == choice) { kind = choice }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        SectionLabel(text: "Who has to believe you")
                        InfoButton(title: "Verification",
                                   message: "\u{201C}My word counts\u{201D} is the honor "
                                   + "system: logging a workout yourself satisfies this "
                                   + "commitment.\n\n\u{201C}An app has to vouch\u{201D} "
                                   + "means only workouts another app recorded count — an "
                                   + "Apple Watch session, the Fitness app, or Strava "
                                   + "synced into Apple Health. Typing one into Health "
                                   + "yourself doesn't.\n\nVerification is part of the "
                                   + "contract: once this hardens it can get stricter, "
                                   + "never weaker.")
                    }
                    ChoiceRow(title: "My word counts",
                              subtitle: "For days you trust yourself.",
                              selected: verification == .selfReported) {
                        verification = .selfReported
                    }
                    ChoiceRow(title: "An app has to vouch",
                              subtitle: "Only workouts another app recorded count.",
                              selected: verification == .appVerified) {
                        verification = .appVerified
                    }
                }
                .onChange(of: verification) { _, chosen in
                    // Explain, then ask — never the other way round. Health is
                    // requested the moment it becomes relevant rather than at
                    // launch, and the user meets a sentence saying what the
                    // permission buys them *before* Apple's sheet appears,
                    // with a way to decline that is not a dead end.
                    guard chosen == .appVerified,
                          health.access == .notDetermined else { return }
                    explainingHealth = true
                }
                // Apple's sheet is asked for in `onDismiss`, once ours has
                // actually gone. Requesting it from the button handler asks
                // UIKit to present into a view that is still dismissing, and
                // the request is dropped: on a device the explanation closed
                // and no Health prompt ever appeared, leaving a commitment
                // that says an app must vouch on a phone that was never asked.
                .sheet(isPresented: $explainingHealth, onDismiss: {
                    guard wantsHealthAccess else { return }
                    wantsHealthAccess = false
                    Task { await health.requestAccess() }
                }) {
                    healthExplanation.presentationDetents([.medium])
                }

                switch kind {
                case .any:
                    Text(activity == .any
                         ? "Any workout recorded in Apple Health will satisfy this."
                         : "One \(activity.rawValue.lowercased()) workout will satisfy this.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .sessions:
                    VStack(alignment: .leading) {
                        Text("\(Int(sessions)) time\(Int(sessions) == 1 ? "" : "s")").font(.headline)
                        Slider(value: $sessions, in: 1...14, step: 1)
                        Text("Each qualifying workout counts once, whatever its length — "
                             + "three separate runs, not one long one split three ways.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
                case .calories:
                    VStack(alignment: .leading) {
                        Text("\(Int(calories)) active calories").font(.headline)
                        Slider(value: $calories, in: 25...800, step: 25)
                        Text("Active calories only — what you burned above resting. "
                             + "The one measure here that a minute of standing still "
                             + "can't satisfy. Best read from a watch; a phone alone "
                             + "estimates it roughly.")
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

        case .visibility:
            // A privacy choice, deliberately its own question: sharing is
            // about who watches, escape is about the contract. The two never
            // share a screen again.
            VStack(alignment: .leading, spacing: 14) {
                ChoiceRow(title: "Only you",
                          subtitle: "The default. Nobody is told anything.",
                          selected: !shareWithFriends) { shareWithFriends = false }
                ChoiceRow(title: "Friends",
                          subtitle: "The title, the deadline, and whether you kept it.",
                          selected: shareWithFriends) { shareWithFriends = true }
                Text("Changeable any time, in either direction — a privacy choice, not "
                     + "a contract term. Never what gets restricted, never your workouts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        case .who:
            // An invitation, not an enrollment (invariant 31): everyone named
            // here gets asked, decides on their own phone, and — only if they
            // accept — gets their own commitment under their own rules.
            VStack(alignment: .leading, spacing: 14) {
                ChoiceRow(title: "Just me",
                          subtitle: "The default. Nobody else is involved.",
                          selected: !withFriends) { withFriends = false; invitees = [] }
                ChoiceRow(title: "With friends",
                          subtitle: "Same promise, separate contracts. Each person "
                                  + "must accept.",
                          selected: withFriends) { withFriends = true }
                if withFriends {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(social.friends) { friend in
                            Button {
                                if invitees.contains(friend.handle) {
                                    invitees.remove(friend.handle)
                                } else {
                                    invitees.insert(friend.handle)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: invitees.contains(friend.handle)
                                          ? "checkmark.square.fill" : "square")
                                    Text(friend.displayName)
                                    Spacer()
                                    Text("@\(friend.handle)")
                                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                                }
                                .foregroundStyle(Theme.ink)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("They'll each be asked, and nothing exists on their phone "
                             + "unless they accept. Their own restrictions, verification "
                             + "and escape rules apply — you share the promise, not the "
                             + "punishment. Everyone who joins sees whether the others "
                             + "did it.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }

        case .escape:
            VStack(alignment: .leading, spacing: 18) {
                rosterPicker

                VStack(alignment: .leading, spacing: 0) {
                    ReceiptRow(label: "Ask",
                               value: roster.isEmpty
                                   ? "Nobody — the Solo route only"
                                   : "\(approvals) of \(roster.count) must approve")
                    ReceiptRow(label: "Solo",
                               value: accountabilityMinutes == 0
                                   ? "Available immediately"
                                   : "Opens after \(Int(accountabilityMinutes)) min")
                    HairRule()
                }

                Button(showingEscapeDetails ? "HIDE DETAILS" : "CUSTOMIZE") {
                    withAnimation { showingEscapeDetails.toggle() }
                }
                .buttonStyle(UnderlineButtonStyle())

                if showingEscapeDetails {
                    VStack(alignment: .leading, spacing: 16) {
                        if !roster.isEmpty {
                            Stepper("Approvals required: \(approvals)",
                                    value: $approvals, in: 1...max(1, roster.count))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wait before a solo override: \(Int(accountabilityMinutes)) min")
                            Slider(value: $accountabilityMinutes, in: 0...120, step: 5)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Warn me 30 minutes before", isOn: $warnBefore)
                            if warnBefore, store.warningDelivery == .denied {
                                Text("Notifications are off, so this warning won't arrive. "
                                     + "The deadline still stands.")
                                    .font(.footnote).foregroundStyle(Theme.signal)
                            }
                        }
                        Toggle("Eligible for Free Overrides", isOn: $rewardEligible)
                    }
                    .transition(.opacity)
                }
            }

        case .review:
            // The receipt. This screen should feel like signing something —
            // every term of the contract, printed, and one act at the bottom.
            VStack(alignment: .leading, spacing: 0) {
                ThickRule()
                ReceiptRow(label: "Do",
                           value: (title.isEmpty ? "Any workout" : title).uppercased())
                ReceiptRow(label: "Counts", value: Format.requirement(requirement))
                ReceiptRow(label: "By", value: repeats == .weekly
                           ? "\(Format.weekdays(weekdays)) at \(timeLabel), \(Int(weeks)) weeks"
                           : Format.deadline(deadline, from: store.now))
                ReceiptRow(label: "Verified by",
                           value: verification == .appVerified
                               ? "An app has to vouch" : "Your word")
                ReceiptRow(label: "Escape", value: roster.isEmpty
                           ? "Solo only, after \(Int(accountabilityMinutes)) min"
                           : "\(approvals) approvals · solo after \(Int(accountabilityMinutes)) min")
                if repeats == .once, social.profileState.profile != nil {
                    ReceiptRow(label: "Visible to",
                               value: shareWithFriends ? "Friends" : "Only you")
                }
                if withFriends, !invitees.isEmpty {
                    ReceiptRow(label: "With",
                               value: invitees.sorted().map { "@\($0)" }
                                   .joined(separator: ", "))
                }
                ReceiptRow(label: repeats == .weekly ? "Fully hardens" : "Hardens",
                           value: Format.relative(hardensAt, from: store.now),
                           valueColor: Theme.signal)
                ThickRule()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Correction window: \(Format.duration(correctionHours * 3600))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Slider(value: $correctionHours, in: 0...6, step: 0.5)
                }
                .padding(.top, 14)

                Text(repeats == .weekly
                     ? "Every occurrence in this plan — including the last week — hardens "
                       + "by then. There's no editing week three once week one has started."
                     : "After this hardens, it can only get harder — and missing the "
                       + "deadline doesn't clear it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: - Health, explained where it is bought

    /// The Health ask, at the only moment it is legible: the user has just said
    /// a workout must be vouched for by another app, so the permission has an
    /// obvious job. Onboarding no longer mentions Health at all — asking for a
    /// health permission because somebody installed a commitment app is asking
    /// for it before there is anything to justify it (docs/onboarding.md).
    private var healthExplanation: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Earned", color: Theme.ink).padding(.top, 36)
            StateWord(word: "APPLE HEALTH", size: 44).padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                Text("Earned reads finished workouts so it can verify this commitment.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("It reads that one type and nothing else, only while something "
                     + "unresolved could be moved by it, and writes nothing back.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 15))
            .foregroundStyle(Theme.muted)
            .padding(.top, 20)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Button("ALLOW HEALTH ACCESS") {
                    // Recorded, then asked for on the way out — see the sheet's
                    // onDismiss. Asking here presents into a dismissing view
                    // and the system drops it silently.
                    wantsHealthAccess = true
                    explainingHealth = false
                }
                .buttonStyle(PosterButtonStyle())
                // Declining is a real choice with a real consequence, so it
                // changes the commitment rather than just closing a sheet.
                Button("Use my word instead") {
                    verification = .selfReported
                    explainingHealth = false
                }
                .buttonStyle(UnderlineButtonStyle())
            }
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    // MARK: - Navigation

    private var controls: some View {
        HStack(spacing: 12) {
            if step != .what {
                Button("Back") { withAnimation { step = neighbour(from: step, direction: -1) } }
                    .font(.headline)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
            }
            if step == .review {
                Button("COMMIT") { commit() }
                    .buttonStyle(PosterButtonStyle())
            } else {
                Button("Next") {
                    withAnimation { step = neighbour(from: step, direction: 1) }
                }
                .buttonStyle(PosterButtonStyle())
                .disabled(!canAdvance)
                .opacity(canAdvance ? 1 : 0.4)
            }
        }
    }

    /// The next or previous question, skipping the visibility step where it
    /// has no answerers — plans (occurrences share individually, later) and
    /// builds with no profile to share from — and the who step where there is
    /// nobody to invite: plans (shared plans are not v1), no profile, no
    /// accepted friends. Shared commitments require accepted Earned friends
    /// (docs/shared-commitments.md §3).
    private func neighbour(from step: Step, direction: Int) -> Step {
        var raw = step.rawValue + direction
        while let candidate = Step(rawValue: raw) {
            if candidate == .visibility
                && (repeats == .weekly || social.profileState.profile == nil) {
                raw += direction
                continue
            }
            if candidate == .who
                && (repeats == .weekly || social.profileState.profile == nil
                    || social.friends.isEmpty) {
                raw += direction
                continue
            }
            return candidate
        }
        return direction > 0 ? .review : .what
    }

    private var canAdvance: Bool {
        switch step {
        case .what: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .when: return repeats == .weekly ? !weekdays.isEmpty : deadline > store.now
        case .who: return !withFriends || !invitees.isEmpty
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
        case .any: return Requirement(activity: activity.filter, metric: .anyQualifyingWorkout,
                                verification: verification)
        case .sessions: return Requirement(activity: activity.filter,
                                metric: .sessionCount(Int(sessions)),
                                verification: verification)
        case .duration: return Requirement(activity: activity.filter, metric: .totalDuration(minutes * 60),
                                verification: verification)
        case .distance: return Requirement(activity: activity.filter, metric: .totalDistance(kilometers * 1000),
                                verification: verification)
        case .calories: return Requirement(activity: activity.filter,
                                metric: .totalActiveEnergy(calories),
                                verification: verification)
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

    /// The roster, restricted to partners who have already consented.
    ///
    /// Someone still awaiting consent is listed but not selectable, and says
    /// why. Hiding them entirely would be worse: the user would wonder where
    /// Dave went. Offering them would let the user harden "2 of Mom and Dave"
    /// while Dave has never answered — a contract with no working way out,
    /// discovered at the worst possible moment (invariant 22).
    @ViewBuilder
    private var rosterPicker: some View {
        let eligible = account.eligiblePartners
        let waiting = account.awaitingConsent

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Who can let you out")

            if eligible.isEmpty && waiting.isEmpty {
                Text("No accountability partners yet. You can still make this commitment — "
                     + "the Solo Override will be the way out. Invite someone in Settings.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }

            ForEach(eligible) { partner in
                Button {
                    if roster.contains(partner.id) { roster.remove(partner.id) }
                    else { roster.insert(partner.id) }
                    approvals = min(approvals, max(1, roster.count))
                } label: {
                    HStack {
                        Image(systemName: roster.contains(partner.id)
                              ? "checkmark.square.fill" : "square")
                        Text(partner.displayName)
                        Spacer()
                    }
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            }

            ForEach(waiting) { partner in
                HStack {
                    Image(systemName: "square.dashed")
                    Text(partner.displayName)
                    Spacer()
                    Text("Awaiting consent")
                        .font(.system(size: 11, weight: .bold)).tracking(1.1)
                }
                .foregroundStyle(Theme.muted)
            }

            if !waiting.isEmpty {
                Text("Someone who hasn't accepted yet can't be counted on. A threshold that "
                     + "includes them would look like a way out and wouldn't be one.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    private func commit() {
        // Every commitment here is satisfied by a *workout*, and in a release
        // build Apple Health is the only way one reaches the ledger — manual
        // logging is a debug tool. Health used to be asked for only when the
        // user chose "an app has to vouch", so the default commitment ("my word
        // counts") was created on a phone that had never been asked, and no
        // finished run could ever complete it. Ask on the way in, for either
        // tier: the sheet arrives beside the screen that promised it.
        Task { await health.requestAccess() }
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
            if created { registerEnvelopes(rosterFor: unregisteredIDs); dismiss() }
            return
        }
        let before = Set(store.allCommitments.map(\.commitment.id))
        let created = store.createCommitment(
            title: title.trimmingCharacters(in: .whitespaces),
            requirement: requirement,
            deadline: deadline,
            correctionWindow: correctionHours * 3600,
            overridePolicy: OverridePolicy(approvalsRequired: approvals,
                                           accountabilityWindow: accountabilityMinutes * 60),
            rewardEligible: rewardEligible,
            warningLead: warnBefore ? 30 * 60 : nil)
        if created {
            let new = store.allCommitments.first { !before.contains($0.commitment.id) }
            if shareWithFriends, let new {
                let now = store.now
                Task { await social.share(new, now: now) }
            }
            // Doing it together: register the agreement and send the
            // invitations. The commitment above is already this user's own
            // contract either way — a network failure here costs the
            // invitations (retryable), never the deal (invariant 30).
            if withFriends, !invitees.isEmpty, let new {
                let now = store.now
                let handles = Array(invitees)
                Task { await social.createShared(for: new, invitees: handles, now: now) }
            }
            registerEnvelopes(rosterFor: unregisteredIDs)
            dismiss()
        }
    }

    /// Registers the new commitment's terms with the server immediately.
    ///
    /// Now rather than at the next launch, because the window closes: an
    /// envelope that does not arrive before the commitment hardens loses the
    /// accountability route for good (S13), and a short-fuse commitment can
    /// harden within minutes. A no-op when there is no backend or nobody is
    /// signed in — the commitment itself is already saved either way.
    private func registerEnvelopes(rosterFor ids: [UUID]) {
        let chosen = Array(roster)
        let rosters = Dictionary(uniqueKeysWithValues: ids.map { ($0, chosen) })
        Task {
            await account.syncEnvelopes(for: store.allCommitments,
                                        rosters: rosters, now: store.now)
        }
    }

    /// Commitments the ledger holds that the server has not been told about.
    /// Newly created ones, in other words — including every occurrence a plan
    /// just generated, which all share the roster chosen here.
    private var unregisteredIDs: [UUID] {
        store.allCommitments
            .filter { $0.resolution == nil && account.registration(of: $0.commitment) == .pending }
            .map(\.commitment.id)
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
