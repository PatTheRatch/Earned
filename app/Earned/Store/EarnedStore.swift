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
    /// Non-nil when a saved ledger could not be replayed on launch.
    @Published var loadFailure: String?
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    private static let onboardedKey = "earned.hasOnboarded"
    private let storage: LedgerStorage
    private let notifications: NotificationScheduler
    private var ticker: AnyCancellable?
    private var authorizationObserver: AnyCancellable?

    /// Whether warnings the user configured can actually be delivered. Surfaced
    /// so the app never presents a warning toggle as working when it isn't.
    @Published private(set) var warningDelivery: NotificationScheduler.Authorization = .notDetermined

    var state: EarnedState { ledger.state }

    init(storage: LedgerStorage = .documents()) {
        let notifications = NotificationScheduler()
        self.storage = storage
        self.notifications = notifications
        self.hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        switch storage.load() {
        case .loaded(let ledger):
            self.ledger = ledger
        case .empty:
            self.ledger = Ledger()
        case .unreadable(let backup, let error):
            self.ledger = Ledger()
            let location = backup.map { " Saved to \($0.lastPathComponent)." } ?? ""
            self.loadFailure = "Your saved history could not be read and was set aside.\(location) "
                + "Starting fresh. (\(error))"
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                // Timer.publish(on: .main) always delivers on the main thread.
                MainActor.assumeIsolated { self?.now = date }
            }
        authorizationObserver = notifications.$authorization
            .sink { [weak self] status in
                // NotificationScheduler is @MainActor, so this always arrives
                // on the main thread — same contract as the ticker above.
                MainActor.assumeIsolated { self?.warningDelivery = status }
            }
        Task { await self.refreshWarnings() }
    }

    // MARK: - Warnings

    /// Re-reads the permission state and re-registers every scheduled warning.
    /// Called on launch and whenever the app returns to the foreground, since
    /// notification permission can be revoked in iOS Settings while Earned is
    /// not running.
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
        } catch {
            // The event is valid and already applied in memory; surface the
            // write failure rather than pretending the commitment is durable.
            rejection = "Saved to memory but not to disk: \(error.localizedDescription)"
        }
        // Any accepted event can move what is due and when: a new commitment,
        // a workout that resolves one, water that restarts the rolling timer.
        let warnings = plannedWarnings
        Task { await notifications.reschedule(warnings) }
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
    @discardableResult
    func createCommitment(title: String,
                          requirement: Requirement,
                          deadline: Date,
                          correctionWindow: TimeInterval,
                          overridePolicy: OverridePolicy,
                          restrictions: RestrictionProfile? = nil,
                          rewardEligible: Bool,
                          warningLead: TimeInterval?) -> Bool {
        let createdAt = eventDate
        let commitment = Commitment(title: title,
                                    requirement: requirement,
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
