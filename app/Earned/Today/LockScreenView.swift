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
            switch store.access {
            case .full:
                earned
            case .restricted(let reasons):
                locked(reasons)
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
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(Theme.paper).frame(height: 3)
                        HStack(alignment: .firstTextBaseline) {
                            Text(headline(for: reason))
                                .font(.system(size: 16, weight: .bold))
                            Spacer()
                            Text(detail(for: reason))
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1)
                        }
                        .foregroundStyle(Theme.paper)
                        .padding(.vertical, 13)
                    }
                }
                Rectangle().fill(Theme.paper).frame(height: 3)
            }
            .padding(.top, 28)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("THE DEAL STILL STANDS.")
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.paper)
                Text("You set this one.")
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
    }

    private func headline(for reason: LockReason) -> String {
        switch reason.source {
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
        }
    }
}

/// The escape hatches, in the order the contract allows them (NORTHSTAR §§22–25).
struct OverrideMenu: View {
    @EnvironmentObject private var store: EarnedStore
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
                    store.append(.overrideRequested(id: UUID(),
                                                    commitmentID: record.commitment.id))
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
            } else if let startedAt = request.soloStartedAt {
                let friction = store.state.soloFriction(forRequest: request.id,
                                                        ifStartedAt: startedAt) ?? 0
                let completeAt = startedAt.addingTimeInterval(friction)
                if store.now < completeAt {
                    Text("Solo override in progress — \(Format.relative(completeAt, from: store.now))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                } else {
                    Button("COMPLETE SOLO OVERRIDE") {
                        store.append(.soloOverrideCompleted(requestID: request.id))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .tint(Theme.ink)
                }
            } else {
                Button("START SOLO OVERRIDE") {
                    store.append(.soloOverrideStarted(requestID: request.id))
                }
                .font(.system(size: 12, weight: .bold))
                .tint(Theme.ink)
            }

            Text("Accountability partners arrive with the backend; until then the "
                 + "solo route is the only one that ends in an unlock.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted.opacity(0.7))
        }
    }
}
