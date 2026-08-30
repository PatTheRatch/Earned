import Foundation

/// Why access is currently restricted. The system must always be able to
/// explain exactly which Gates prevent access (NORTHSTAR §19, §39.10).
public struct LockReason: Equatable, Sendable {
    public var gate: GateID
    /// Default developer-provided copy; the app may render its own.
    public var headline: String
    public var progress: CommitmentProgress?
    /// What this Gate alone takes away.
    public var restrictions: RestrictionProfile
}

/// What is allowed right now.
///
/// Access is not one global binary. Each unsatisfied Gate contributes its own
/// restriction profile, and what is actually in force is their **union**
/// (NORTHSTAR §5, §6): an unmet Hydration Gate can strip the phone back to bare
/// communication while an unmet Exercise Gate leaves maps and music alone, and
/// when both are closed the stricter result follows automatically.
public struct AccessState: Equatable, Sendable {
    /// Every Gate currently preventing full access, in the order the user should
    /// read them: hydration first, then commitments by deadline.
    public var lockReasons: [LockReason]
    /// The union of the restriction profiles of every unsatisfied Gate.
    public var effectiveRestrictions: RestrictionProfile

    public var isFullAccess: Bool { lockReasons.isEmpty }
    public var isRestricted: Bool { !lockReasons.isEmpty }

    public static let fullAccess = AccessState(lockReasons: [], effectiveRestrictions: .none)

    /// Whether one specific thing is currently blocked.
    public func restricts(_ token: RestrictionToken) -> Bool {
        effectiveRestrictions.tokens.contains(token)
    }
}

/// A scheduled pre-enforcement warning (NORTHSTAR §20). Informational only —
/// warnings never create grace periods.
public struct GateWarning: Equatable, Sendable {
    public var date: Date
    public var gate: GateID
    public var headline: String
}

/// Reliability figures for accountability context (NORTHSTAR §24).
public struct ReliabilityStats: Equatable, Sendable {
    public var completed: Int
    public var missedDeadlines: Int
    public var overrideRequests: Int
}

extension EarnedState {
    // MARK: - Gate status

    public func hydrationStatus(now: Date) -> HydrationStatus {
        guard let hydration else { return .dormant }
        return hydration.status(lastAcknowledgment: lastWaterAcknowledgment, now: now)
    }

    /// Unresolved commitments whose deadline has passed. Any of these leaves its
    /// Gate unsatisfied; pending commitments do not (NORTHSTAR §19).
    public func overdueCommitments(now: Date) -> [CommitmentRecord] {
        commitments.values
            .filter { $0.isOverdue(now: now) }
            .sorted { $0.commitment.deadline < $1.commitment.deadline }
    }

    /// Unresolved commitments not yet due, soonest deadline first.
    public func pendingCommitments(now: Date) -> [CommitmentRecord] {
        commitments.values
            .filter { $0.resolution == nil && now <= $0.commitment.deadline }
            .sorted { $0.commitment.deadline < $1.commitment.deadline }
    }

    /// Unresolved commitments a workout finished **right now** would count
    /// toward: their eligible window has opened, whether or not their deadline
    /// has passed.
    ///
    /// This is the question `eligibleFrom` exists to answer, and it is not the
    /// same as "unresolved". A plan occurrence three weeks out is pending but
    /// not live — going for a run today does nothing for it — while an overdue
    /// commitment is still live, because a late workout is exactly what clears
    /// it (NORTHSTAR §16).
    public func liveCommitments(now: Date) -> [CommitmentRecord] {
        commitments.values
            .filter { $0.resolution == nil && $0.commitment.eligibleFrom <= now }
            .sorted { $0.commitment.deadline < $1.commitment.deadline }
    }

    /// Outstanding workout debt. Missed commitments persist but debt does not
    /// compound: the maximum is 1 (NORTHSTAR §16), however many deadlines have
    /// been missed.
    public func workoutDebt(now: Date) -> Int {
        min(1, overdueCommitments(now: now).count)
    }

    /// Accumulated progress toward a commitment (NORTHSTAR §14). Only workouts
    /// inside the commitment's eligible period and matching its activity filter
    /// count.
    public func progress(for commitmentID: UUID) -> CommitmentProgress? {
        guard let record = commitments[commitmentID] else { return nil }
        let eligible = workouts.filter { $0.isEligible(for: record.commitment) }
        return record.commitment.requirement.progress(over: eligible)
    }

    // MARK: - Access

    /// Full Access = every currently active Gate is satisfied (NORTHSTAR §5).
    /// Restrictions in force = union over the unsatisfied ones (§6).
    public func accessState(now: Date) -> AccessState {
        var reasons: [LockReason] = []

        if case .unsatisfied = hydrationStatus(now: now) {
            reasons.append(LockReason(gate: .hydration,
                                      headline: "Drink some water",
                                      progress: nil,
                                      restrictions: hydration?.restrictions ?? .none))
        }
        for record in overdueCommitments(now: now) {
            reasons.append(LockReason(gate: .commitment(record.commitment.id),
                                      headline: record.commitment.title,
                                      progress: progress(for: record.commitment.id),
                                      restrictions: record.commitment.restrictions))
        }

        return AccessState(lockReasons: reasons,
                           effectiveRestrictions: RestrictionProfile.union(reasons.map(\.restrictions)))
    }

    /// The restriction profile a Gate would impose, whether or not it is
    /// currently closed — for previewing "what this costs me" in the UI.
    public func restrictions(of gate: GateID) -> RestrictionProfile {
        switch gate {
        case .hydration:
            return hydration?.restrictions ?? .none
        case .commitment(let id):
            return commitments[id]?.commitment.restrictions ?? .none
        }
    }

    /// The next moment the access state could change without any new event:
    /// hydration timer/window transitions and commitment deadlines. The
    /// enforcement layer schedules re-evaluation at this time.
    public func nextTransition(after date: Date) -> Date? {
        var candidates: [Date] = []
        if let hydration,
           let next = hydration.nextTransition(lastAcknowledgment: lastWaterAcknowledgment, now: date) {
            candidates.append(next)
        }
        candidates += pendingCommitments(now: date).map { $0.commitment.deadline }
        return candidates.filter { $0 > date }.min()
    }

    /// Configured warnings due after `now` (NORTHSTAR §20).
    public func upcomingWarnings(now: Date) -> [GateWarning] {
        var warnings: [GateWarning] = []
        if let hydration, let lead = hydration.warningLead,
           case .satisfied(let expiresAt) = hydrationStatus(now: now) {
            let date = expiresAt.addingTimeInterval(-lead)
            if date > now {
                warnings.append(GateWarning(date: date, gate: .hydration,
                                            headline: "Hydration Gate closes soon"))
            }
        }
        for record in pendingCommitments(now: now) {
            guard let lead = record.commitment.warningLead else { continue }
            let date = record.commitment.deadline.addingTimeInterval(-lead)
            if date > now {
                warnings.append(GateWarning(date: date,
                                            gate: .commitment(record.commitment.id),
                                            headline: "\(record.commitment.title) due soon"))
            }
        }
        return warnings.sorted { $0.date < $1.date }
    }

    // MARK: - Plans

    /// Live plans, newest first.
    public func activePlans() -> [PlanRecord] {
        plans.values
            .filter { !$0.isCancelled }
            .sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    /// Every commitment generated by one plan, in deadline order.
    public func occurrences(ofPlan planID: UUID) -> [CommitmentRecord] {
        commitments.values
            .filter { $0.commitment.planID == planID }
            .sorted { $0.commitment.deadline < $1.commitment.deadline }
    }

    // MARK: - Overrides

    /// The unresolved override request for a commitment, if the commitment
    /// itself is still unresolved.
    public func activeOverrideRequest(forCommitment commitmentID: UUID) -> OverrideRequest? {
        guard commitments[commitmentID]?.resolution == nil else { return nil }
        return overrideRequests.values.first { $0.commitmentID == commitmentID && !$0.isResolved }
    }

    /// The friction a solo override starting at `startedAt` must overcome,
    /// escalated by solo overrides granted within the escalation's recent window
    /// (NORTHSTAR §25).
    func requiredSoloFriction(startedAt: Date, escalation: SoloEscalation) -> FrictionRequirement {
        let windowStart = startedAt.addingTimeInterval(-escalation.recentWindow)
        let recentSolos = overrideRequests.values.filter {
            $0.grantedKind == .solo
                && $0.grantedAt.map { granted in granted > windowStart && granted <= startedAt } == true
        }
        return escalation.requirement(recentSoloCount: recentSolos.count)
    }

    /// What a solo override on this request would cost — exposed so the app can
    /// show the price before the user starts.
    public func soloFriction(forRequest requestID: UUID, ifStartedAt date: Date) -> FrictionRequirement? {
        guard let request = overrideRequests[requestID],
              let record = commitments[request.commitmentID] else { return nil }
        if let frozen = request.soloRequirement { return frozen }
        return requiredSoloFriction(startedAt: date,
                                    escalation: record.commitment.overridePolicy.soloEscalation)
    }

    // MARK: - Rewards

    /// Progress toward the next Free Override, for display.
    public func completionStreak(now: Date) -> Int { rewardStreak(at: now) }

    // MARK: - Reliability (NORTHSTAR §24)

    public func reliability(now: Date, window: TimeInterval = 30 * 24 * 3600) -> ReliabilityStats {
        let windowStart = now.addingTimeInterval(-window)
        var completed = 0
        var missed = 0
        for record in commitments.values {
            if case .completed(let at) = record.resolution, at > windowStart, at <= record.commitment.deadline {
                completed += 1
            }
            let deadline = record.commitment.deadline
            if deadline > windowStart, deadline <= now {
                let completedOnTime: Bool
                if case .completed(let at) = record.resolution, at <= deadline { completedOnTime = true }
                else { completedOnTime = false }
                if !completedOnTime, record.resolution?.isCancellation != true { missed += 1 }
            }
        }
        let requests = overrideRequests.values.filter { $0.requestedAt > windowStart }.count
        return ReliabilityStats(completed: completed, missedDeadlines: missed, overrideRequests: requests)
    }
}

extension CommitmentResolution {
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
