import Foundation

/// Why access is currently restricted. The system must always be able to
/// explain exactly which Gates prevent access (NORTHSTAR §19, §39.10).
public struct LockReason: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case hydration
        case commitment(UUID)
    }
    public var source: Source
    /// Default developer-provided copy; the app may render its own.
    public var headline: String
    public var progress: CommitmentProgress?
}

public enum AccessState: Equatable, Sendable {
    case full
    case restricted([LockReason])
}

/// A scheduled pre-enforcement warning (NORTHSTAR §20). Informational only —
/// warnings never create grace periods.
public struct GateWarning: Equatable, Sendable {
    public var date: Date
    public var source: LockReason.Source
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

    /// Unresolved commitments whose deadline has passed. Any of these makes the
    /// Exercise Gate unsatisfied; pending commitments do not (NORTHSTAR §19).
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

    /// Outstanding workout debt. Missed commitments persist but debt does not
    /// compound: the maximum is 1 (NORTHSTAR §16), however many deadlines have
    /// been missed.
    public func workoutDebt(now: Date) -> Int {
        min(1, overdueCommitments(now: now).count)
    }

    /// Accumulated progress toward a commitment (NORTHSTAR §14).
    public func progress(for commitmentID: UUID) -> CommitmentProgress? {
        guard let record = commitments[commitmentID] else { return nil }
        let eligible = workouts.filter { $0.isEligible(for: record.commitment) }
        return record.commitment.requirement.progress(over: eligible)
    }

    // MARK: - Access

    /// Full Access = every currently active Gate is satisfied (NORTHSTAR §5).
    public func accessState(now: Date) -> AccessState {
        var reasons: [LockReason] = []
        if case .unsatisfied = hydrationStatus(now: now) {
            reasons.append(LockReason(source: .hydration, headline: "Drink some water", progress: nil))
        }
        for record in overdueCommitments(now: now) {
            reasons.append(LockReason(
                source: .commitment(record.commitment.id),
                headline: record.commitment.title,
                progress: progress(for: record.commitment.id)))
        }
        return reasons.isEmpty ? .full : .restricted(reasons)
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
                warnings.append(GateWarning(date: date, source: .hydration, headline: "Hydration Gate closes soon"))
            }
        }
        for record in pendingCommitments(now: now) {
            guard let lead = record.commitment.warningLead else { continue }
            let date = record.commitment.deadline.addingTimeInterval(-lead)
            if date > now {
                warnings.append(GateWarning(
                    date: date,
                    source: .commitment(record.commitment.id),
                    headline: "\(record.commitment.title) due soon"))
            }
        }
        return warnings.sorted { $0.date < $1.date }
    }

    // MARK: - Overrides

    /// The unresolved override request for a commitment, if the commitment
    /// itself is still unresolved.
    public func activeOverrideRequest(forCommitment commitmentID: UUID) -> OverrideRequest? {
        guard commitments[commitmentID]?.resolution == nil else { return nil }
        return overrideRequests.values.first { $0.commitmentID == commitmentID && !$0.isResolved }
    }

    /// Solo friction owed for a solo override starting at `startedAt`, escalated
    /// by solo overrides granted within the escalation's recent window
    /// (NORTHSTAR §25).
    func requiredSoloFriction(startedAt: Date, escalation: SoloEscalation) -> TimeInterval {
        let windowStart = startedAt.addingTimeInterval(-escalation.recentWindow)
        let recentSolos = overrideRequests.values.filter {
            $0.grantedKind == .solo
                && $0.grantedAt.map { granted in granted > windowStart && granted <= startedAt } == true
        }
        return escalation.friction(recentSoloCount: recentSolos.count)
    }

    /// Friction a solo override on this request would currently require —
    /// exposed so the app can show it before the user starts.
    public func soloFriction(forRequest requestID: UUID, ifStartedAt date: Date) -> TimeInterval? {
        guard let request = overrideRequests[requestID],
              let record = commitments[request.commitmentID] else { return nil }
        return requiredSoloFriction(startedAt: request.soloStartedAt ?? date,
                                    escalation: record.commitment.overridePolicy.soloEscalation)
    }

    // MARK: - Free Overrides (NORTHSTAR §22)

    /// Free Overrides currently stored. Earned by consecutive on-time
    /// completions of reward-eligible commitments; capped, with earning at the
    /// cap forfeited; reduced by spends. Computed by replaying commitment
    /// outcomes and spends in time order.
    public func freeOverrideBalance(now: Date) -> Int {
        enum Outcome { case success, miss, spend }
        var timeline: [(Date, Outcome)] = freeOverrideSpends.map { ($0, .spend) }

        for record in commitments.values where record.commitment.rewardEligible {
            let deadline = record.commitment.deadline
            switch record.resolution {
            case .completed(let at):
                timeline.append(at <= deadline ? (at, .success) : (deadline, .miss))
            case .overridden(_, let at):
                // An overridden commitment was not completed; the streak breaks
                // when the obligation was cleared (or at the deadline if that
                // came first).
                timeline.append((min(at, deadline), .miss))
            case .cancelled:
                continue
            case nil:
                if now > deadline { timeline.append((deadline, .miss)) }
            }
        }

        timeline.sort { $0.0 < $1.0 }
        var streak = 0
        var balance = 0
        for (_, outcome) in timeline {
            switch outcome {
            case .success:
                streak += 1
                if streak >= rewardPolicy.streakThreshold {
                    if balance < rewardPolicy.maxStored { balance += 1 }
                    streak = 0
                }
            case .miss:
                streak = 0
            case .spend:
                balance -= 1
            }
        }
        return max(0, balance)
    }

    /// Current streak of consecutive on-time completions (for UI).
    public func completionStreak(now: Date) -> Int {
        enum Outcome { case success, miss }
        var timeline: [(Date, Outcome)] = []
        for record in commitments.values where record.commitment.rewardEligible {
            let deadline = record.commitment.deadline
            switch record.resolution {
            case .completed(let at):
                timeline.append(at <= deadline ? (at, .success) : (deadline, .miss))
            case .overridden(_, let at):
                timeline.append((min(at, deadline), .miss))
            case .cancelled:
                continue
            case nil:
                if now > deadline { timeline.append((deadline, .miss)) }
            }
        }
        timeline.sort { $0.0 < $1.0 }
        var streak = 0
        for (_, outcome) in timeline {
            switch outcome {
            case .success:
                streak += 1
                if streak >= rewardPolicy.streakThreshold { streak = 0 }
            case .miss:
                streak = 0
            }
        }
        return streak
    }

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
