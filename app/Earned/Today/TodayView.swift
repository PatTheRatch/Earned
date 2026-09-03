import SwiftUI
import FamilyControls
import EarnedKit

/// Home answers one question — what do I need to do right now? — in the poster
/// voice: one huge state word, then quiet rule-separated rows (NORTHSTAR §29,
/// docs/design-language.md).
struct TodayView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var teachings: Teachings
    @State private var showingNewCommitment = false
    @State private var showingLockScreen = false
    @State private var showingFinishSetup = false
    @State private var teaching: Teachings.Lesson?

    /// Nothing has ever been owed and nothing is owed now — the state a user
    /// lands in the moment setup finishes. It used to be a grey sentence at the
    /// bottom of an otherwise empty screen, which read as an app that did not
    /// work rather than one waiting to be given something to do.
    private var isFirstUse: Bool {
        store.overdue.isEmpty && store.upcoming.isEmpty
            && store.state.commitments.isEmpty
    }

    /// The first Gate this phone has ever had open. The word is taught here
    /// because here it is a thing on screen rather than a definition.
    private var shouldTeachGate: Bool {
        !teachings.hasSeen(.gate) && store.isRestricted
    }

    /// The first missed deadline. Far more comprehensible than a debt lecture
    /// on install, which is where this used to live.
    private var shouldTeachOverdue: Bool {
        !teachings.hasSeen(.overdue) && !store.overdue.isEmpty
    }

    /// Anti-circumvention advice, offered only once enforcement has been felt
    /// to work — it is advice, not consent, and it is meaningless to somebody
    /// who has not yet watched an app go dark.
    private var shouldOfferPasscode: Bool {
        !teachings.hasSeen(.passcode)
            && store.setup.isComplete
            && !store.state.commitments.values.contains { $0.resolution == nil }
            && store.state.commitments.values.contains { $0.resolution != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Earned", color: Theme.ink)
                        .padding(.top, 12)

                    // The two-second answer. CLEAR. is the day's state;
                    // EARNED. stays the brand's word for the unlock moment
                    // itself, so the masthead never reads "EARNED / EARNED."
                    Button { showingLockScreen = true } label: {
                        StateWord(word: stateWord)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityLabel(stateDescription)

                    // Setup that never finished is a different fact from a
                    // permission that was revoked, and only one of them has an
                    // action attached. Both are honest about the same thing:
                    // Earned is remembering, not enforcing.
                    if !store.setup.isComplete {
                        SetupNotice(status: store.setup) { showingFinishSetup = true }
                    } else if store.shielding != .approved {
                        EnforcementNotice(owing: !store.unenforceableGates.isEmpty)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        hydrationRow
                        ForEach(store.overdue, id: \.commitment.id) { record in
                            overdueRow(record)
                        }
                        ForEach(store.upcomingEntries) { entry in
                            switch entry {
                            case .commitment(let record): upcomingRow(record)
                            case .plan(let summary): planRow(summary)
                            }
                        }
                        ThickRule()
                    }
                    .padding(.top, 22)

                    if store.freeOverrides > 0 {
                        TicketView(count: store.freeOverrides)
                            .padding(.top, 20)
                    }

                    if isFirstUse {
                        // The handoff from setup. Not a success screen and not
                        // a celebration — a statement that Earned is ready and
                        // one dominant thing to do about it.
                        VStack(alignment: .leading, spacing: 8) {
                            // Only claimed when it is true. Saying "Earned is
                            // set up" directly beneath a notice explaining that
                            // it cannot block anything yet is the app
                            // contradicting itself on one screen.
                            if store.setup.isComplete {
                                Text("Earned is set up.")
                                    .font(Theme.blocker(18))
                                    .foregroundStyle(Theme.ink)
                            }
                            Text("Make one deal and see how it works.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.top, 22)
                    } else if store.overdue.isEmpty && store.upcoming.isEmpty {
                        Text("Nothing owed. Make a commitment when you know what you owe yourself.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 20)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        // On the very first visit the deal is the act, and the
                        // water button is not: a user who has never made a
                        // commitment has nothing to compare a glass of water
                        // to. Afterwards the everyday order returns.
                        if isFirstUse {
                            Button("MAKE YOUR FIRST DEAL") { showingNewCommitment = true }
                                .buttonStyle(PosterButtonStyle())
                            if store.state.hydration?.enabled == true {
                                Button("I drank some water") { store.acknowledgeWater() }
                                    .buttonStyle(UnderlineButtonStyle())
                            }
                        } else {
                            if store.state.hydration?.enabled == true {
                                Button("I DRANK SOME WATER") { store.acknowledgeWater() }
                                    .buttonStyle(PosterButtonStyle())
                            }
                            Button("+ MAKE A COMMITMENT") { showingNewCommitment = true }
                                .buttonStyle(UnderlineButtonStyle())
                        }
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewCommitment) { NewCommitmentView() }
            .sheet(isPresented: $showingLockScreen) { LockScreenView() }
            .sheet(isPresented: $showingFinishSetup) { FinishSetupView() }
            .sheet(item: $teaching) { lesson in
                teachingSheet(lesson).presentationDetents([.medium])
            }
            // One lesson at a time, and only when its moment has arrived. The
            // flag is written when the card is *offered*, not when it is
            // dismissed, so a user who swipes it away is not shown it again on
            // the next tick of the clock.
            .onChange(of: dueLesson) { _, due in
                guard teaching == nil, let due else { return }
                teaching = due
                teachings.markSeen(due)
            }
            .onAppear {
                guard teaching == nil, let due = dueLesson else { return }
                teaching = due
                teachings.markSeen(due)
            }
            .rejectionAlert()
        }
    }

    // MARK: - What the masthead is allowed to claim

    /// `LOCKED.` is a claim about the phone, not about the obligation.
    ///
    /// Today used to print it whenever a Gate was unsatisfied — directly above
    /// a notice reading "Earned can't block apps yet", which is the app
    /// contradicting itself in two lines. Worse, it spends the word: if
    /// `LOCKED.` sometimes means "nothing is actually blocked", it stops
    /// meaning anything, and the one state the whole product exists to create
    /// becomes decoration.
    ///
    /// So the obligation and the enforcement are said separately. **OWED.** is
    /// the honest word for a Gate that is closed while Earned cannot act on
    /// it: the debt is undiminished — it is stated first and in the same size —
    /// but the phone is not being held shut, and pretending otherwise would be
    /// the app taking credit for something it did not do (NORTHSTAR §33).
    private var stateWord: String {
        guard store.isRestricted else { return "CLEAR" }
        return store.shielding.canShield ? "LOCKED" : "OWED"
    }

    private var stateDescription: String {
        switch stateWord {
        case "CLEAR":  return "Clear. Every gate satisfied."
        case "LOCKED": return "Locked. Show what is owed."
        default:       return "Owed. Still owed, but Earned cannot block apps "
                            + "right now. Show what is owed."
        }
    }

    // MARK: - Just-in-time teaching

    /// Which lesson, if any, this screen owes the user right now. Ordered by
    /// urgency rather than by when they were written: a missed deadline is the
    /// more surprising fact, so it takes the screen if both are due.
    private var dueLesson: Teachings.Lesson? {
        if shouldTeachOverdue { return .overdue }
        if shouldTeachGate { return .gate }
        if shouldOfferPasscode { return .passcode }
        return nil
    }

    @ViewBuilder
    private func teachingSheet(_ lesson: Teachings.Lesson) -> some View {
        switch lesson {
        case .gate:
            TeachingSheet(
                word: "THIS IS A GATE",
                lines: ["An unfinished obligation keeps its restrictions in force.",
                        "If several Gates are open, their restrictions combine.",
                        "It closes when you satisfy it — or when you use an Override."])
        case .overdue:
            TeachingSheet(
                word: "OVERDUE",
                lines: ["The deadline passed. The deal didn't.",
                        "Your restrictions stay in force until this is resolved — by "
                            + "doing it, or by an Override.",
                        "Completing it late still counts. It just counts as late."])
        case .passcode:
            TeachingSheet(
                word: "WANT A STRONGER DEAL?",
                lines: ["Earned cannot stop you from revoking Screen Time access, and it "
                            + "will never pretend otherwise.",
                        "If you want more friction, protect Screen Time in iOS Settings "
                            + "with a passcode you don't keep close at hand — give it to "
                            + "someone, or use a code you don't memorise.",
                        "Earned never sees, stores or transmits that passcode. It can't "
                            + "be recovered from here."],
                acknowledgement: "NOT NOW")
        case .waysOut, .reachable:
            // Both are taught where they are needed: the Override ladder on
            // the override surface, notifications on Social at the moment
            // somebody first depends on this phone noticing something.
            EmptyView()
        }
    }

    // MARK: - Rows: thick rule, small-caps label, one bold line, quiet context.

    @ViewBuilder
    private var hydrationRow: some View {
        if store.state.hydration?.enabled == true {
            NavigationLink {
                HydrationDetailView()
            } label: {
                row(label: "Water", line: hydrationLine)
            }
            .buttonStyle(.plain)
        }
    }

    private var hydrationLine: Text {
        switch store.hydration {
        case .satisfied(let expiresAt):
            let left = Format.duration(max(0, expiresAt.timeIntervalSince(store.now)))
            return Text("Fine. \(left) left.").foregroundStyle(Theme.ink)
        case .unsatisfied:
            return Text("Drink some water. ").foregroundStyle(Theme.ink)
                 + Text("Now.").foregroundStyle(Theme.signal)
        case .dormant:
            return Text("Resting until active hours.").foregroundStyle(Theme.muted)
        }
    }

    private func overdueRow(_ record: CommitmentRecord) -> some View {
        NavigationLink {
            CommitmentDetailView(commitmentID: record.commitment.id)
        } label: {
            row(label: record.commitment.title,
                line: overdueLine(record),
                context: "was due \(Format.deadline(record.commitment.deadline, from: store.now).lowercased())")
        }
        .buttonStyle(.plain)
    }

    private func overdueLine(_ record: CommitmentRecord) -> Text {
        guard let progress = store.state.progress(for: record.commitment.id),
              progress.unit != .workouts || progress.required > 1,
              progress.achieved > 0 else {
            return Text("Not done. ").foregroundStyle(Theme.ink)
                 + Text("Still owed.").foregroundStyle(Theme.signal)
        }
        let done = Format.progress(progress)
        let left = Format.remaining(progress) ?? "Done."
        return Text("\(done). ").foregroundStyle(Theme.ink)
             + Text(left).foregroundStyle(Theme.signal)
    }

    private func upcomingRow(_ record: CommitmentRecord) -> some View {
        NavigationLink {
            CommitmentDetailView(commitmentID: record.commitment.id)
        } label: {
            row(label: dayLabel(record.commitment.deadline),
                line: Text("\(record.commitment.title) by \(timeLabel(record.commitment.deadline)).")
                    .foregroundStyle(Theme.muted),
                context: liveNote(record))
        }
        .buttonStyle(.plain)
    }

    /// A whole recurring plan in one row, headlined by its next outstanding day.
    private func planRow(_ summary: PlanSummary) -> some View {
        NavigationLink {
            PlanDetailView(planID: summary.plan.id)
        } label: {
            row(label: dayLabel(summary.next.commitment.deadline),
                line: Text("\(summary.plan.title) by "
                           + "\(timeLabel(summary.next.commitment.deadline)).")
                    .foregroundStyle(Theme.muted),
                context: [summary.scheduleLine, liveNote(summary.next)]
                    .compactMap { $0 }.joined(separator: " · "))
        }
        .buttonStyle(.plain)
    }

    /// Says so when a commitment's window hasn't opened yet — a run today does
    /// nothing for Friday's obligation, and the row shouldn't imply otherwise.
    private func liveNote(_ record: CommitmentRecord) -> String? {
        guard record.commitment.eligibleFrom > store.now else { return nil }
        return "counts from \(dayLabel(record.commitment.eligibleFrom).lowercased())"
    }

    private func row(label: String, line: Text, context: String? = nil) -> some View {
        PosterRow(label: label, line: { line.font(Theme.blocker()) },
                  context: context, chevron: true)
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Enforcement integrity, as a *secondary* technical state.
///
/// Deliberately never competes with the state word. What you owe is the
/// contract and stays primary; whether Earned can currently act on it is a
/// separate fact about the machinery. The two must not collapse into one
/// Setup that was skipped rather than revoked, with the way to finish it.
///
/// Onboarding is a guided sequence because Screen Time → app selection →
/// activation has a real dependency order, and a freeform checklist invites
/// picking apps before there is permission to block them. But once somebody has
/// skipped a step, marching them back through screens they already completed is
/// the wrong recovery: this is the checklist, arriving only after the ordering
/// problem it would have caused is behind us.
private struct SetupNotice: View {
    let status: SetupStatus
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FINISH SETUP")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.signal)
            Text("Your commitments still count, but Earned can't block apps yet.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            // The button names the next actual step rather than repeating the
            // label above it, which read as the same words twice.
            Button(status.screenTimeOn ? "Choose apps" : "Turn on blocking") { finish() }
                .buttonStyle(UnderlineButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The two steps of setup, in the order they depend on each other, reachable
/// without re-running onboarding.
struct FinishSetupView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()

    private var status: SetupStatus { store.setup }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Earned", color: Theme.ink).padding(.top, 12)
                StateWord(word: "FINISH SETUP", size: 44).padding(.top, 4)

                VStack(alignment: .leading, spacing: 0) {
                    HairRule()
                    row(label: "SCREEN TIME",
                        value: status.screenTimeOn ? "On" : "Not enabled",
                        done: status.screenTimeOn) {
                        if store.shielding == .denied {
                            openSystemSettings()
                        } else {
                            Task { await store.requestShieldingAuthorization() }
                        }
                    }
                    HairRule()
                    row(label: "RESTRICTIONS",
                        value: status.hasRestrictions
                            ? "\(status.restrictionCount) selected" : "None selected",
                        // Never a dead picker: choosing apps is only offered
                        // once there is a permission that could act on them.
                        done: status.hasRestrictions,
                        enabled: status.screenTimeOn) {
                        selection = RestrictionBridge.selection(
                            from: store.state.defaultCommitmentRestrictions)
                        picking = true
                    }
                    HairRule()
                }
                .padding(.top, 24)

                if let failure = store.shieldingFailure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }

                Spacer()

                if status.isComplete {
                    Text("Earned can enforce your Gates.")
                        .font(.system(size: 14)).foregroundStyle(Theme.ink)
                        .padding(.bottom, 12)
                }
                Button(status.isComplete ? "DONE" : "CLOSE") { dismiss() }
                    .buttonStyle(PosterButtonStyle())
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .familyActivityPicker(isPresented: $picking, selection: $selection)
            .onChange(of: picking) { wasPicking, isPicking in
                guard wasPicking && !isPicking else { return }
                store.setDefaultRestrictions(RestrictionBridge.profile(from: selection))
            }
        }
    }

    @ViewBuilder
    private func row(label: String, value: String, done: Bool,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .bold)).tracking(1.5)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(done ? Theme.ink : Theme.signal)
                if !done && enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done || !enabled)
        .accessibilityElement(children: .combine)
        .accessibilityHint(done ? "Done"
                                : (enabled ? "Opens setup" : "Turn on Screen Time first"))
    }
}

/// LOCKED/UNLOCKED binary (NORTHSTAR §33) — so this says enforcement is off
/// without ever implying the obligation went with it.
private struct EnforcementNotice: View {
    /// Whether a Gate is actually unsatisfied right now. Enforcement being off
    /// while nothing is owed is a footnote; while something is owed it matters.
    let owing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ENFORCEMENT OFF")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(owing ? Theme.signal : Theme.muted)
            Text(owing
                 ? "Earned can't block anything right now. Still owed either way."
                 : "Earned can't block anything right now.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}
