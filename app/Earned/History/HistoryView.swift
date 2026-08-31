import SwiftUI
import EarnedKit

/// Progress answers one question — is Earned working for me? — with a
/// scoreboard, not a database summary. One headline figure, a short behavioral
/// story under it, then the record itself. No XP, no ranking: the numbers are
/// facts about kept promises (NORTHSTAR §30, §45).
struct ProgressScreen: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        NavigationStack {
            PosterPage {
                PageHeader(title: "PROGRESS")

                let stats = store.state.reliability(now: store.now)
                let streaks = store.state.socialStreaks(now: store.now)
                let decided = stats.completed + stats.missedDeadlines

                if decided == 0 && store.allCommitments.isEmpty {
                    EmptyState(title: "NOT ENOUGH HISTORY YET",
                               message: "Keep a few commitments and this starts telling "
                                        + "a story.")
                        .padding(.top, Theme.blockSpacing)
                } else {
                    headline(stats: stats, decided: decided)
                    ThickRule().padding(.top, 20)
                    storyRow(streaks: streaks, stats: stats)
                }

                plansBlock
                historyBlock
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - The headline: one figure, everything else quieter.

    @ViewBuilder
    private func headline(stats: ReliabilityStats, decided: Int) -> some View {
        if decided > 0 {
            let percent = Int((Double(stats.completed) / Double(decided) * 100).rounded())
            VStack(alignment: .leading, spacing: 4) {
                Metric(value: "\(percent)% KEPT",
                       caption: "\(stats.completed) of \(decided) commitments · last 30 days",
                       size: 56,
                       color: percent >= 50 ? Theme.ink : Theme.signal)
            }
            .padding(.top, Theme.blockSpacing)
        } else {
            Text("Nothing has come due in the last 30 days.")
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
                .padding(.top, Theme.blockSpacing)
        }
    }

    /// The behavioural story: streaks and escapes at second weight, debt and
    /// bypasses only when they exist — signal names a consequence or stays home.
    @ViewBuilder
    private func storyRow(streaks: SocialStreaks, stats: ReliabilityStats) -> some View {
        let debt = store.state.workoutDebt(now: store.now)
        HStack(alignment: .top, spacing: Theme.blockSpacing) {
            Metric(value: "\(streaks.commitmentsKept) IN A ROW",
                   caption: "on time", size: 30)
            Metric(value: streaks.sinceLastOverride.map { "\($0)" } ?? "—",
                   caption: streaks.sinceLastOverride == nil
                            ? "no Overrides yet" : "since last Override",
                   size: 30)
            if store.freeOverrides > 0 {
                Metric(value: "\(store.freeOverrides)", caption: "Free Overrides", size: 30)
            }
        }
        .padding(.top, 18)

        if debt > 0 || stats.missedDeadlines > 0 || stats.enforcementBypasses > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if debt > 0 {
                    factLine("\(debt) workout still owed.", color: Theme.signal)
                }
                if stats.missedDeadlines > 0 {
                    factLine("\(stats.missedDeadlines) missed "
                             + "deadline\(stats.missedDeadlines == 1 ? "" : "s") "
                             + "in 30 days.", color: Theme.muted)
                }
                if stats.enforcementBypasses > 0 {
                    // Counted apart from Overrides, always: one resolved the
                    // obligation, the other walked past it (NORTHSTAR §33).
                    factLine("\(stats.enforcementBypasses) enforcement "
                             + "bypass\(stats.enforcementBypasses == 1 ? "" : "es").",
                             color: Theme.signal)
                }
            }
            .padding(.top, 14)
        }
    }

    private func factLine(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
    }

    // MARK: - Plans

    @ViewBuilder
    private var plansBlock: some View {
        if !store.activePlans.isEmpty {
            SectionLabel(text: "Plans").padding(.top, Theme.blockSpacing)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.activePlans, id: \.plan.id) { record in
                    let occurrences = store.state.occurrences(ofPlan: record.plan.id)
                    let done = occurrences.filter {
                        if case .completed = $0.resolution { return true } else { return false }
                    }.count
                    NavigationLink {
                        PlanDetailView(planID: record.plan.id)
                    } label: {
                        PosterRow(label: Format.weekdays(record.plan.weekdays),
                                  line: {
                                      Text(record.plan.title)
                                          .font(Theme.blocker(16))
                                          .foregroundStyle(Theme.ink)
                                  },
                                  context: "\(done) of \(occurrences.count) done",
                                  chevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - The record

    @ViewBuilder
    private var historyBlock: some View {
        if !store.allCommitments.isEmpty {
            SectionLabel(text: "The record").padding(.top, Theme.blockSpacing)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.allCommitments, id: \.commitment.id) { record in
                    NavigationLink {
                        CommitmentDetailView(commitmentID: record.commitment.id)
                    } label: {
                        recordRow(record)
                    }
                    .buttonStyle(.plain)
                }
                HairRule()
            }
            .padding(.top, 4)
        }
    }

    private func recordRow(_ record: CommitmentRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairRule()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.commitment.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("\(Format.deadline(record.commitment.deadline, from: store.now))"
                         + " · \(outcome(record))")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                StatusTag(text: tag(record), color: tagColor(record))
            }
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
    }

    private func tag(_ record: CommitmentRecord) -> String {
        switch record.resolution {
        case .completed(let at):
            return at <= record.commitment.deadline ? "KEPT" : "KEPT LATE"
        case .overridden: return "OVERRIDE"
        case .cancelled: return "CANCELLED"
        case nil: return record.isOverdue(now: store.now) ? "OVERDUE" : "OPEN"
        }
    }

    private func tagColor(_ record: CommitmentRecord) -> Color {
        switch record.resolution {
        case .completed: return Theme.ink
        case .overridden, .cancelled: return Theme.muted
        case nil: return record.isOverdue(now: store.now) ? Theme.signal : Theme.muted
        }
    }

    private func outcome(_ record: CommitmentRecord) -> String {
        switch record.resolution {
        case .completed(let at):
            return at <= record.commitment.deadline ? "completed on time" : "completed late"
        case .overridden(let kind, _):
            switch kind {
            case .free: return "Free Override"
            case .accountability: return "Accountability Override"
            case .solo: return "Solo Override"
            }
        case .cancelled: return "cancelled in the correction window"
        case nil:
            return record.isOverdue(now: store.now) ? "still owed" : "outstanding"
        }
    }
}
