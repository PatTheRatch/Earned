import SwiftUI
import EarnedKit

/// Home answers one question — what do I need to do right now? — in the poster
/// voice: one huge state word, then quiet rule-separated rows (NORTHSTAR §29,
/// docs/design-language.md).
struct TodayView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var showingNewCommitment = false
    @State private var showingLockScreen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Earned", color: Theme.ink)
                        .padding(.top, 12)

                    Button { showingLockScreen = true } label: {
                        StateWord(word: store.isRestricted ? "LOCKED" : "EARNED")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                    if store.shielding != .approved {
                        EnforcementNotice(owing: !store.unenforceableGates.isEmpty)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        hydrationRow
                        ForEach(store.overdue, id: \.commitment.id) { record in
                            overdueRow(record)
                        }
                        ForEach(store.upcomingEntries) { entry in
                            switch entry {
                            case .commitment(let record): upcomingRow(record)
                            case .plan(let summary): planRow(summary)
                            }
                        }
                        ThickRule()
                    }
                    .padding(.top, 22)

                    if store.freeOverrides > 0 {
                        TicketView(count: store.freeOverrides)
                            .padding(.top, 20)
                    }

                    if store.overdue.isEmpty && store.upcoming.isEmpty {
                        Text("Nothing owed. Make a commitment when you know what you owe yourself.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 20)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        if store.state.hydration?.enabled == true {
                            Button("I DRANK SOME WATER") { store.acknowledgeWater() }
                                .buttonStyle(PosterButtonStyle())
                        }
                        Button {
                            showingNewCommitment = true
                        } label: {
                            Text("+ NEW COMMITMENT")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(Theme.ink)
                                .padding(.bottom, 2)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Theme.ink).frame(height: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewCommitment) { NewCommitmentView() }
            .sheet(isPresented: $showingLockScreen) { LockScreenView() }
            .rejectionAlert()
        }
    }

    // MARK: - Rows: thick rule, small-caps label, one bold line, quiet context.

    @ViewBuilder
    private var hydrationRow: some View {
        if store.state.hydration?.enabled == true {
            NavigationLink {
                HydrationDetailView()
            } label: {
                row(label: "Water", line: hydrationLine)
            }
            .buttonStyle(.plain)
        }
    }

    private var hydrationLine: Text {
        switch store.hydration {
        case .satisfied(let expiresAt):
            let left = Format.duration(max(0, expiresAt.timeIntervalSince(store.now)))
            return Text("Fine. \(left) left.").foregroundStyle(Theme.ink)
        case .unsatisfied:
            return Text("Drink some water. ").foregroundStyle(Theme.ink)
                 + Text("Now.").foregroundStyle(Theme.signal)
        case .dormant:
            return Text("Resting until active hours.").foregroundStyle(Theme.muted)
        }
    }

    private func overdueRow(_ record: CommitmentRecord) -> some View {
        NavigationLink {
            CommitmentDetailView(commitmentID: record.commitment.id)
        } label: {
            row(label: record.commitment.title,
                line: overdueLine(record),
                context: "was due \(Format.deadline(record.commitment.deadline, from: store.now).lowercased())")
        }
        .buttonStyle(.plain)
    }

    private func overdueLine(_ record: CommitmentRecord) -> Text {
        guard let progress = store.state.progress(for: record.commitment.id),
              progress.unit != .workouts || progress.required > 1,
              progress.achieved > 0 else {
            return Text("Not done. ").foregroundStyle(Theme.ink)
                 + Text("Still owed.").foregroundStyle(Theme.signal)
        }
        let done = Format.progress(progress)
        let left = Format.remaining(progress) ?? "Done."
        return Text("\(done). ").foregroundStyle(Theme.ink)
             + Text(left).foregroundStyle(Theme.signal)
    }

    private func upcomingRow(_ record: CommitmentRecord) -> some View {
        NavigationLink {
            CommitmentDetailView(commitmentID: record.commitment.id)
        } label: {
            row(label: dayLabel(record.commitment.deadline),
                line: Text("\(record.commitment.title) by \(timeLabel(record.commitment.deadline)).")
                    .foregroundStyle(Theme.muted),
                context: liveNote(record))
        }
        .buttonStyle(.plain)
    }

    /// A whole recurring plan in one row, headlined by its next outstanding day.
    private func planRow(_ summary: PlanSummary) -> some View {
        NavigationLink {
            PlanDetailView(planID: summary.plan.id)
        } label: {
            row(label: dayLabel(summary.next.commitment.deadline),
                line: Text("\(summary.plan.title) by "
                           + "\(timeLabel(summary.next.commitment.deadline)).")
                    .foregroundStyle(Theme.muted),
                context: [summary.scheduleLine, liveNote(summary.next)]
                    .compactMap { $0 }.joined(separator: " · "))
        }
        .buttonStyle(.plain)
    }

    /// Says so when a commitment's window hasn't opened yet — a run today does
    /// nothing for Friday's obligation, and the row shouldn't imply otherwise.
    private func liveNote(_ record: CommitmentRecord) -> String? {
        guard record.commitment.eligibleFrom > store.now else { return nil }
        return "counts from \(dayLabel(record.commitment.eligibleFrom).lowercased())"
    }

    private func row(label: String, line: Text, context: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ThickRule()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: label)
                    line.font(Theme.blocker())
                    if let context {
                        Text(context)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
            .padding(.vertical, 14)
        }
        .contentShape(Rectangle())
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Enforcement integrity, as a *secondary* technical state.
///
/// Deliberately never competes with the state word. What you owe is the
/// contract and stays primary; whether Earned can currently act on it is a
/// separate fact about the machinery. The two must not collapse into one
/// LOCKED/UNLOCKED binary (NORTHSTAR §33) — so this says enforcement is off
/// without ever implying the obligation went with it.
private struct EnforcementNotice: View {
    /// Whether a Gate is actually unsatisfied right now. Enforcement being off
    /// while nothing is owed is a footnote; while something is owed it matters.
    let owing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ENFORCEMENT OFF")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(owing ? Theme.signal : Theme.muted)
            Text(owing
                 ? "Earned can't block anything right now. Still owed either way."
                 : "Earned can't block anything right now.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}
