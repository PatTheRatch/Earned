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
    @EnvironmentObject private var account: AccountStore
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
    @State private var activity: ActivityFilterChoice = .any
    private enum ActivityFilterChoice: Hashable, CaseIterable {
        case any, running, walking, cycling, strength
        var filter: ActivityFilter {
            switch self {
            case .any: return .any
            case .running: return .only(.running)
            case .walking: return .only(.walking)
            case .cycling: return .only(.cycling)
            case .strength: return .only(.strength)
            }
        }
        var label: String {
            switch self {
            case .any: return "Any workout"
            case .running: return "Running"
            case .walking: return "Walking"
            case .cycling: return "Cycling"
            case .strength: return "Strength"
            }
        }
        init(_ filter: ActivityFilter) {
            switch filter {
            case .any: self = .any
            case .types(let set):
                switch set.first {
                case .running: self = .running
                case .walking: self = .walking
                case .cycling: self = .cycling
                case .strength: self = .strength
                default: self = .any
                }
            }
        }
    }

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
            if record.isOverdue(now: store.now) {
                Section {
                    StateWord(word: "OVERDUE", size: 56)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                }
            }
            Section("Status") {
                LabeledContent("State", value: statusText(record))
                if let progress, progress.required > 0 {
                    LabeledContent("Progress", value: Format.progress(progress))
                }
                LabeledContent("Counts from",
                               value: Format.deadline(commitment.eligibleFrom, from: store.now))
                // Where this day came from, so an occurrence is never a mystery
                // commitment the user doesn't remember making.
                if let planID = commitment.planID, let plan = store.state.plans[planID] {
                    NavigationLink {
                        PlanDetailView(planID: planID)
                    } label: {
                        LabeledContent("Part of", value: plan.plan.title)
                    }
                }
                LabeledContent(hardened ? "Hardened" : "Hardens") {
                    Text(hardened ? "Yes — only harder edits allowed"
                                  : Format.relative(commitment.hardensAt, from: store.now))
                }
                RegistrationRow(registration: account.registration(of: commitment))
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

            restrictionsSection(for: record)

            if record.resolution == nil {
                Section("Ways out") {
                    OverrideMenu(record: record)
                }
            }

            if !hardened {
                Section {
                    Button("Cancel commitment", role: .destructive) {
                        if store.cancelCommitment(commitmentID) { dismiss() }
                    }
                }
            }
        }
        .paperList()
    }

    @ViewBuilder
    private func requirementEditor(current: Requirement, hardened: Bool) -> some View {
        if hardened {
            LabeledContent("Counts", value: current.activity.displayName)
        } else {
            Picker("Counts", selection: Binding(
                get: { activity },
                set: { activity = $0; saveRequirement() })) {
                ForEach(ActivityFilterChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
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
        if case .totalDuration(let seconds) = current.metric { return max(5, seconds / 60) }
        return 5
    }

    private func minDistance(_ current: Requirement) -> Double {
        if case .totalDistance(let meters) = current.metric { return max(0.5, meters / 1000) }
        return 0.5
    }

    private var requirementValue: Requirement {
        switch kind {
        case .any: return Requirement(activity: activity.filter, metric: .anyQualifyingWorkout)
        case .duration: return Requirement(activity: activity.filter, metric: .totalDuration(minutes * 60))
        case .distance: return Requirement(activity: activity.filter, metric: .totalDistance(kilometers * 1000))
        }
    }

    @ViewBuilder
    private func restrictionsSection(for record: CommitmentRecord) -> some View {
        Section {
            if record.commitment.restrictions.isEmpty {
                Text("Nothing").foregroundStyle(.secondary)
            } else {
                ForEach(record.commitment.restrictions.sortedTokens, id: \.self) {
                    RestrictionTokenLabel(token: $0)
                }
            }
        } header: {
            Text("What this Gate takes")
        } footer: {
            Text("This Gate's own profile. While it is unsatisfied these are blocked, on top of "
                 + "whatever any other closed Gate blocks. Adding is always allowed; removing "
                 + "needs full access and nothing hardened outstanding.")
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
        activity = ActivityFilterChoice(commitment.requirement.activity)
        switch commitment.requirement.metric {
        case .anyQualifyingWorkout:
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
