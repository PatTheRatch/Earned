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

/// One earned Free Override. Immutable once written.
public struct FreeOverrideGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let earnedAt: Date
    public let source: FreeOverrideSource
    public internal(set) var spentAt: Date?
    public internal(set) var spentOn: UUID?

    public var isSpent: Bool { spentAt != nil }
}

/// The projected state of the whole system: a pure function of the ledger.
public struct EarnedState: Codable, Equatable, Sendable {
    public internal(set) var hydration: HydrationConfig?
    public internal(set) var lastWaterAcknowledgment: Date?
    public internal(set) var rewardPolicy: RewardPolicy = RewardPolicy()
    public internal(set) var commitments: [UUID: CommitmentRecord] = [:]
    public internal(set) var plans: [UUID: PlanRecord] = [:]
    public internal(set) var workouts: [Workout] = []
    /// The profile applied to new commitments that don't carry their own. A
    /// convenience default only — the Gate that actually restricts is the
    /// commitment, and it owns its profile from creation.
    public internal(set) var defaultCommitmentRestrictions: RestrictionProfile = .none
    public internal(set) var overrideRequests: [UUID: OverrideRequest] = [:]
    /// Free Overrides as immutable grants. Balance is the count of unspent ones;
    /// it is never recomputed from the current reward policy.
    public internal(set) var freeOverrideGrants: [FreeOverrideGrant] = []
    /// Whether Earned currently holds OS authority to enforce. Tracked
    /// separately from gate state and never conflated with it (NORTHSTAR §33).
    public internal(set) var enforcementStatus: EnforcementStatus = .unknown
    /// Every occasion enforcement went away while a hardened obligation was
    /// outstanding. Preserved as history; resolves nothing.
    public internal(set) var enforcementBypasses: [EnforcementBypass] = []
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

    /// Events the engine itself produces as a consequence of the transition from
    /// `previous` to `self`.
    ///
    /// Only `Ledger.append` calls this, and it appends the results as real
    /// entries. Replay deliberately does *not* re-derive: the derived events are
    /// already in history, which is what makes an earned Free Override immutable
    /// rather than a function of today's reward policy.
    func derivedEvents(from previous: EarnedState, at date: Date) -> [Event] {
        guard completedOnTimeCount > previous.completedOnTimeCount else { return [] }
        guard shouldEarnFreeOverride(at: date) else { return [] }
        return [.freeOverrideEarned(id: UUID(), source: .streak)]
    }

    /// Completion is the only thing that can earn a reward, so a transition is
    /// interesting only when this count goes up.
    private var completedOnTimeCount: Int {
        commitments.values.reduce(into: 0) { total, record in
            if case .completed(let at) = record.resolution,
               record.commitment.rewardEligible,
               at <= record.commitment.deadline {
                total += 1
            }
        }
    }

    private mutating func mutate(_ event: Event, at date: Date) throws {
        switch event {
        case .hydrationConfigured(let config):
            try validateHydrationConfig(config, at: date)
            hydration = config

        case .rewardPolicyConfigured(let policy):
            try validateRewardPolicy(policy, at: date)
            rewardPolicy = policy

        case .defaultCommitmentRestrictionsChanged(let profile):
            // The default is not itself a Gate, so loosening it restricts
            // nothing that is currently in force; no guard is needed.
            defaultCommitmentRestrictions = profile

        case .restrictedAppsChanged(let added, let removed):
            // v1 history: the old global set becomes the default profile.
            defaultCommitmentRestrictions = defaultCommitmentRestrictions
                .adding(Set(added.map(RestrictionToken.init)))
                .removing(Set(removed.map(RestrictionToken.init)))

        case .waterAcknowledged:
            lastWaterAcknowledgment = date

        case .commitmentCreated(let commitment):
            try validateNewCommitment(commitment, at: date)
            commitments[commitment.id] = CommitmentRecord(commitment: commitment, resolution: nil)
            resolveIfSatisfied(commitmentID: commitment.id)

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
            } else {
                try validateRestrictionsLoosening(from: record.commitment.restrictions,
                                                  to: edited.restrictions, at: date)
            }
            commitments[id]?.commitment = edited
            resolveIfSatisfied(commitmentID: id)

        case .commitmentCancelled(let id):
            let record = try unresolvedRecord(id)
            guard !record.commitment.isHardened(at: date) else {
                throw EarnedError.cancellationAfterHardening(id)
            }
            commitments[id]?.resolution = .cancelled(at: date)

        case .planCreated(let plan):
            guard plans[plan.id] == nil else {
                throw EarnedError.invalidPlan("Duplicate plan id.")
            }
            guard plan.isValid else {
                throw EarnedError.invalidPlan("Weekdays, deadline time, date range and requirement must all be valid.")
            }
            guard plan.createdAt == date else {
                throw EarnedError.invalidPlan("createdAt must equal the event date.")
            }
            plans[plan.id] = PlanRecord(plan: plan, cancelledAt: nil)

        case .planCancelled(let id):
            guard var record = plans[id] else { throw EarnedError.planNotFound(id) }
            guard !record.isCancelled else { throw EarnedError.planAlreadyCancelled(id) }
            record.cancelledAt = date
            plans[id] = record
            // Cancelling a plan withdraws an occurrence when either:
            //
            //   - it is still inside its correction window (the ordinary rule), or
            //   - its eligible window has not opened yet.
            //
            // The second clause exists because every occurrence's correction
            // window runs from *plan creation*, so without it a four-week plan
            // would harden solid two hours after it was made and cancelling it
            // would withdraw nothing at all. An occurrence whose window has not
            // opened is not yet a live obligation — there has been no day on
            // which it could have been honoured — so withdrawing it takes
            // nothing away. Occurrences already in their window survive,
            // hardened or not: those are real contracts (NORTHSTAR §12).
            //
            // The backend reproduces this predicate in
            // `public.withdraw_plan_envelopes`, because plan cancellation is the
            // one easing operation it must accept and it verifies rather than
            // trusts it. Both clauses below are expressible in the fields a
            // Contract Envelope carries, which is why that is possible — change
            // this and the SQL has to change with it.
            for (commitmentID, commitmentRecord) in commitments
            where commitmentRecord.commitment.planID == id
                && commitmentRecord.resolution == nil
                && (!commitmentRecord.commitment.isHardened(at: date)
                    || commitmentRecord.commitment.eligibleFrom > date) {
                commitments[commitmentID]?.resolution = .cancelled(at: date)
            }

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
            // Resolve in deadline order so that when one workout can satisfy
            // several obligations, the oldest debt is cleared first.
            for id in commitments.keys.sorted(by: { deadline(of: $0) < deadline(of: $1) }) {
                resolveIfSatisfied(commitmentID: id)
            }

        case .enforcementUnavailableDetected:
            // Only a real transition counts. The app polls on every launch and
            // foreground, so without this guard a single revocation would mint
            // a fresh bypass every time the user opened Earned.
            guard enforcementStatus != .unavailable else { return }
            // Losing authority you never had is not a bypass: a first-run user
            // who has not granted Screen Time has taken nothing away.
            let established = enforcementStatus == .available
            enforcementStatus = .unavailable
            guard established else { return }
            let outstanding = commitments.values
                .filter { $0.resolution == nil && $0.commitment.isHardened(at: date) }
                .map(\.commitment.id)
                .sorted { $0.uuidString < $1.uuidString }
            // No hardened obligation outstanding means nothing was escaped.
            // Enforcement simply became unavailable, which is not a failure.
            guard !outstanding.isEmpty else { return }
            enforcementBypasses.append(EnforcementBypass(
                id: enforcementBypasses.count,
                detectedAt: date, outstandingCommitmentIDs: outstanding))

        case .enforcementRestored:
            guard enforcementStatus != .available else { return }
            enforcementStatus = .available
            for index in enforcementBypasses.indices where enforcementBypasses[index].isOngoing {
                enforcementBypasses[index].resolvedAt = date
            }

        case .freeOverrideEarned(let id, let source):
            guard !freeOverrideGrants.contains(where: { $0.id == id }) else { return }
            // Earning at the cap is forfeited, not banked (NORTHSTAR §22).
            guard freeOverrideBalance < rewardPolicy.maxStored || source == .migration else { return }
            freeOverrideGrants.append(FreeOverrideGrant(id: id, earnedAt: date, source: source,
                                                        spentAt: nil, spentOn: nil))

        case .freeOverrideSpent(let commitmentID):
            _ = try unresolvedRecord(commitmentID)
            guard let index = freeOverrideGrants.firstIndex(where: { !$0.isSpent }) else {
                throw EarnedError.insufficientFreeOverrides
            }
            freeOverrideGrants[index].spentAt = date
            freeOverrideGrants[index].spentOn = commitmentID
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
            // Freeze the requirement at start, so a policy edit mid-challenge
            // cannot make an in-flight escape cheaper.
            request.soloRequirement = requiredSoloFriction(startedAt: date,
                                                           escalation: policy.soloEscalation)
            request.soloEffortUnits = 0
            overrideRequests[requestID] = request

        case .soloOverrideProgressRecorded(let requestID, let units):
            var request = try activeRequest(requestID)
            guard request.soloStartedAt != nil, let requirement = request.soloRequirement else {
                throw EarnedError.soloOverrideNotStarted(requestID)
            }
            guard units > 0 else {
                throw EarnedError.invalidFrictionProgress("Effort must be positive.")
            }
            request.soloEffortUnits = min(requirement.effortUnits, request.soloEffortUnits + units)
            overrideRequests[requestID] = request

        case .soloOverrideCompleted(let requestID):
            var request = try activeRequest(requestID)
            guard let startedAt = request.soloStartedAt,
                  let requirement = request.soloRequirement else {
                throw EarnedError.soloOverrideNotStarted(requestID)
            }
            let elapsed = date.timeIntervalSince(startedAt)
            guard requirement.isSatisfied(unitsCompleted: request.soloEffortUnits, elapsed: elapsed) else {
                throw EarnedError.soloOverrideFrictionIncomplete(
                    unitsRemaining: max(0, requirement.effortUnits - request.soloEffortUnits),
                    completableAt: startedAt.addingTimeInterval(requirement.minimumElapsed))
            }
            request.grantedAt = date
            request.grantedKind = .solo
            overrideRequests[requestID] = request
            commitments[request.commitmentID]?.resolution = .overridden(.solo, at: date)
        }
    }

    private func deadline(of id: UUID) -> Date {
        commitments[id]?.commitment.deadline ?? .distantFuture
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

    /// Loosening any Gate's restriction profile requires Full Access and no
    /// hardened, unresolved commitment. Tightening is always allowed.
    private func validateRestrictionsLoosening(from current: RestrictionProfile,
                                               to proposed: RestrictionProfile,
                                               at date: Date) throws {
        guard !proposed.isAtLeastAsStrict(as: current) else { return }
        guard accessState(now: date).isFullAccess else {
            throw EarnedError.restrictionsLooseningNotAllowed("Loosening requires Full Access.")
        }
        guard !hasHardenedUnresolvedCommitment(at: date) else {
            throw EarnedError.restrictionsLooseningNotAllowed(
                "A hardened commitment is outstanding; its restrictions cannot shrink (NORTHSTAR §12).")
        }
    }

    /// Same shape of rule as restrictions: stricter anytime, easier only from a
    /// position of full access with nothing hardened outstanding. Without this a
    /// locked user could lower the streak threshold and mint an escape route.
    private func validateRewardPolicy(_ policy: RewardPolicy, at date: Date) throws {
        guard policy.isValid else {
            throw EarnedError.invalidRewardPolicy("streakThreshold must be >= 1 and maxStored >= 0.")
        }
        guard !policy.isAtLeastAsHard(as: rewardPolicy) else { return }
        guard accessState(now: date).isFullAccess else {
            throw EarnedError.rewardPolicyEasingNotAllowed("Easing requires Full Access.")
        }
        guard !hasHardenedUnresolvedCommitment(at: date) else {
            throw EarnedError.rewardPolicyEasingNotAllowed(
                "A hardened commitment is outstanding.")
        }
    }

    func hasHardenedUnresolvedCommitment(at date: Date) -> Bool {
        commitments.values.contains {
            $0.resolution == nil && $0.commitment.isHardened(at: date)
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
        guard commitment.eligibleFrom <= commitment.deadline else {
            throw EarnedError.invalidCommitment("Eligible period must open before the deadline.")
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
        guard commitment.requirement.isValid else {
            throw EarnedError.invalidCommitment(
                "Requirement needs a non-empty activity filter and a positive amount.")
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

    // MARK: - Reward earning

    /// Free Overrides currently banked. A plain count of unspent grants — never
    /// a replay of history against the current policy.
    public var freeOverrideBalance: Int {
        freeOverrideGrants.filter { !$0.isSpent }.count
    }

    /// On-time completions of reward-eligible commitments since the last Free
    /// Override was earned, with any missed deadline in that span resetting the
    /// count to zero.
    ///
    /// Evaluated at a given instant, from resolutions that are already
    /// determined, so it is deterministic on replay.
    func rewardStreak(at date: Date) -> Int {
        let since = freeOverrideGrants.map(\.earnedAt).max() ?? .distantPast

        enum Outcome { case success, miss }
        var timeline: [(Date, Outcome)] = []

        for record in commitments.values where record.commitment.rewardEligible {
            let deadline = record.commitment.deadline
            switch record.resolution {
            case .completed(let at):
                timeline.append(at <= deadline ? (at, .success) : (deadline, .miss))
            case .overridden(_, let at):
                // An overridden commitment was not completed; the streak breaks
                // when the obligation was cleared, or at the deadline if that
                // came first.
                timeline.append((min(at, deadline), .miss))
            case .cancelled:
                continue
            case nil:
                if date > deadline { timeline.append((deadline, .miss)) }
            }
        }

        // A detected bypass breaks the streak. It resolves nothing and clears
        // no debt — it only records that the consequence stopped being
        // enforceable while something hardened was owed, and a streak is a
        // claim about honouring commitments (NORTHSTAR §33).
        for bypass in enforcementBypasses {
            timeline.append((bypass.detectedAt, .miss))
        }

        var streak = 0
        for (at, outcome) in timeline.sorted(by: { $0.0 < $1.0 }) where at > since && at <= date {
            switch outcome {
            case .success: streak += 1
            case .miss: streak = 0
            }
        }
        return streak
    }

    private func shouldEarnFreeOverride(at date: Date) -> Bool {
        guard freeOverrideBalance < rewardPolicy.maxStored else { return false }
        let streak = rewardStreak(at: date)
        return streak > 0 && streak >= rewardPolicy.streakThreshold
    }
}
