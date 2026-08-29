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
    private var ticker: AnyCancellable?

    var state: EarnedState { ledger.state }

    init(storage: LedgerStorage = .documents()) {
        self.storage = storage
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
    }

    // MARK: - Writing

    /// Appends an event, persisting on success. Returns false and populates
    /// `rejection` when EarnedKit refuses it — a monotonicity violation, an
    /// override taken too early, a spend with no balance.
    @discardableResult
    func append(_ event: Event, at date: Date = Date()) -> Bool {
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
        let createdAt = Date()
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
        let createdAt = Date()
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

    /// Records one unit of active friction toward a solo override.
    @discardableResult
    func recordFrictionProgress(requestID: UUID, units: Int = 1) -> Bool {
        append(.soloOverrideProgressRecorded(requestID: requestID, units: units))
    }
}
