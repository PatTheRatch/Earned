import SwiftUI
import EarnedKit

/// The acceptance screen: the invitee's own Deal (NORTHSTAR §46, invariant 31).
///
/// The shared terms — what, how much, by when — arrive frozen from the
/// invitation. Everything else on this screen is the invitee's alone:
/// verification, escape rules, correction window. Nothing exists anywhere
/// until COMMIT — an invitation obliges nobody, and the inviter never set a
/// single term of what this screen binds.
struct AcceptSharedInvitationView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var health: HealthImporter
    @Environment(\.dismiss) private var dismiss

    let invitation: SharedInvitation

    @State private var verification: WorkoutVerification = .selfReported
    @State private var approvals = 2
    @State private var roster: Set<UUID> = []
    @State private var accountabilityMinutes = 30.0
    @State private var correctionHours = 2.0
    @State private var warnBefore = true
    @State private var rewardEligible = true
    @State private var accepting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("THE DEAL")
                        .font(Theme.display(34))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)

                    Text("\(invitation.inviterDisplayName) shares the promise. How Earned "
                         + "enforces it on your phone is nobody's choice but yours.")
                        .font(Theme.body).foregroundStyle(Theme.muted)

                    receipt
                    verificationSection
                    escapeSection

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Correction window: \(Format.duration(correctionHours * 3600))")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                        Slider(value: $correctionHours, in: 0...6, step: 0.5)
                    }

                    Text("Your clock starts at your acceptance — not at "
                         + "\(invitation.inviterDisplayName)'s. After this hardens, it can "
                         + "only get harder, and missing the deadline doesn't clear it.")
                        .font(Theme.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(accepting ? "COMMITTING…" : "COMMIT") { accept() }
                        .buttonStyle(PosterButtonStyle())
                        .disabled(accepting)

                    if let failure = social.failure {
                        Text(failure).font(Theme.footnote).foregroundStyle(Theme.signal)
                    }
                    if let rejection = store.rejection {
                        Text(rejection).font(Theme.footnote).foregroundStyle(Theme.signal)
                    }
                }
                .padding(24)
            }
            .background(Theme.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task { await account.refreshPartners() }
        }
    }

    private var hardensAt: Date {
        let window = min(correctionHours * 3600,
                         invitation.terms.deadline.timeIntervalSince(store.now)
                            * Commitment.hardeningFraction)
        return store.now.addingTimeInterval(max(0, window))
    }

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThickRule()
            ReceiptRow(label: "Do", value: invitation.title.uppercased())
            ReceiptRow(label: "Counts", value: invitation.terms.label)
            ReceiptRow(label: "By", value: Format.deadline(invitation.terms.deadline,
                                                          from: store.now))
            ReceiptRow(label: "With",
                       value: "\(invitation.inviterDisplayName)"
                            + (invitation.acceptedCount > 1
                               ? " + \(invitation.acceptedCount - 1) more" : ""))
            ReceiptRow(label: "They see", value: "Whether you did it — nothing else")
            ReceiptRow(label: "Hardens",
                       value: Format.relative(hardensAt, from: store.now),
                       valueColor: Theme.signal)
            ThickRule()
        }
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Who has to believe you")
            ChoiceRow(title: "My word counts",
                      subtitle: "For days you trust yourself.",
                      selected: verification == .selfReported) {
                verification = .selfReported
            }
            ChoiceRow(title: "An app has to vouch",
                      subtitle: "Only workouts another app recorded count.",
                      selected: verification == .appVerified) {
                verification = .appVerified
            }
            Text("The roster states each person's tier factually. Nobody's choice "
                 + "here changes anybody else's.")
                .font(Theme.footnote).foregroundStyle(Theme.muted)
                .padding(.top, 6)
        }
        .onChange(of: verification) { _, chosen in
            // Same moment the creation flow asks: while the user is looking
            // at the sentence that explains why.
            guard chosen == .appVerified else { return }
            Task { await health.requestAccess() }
        }
    }

    /// The invitee's own escape rules — same defaults as any new commitment.
    /// Shared participants have no authority here (invariant 24 extended):
    /// only consented accountability partners can appear on this roster.
    private var escapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Who can let you out")
            let eligible = account.eligiblePartners
            if eligible.isEmpty {
                Text("No accountability partners yet — the Solo route will be the way "
                     + "out. Doing this together gives nobody approval authority.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(eligible) { partner in
                Button {
                    if roster.contains(partner.id) { roster.remove(partner.id) }
                    else { roster.insert(partner.id) }
                    approvals = min(approvals, max(1, roster.count))
                } label: {
                    HStack {
                        Image(systemName: roster.contains(partner.id)
                              ? "checkmark.square.fill" : "square")
                        Text(partner.displayName)
                        Spacer()
                    }
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            }
            if !roster.isEmpty {
                Stepper("Approvals required: \(approvals)",
                        value: $approvals, in: 1...max(1, roster.count))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Wait before a solo override: \(Int(accountabilityMinutes)) min")
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                Slider(value: $accountabilityMinutes, in: 0...120, step: 5)
            }
            Toggle("Warn me 30 minutes before", isOn: $warnBefore)
            Toggle("Eligible for Free Overrides", isOn: $rewardEligible)
        }
    }

    private func accept() {
        accepting = true
        // Whichever tier they chose: Apple Health is the only route a finished
        // workout has into a release build's ledger, so a commitment accepted
        // on a phone that was never asked cannot be kept — only overridden.
        Task { await health.requestAccess() }
        Task {
            let policy = OverridePolicy(approvalsRequired: approvals,
                                        accountabilityWindow: accountabilityMinutes * 60)
            let accepted = await social.acceptSharedInvitation(
                invitation, into: store,
                verification: verification,
                correctionWindow: correctionHours * 3600,
                overridePolicy: policy,
                rewardEligible: rewardEligible,
                warningLead: warnBefore ? 30 * 60 : nil)
            if accepted {
                // The new commitment's accountability terms go to the server
                // now, not at next launch — same urgency as any short-fuse
                // commitment (S13), and this one may be hours from hardening.
                let chosen = Array(roster)
                let rosters = Dictionary(uniqueKeysWithValues:
                    store.allCommitments
                        .filter { social.sharedRegistry.agreementID(for: $0.commitment.id)
                                    == invitation.id }
                        .map { ($0.commitment.id, chosen) })
                await account.syncEnvelopes(for: store.allCommitments,
                                            rosters: rosters, now: store.now)
                dismiss()
            }
            accepting = false
        }
    }
}

/// One shared commitment, printed: the terms once, then a line per person.
/// Join order, no ranking, no places — mutual visibility is the whole
/// mechanic (NORTHSTAR §46).
struct SharedCommitmentDetailView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    let sharedID: UUID

    private var shared: SharedCommitment? {
        social.sharedCommitments.first { $0.id == sharedID }
    }

    var body: some View {
        PosterPage {
            if let shared {
                PageHeader(title: shared.title.uppercased())

                Text("\(shared.terms.label) · by "
                     + Format.deadline(shared.terms.deadline, from: store.now))
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shared.participants) { participant in
                        participantRow(participant, in: shared)
                    }
                }
                .padding(.top, Theme.blockSpacing)

                // One line, because this screen is read every time and the
                // architecture behind it is read once. The longer version —
                // own Gate, own rules, own ways out — belongs where somebody
                // is deciding whether to accept, not on the status page of a
                // commitment they already made.
                Text("Same promise. Your own Gate.")
                    .font(Theme.blocker(16)).foregroundStyle(Theme.ink)
                    .padding(.top, Theme.blockSpacing)

                actions(for: shared)
            } else {
                PageHeader(title: "TOGETHER")
                EmptyState(title: "NOT HERE ANY MORE",
                           message: "This shared commitment is no longer visible to you. "
                                  + "Anything you committed to is still yours, on Today.")
                    .padding(.top, Theme.blockSpacing)
            }
        }
        .refreshable { await social.refreshShared() }
    }

    private func participantRow(_ participant: SharedParticipant,
                                in shared: SharedCommitment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairRule().padding(.top, 8)
            HStack(spacing: 12) {
                AvatarView(avatarPath: participant.avatarPath,
                           displayName: participant.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(participant.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        Text("@\(participant.handle)")
                        // Stated only when tiers differ: a difference is a
                        // fact, a uniform label is noise (§8 of the design).
                        if shared.mixedVerification, participant.isAccepted,
                           let verification = participant.verification {
                            Text(verification == "app_verified"
                                 ? "· app-verified" : "· self-reported")
                        }
                    }
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !participant.isAccepted {
                    Text("INVITED")
                        .font(.system(size: 11, weight: .bold)).tracking(1.1)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(shared.terms.progressLine(progress: participant.progress))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if participant.isDone {
                            StatusTag(text: participant.progressState == "kept_late"
                                      ? "DONE LATE" : "DONE ✓", color: Theme.ink)
                        } else if participant.progressState == "overridden" {
                            Text("Override").font(Theme.footnote).foregroundStyle(Theme.muted)
                        } else if participant.progressState == "ended" {
                            Text("ended").font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func actions(for shared: SharedCommitment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if shared.createdByMe {
                if shared.state == "open" {
                    // Named for what the server does — stop accepting answers
                    // to outstanding invitations — rather than for a social
                    // posture. "Close to new people" reads like a privacy
                    // setting about who may find you, which is a different
                    // feature and not this one.
                    Button("CLOSE INVITES") {
                        Task { await social.cancelShared(shared) }
                    }
                    .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                    Text("Pending invites expire. Existing commitments stay unchanged.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                }
            } else {
                Button("LEAVE") {
                    Task { await social.leaveShared(shared); dismiss() }
                }
                .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                Text("Leaving changes who can see you — never what you owe. Your "
                     + "commitment stays on Today, with its usual ways out.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, Theme.blockSpacing)
    }
}
