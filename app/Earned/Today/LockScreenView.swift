import SwiftUI
import EarnedKit

/// The in-app lock surface: a red printed notice stating the deal. Factual, not
/// taunting — "NICE TRY." is reserved for the real shield in step 3, the moment
/// the user actually tries to open a restricted app (docs/design-language.md).
struct LockScreenView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.access.isFullAccess {
                earned
            } else {
                // A stack, so the notice can lead somewhere. This screen used
                // to be a dead end with a CLOSE button: it named every Gate
                // holding the phone shut and offered no route to the ways out
                // of any of them. Someone who opens this at 11pm because they
                // cannot get into an app is exactly the person who must not
                // have to remember that overrides live two taps away on
                // another tab (NORTHSTAR §19, §22).
                NavigationStack { locked(store.access.lockReasons) }
            }
        }
    }

    // MARK: - Full access

    private var earned: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Earned", color: Theme.ink)
                .padding(.top, 40)
            StateWord(word: "EARNED", size: 92)
                .padding(.top, 4)
            Text("Every gate is satisfied.")
                .font(Theme.blocker())
                .foregroundStyle(Theme.ink)
                .padding(.top, 10)
            Text("Your rules. Your deal.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
            Spacer()
            Button("CLOSE") { dismiss() }
                .buttonStyle(PosterButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    // MARK: - Restricted

    private func locked(_ reasons: [LockReason]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Earned", color: Theme.paper)
                .padding(.top, 40)

            Text("STILL\nLOCKED.")
                .font(Theme.display(88))
                .foregroundStyle(Theme.paper)
                .lineSpacing(-4)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    reasonRow(reason)
                }
                Rectangle().fill(Theme.paper).frame(height: 3)
            }
            .padding(.top, 28)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("THE DEAL STILL STANDS.")
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.paper)
                Text(hasCommitmentReason(reasons)
                     ? "You set this one. Tap a line above for its ways out."
                     : "You set this one.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper.opacity(0.8))
            }
            .padding(.bottom, 20)

            Button("CLOSE") { dismiss() }
                .buttonStyle(PosterButtonStyle(background: Theme.paper, foreground: Theme.signal))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.signal)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// One closed Gate. A commitment leads to its own deal — and its ways out;
    /// hydration leads nowhere, because a glass of water is the only way out
    /// of hydration and there is nothing to negotiate.
    @ViewBuilder
    private func reasonRow(_ reason: LockReason) -> some View {
        switch reason.gate {
        case .commitment(let id):
            NavigationLink {
                CommitmentDetailView(commitmentID: id)
            } label: {
                rowBody(reason, chevron: true)
            }
            .buttonStyle(.plain)
        case .hydration:
            rowBody(reason, chevron: false)
        }
    }

    private func rowBody(_ reason: LockReason, chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.paper).frame(height: 3)
            HStack(alignment: .firstTextBaseline) {
                Text(headline(for: reason))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text(detail(for: reason))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.paper)
            .padding(.vertical, 13)
        }
        .contentShape(Rectangle())
    }

    private func hasCommitmentReason(_ reasons: [LockReason]) -> Bool {
        reasons.contains { reason in
            if case .commitment = reason.gate { return true }
            return false
        }
    }

    private func headline(for reason: LockReason) -> String {
        switch reason.gate {
        case .hydration: return "Drink some water"
        case .commitment: return reason.headline
        }
    }

    private func detail(for reason: LockReason) -> String {
        guard let progress = reason.progress, progress.required > 0 else { return "NOW" }
        switch progress.unit {
        case .workouts:
            return progress.achieved >= progress.required ? "DONE" : "OWED"
        case .seconds:
            return "\(Int(progress.achieved / 60))/\(Int(progress.required / 60)) MIN"
        case .meters:
            return String(format: "%.1f/%.1f KM", progress.achieved / 1000, progress.required / 1000)
        case .kilocalories:
            return "\(Int(progress.achieved))/\(Int(progress.required)) CAL"
        }
    }
}

/// The escape hatches, in the order the contract allows them (NORTHSTAR §§22–25).
struct OverrideMenu: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    let record: CommitmentRecord

    private var request: OverrideRequest? {
        store.state.activeOverrideRequest(forCommitment: record.commitment.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.freeOverrides > 0 {
                Button("USE A FREE OVERRIDE (\(store.freeOverrides) LEFT)") {
                    store.spendFreeOverride(on: record.commitment.id)
                }
                .font(.system(size: 12, weight: .bold))
                .tint(Theme.ink)
            }

            if let request {
                requestStatus(request)
            } else {
                Button("Request an override") {
                    // Local first, and unconditionally. The Solo clock starts
                    // here on this device's own time, so a user is never
                    // trapped by our downtime (§11, S8); asking the partners
                    // is what happens *next*, and may not happen at all.
                    let requestID = UUID()
                    guard store.append(.overrideRequested(id: requestID,
                                                          commitmentID: record.commitment.id))
                    else { return }
                    Task {
                        await account.requestOverride(
                            requestID: requestID,
                            commitmentID: record.commitment.id,
                            progress: store.state.progress(for: record.commitment.id),
                            reliability: store.state.reliability(now: store.now))
                    }
                }
                .font(.system(size: 12))
                .tint(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private func requestStatus(_ request: OverrideRequest) -> some View {
        let policy = record.commitment.overridePolicy
        let soloAt = request.soloAvailableAt(policy: policy)

        VStack(alignment: .leading, spacing: 6) {
            Text("Override requested · \(request.approvals.count)/\(policy.approvalsRequired) approvals")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)

            if store.now < soloAt {
                Text("Solo override available \(Format.relative(soloAt, from: store.now))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else if request.soloStartedAt != nil {
                SoloFrictionRow(request: request)
            } else {
                if let requirement = store.state.soloFriction(forRequest: request.id,
                                                              ifStartedAt: store.now) {
                    Text("Costs \(requirement.effortUnits) taps of held attention, "
                         + "over at least \(Format.duration(requirement.minimumElapsed)).")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Button("START SOLO OVERRIDE") {
                    store.append(.soloOverrideStarted(requestID: request.id))
                }
                .font(.system(size: 12, weight: .bold))
                .tint(Theme.ink)
            }

            partnerStatus
        }
    }

    /// What can honestly be said about the partners.
    ///
    /// Never "2 approvals received": while offline we do not know that, and
    /// §11 is explicit that saying so would be a lie told by a progress bar.
    /// What this device knows is whether anyone was asked, and whether a
    /// grant it cannot yet check is sitting in the queue.
    @ViewBuilder
    private var partnerStatus: some View {
        Group {
            if let failure = account.requestFailure {
                Text(failure)
            } else if account.heldGrants > 0 {
                Text("An approval arrived that this app cannot verify yet. "
                     + "Retrying after the next key refresh.")
            } else if let receipt = account.lastRequest, receipt.partnersNotified > 0 {
                Text("Asked \(receipt.partnersNotified) "
                     + "\(receipt.partnersNotified == 1 ? "partner" : "partners"). "
                     + "Waiting to hear back.")
            } else if account.hasAccountabilityRoute(for: record.commitment.id) {
                Text("Waiting to hear back from your partners.")
            } else {
                Text("No accountability route on this commitment; "
                     + "the solo route is the only one that ends in an unlock.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted.opacity(0.7))
    }
}


/// The active-friction challenge, in its simplest honest form: the user has to
/// actually produce effort, one deliberate act at a time, and the elapsed floor
/// still applies.
///
/// **This is a test implementation.** The final friction mechanic is an open
/// product-design surface (docs/earnedkit-semantics.md) — what matters here is
/// that the domain now requires measurable effort, so the UX can be replaced
/// without touching the rules.
struct SoloFrictionRow: View {
    @EnvironmentObject private var store: EarnedStore
    let request: OverrideRequest

    var body: some View {
        let requirement = request.soloRequirement ?? FrictionRequirement(effortUnits: 0, minimumElapsed: 0)
        let remaining = request.soloUnitsRemaining ?? 0
        let completableAt = (request.soloStartedAt ?? store.now)
            .addingTimeInterval(requirement.minimumElapsed)
        let timeLeft = completableAt.timeIntervalSince(store.now)

        VStack(alignment: .leading, spacing: 6) {
            Text("\(request.soloEffortUnits) / \(requirement.effortUnits) effort")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.ink)
            if timeLeft > 0 {
                Text("Earliest finish \(Format.relative(completableAt, from: store.now)).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            if remaining > 0 {
                Button("KEEP GOING") {
                    store.recordFrictionProgress(requestID: request.id)
                }
                .font(.system(size: 12, weight: .bold))
                .tint(Theme.ink)
            } else if timeLeft > 0 {
                Text("Effort done. The clock is not.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else {
                Button("COMPLETE SOLO OVERRIDE") {
                    store.append(.soloOverrideCompleted(requestID: request.id))
                }
                .font(.system(size: 12, weight: .bold))
                .tint(Theme.signal)
            }
        }
    }
}
