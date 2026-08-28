import Foundation

/// A commitment together with its terminal resolution, if any.
public struct CommitmentRecord: Codable, Equatable, Sendable {
    public internal(set) var commitment: Commitment
    public internal(set) var resolution: CommitmentResolution?

    public var isResolved: Bool { resolution != nil }

    /// Overdue is a live condition, not a resolution: unresolved and past deadline.
    public func isOverdue(now: Date) -> Bool {
        resolution == nil && now > commitment.deadline
    }
}

/// The projected state of the whole system: a pure function of the ledger.
public struct EarnedState: Codable, Equatable, Sendable {
    public internal(set) var hydration: HydrationConfig?
    public internal(set) var lastWaterAcknowledgment: Date?
    public internal(set) var rewardPolicy: RewardPolicy = RewardPolicy()
    public internal(set) var commitments: [UUID: CommitmentRecord] = [:]
    public internal(set) var workouts: [Workout] = []
    /// Opaque identifiers for the restricted app selection (FamilyControls
    /// tokens on iOS). EarnedKit governs *when* changes are allowed, never what
    /// the apps are.
    public internal(set) var restrictedApps: Set<String> = []
    public internal(set) var overrideRequests: [UUID: OverrideRequest] = [:]
    public internal(set) var freeOverrideSpends: [Date] = []
    public internal(set) var lastEventDate: Date?

    public init() {}

    // MARK: - Validation + application

    /// Validates an event against the current state, throwing if it would
    /// violate an invariant, and returns the state with the event applied.
    func applying(_ event: Event, at date: Date) throws -> EarnedState {
        if let last = lastEventDate, date < last {
            throw EarnedError.eventOutOfOrder(eventDate: date, lastEventDate: last)
        }
        var next = self
        try next.mutate(event, at: date)
        next.lastEventDate = date
        return next
    }

    private mutating func mutate(_ event: Event, at date: Date) throws {
        switch event {
        case .hydrationConfigured(let config):
            try validateHydrationConfig(config, at: date)
            hydration = config

        case .rewardPolicyConfigured(let policy):
            guard policy.streakThreshold >= 1, policy.maxStored >= 0 else {
                throw EarnedError.invalidCommitment("Reward policy requires streakThreshold >= 1 and maxStored >= 0.")
            }
            rewardPolicy = policy

        case .restrictedAppsChanged(let added, let removed):
            try validateRestrictedRemoval(removed, at: date)
            restrictedApps.formUnion(added)
            restrictedApps.subtract(removed)

        case .waterAcknowledged:
            lastWaterAcknowledgment = date

        case .commitmentCreated(let commitment):
            try validateNewCommitment(commitment, at: date)
            commitments[commitment.id] = CommitmentRecord(commitment: commitment, resolution: nil)

        case .commitmentEdited(let id, let edit):
            let record = try unresolvedRecord(id)
            let edited = edit.applied(to: record.commitment)
            try validateCommitmentShape(edited)
            guard edited.deadline > date else {
                throw EarnedError.invalidCommitment("Edited deadline must be in the future.")
            }
            if record.commitment.isHardened(at: date) {
                guard edited.isAtLeastAsHard(as: record.commitment) else {
                    throw EarnedError.monotonicityViolation(
                        "Commitment '\(record.commitment.title)' has hardened; edits may only make it harder.")
                }
            }
            commitments[id]?.commitment = edited
            resolveIfSatisfied(commitmentID: id)

        case .commitmentCancelled(let id):
            let record = try unresolvedRecord(id)
            guard !record.commitment.isHardened(at: date) else {
                throw EarnedError.cancellationAfterHardening(id)
            }
            commitments[id]?.resolution = .cancelled(at: date)

        case .workoutRecorded(let workout):
            guard workout.end > workout.start else {
                throw EarnedError.invalidWorkout("Workout must end after it starts.")
            }
            guard workout.end <= date else {
                throw EarnedError.invalidWorkout("Workout cannot end in the future.")
            }
            if let distance = workout.distanceMeters, distance < 0 {
                throw EarnedError.invalidWorkout("Distance cannot be negative.")
            }
            // HealthKit can deliver the same workout more than once; re-recording
            // an already-known workout is a harmless no-op.
            guard !workouts.contains(where: { $0.id == workout.id }) else { return }
            workouts.append(workout)
            for id in commitments.keys {
                resolveIfSatisfied(commitmentID: id)
            }

        case .freeOverrideSpent(let commitmentID):
            _ = try unresolvedRecord(commitmentID)
            guard freeOverrideBalance(now: date) >= 1 else {
                throw EarnedError.insufficientFreeOverrides
            }
            freeOverrideSpends.append(date)
            commitments[commitmentID]?.resolution = .overridden(.free, at: date)

        case .overrideRequested(let id, let commitmentID):
            _ = try unresolvedRecord(commitmentID)
            guard activeOverrideRequest(forCommitment: commitmentID) == nil else {
                throw EarnedError.duplicateOverrideRequest(commitmentID: commitmentID)
            }
            overrideRequests[id] = OverrideRequest(id: id, commitmentID: commitmentID, requestedAt: date)

        case .overrideApprovalRecorded(let requestID, let partnerID):
            var request = try activeRequest(requestID)
            try validateFreshVote(request, partnerID: partnerID)
            request.approvals[partnerID] = date
            let policy = try unresolvedRecord(request.commitmentID).commitment.overridePolicy
            if request.approvals.count >= policy.approvalsRequired {
                request.grantedAt = date
                request.grantedKind = .accountability
                commitments[request.commitmentID]?.resolution = .overridden(.accountability, at: date)
            }
            overrideRequests[requestID] = request

        case .overrideDenialRecorded(let requestID, let partnerID):
            var request = try activeRequest(requestID)
            try validateFreshVote(request, partnerID: partnerID)
            request.denials[partnerID] = date
            overrideRequests[requestID] = request

        case .soloOverrideStarted(let requestID):
            var request = try activeRequest(requestID)
            guard request.soloStartedAt == nil else {
                throw EarnedError.soloOverrideAlreadyStarted(requestID)
            }
            let policy = try unresolvedRecord(request.commitmentID).commitment.overridePolicy
            let availableAt = request.soloAvailableAt(policy: policy)
            guard date >= availableAt else {
                throw EarnedError.soloOverrideNotYetAvailable(availableAt: availableAt)
            }
            request.soloStartedAt = date
            overrideRequests[requestID] = request

        case .soloOverrideCompleted(let requestID):
            var request = try activeRequest(requestID)
            guard let startedAt = request.soloStartedAt else {
                throw EarnedError.soloOverrideNotStarted(requestID)
            }
            let policy = try unresolvedRecord(request.commitmentID).commitment.overridePolicy
            let friction = requiredSoloFriction(startedAt: startedAt, escalation: policy.soloEscalation)
            let completableAt = startedAt.addingTimeInterval(friction)
            guard date >= completableAt else {
                throw EarnedError.soloOverrideFrictionIncomplete(completableAt: completableAt)
            }
            request.grantedAt = date
            request.grantedKind = .solo
            overrideRequests[requestID] = request
            commitments[request.commitmentID]?.resolution = .overridden(.solo, at: date)
        }
    }

    // MARK: - Validation helpers

    private func validateHydrationConfig(_ config: HydrationConfig, at date: Date) throws {
        guard config.interval > 0 else {
            throw EarnedError.invalidHydrationConfig("Interval must be positive.")
        }
        guard config.activeHours.isValid else {
            throw EarnedError.invalidHydrationConfig("Active hours must be a valid same-day window with a known time zone.")
        }
        // Easier changes are only allowed while the gate is satisfied — a locked
        // user must not unlock by loosening the hydration contract.
        if let current = hydration, !config.isAtLeastAsHard(as: current) {
            let status = current.status(lastAcknowledgment: lastWaterAcknowledgment, now: date)
            guard status.isSatisfied else { throw EarnedError.hydrationEasierWhileUnsatisfied }
        }
    }

    private func validateRestrictedRemoval(_ removed: Set<String>, at date: Date) throws {
        guard !removed.isEmpty else { return }
        guard case .full = accessState(now: date) else {
            throw EarnedError.restrictedRemovalNotAllowed("Removal requires Full Access.")
        }
        let hardenedUnresolved = commitments.values.contains {
            $0.resolution == nil && $0.commitment.isHardened(at: date)
        }
        guard !hardenedUnresolved else {
            throw EarnedError.restrictedRemovalNotAllowed(
                "A hardened commitment is outstanding; its restrictions cannot shrink (NORTHSTAR §12).")
        }
    }

    private func validateNewCommitment(_ commitment: Commitment, at date: Date) throws {
        guard commitments[commitment.id] == nil else {
            throw EarnedError.invalidCommitment("Duplicate commitment id.")
        }
        guard commitment.createdAt == date else {
            throw EarnedError.invalidCommitment("createdAt must equal the event date.")
        }
        guard commitment.deadline > date else {
            throw EarnedError.invalidCommitment("Deadline must be in the future.")
        }
        guard commitment.configuredCorrectionWindow >= 0 else {
            throw EarnedError.invalidCommitment("Correction window cannot be negative.")
        }
        guard commitment.overridePolicy.approvalsRequired >= 1 else {
            throw EarnedError.invalidCommitment("At least one accountability approval is required (NORTHSTAR §26).")
        }
        guard commitment.overridePolicy.accountabilityWindow >= 0 else {
            throw EarnedError.invalidCommitment("Accountability window cannot be negative.")
        }
        try validateCommitmentShape(commitment)
    }

    private func validateCommitmentShape(_ commitment: Commitment) throws {
        switch commitment.requirement {
        case .anyWorkout:
            break
        case .totalDuration(let seconds):
            guard seconds > 0 else { throw EarnedError.invalidCommitment("Required duration must be positive.") }
        case .totalDistance(let meters):
            guard meters > 0 else { throw EarnedError.invalidCommitment("Required distance must be positive.") }
        }
    }

    private func validateFreshVote(_ request: OverrideRequest, partnerID: String) throws {
        guard request.approvals[partnerID] == nil, request.denials[partnerID] == nil else {
            throw EarnedError.partnerAlreadyVoted(partnerID: partnerID)
        }
    }

    private func unresolvedRecord(_ id: UUID) throws -> CommitmentRecord {
        guard let record = commitments[id] else { throw EarnedError.commitmentNotFound(id) }
        guard record.resolution == nil else { throw EarnedError.commitmentAlreadyResolved(id) }
        return record
    }

    private func activeRequest(_ id: UUID) throws -> OverrideRequest {
        guard let request = overrideRequests[id] else { throw EarnedError.overrideRequestNotFound(id) }
        guard !request.isResolved else { throw EarnedError.overrideRequestAlreadyResolved(id) }
        // A request whose commitment resolved by other means (workout completed,
        // free override spent) is moot.
        guard commitments[request.commitmentID]?.resolution == nil else {
            throw EarnedError.overrideRequestAlreadyResolved(id)
        }
        return request
    }

    // MARK: - Completion

    /// Marks a commitment completed if its accumulated eligible workouts satisfy
    /// the requirement. Completion time is the end of the workout that crossed
    /// the threshold (deterministic even when workouts sync out of order).
    private mutating func resolveIfSatisfied(commitmentID: UUID) {
        guard let record = commitments[commitmentID], record.resolution == nil else { return }
        let eligible = workouts
            .filter { $0.isEligible(for: record.commitment) }
            .sorted { $0.end < $1.end }
        var counted: [Workout] = []
        for workout in eligible {
            counted.append(workout)
            if record.commitment.requirement.progress(over: counted).isSatisfied {
                commitments[commitmentID]?.resolution = .completed(at: workout.end)
                return
            }
        }
    }
}
