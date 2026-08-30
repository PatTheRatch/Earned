import SwiftUI
import EarnedKit

/// One recurring plan and every day it created.
///
/// The plan is a template, not a Gate: each row below is an ordinary
/// commitment with its own deadline, window and outcome. This screen exists so
/// the twelve of them read as the one decision that made them.
struct PlanDetailView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    let planID: UUID

    @State private var confirmingCancel = false

    private var record: PlanRecord? { store.state.plans[planID] }
    private var occurrences: [CommitmentRecord] { store.state.occurrences(ofPlan: planID) }

    var body: some View {
        Group {
            if let record {
                List {
                    termsSection(record.plan)
                    daysSection
                    if !record.isCancelled { cancelSection }
                }
                .paperList()
                .navigationTitle(record.plan.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                Text("This plan no longer exists.").foregroundStyle(.secondary)
            }
        }
        .rejectionAlert()
    }

    private func termsSection(_ plan: CommitmentPlan) -> some View {
        Section {
            LabeledContent("Schedule", value: Format.weekdays(plan.weekdays))
            LabeledContent("By", value: Format.timeOfDay(plan.deadlineMinuteOfDay))
            LabeledContent("Counts as done", value: Format.requirement(plan.requirement))
            LabeledContent("Days", value: "\(completedCount) of \(occurrences.count) done")
        } header: {
            Text("The deal")
        } footer: {
            Text("Each day below is its own commitment with its own deadline. A workout only "
                 + "counts toward the day it belongs to — finishing Monday's run does nothing "
                 + "for Wednesday's.")
        }
    }

    private var daysSection: some View {
        Section("Every day in this plan") {
            ForEach(occurrences, id: \.commitment.id) { occurrence in
                NavigationLink {
                    CommitmentDetailView(commitmentID: occurrence.commitment.id)
                } label: {
                    OccurrenceRow(record: occurrence, now: store.now)
                }
            }
        }
    }

    private var cancelSection: some View {
        Section {
            Button("Cancel this plan", role: .destructive) { confirmingCancel = true }
                .confirmationDialog("Cancel this plan?",
                                    isPresented: $confirmingCancel, titleVisibility: .visible) {
                    Button("Cancel the plan", role: .destructive) {
                        guard store.cancelPlan(planID) else { return }
                        // The server withdraws exactly the occurrences the
                        // ledger did, deciding it from the envelope fields
                        // itself rather than being told which ones (§4.6).
                        Task { await account.withdrawPlan(planID) }
                        dismiss()
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("Days that haven't started yet are withdrawn. Days already underway "
                         + "stand — those are live commitments.")
                }
        } footer: {
            Text("You committed to the whole plan when you made it, so it hardened as one "
                 + "thing. Cancelling can only take back days that have not begun.")
        }
    }

    private var completedCount: Int {
        occurrences.filter {
            if case .completed = $0.resolution { return true } else { return false }
        }.count
    }
}

/// One day of a plan: what it is, and what became of it.
private struct OccurrenceRow: View {
    let record: CommitmentRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(record.commitment.deadline.formatted(.dateTime.weekday(.abbreviated)
                                                          .month(.abbreviated).day()))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(tag)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(tagColor)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasOpened: Bool { record.commitment.eligibleFrom <= now }

    private var tag: String {
        switch record.resolution {
        case .completed: return "DONE"
        case .overridden: return "OVERRIDE"
        case .cancelled: return "WITHDRAWN"
        case nil:
            if record.isOverdue(now: now) { return "OVERDUE" }
            return hasOpened ? "TODAY" : "LATER"
        }
    }

    private var tagColor: Color {
        switch record.resolution {
        case .completed: return Theme.ink
        case .overridden, .cancelled: return Theme.muted
        case nil: return record.isOverdue(now: now) ? Theme.signal : Theme.muted
        }
    }

    private var detail: String {
        switch record.resolution {
        case .completed(let at):
            return at <= record.commitment.deadline ? "Completed" : "Completed late"
        case .overridden: return "Overridden"
        case .cancelled: return "Withdrawn when the plan was cancelled"
        case nil:
            if record.isOverdue(now: now) { return "Overdue — still owed" }
            return hasOpened
                ? "Due \(Format.timeOfDay(minuteOfDay(record.commitment.deadline)))"
                : "Opens \(record.commitment.eligibleFrom.formatted(.dateTime.weekday(.wide)))"
        }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
