import SwiftUI
import EarnedKit

/// Home answers one question: what do I need to do right now? It stays
/// intentionally sparse (NORTHSTAR §29).
struct TodayView: View {
    @EnvironmentObject private var store: EarnedStore
    @State private var showingNewCommitment = false
    @State private var showingLockScreen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    phoneStatus
                    hydrationCard
                    exerciseSection
                    upcomingSection
                    newCommitmentButton
                }
                .padding(20)
            }
            .navigationTitle("Today")
            .background(Theme.canvas)
            .sheet(isPresented: $showingNewCommitment) { NewCommitmentView() }
            .sheet(isPresented: $showingLockScreen) { LockScreenView() }
            .rejectionAlert()
        }
    }

    // MARK: - Phone status

    private var phoneStatus: some View {
        Button {
            showingLockScreen = true
        } label: {
            HStack(spacing: 12) {
                Text(store.isRestricted ? "🔒" : "🔓").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isRestricted ? "Restricted" : "Full Access")
                        .font(.headline)
                        .foregroundStyle(store.isRestricted ? Theme.locked : Theme.satisfied)
                    Text(store.isRestricted
                         ? "Tap to see what's holding it"
                         : "Every active Gate is satisfied")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.footnote)
            }
            .cardBackground()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hydration

    @ViewBuilder
    private var hydrationCard: some View {
        if store.state.hydration?.enabled == true {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    HydrationDetailView()
                } label: {
                    HStack {
                        GateHeadline(emoji: "💧",
                                     title: "Water",
                                     status: hydrationStatusText,
                                     tint: hydrationTint)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.footnote)
                    }
                }
                .buttonStyle(.plain)
                Button("I drank some water") { store.acknowledgeWater() }
                    .buttonStyle(CommitButtonStyle(tint: hydrationTint))
            }
            .cardBackground()
        }
    }

    private var hydrationStatusText: String {
        switch store.hydration {
        case .satisfied(let expiresAt):
            return "Good — locks again \(Format.relative(expiresAt, from: store.now))"
        case .unsatisfied:
            return "Drink some water to unlock"
        case .dormant:
            return store.state.hydration?.enabled == true ? "Resting until active hours" : "Off"
        }
    }

    private var hydrationTint: Color {
        switch store.hydration {
        case .satisfied: return Theme.satisfied
        case .unsatisfied: return Theme.locked
        case .dormant: return Theme.waiting
        }
    }

    // MARK: - Exercise

    @ViewBuilder
    private var exerciseSection: some View {
        let overdue = store.overdue
        if !overdue.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                GateHeadline(emoji: "🏃",
                             title: overdue.count == 1 ? "Exercise" : "Exercise (\(overdue.count) overdue)",
                             status: "Overdue — the deal still stands",
                             tint: Theme.locked)
                ForEach(overdue, id: \.commitment.id) { record in
                    NavigationLink {
                        CommitmentDetailView(commitmentID: record.commitment.id)
                    } label: {
                        CommitmentRow(record: record,
                                      progress: store.state.progress(for: record.commitment.id),
                                      now: store.now)
                    }
                    .buttonStyle(.plain)
                    OverrideMenu(record: record)
                }
            }
            .cardBackground()
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingSection: some View {
        let upcoming = store.upcoming
        if upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing due").font(.headline)
                Text("No commitments outstanding. Make one when you know what you owe yourself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .cardBackground()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Upcoming").font(.headline)
                ForEach(upcoming, id: \.commitment.id) { record in
                    NavigationLink {
                        CommitmentDetailView(commitmentID: record.commitment.id)
                    } label: {
                        CommitmentRow(record: record,
                                      progress: store.state.progress(for: record.commitment.id),
                                      now: store.now)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardBackground()
        }
    }

    private var newCommitmentButton: some View {
        Button("+ New Commitment") { showingNewCommitment = true }
            .buttonStyle(CommitButtonStyle(tint: .primary))
    }
}

// MARK: - Shared rows

struct GateHeadline: View {
    let emoji: String
    let title: String
    let status: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(status).font(.footnote).foregroundStyle(tint)
            }
            Spacer()
        }
    }
}

struct CommitmentRow: View {
    let record: CommitmentRecord
    let progress: CommitmentProgress?
    let now: Date

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.commitment.title).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(Format.deadline(record.commitment.deadline, from: now))
                    if let progress, progress.required > 1 || progress.unit != .workouts {
                        Text("·")
                        Text(Format.progress(progress))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption2)
        }
        .contentShape(Rectangle())
    }
}
