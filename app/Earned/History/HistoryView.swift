import SwiftUI
import EarnedKit

/// Behaviour over time. Sparse on purpose: enough to answer "am I actually
/// doing this?" without becoming a dashboard (NORTHSTAR §30).
struct HistoryView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        NavigationStack {
            List {
                Section("Now") {
                    LabeledContent("Current streak", value: "\(store.streak)")
                    LabeledContent("Free Overrides", value: "\(store.freeOverrides)")
                    LabeledContent("Workout debt", value: "\(store.state.workoutDebt(now: store.now))")
                }

                Section("Last 30 days") {
                    let stats = store.state.reliability(now: store.now)
                    LabeledContent("Completed on time", value: "\(stats.completed)")
                    LabeledContent("Missed deadlines", value: "\(stats.missedDeadlines)")
                    LabeledContent("Override requests", value: "\(stats.overrideRequests)")
                    // Counted, and counted separately: an override resolved the
                    // obligation, a bypass left it standing (NORTHSTAR §33).
                    LabeledContent("Enforcement bypasses",
                                   value: "\(stats.enforcementBypasses)")
                }

                if !store.activePlans.isEmpty {
                    Section {
                        ForEach(store.activePlans, id: \.plan.id) { record in
                            let occurrences = store.state.occurrences(ofPlan: record.plan.id)
                            NavigationLink {
                                PlanDetailView(planID: record.plan.id)
                            } label: {
                                PlanRow(plan: record.plan,
                                        done: occurrences.filter {
                                            if case .completed = $0.resolution { return true }
                                            else { return false }
                                        }.count,
                                        total: occurrences.count)
                            }
                        }
                    } header: {
                        Text("Plans")
                    } footer: {
                        Text("Each plan's days are also listed below individually — this is "
                             + "the same work, counted as the one decision that made it.")
                    }
                }

                Section("Commitments") {
                    if store.allCommitments.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.allCommitments, id: \.commitment.id) { record in
                        NavigationLink {
                            CommitmentDetailView(commitmentID: record.commitment.id)
                        } label: {
                            HistoryRow(record: record, now: store.now)
                        }
                    }
                }
            }
            .paperList()
            .navigationTitle("History")
        }
    }
}

private struct PlanRow: View {
    let plan: CommitmentPlan
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.title).font(.subheadline.weight(.medium))
            Text("\(Format.weekdays(plan.weekdays)) · \(done) of \(total) done")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let record: CommitmentRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.commitment.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(tag)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(tagColor)
            }
            Text("\(Format.deadline(record.commitment.deadline, from: now)) · \(outcome)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tag: String {
        switch record.resolution {
        case .completed: return "DONE"
        case .overridden: return "OVERRIDE"
        case .cancelled: return "CANCELLED"
        case nil: return record.isOverdue(now: now) ? "OVERDUE" : "OPEN"
        }
    }

    private var tagColor: Color {
        switch record.resolution {
        case .completed: return Theme.ink
        case .overridden, .cancelled: return Theme.muted
        case nil: return record.isOverdue(now: now) ? Theme.signal : Theme.muted
        }
    }

    private var outcome: String {
        switch record.resolution {
        case .completed(let at):
            return at <= record.commitment.deadline ? "Completed" : "Completed late"
        case .overridden(let kind, _):
            switch kind {
            case .free: return "Free Override"
            case .accountability: return "Accountability Override"
            case .solo: return "Solo Override"
            }
        case .cancelled: return "Cancelled during the correction window"
        case nil:
            return record.isOverdue(now: now) ? "Overdue — still owed" : "Outstanding"
        }
    }
}
