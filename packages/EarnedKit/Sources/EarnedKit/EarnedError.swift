import Foundation

/// Every way an event can be rejected by the ledger. The associated messages are
/// developer-facing; user-facing copy belongs to the app layer.
public enum EarnedError: Error, Equatable, CustomStringConvertible {
    /// Events must be appended in non-decreasing date order.
    case eventOutOfOrder(eventDate: Date, lastEventDate: Date)

    // Hydration
    case invalidHydrationConfig(String)
    /// Easier hydration changes are only allowed while the Hydration Gate is satisfied.
    case hydrationEasierWhileUnsatisfied

    // Commitments
    case commitmentNotFound(UUID)
    case commitmentAlreadyResolved(UUID)
    case invalidCommitment(String)
    /// The Monotonic Commitment Principle: hardened commitments may only become harder.
    case monotonicityViolation(String)
    /// Cancellation is only allowed during the correction window.
    case cancellationAfterHardening(UUID)

    // Workouts
    case invalidWorkout(String)

    // Restricted set
    /// Removals require Full Access and no hardened, unresolved commitment.
    case restrictedRemovalNotAllowed(String)

    // Overrides
    case insufficientFreeOverrides
    case overrideRequestNotFound(UUID)
    case overrideRequestAlreadyResolved(UUID)
    case duplicateOverrideRequest(commitmentID: UUID)
    case partnerAlreadyVoted(partnerID: String)
    case soloOverrideNotYetAvailable(availableAt: Date)
    case soloOverrideAlreadyStarted(UUID)
    case soloOverrideNotStarted(UUID)
    case soloOverrideFrictionIncomplete(completableAt: Date)

    public var description: String {
        switch self {
        case .eventOutOfOrder(let event, let last):
            return "Event dated \(event) precedes last ledger event dated \(last)."
        case .invalidHydrationConfig(let reason):
            return "Invalid hydration configuration: \(reason)"
        case .hydrationEasierWhileUnsatisfied:
            return "Hydration configuration cannot be made easier while the Hydration Gate is unsatisfied."
        case .commitmentNotFound(let id):
            return "No commitment with id \(id)."
        case .commitmentAlreadyResolved(let id):
            return "Commitment \(id) is already resolved."
        case .invalidCommitment(let reason):
            return "Invalid commitment: \(reason)"
        case .monotonicityViolation(let reason):
            return "Monotonicity violation: \(reason)"
        case .cancellationAfterHardening(let id):
            return "Commitment \(id) has hardened and can no longer be cancelled."
        case .invalidWorkout(let reason):
            return "Invalid workout: \(reason)"
        case .restrictedRemovalNotAllowed(let reason):
            return "Restricted apps cannot be removed: \(reason)"
        case .insufficientFreeOverrides:
            return "No Free Override available."
        case .overrideRequestNotFound(let id):
            return "No override request with id \(id)."
        case .overrideRequestAlreadyResolved(let id):
            return "Override request \(id) is already resolved."
        case .duplicateOverrideRequest(let commitmentID):
            return "An unresolved override request already exists for commitment \(commitmentID)."
        case .partnerAlreadyVoted(let partnerID):
            return "Partner \(partnerID) has already voted on this request."
        case .soloOverrideNotYetAvailable(let availableAt):
            return "Solo override unavailable until the accountability window elapses at \(availableAt)."
        case .soloOverrideAlreadyStarted(let id):
            return "Solo override already started for request \(id)."
        case .soloOverrideNotStarted(let id):
            return "Solo override has not been started for request \(id)."
        case .soloOverrideFrictionIncomplete(let completableAt):
            return "Solo override friction not yet complete; completable at \(completableAt)."
        }
    }
}
