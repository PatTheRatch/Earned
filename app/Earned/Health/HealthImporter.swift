import Foundation
import HealthKit
import EarnedKit

/// Reads finished workouts out of Apple Health and offers them to the ledger
/// (NORTHSTAR §15, walkthrough step 4 — the last stub in the daily loop).
///
/// One integration covers every verification source the product names. Apple
/// Watch workouts, Fitness app sessions, and Strava runs all land in HealthKit
/// (Strava syncs there when the user allows it), each stamped with the writing
/// app's identity — assigned by iOS, not claimed by the app — so "the fitness
/// app says a run was logged" and "Strava knows" are the same read.
///
/// What this deliberately is not: surveillance. NORTHSTAR §36 is blunt that
/// Earned must not become a health-data platform because access exists. So the
/// importer asks Health for exactly one type — workouts — reads only while
/// something unresolved could be moved by them, keeps only what the ledger has
/// always kept about a workout, and never writes anything back.
@MainActor
final class HealthImporter: ObservableObject {

    enum Access: Equatable {
        /// This device has no Health store (an iPad, in practice).
        case unavailable
        case notDetermined
        /// The user was asked. Health hides *read* denials — an app cannot
        /// tell "denied" from "no data", by design — so this is the terminal
        /// state and the UI must not pretend to know more than that.
        case requested
    }

    @Published private(set) var access: Access
    /// The last import's failure, if any, in Health's words. Cleared by the
    /// next pass that works.
    @Published private(set) var failure: String?

    private let store: HKHealthStore?

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            let store = HKHealthStore()
            self.store = store
            self.access = .notDetermined
            // authorizationStatus is a synchronous XPC round-trip to healthd,
            // and this init runs during app launch on the main thread. On a
            // freshly booted simulator healthd can take minutes to answer,
            // which held the first frame hostage — so the status resolves off
            // the launch path and the UI corrects itself when it lands.
            Task.detached { [weak self] in
                let status = store.authorizationStatus(for: .workoutType())
                await MainActor.run {
                    self?.access = status == .notDetermined ? .notDetermined : .requested
                }
            }
        } else {
            self.store = nil
            self.access = .unavailable
        }
    }

    /// Ask for read access to workouts — one type, nothing else.
    func requestAccess() async {
        guard let store, access == .notDetermined else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [.workoutType()])
            access = .requested
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Pull in any Health workout the ledger has not seen that could move an
    /// unresolved commitment.
    ///
    /// Idempotent by construction rather than by bookkeeping: each imported
    /// workout keeps the HK workout's own UUID, the importer skips ids the
    /// ledger already holds, and the reducer deduplicates as the backstop —
    /// a duplicate is accepted and counted once, a semantic the engine has
    /// pinned since before this importer existed, because a ledger that
    /// already holds the duplicate event must keep replaying forever. No
    /// anchor to persist, nothing to get out of sync.
    func importWorkouts(into earned: EarnedStore) async {
        guard let store, access == .requested else { return }

        // Only what could matter: the earliest moment any unresolved
        // commitment would count a workout from. No open obligations means
        // nothing to read, which is the §36 posture — access exists for the
        // deal, not for the data.
        let unresolved = earned.state.commitments.values.filter { $0.resolution == nil }
        guard let horizon = unresolved.map(\.commitment.eligibleFrom).min() else { return }

        let workouts: [HKWorkout]
        do {
            workouts = try await finishedWorkouts(in: store, since: horizon)
        } catch {
            failure = error.localizedDescription
            return
        }
        failure = nil

        let known = Set(earned.state.workouts.map(\.id))
        for sample in workouts where !known.contains(sample.uuid) {
            earned.recordWorkout(Workout(id: sample.uuid,
                                         activity: Self.activity(of: sample),
                                         start: sample.startDate,
                                         end: sample.endDate,
                                         distanceMeters: sample.totalDistance?
                                             .doubleValue(for: .meter()),
                                         activeEnergyKilocalories: Self.activeEnergy(of: sample),
                                         evidence: Self.evidence(of: sample)))
        }
    }

    private func finishedWorkouts(in store: HKHealthStore,
                                  since horizon: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: horizon, end: nil,
                                                    options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(), predicate: predicate, limit: 200,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                   ascending: true)]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKWorkout] ?? [])
                }
            }
            store.execute(query)
        }
    }

    // MARK: - What the sample says about itself

    /// Who vouches for this workout (WorkoutEvidence's contract).
    ///
    /// Health lets a person type a workout straight into the Health app; iOS
    /// marks those user-entered. That is the user's word wearing a lab coat,
    /// and it counts exactly as much as the same word typed into Earned —
    /// which is to say fully, on an honor commitment, and not at all on a
    /// verified one. Everything else is vouched for by the app that wrote it.
    private static func evidence(of sample: HKWorkout) -> WorkoutEvidence {
        if sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true {
            return .selfReported
        }
        let source = sample.sourceRevision.source.bundleIdentifier
        // Belt and braces: nothing Earned itself ever wrote may count as
        // another app vouching. Earned writes nothing to Health today; this
        // line is what keeps that sentence from becoming load-bearing.
        if source == Bundle.main.bundleIdentifier {
            return .selfReported
        }
        return .appVerified(source: source)
    }

    /// Active energy only — the calories burned *above* resting.
    ///
    /// Not `totalEnergyBurned`, which folds in the basal rate a body spends
    /// lying still: a workout can post a total above zero having demanded
    /// nothing, which is exactly the reading a commitment measured in effort
    /// must not accept. (`totalEnergyBurned` is also deprecated from iOS 18;
    /// `statistics(for:)` has been the answer since 16.)
    private static func activeEnergy(of sample: HKWorkout) -> Double? {
        sample.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private static func activity(of sample: HKWorkout) -> ActivityType {
        switch sample.workoutActivityType {
        case .running: return .running
        case .walking, .hiking: return .walking
        case .cycling, .handCycling: return .cycling
        case .traditionalStrengthTraining, .functionalStrengthTraining,
             .coreTraining, .crossTraining, .highIntensityIntervalTraining:
            return .strength
        case .swimming: return .swimming
        default: return .other
        }
    }
}
