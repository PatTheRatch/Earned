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
            .navigationTitle("History")
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
                Text(symbol).font(.subheadline)
            }
            Text("\(Format.deadline(record.commitment.deadline, from: now)) · \(outcome)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch record.resolution {
        case .completed: return "✅"
        case .overridden: return "🎟️"
        case .cancelled: return "⚪️"
        case nil: return record.isOverdue(now: now) ? "🔴" : "⏳"
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
