import Combine
import Foundation
import EarnedKit

/// The app's single source of truth: an EarnedKit ledger, persisted on every
/// accepted event, plus a ticking clock so gate countdowns stay live.
///
/// The store never decides product rules — EarnedKit does. Anything this type
/// rejects was rejected by the domain engine, and the message comes from there.
@MainActor
final class EarnedStore: ObservableObject {
    @Published private(set) var ledger: Ledger
    /// Advances every second while the app is foregrounded, so "locks again in
    /// 42 min" and overdue transitions are visible without user action.
    @Published private(set) var now: Date = Date()
    /// Set when the domain engine refuses an event; surfaced to the user and
    /// cleared on the next successful one.
    @Published var rejection: String?
    /// Non-nil when a saved ledger could not be replayed on launch. Cleared
    /// when the user dismisses the alert, because an alert that will not go
    /// away is its own bug.
    @Published var loadFailure: String?
    /// The quarantined file's name, if history was set aside this launch. Kept
    /// after `loadFailure` is dismissed: a tester who taps OK on the alert and
    /// then reports "all my commitments vanished" needs the diagnostics screen
    /// to still know it happened, and to name the file that has their history
    /// in it.
    @Published private(set) var quarantinedHistory: String?
    /// How many entries came back from iCloud this launch, if any. Surfaced in
    /// Diagnostics so a restore is visible rather than mysterious.
    @Published private(set) var restoredEntries: Int?
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    private static let onboardedKey = "earned.hasOnboarded"
    private let storage: LedgerStorage
    private let notifications: NotificationScheduler
    private let screenTime: ScreenTimeController
    private var ticker: AnyCancellable?
    private var authorizationObserver: AnyCancellable?
    private var shieldObserver: AnyCancellable?
    private var shieldFailureObserver: AnyCancellable?

    /// Whether Earned can actually block anything. Surfaced so the app never
    /// claims a Gate is enforcing when Screen Time has not been granted.
    @Published private(set) var shielding: ScreenTimeController.Authorization = .notDetermined
    /// Why Screen Time refused, when it did. Shown rather than swallowed.
    @Published private(set) var shieldingFailure: String?

    /// Whether warnings the user configured can actually be delivered. Surfaced
    /// so the app never presents a warning toggle as working when it isn't.
    @Published private(set) var warningDelivery: NotificationScheduler.Authorization = .notDetermined

    var state: EarnedState { ledger.state }

    /// The copy in the user's own iCloud. Local stays authoritative; this is
    /// written after the fact and read only when there is no local history.
    let mirror = LedgerMirror()
    /// Set at launch when the container held nothing, so the mirror is asked
    /// once. Never on a launch that found history: the local ledger is the
    /// authority and a backup must not overwrite a working phone.
    private var restoreFromMirror = false

    init(storage: LedgerStorage = .documents()) {
        let notifications = NotificationScheduler()
        let screenTime = ScreenTimeController()
        self.storage = storage
        self.notifications = notifications
        self.screenTime = screenTime
        self.hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        switch storage.load() {
        case .loaded(let ledger):
            self.ledger = ledger
        case .empty:
            self.ledger = Ledger()
            // No local history: a first install, or a reinstall that cleared
            // the container. The second is what this exists for — deleting the
            // app was the cheapest way out of a commitment in the product.
            restoreFromMirror = true
        case .unreadable(let backup, let error):
            self.ledger = Ledger()
            let location = backup.map { " Saved to \($0.lastPathComponent)." } ?? ""
            self.loadFailure = "Your saved history could not be read and was set aside.\(location) "
                + "Starting fresh. (\(error))"
            self.quarantinedHistory = backup?.lastPathComponent ?? "moving it aside also failed"
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                // Timer.publish(on: .main) always delivers on the main thread.
                MainActor.assumeIsolated {
                    self?.now = date
                    // A Gate can close with nobody touching the phone — a
                    // deadline simply passing — so the shield follows the
                    // clock, not just user actions. Applying is a no-op when
                    // nothing changed.
                    self?.syncShield()
                }
            }
        shieldObserver = screenTime.$authorization
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.shielding = status
                    self?.syncShield()
                }
            }
        shieldFailureObserver = screenTime.$failure
            .sink { [weak self] message in
                MainActor.assumeIsolated { self?.shieldingFailure = message }
            }
        authorizationObserver = notifications.$authorization
            .sink { [weak self] status in
                // NotificationScheduler is @MainActor, so this always arrives
                // on the main thread — same contract as the ticker above.
                MainActor.assumeIsolated { self?.warningDelivery = status }
            }
        refreshShielding()
        Task { await self.refreshWarnings() }
        if restoreFromMirror { Task { await self.adoptMirroredHistory() } }
    }

    /// Take back what a reinstall cleared.
    ///
    /// Only ever called on a launch that found no local history, and it merges
    /// rather than replaces — belt and braces, since anything appended between
    /// launch and the network answering must survive. Commitments come back
    /// exactly as they were made, which means already hardened: hardening is a
    /// function of the event's own `createdAt`, so reinstalling is not a way
    /// back into the correction window.
    ///
    /// Silent on failure. No iCloud account, no backup, no connection — all
    /// ordinary, and all leaving the app exactly as it was before this existed.
    private func adoptMirroredHistory() async {
        guard let backup = await mirror.restore(), !backup.entries.isEmpty else { return }
        guard let merged = try? ledger.merged(with: backup) else { return }
        guard merged.entries.count > ledger.entries.count else { return }
        ledger = merged
        try? storage.save(ledger)
        restoredEntries = merged.entries.count
        syncShield()
        Task { await refreshWarnings() }
    }

    // MARK: - Enforcement

    /// Puts the currently-unsatisfied Gates' restrictions into force.
    ///
    /// EarnedKit already computed the answer — `effectiveRestrictions` is the
    /// union across every closed Gate — so this only hands it to the system.
    private func syncShield() {
        guard screenTime.authorization.canShield else { return }
        screenTime.apply(access.effectiveRestrictions)
        // What is in force now, and what will be in force at every deadline
        // ahead, are two different jobs. This one covers the app being open;
        // the schedule below covers it being closed, which is the case that
        // actually matters — nobody opens a commitment app to be restricted.
        ShieldScheduler.reschedule(for: state, now: now)
        // And what the shield should say when one of those restrictions is
        // actually met. Written here rather than in `reschedule` because it
        // describes the Gates closed right now, not the ones closing later.
        ShieldScheduler.publishCopy(for: access)
    }

    /// Re-reads Screen Time permission, which can be revoked in iOS Settings
    /// while Earned isn't running, and re-applies whatever should be in force.
    func refreshShielding() {
        screenTime.refreshAuthorization()
        recordEnforcementTransition()
        if screenTime.authorization.canShield {
            // Once per foreground, insist on a real re-registration rather than
            // trusting the scheduler's cache. The cache is what stops the
            // one-second ticker from hammering the DeviceActivity daemon, but
            // it cannot know that the system dropped a schedule, or that
            // authorization went away and came back while Earned was closed.
            ShieldScheduler.invalidate()
            syncShield()
        } else {
            // Holding restrictions the user can no longer manage would be a
            // trap — including the ones scheduled for later, which were never
            // visible to manage in the first place. Dropping the schedules too
            // costs nothing: `syncShield` rebuilds them from scratch whenever
            // authorization comes back.
            screenTime.clear()
            ShieldScheduler.clear()
        }
    }

    /// Writes enforcement-integrity transitions into the ledger.
    ///
    /// This is the only place the app tells EarnedKit about OS authority, and
    /// it is deliberately poll-driven: iOS does **not** notify a backgrounded
    /// app that Screen Time authorization was revoked — `AuthorizationCenter`'s
    /// publisher stays silent — so the earliest Earned can know is the next
    /// time it runs. The event is named for detection, not revocation, because
    /// the moment of the user's action is genuinely unknowable (NORTHSTAR §33).
    ///
    /// Only the *loss* of established authority is recorded. A user who has
    /// never granted Screen Time has taken nothing away, so `unknown` is left
    /// alone rather than written down as a loss.
    private func recordEnforcementTransition() {
        let canEnforce = screenTime.authorization.canShield
        switch (state.enforcementStatus, canEnforce) {
        case (.available, false):
            append(.enforcementUnavailableDetected)
        case (.unknown, true), (.unavailable, true):
            append(.enforcementRestored)
        default:
            break
        }
    }

    /// Whether setup got far enough for Earned to actually enforce anything.
    ///
    /// Both halves of it are skippable during onboarding and both stay genuinely
    /// optional afterwards — but an app that can only remember commitments must
    /// never present itself as one that is holding apps closed, so Today reads
    /// this rather than assuming (NORTHSTAR §33).
    var setup: SetupStatus {
        SetupStatus(screenTimeOn: screenTime.authorization.canShield,
                    restrictionCount: state.defaultCommitmentRestrictions.count)
    }

    /// Unsatisfied Gates that Earned currently cannot act on. Non-empty only
    /// when something is owed *and* enforcement is gone.
    var unenforceableGates: [LockReason] {
        guard !screenTime.authorization.canShield else { return [] }
        return access.lockReasons
    }

    /// Asks for Screen Time permission. Called from onboarding and Settings —
    /// never silently, since this is the permission that lets Earned actually
    /// take something away.
    func requestShieldingAuthorization() async {
        await screenTime.requestAuthorization()
        refreshShielding()
    }

    // MARK: - Warnings

    /// Re-reads the permission state and re-registers every scheduled warning.
    /// Called on launch and whenever the app returns to the foreground, since
    /// notification permission can be revoked in iOS Settings while Earned is
    /// not running.
    /// Ask for notification permission deliberately, from a screen that has
    /// just explained what it is for. Distinct from the incidental request
    /// `reschedule` makes when a warning is first scheduled.
    func requestWarningAuthorization() async {
        await notifications.requestAuthorization()
        await notifications.reschedule(plannedWarnings)
    }

    func refreshWarnings() async {
        await notifications.refreshAuthorization()
        await notifications.reschedule(plannedWarnings)
    }

    /// How many warnings are currently queued to arrive.
    var scheduledWarningCount: Int { plannedWarnings.count }

    /// Every configured warning, rendered into the words the user will read.
    ///
    /// EarnedKit decides which Gates warn and when (`upcomingWarnings`); this
    /// only supplies the wording. A warning states a fact and offers no way
    /// out — see `NotificationScheduler`.
    private var plannedWarnings: [WarningNotification] {
        state.upcomingWarnings(now: now).compactMap { warning in
            switch warning.gate {
            case .hydration:
                guard let lead = state.hydration?.warningLead else { return nil }
                return WarningNotification(
                    id: NotificationScheduler.hydrationIdentifier,
                    fireAt: warning.date,
                    title: "Water",
                    body: "The Hydration Gate closes in \(Format.duration(lead)).")
            case .commitment(let id):
                guard let commitment = state.commitments[id]?.commitment,
                      let lead = commitment.warningLead else { return nil }
                return WarningNotification(
                    id: NotificationScheduler.identifier(forCommitment: id),
                    fireAt: warning.date,
                    title: commitment.title,
                    body: "Due in \(Format.duration(lead)).")
            }
        }
    }

    // MARK: - Writing

    /// The wall clock, clamped never to precede the ledger's newest entry.
    ///
    /// Real clocks go backwards — an NTP correction after a fast clock, a
    /// manual change — and the ledger's chronology invariant would then turn a
    /// perfectly legitimate tap into a baffling rejection. Recording the event
    /// at the ledger's frontier instead is honest: it happened no earlier than
    /// the last thing that happened. (Deliberately *not* a defense against
    /// clock tampering to dodge a deadline — gate state is computed against
    /// the wall clock, and resisting that is an enforcement-layer problem.)
    private var eventDate: Date {
        max(Date(), ledger.entries.last?.date ?? .distantPast)
    }

    /// Appends an event, persisting on success. Returns false and populates
    /// `rejection` when EarnedKit refuses it — a monotonicity violation, an
    /// override taken too early, a spend with no balance.
    @discardableResult
    func append(_ event: Event, at date: Date? = nil) -> Bool {
        let date = date ?? eventDate
        var updated = ledger
        do {
            try updated.append(event, at: date)
        } catch {
            rejection = (error as? EarnedError).map { String(describing: $0) }
                ?? error.localizedDescription
            return false
        }
        ledger = updated
        now = max(now, date)
        rejection = nil
        do {
            try storage.save(ledger)
            // Best-effort, and after the local write: the copy in iCloud is a
            // backup, never a precondition for the deal being recorded.
            mirror.save(ledger)
        } catch {
            // The event is valid and already applied in memory; surface the
            // write failure rather than pretending the commitment is durable.
            rejection = "Saved to memory but not to disk: \(error.localizedDescription)"
        }
        // Any accepted event can move what is due and when: a new commitment,
        // a workout that resolves one, water that restarts the rolling timer.
        let warnings = plannedWarnings
        Task { await notifications.reschedule(warnings) }
        // Drinking water or finishing a run should lift the shield now, not on
        // the next tick.
        syncShield()
        return true
    }

    // MARK: - Convenience actions

    @discardableResult
    func acknowledgeWater() -> Bool { append(.waterAcknowledged) }

    @discardableResult
    func configureHydration(_ config: HydrationConfig) -> Bool {
        append(.hydrationConfigured(config))
    }

    /// Creates a commitment. `createdAt` must equal the event date, so the
    /// timestamp is taken here rather than by the caller.
    ///
    /// `id` is normally minted here; accepting a shared commitment passes the
    /// id the server recorded, so a retried acceptance converges on one
    /// commitment. `eligibleFrom` later than creation is a *harder* term —
    /// a shared window that opens tomorrow must not be satisfiable today.
    @discardableResult
    func createCommitment(id: UUID = UUID(),
                          title: String,
                          requirement: Requirement,
                          eligibleFrom: Date? = nil,
                          deadline: Date,
                          correctionWindow: TimeInterval,
                          overridePolicy: OverridePolicy,
                          restrictions: RestrictionProfile? = nil,
                          rewardEligible: Bool,
                          warningLead: TimeInterval?) -> Bool {
        let createdAt = eventDate
        let commitment = Commitment(id: id,
                                    title: title,
                                    requirement: requirement,
                                    eligibleFrom: eligibleFrom.map { max($0, createdAt) },
                                    deadline: deadline,
                                    createdAt: createdAt,
                                    configuredCorrectionWindow: correctionWindow,
                                    overridePolicy: overridePolicy,
                                    restrictions: restrictions ?? state.defaultCommitmentRestrictions,
                                    rewardEligible: rewardEligible,
                                    warningLead: warningLead)
        return append(.commitmentCreated(commitment), at: createdAt)
    }

    /// Creates a recurring plan and, in the same instant, every occurrence it
    /// generates. The occurrences are ordinary commitments from here on; the
    /// plan is kept only so it can be shown and cancelled as one thing.
    @discardableResult
    func createPlan(title: String,
                    requirement: Requirement,
                    weekdays: Set<Int>,
                    deadlineMinuteOfDay: Int,
                    startDate: Date,
                    endDate: Date,
                    correctionWindow: TimeInterval,
                    overridePolicy: OverridePolicy,
                    restrictions: RestrictionProfile? = nil,
                    rewardEligible: Bool,
                    warningLead: TimeInterval?) -> Bool {
        let createdAt = eventDate
        let plan = CommitmentPlan(title: title,
                                  requirement: requirement,
                                  weekdays: weekdays,
                                  deadlineMinuteOfDay: deadlineMinuteOfDay,
                                  startDate: startDate,
                                  endDate: endDate,
                                  configuredCorrectionWindow: correctionWindow,
                                  overridePolicy: overridePolicy,
                                  restrictions: restrictions ?? state.defaultCommitmentRestrictions,
                                  rewardEligible: rewardEligible,
                                  warningLead: warningLead,
                                  createdAt: createdAt)
        let occurrences = plan.occurrences()
        guard !occurrences.isEmpty else {
            rejection = "That plan doesn't schedule anything before its end date."
            return false
        }
        guard append(.planCreated(plan), at: createdAt) else { return false }
        for occurrence in occurrences {
            guard append(.commitmentCreated(occurrence), at: createdAt) else { return false }
        }
        return true
    }

    @discardableResult
    func cancelPlan(_ id: UUID) -> Bool { append(.planCancelled(id: id)) }

    @discardableResult
    func cancelCommitment(_ id: UUID) -> Bool { append(.commitmentCancelled(id: id)) }

    @discardableResult
    func spendFreeOverride(on commitmentID: UUID) -> Bool {
        append(.freeOverrideSpent(commitmentID: commitmentID))
    }

    @discardableResult
    func recordWorkout(_ workout: Workout) -> Bool { append(.workoutRecorded(workout)) }

    /// The default profile applied to newly created commitments.
    @discardableResult
    func setDefaultRestrictions(_ profile: RestrictionProfile) -> Bool {
        append(.defaultCommitmentRestrictionsChanged(profile))
    }

    /// Changes one Gate's own restriction profile.
    @discardableResult
    func setRestrictions(_ profile: RestrictionProfile, of gate: GateID) -> Bool {
        switch gate {
        case .hydration:
            guard var config = state.hydration else { return false }
            config.restrictions = profile
            return append(.hydrationConfigured(config))
        case .commitment(let id):
            return append(.commitmentEdited(id: id, edit: CommitmentEdit(restrictions: profile)))
        }
    }

    @discardableResult
    func configureRewards(_ policy: RewardPolicy) -> Bool {
        append(.rewardPolicyConfigured(policy))
    }

    // MARK: - Reading

    var access: AccessState { state.accessState(now: now) }
    var isRestricted: Bool { access.isRestricted }
    /// Everything currently blocked: the union across unsatisfied Gates.
    var effectiveRestrictions: RestrictionProfile { access.effectiveRestrictions }
    var hydration: HydrationStatus { state.hydrationStatus(now: now) }
    var overdue: [CommitmentRecord] { state.overdueCommitments(now: now) }
    var upcoming: [CommitmentRecord] { state.pendingCommitments(now: now) }
    var freeOverrides: Int { state.freeOverrideBalance }
    var streak: Int { state.completionStreak(now: now) }

    /// Every commitment ever made, newest deadline first.
    var allCommitments: [CommitmentRecord] {
        state.commitments.values.sorted { $0.commitment.deadline > $1.commitment.deadline }
    }

    var activePlans: [PlanRecord] { state.activePlans() }

    /// What a workout finished right now would count toward.
    var live: [CommitmentRecord] { state.liveCommitments(now: now) }

    /// Today's upcoming list, with plan occurrences folded into one entry each.
    ///
    /// A four-week Mon/Wed/Fri plan creates twelve commitments, and listing
    /// twelve near-identical rows is exactly what making it a plan was meant to
    /// avoid: it is one decision, shown once. Overdue occurrences are
    /// deliberately *not* folded — each is a Gate holding the phone closed, and
    /// the lock notice has to name every one of them (NORTHSTAR §19).
    var upcomingEntries: [UpcomingEntry] {
        var entries: [UpcomingEntry] = []
        var seenPlans: Set<UUID> = []

        for record in upcoming {
            guard let planID = record.commitment.planID,
                  let planRecord = state.plans[planID], !planRecord.isCancelled else {
                entries.append(.commitment(record))
                continue
            }
            guard seenPlans.insert(planID).inserted else { continue }
            // `upcoming` is deadline-ordered, so the first occurrence seen for a
            // plan is its next one.
            entries.append(.plan(summary(of: planRecord.plan, next: record)))
        }
        return entries
    }

    private func summary(of plan: CommitmentPlan, next: CommitmentRecord) -> PlanSummary {
        let occurrences = state.occurrences(ofPlan: plan.id)
        return PlanSummary(
            plan: plan,
            next: next,
            completed: occurrences.filter {
                if case .completed = $0.resolution { return true } else { return false }
            }.count,
            total: occurrences.count)
    }

    /// Records one unit of active friction toward a solo override.
    @discardableResult
    func recordFrictionProgress(requestID: UUID, units: Int = 1) -> Bool {
        append(.soloOverrideProgressRecorded(requestID: requestID, units: units))
    }
}
