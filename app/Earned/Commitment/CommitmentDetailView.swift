import SwiftUI
import EarnedKit

/// The contract, in full — what tapping a commitment opens.
///
/// Before hardening, everything is editable freely. After hardening, EarnedKit
/// enforces the Monotonic Commitment Principle server-side (in the ledger); this
/// view narrows the controls to match so the user isn't shown a slider that will
/// just get rejected — but the source of truth is still the ledger's validation,
/// not this screen.
struct CommitmentDetailView: View {
    @EnvironmentObject private var store: EarnedStore
    @Environment(\.dismiss) private var dismiss
    let commitmentID: UUID

    @State private var title = ""
    @State private var kind: RequirementKind = .any
    @State private var minutes = 30.0
    @State private var kilometers = 5.0
    @State private var deadline = Date()
    @State private var approvals = 2
    @State private var accountabilityMinutes = 30.0
    @State private var loaded = false

    private enum RequirementKind: Hashable { case any, duration, distance }

    private var record: CommitmentRecord? { store.state.commitments[commitmentID] }

    var body: some View {
        Group {
            if let record {
                form(for: record)
            } else {
                ContentUnavailableViewCompat()
            }
        }
        .navigationTitle(record?.commitment.title ?? "Commitment")
        .navigationBarTitleDisplayMode(.inline)
        .rejectionAlert()
        .onAppear { if !loaded { load(from: record) ; loaded = true } }
    }

    @ViewBuilder
    private func form(for record: CommitmentRecord) -> some View {
        let commitment = record.commitment
        let hardened = commitment.isHardened(at: store.now)
        let progress = store.state.progress(for: commitmentID)

        List {
            Section("Status") {
                LabeledContent("State", value: statusText(record))
                if let progress, progress.required > 0 {
                    LabeledContent("Progress", value: Format.progress(progress))
                }
                LabeledContent(hardened ? "Hardened" : "Hardens") {
                    Text(hardened ? "Yes — only harder edits allowed"
                                  : Format.relative(commitment.hardensAt, from: store.now))
                }
            }

            Section {
                TextField("Title", text: $title)
                    .onSubmit { saveTitle() }
                requirementEditor(current: commitment.requirement, hardened: hardened)
                DatePicker("Deadline",
                          selection: $deadline,
                          in: hardened ? Date.distantPast...commitment.deadline : store.now...Date.distantFuture,
                          displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: deadline) { saveDeadline() }
                if hardened {
                    Text("Hardened: the deadline can only move earlier.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("What & when")
            }

            Section {
                Stepper("Approvals required: \(approvals)",
                       value: $approvals,
                       in: max(commitment.overridePolicy.approvalsRequired, 1)...max(commitment.overridePolicy.approvalsRequired, 5))
                    .onChange(of: approvals) { updateOverridePolicy() }
                VStack(alignment: .leading) {
                    Text("Wait before solo override: \(Int(accountabilityMinutes)) min")
                    Slider(value: $accountabilityMinutes,
                          in: (commitment.overridePolicy.accountabilityWindow / 60)...max(commitment.overridePolicy.accountabilityWindow / 60, 180), step: 5)
                        .onChange(of: accountabilityMinutes) { updateOverridePolicy() }
                }
            } header: {
                Text("Escape rules")
            } footer: {
                if hardened {
                    Text("Hardened: overrides can only get stricter, never easier.")
                }
            }

            Section {
                LabeledContent("Earns Free Overrides", value: commitment.rewardEligible ? "Yes" : "No")
                Text("Fixed at creation — this can't change, even before hardening, since it's "
                     + "neither a harder nor an easier edit.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Rewards")
            }

            restrictedAppsSection

            if !hardened {
                Section {
                    Button("Cancel commitment", role: .destructive) {
                        if store.cancelCommitment(commitmentID) { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func requirementEditor(current: Requirement, hardened: Bool) -> some View {
        switch kind {
        case .any:
            if hardened {
                LabeledContent("Requirement", value: "Any workout")
            } else {
                Picker("Requirement", selection: Binding(
                    get: { kind },
                    set: { newKind in
                        kind = newKind
                        saveRequirement()
                    })) {
                    Text("Any workout").tag(RequirementKind.any)
                    Text("Total duration").tag(RequirementKind.duration)
                    Text("Total distance").tag(RequirementKind.distance)
                }
            }
        case .duration:
            VStack(alignment: .leading) {
                Text("Duration: \(Int(minutes)) min")
                Slider(value: $minutes, in: minDuration(current)...240, step: 5)
                    .onChange(of: minutes) { saveRequirement() }
            }
            if hardened {
                Text("Hardened: duration can only increase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .distance:
            VStack(alignment: .leading) {
                Text(String(format: "Distance: %.1f km", kilometers))
                Slider(value: $kilometers, in: minDistance(current)...50, step: 0.5)
                    .onChange(of: kilometers) { saveRequirement() }
            }
            if hardened {
                Text("Hardened: distance can only increase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func minDuration(_ current: Requirement) -> Double {
        if case .totalDuration(let seconds) = current { return max(5, seconds / 60) }
        return 5
    }

    private func minDistance(_ current: Requirement) -> Double {
        if case .totalDistance(let meters) = current { return max(0.5, meters / 1000) }
        return 0.5
    }

    private var requirementValue: Requirement {
        switch kind {
        case .any: return .anyWorkout
        case .duration: return .totalDuration(minutes * 60)
        case .distance: return .totalDistance(kilometers * 1000)
        }
    }

    @ViewBuilder
    private var restrictedAppsSection: some View {
        Section {
            if store.state.restrictedApps.isEmpty {
                Text("Nothing restricted yet").foregroundStyle(.secondary)
            } else {
                ForEach(store.state.restrictedApps.sorted(), id: \.self) { Text($0) }
            }
        } header: {
            Text("What's gated")
        } footer: {
            Text("Every active Gate shares one restricted set — manage it in Settings.")
        }
    }

    private func statusText(_ record: CommitmentRecord) -> String {
        switch record.resolution {
        case .completed(let at):
            return at <= record.commitment.deadline ? "Completed" : "Completed late"
        case .overridden(let kind, _):
            switch kind {
            case .free: return "Cleared — Free Override"
            case .accountability: return "Cleared — Accountability Override"
            case .solo: return "Cleared — Solo Override"
            }
        case .cancelled: return "Cancelled"
        case nil:
            return record.isOverdue(now: store.now) ? "Overdue" : "Outstanding"
        }
    }

    // MARK: - Editing

    private func load(from record: CommitmentRecord?) {
        guard let commitment = record?.commitment else { return }
        title = commitment.title
        deadline = commitment.deadline
        approvals = commitment.overridePolicy.approvalsRequired
        accountabilityMinutes = commitment.overridePolicy.accountabilityWindow / 60
        switch commitment.requirement {
        case .anyWorkout:
            kind = .any
        case .totalDuration(let seconds):
            kind = .duration
            minutes = seconds / 60
        case .totalDistance(let meters):
            kind = .distance
            kilometers = meters / 1000
        }
    }

    private func saveTitle() {
        store.append(.commitmentEdited(id: commitmentID, edit: CommitmentEdit(title: title)))
    }

    private func saveDeadline() {
        store.append(.commitmentEdited(id: commitmentID, edit: CommitmentEdit(deadline: deadline)))
    }

    private func saveRequirement() {
        store.append(.commitmentEdited(id: commitmentID, edit: CommitmentEdit(requirement: requirementValue)))
    }

    private func updateOverridePolicy() {
        guard let current = record?.commitment.overridePolicy else { return }
        var policy = current
        policy.approvalsRequired = approvals
        policy.accountabilityWindow = accountabilityMinutes * 60
        store.append(.commitmentEdited(id: commitmentID, edit: CommitmentEdit(overridePolicy: policy)))
    }
}

/// `ContentUnavailableView` requires iOS 17; this target's deployment target is
/// 17.0, but a plain fallback avoids any doubt while the toolchain is mid-setup.
private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Gone").font(.headline)
            Text("This commitment no longer exists.").foregroundStyle(.secondary)
        }
        .padding()
    }
}
