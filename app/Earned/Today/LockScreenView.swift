import SwiftUI
import EarnedKit

/// The receipt. It explains the contract and nothing else: not a coaching
/// surface, not a feed (NORTHSTAR §8).
///
/// In this build it is a screen you can open. Once the Screen Time extensions
/// land it becomes the shield itself, rendered over a restricted app.
struct LockScreenView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            switch store.access {
            case .full:
                unlocked
            case .restricted(let reasons):
                locked(reasons)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(CommitButtonStyle(tint: .primary))
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
    }

    private var unlocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🔓 Unlocked").font(.largeTitle.weight(.semibold))
            Text("Every active Gate is satisfied.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func locked(_ reasons: [LockReason]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("🔒 Still locked").font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(emoji(for: reason))
                            Text(reason.headline).font(.title3.weight(.medium))
                        }
                        if let progress = reason.progress, progress.required > 0 {
                            Text(Format.progress(progress))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let remaining = Format.remaining(progress) {
                                Text(remaining).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Text(reasons.count == 1
                 ? "Satisfy this to unlock."
                 : "Satisfy all active requirements to unlock.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func emoji(for reason: LockReason) -> String {
        switch reason.source {
        case .hydration: return "💧"
        case .commitment: return "🏃"
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
                Button("🎟️ Use a Free Override (\(store.freeOverrides) left)") {
                    store.spendFreeOverride(on: record.commitment.id)
                }
                .font(.footnote.weight(.medium))
            }

            if let request {
                requestStatus(request)
            } else {
                Button("Request an Override") {
                    store.append(.overrideRequested(id: UUID(),
                                                    commitmentID: record.commitment.id))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func requestStatus(_ request: OverrideRequest) -> some View {
        let policy = record.commitment.overridePolicy
        let soloAt = request.soloAvailableAt(policy: policy)

        VStack(alignment: .leading, spacing: 6) {
            Text("Override requested · \(request.approvals.count)/\(policy.approvalsRequired) approvals")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.now < soloAt {
                Text("Solo override available \(Format.relative(soloAt, from: store.now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let startedAt = request.soloStartedAt {
                let friction = store.state.soloFriction(forRequest: request.id,
                                                        ifStartedAt: startedAt) ?? 0
                let completeAt = startedAt.addingTimeInterval(friction)
                if store.now < completeAt {
                    Text("Solo override in progress — \(Format.relative(completeAt, from: store.now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Complete Solo Override") {
                        store.append(.soloOverrideCompleted(requestID: request.id))
                    }
                    .font(.footnote.weight(.medium))
                }
            } else {
                Button("Start Solo Override") {
                    store.append(.soloOverrideStarted(requestID: request.id))
                }
                .font(.footnote.weight(.medium))
            }

            Text("Accountability partners arrive with the backend; until then the "
                 + "solo route is the only one that ends in an unlock.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
