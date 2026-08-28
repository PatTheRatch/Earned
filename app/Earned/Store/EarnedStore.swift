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
                          rewardEligible: Bool,
                          warningLead: TimeInterval?) -> Bool {
        let createdAt = Date()
        let commitment = Commitment(title: title,
                                    requirement: requirement,
                                    deadline: deadline,
                                    createdAt: createdAt,
                                    configuredCorrectionWindow: correctionWindow,
                                    overridePolicy: overridePolicy,
                                    rewardEligible: rewardEligible,
                                    warningLead: warningLead)
        return append(.commitmentCreated(commitment), at: createdAt)
    }

    @discardableResult
    func cancelCommitment(_ id: UUID) -> Bool { append(.commitmentCancelled(id: id)) }

    @discardableResult
    func spendFreeOverride(on commitmentID: UUID) -> Bool {
        append(.freeOverrideSpent(commitmentID: commitmentID))
    }

    @discardableResult
    func recordWorkout(_ workout: Workout) -> Bool { append(.workoutRecorded(workout)) }

    @discardableResult
    func changeRestrictedApps(added: Set<String>, removed: Set<String>) -> Bool {
        append(.restrictedAppsChanged(added: added, removed: removed))
    }

    @discardableResult
    func configureRewards(_ policy: RewardPolicy) -> Bool {
        append(.rewardPolicyConfigured(policy))
    }

    // MARK: - Reading

    var access: AccessState { state.accessState(now: now) }
    var isRestricted: Bool { access != .full }
    var hydration: HydrationStatus { state.hydrationStatus(now: now) }
    var overdue: [CommitmentRecord] { state.overdueCommitments(now: now) }
    var upcoming: [CommitmentRecord] { state.pendingCommitments(now: now) }
    var freeOverrides: Int { state.freeOverrideBalance(now: now) }
    var streak: Int { state.completionStreak(now: now) }

    /// Every commitment ever made, newest deadline first.
    var allCommitments: [CommitmentRecord] {
        state.commitments.values.sorted { $0.commitment.deadline > $1.commitment.deadline }
    }
}
