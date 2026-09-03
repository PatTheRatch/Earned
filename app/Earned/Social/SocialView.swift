import AuthenticationServices
import SwiftUI
import EarnedKit

/// The Social tab: a quiet accountability roster, not a feed (NORTHSTAR §45).
///
/// You, then anything waiting on you, then your people, then a bounded shelf
/// of what they chose to share — and then it ends. Nothing here is required
/// for Earned to work; the Gates neither know nor care.
struct SocialView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore

    @State private var showingAdd = false
    @State private var showingSetup = false
    /// The invitation whose Deal is being read. Accepting happens only there —
    /// nobody binds to a shared commitment without seeing their own contract
    /// first (docs/shared-commitments.md §4.3).
    @State private var readingInvitation: SharedInvitation?
    @EnvironmentObject private var teachings: Teachings
    @EnvironmentObject private var push: PushRegistrar
    @State private var offeringNotifications = false

    /// True once somebody is actually waiting on this user, or could be.
    ///
    /// This is the moment notifications are worth asking for, and it is the
    /// only moment: at launch there is nothing to be reachable *for*, and a
    /// permission asked before its reason is a permission refused. A shared
    /// commitment or an accountability relationship means another person now
    /// depends on this phone noticing something.
    private var somebodyIsWaiting: Bool {
        !social.sharedCommitments.isEmpty || !social.sharedInvitations.isEmpty
            || !account.partners.isEmpty || !account.partnerRequests.isEmpty
            || !account.pendingApprovals.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch account.session {
                case .notConfigured:
                    intro(message: "No backend is configured for this build, so there is "
                                 + "nobody to connect to yet. Everything else works as normal.")
                case .signedOut, .failed:
                    signedOut
                case .signingIn:
                    PosterPage {
                        PageHeader(title: "SOCIAL")
                        ProgressView().padding(.top, Theme.blockSpacing)
                    }
                case .signedIn:
                    signedIn
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAdd) { AddFriendView() }
            .sheet(isPresented: $showingSetup) { ProfileSetupView() }
            .sheet(item: $readingInvitation) { invitation in
                AcceptSharedInvitationView(invitation: invitation)
            }
            .sheet(isPresented: $offeringNotifications) {
                reachableSheet.presentationDetents([.medium])
            }
            .onChange(of: somebodyIsWaiting) { _, waiting in offerNotifications(waiting) }
            .onAppear { offerNotifications(somebodyIsWaiting) }
        }
        .task {
            await social.refreshProfile()
            await social.refreshSocial()
            await social.refreshShared()
            await social.refreshActivity()
            await account.refreshPartners()
        }
    }

    // MARK: - Staying reachable

    /// Offered once, and only once, when somebody first depends on this phone
    /// noticing something. Refusing costs timeliness and nothing else: every
    /// ask exists as a row the app fetches on its own, so the in-app surfaces
    /// remain the source of truth and push is only delivery.
    private func offerNotifications(_ waiting: Bool) {
        guard waiting, !teachings.hasSeen(.reachable),
              store.warningDelivery == .notDetermined,
              !offeringNotifications else { return }
        offeringNotifications = true
        teachings.markSeen(.reachable)
    }

    private var reachableSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Earned", color: Theme.ink).padding(.top, 36)
            StateWord(word: "STAY REACHABLE", size: 40, lines: 2).padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                Text("Earned can notify you when someone sends you a commitment, asks "
                     + "you to be an accountability partner, or needs your approval.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Those three, and nothing else. No activity summaries, no streak "
                     + "updates, no nudges to open the app.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 15)).foregroundStyle(Theme.muted)
            .padding(.top, 20)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Button("ALLOW NOTIFICATIONS") {
                    offeringNotifications = false
                    // Requested on the way out, once this sheet has actually
                    // gone: asking while a sheet is dismissing presents into a
                    // view that is leaving, and iOS drops the request.
                    Task {
                        await store.requestWarningAuthorization()
                        push.registerIfPermitted(authorization: store.warningDelivery)
                    }
                }
                .buttonStyle(PosterButtonStyle())
                Button("Not now") { offeringNotifications = false }
                    .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
            }
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    // MARK: - Pre-profile states

    private func intro(message: String) -> some View {
        PosterPage {
            PageHeader(title: "SOCIAL")
            Text("Make a promise visible, and walking away from it starts to weigh "
                 + "something.")
                .font(Theme.blocker(17))
                .foregroundStyle(Theme.ink)
                .padding(.top, Theme.blockSpacing)
            Text(message)
                .font(Theme.body).foregroundStyle(Theme.muted)
                .padding(.top, 10)
        }
    }

    private var signedOut: some View {
        PosterPage {
            PageHeader(title: "SOCIAL")
            Text("Make a promise visible, and walking away from it starts to weigh "
                 + "something.")
                .font(Theme.blocker(17))
                .foregroundStyle(Theme.ink)
                .padding(.top, Theme.blockSpacing)
            Text("Friends see what you choose to share — and nothing gives anyone "
                 + "authority over your commitments. Sign in to set up your profile.")
                .font(Theme.body).foregroundStyle(Theme.muted)
                .padding(.top, 10)
            SignInWithAppleButton(.signIn,
                                  onRequest: account.prepareRequest,
                                  onCompletion: handleSignIn)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 46)
                .padding(.top, Theme.blockSpacing)
            if case .failed(let message) = account.session {
                Text(message).font(Theme.footnote).foregroundStyle(Theme.signal)
                    .padding(.top, 8)
            }
        }
    }

    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        // The profile-setup offer rides the session change, watched in
        // MainTabView — sign-in resolves asynchronously.
        account.completeSignIn(result)
        Task { await account.refreshPartners() }
    }

    // MARK: - The roster

    @ViewBuilder
    private var signedIn: some View {
        if social.needsSetup {
            PosterPage {
                PageHeader(title: "SOCIAL")
                EmptyState(title: "YOU NEED A NAME FIRST",
                           message: "A profile is a display name and a handle. A photo and "
                                    + "a city are optional — this is an identity card, not "
                                    + "a questionnaire.")
                    .padding(.top, Theme.blockSpacing)
                Button("SET UP YOUR PROFILE") { showingSetup = true }
                    .buttonStyle(PosterButtonStyle())
                    .padding(.top, 12)
            }
        } else {
            roster
        }
    }

    private var roster: some View {
        PosterPage {
            HStack(alignment: .top) {
                PageHeader(title: "SOCIAL")
                Spacer()
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add friend")
                .padding(.top, 16)
            }

            youBlock

            // Order is the argument this screen makes: anything a named person
            // is waiting on you for, then what you are doing together, then
            // who your people are, then the bounded shelf of what they chose
            // to share. Approvals lead because a clock is running on them.
            if !account.pendingApprovals.isEmpty { approvalsBlock }
            if !social.sharedInvitations.isEmpty { sharedInvitationsBlock }
            if !account.partnerRequests.isEmpty { accountabilityBlock }
            if !social.requests.isEmpty { requestsBlock }
            if !social.sharedCommitments.isEmpty { togetherBlock }
            peopleBlock
            recentBlock

            if let failure = social.failure {
                Text(failure).font(Theme.footnote).foregroundStyle(Theme.signal)
                    .padding(.top, 12)
            }
        }
        .refreshable {
            await social.refreshProfile()
            await social.refreshSocial()
            await social.refreshShared()
            await social.refreshActivity()
            await account.refreshPartners()
        }
    }

    // MARK: - Shared commitments (NORTHSTAR §46)

    /// Invitations waiting on this user. An invitation obliges nobody — no
    /// Gate exists until the Deal is read and committed (invariant 31), so
    /// the accept path goes through the Deal sheet, never a one-tap yes.
    private var sharedInvitationsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Invitations").padding(.top, Theme.blockSpacing)
            // The most important thing on this screen when it exists, so it
            // gets the weight: a person's name at blocker size, the commitment
            // beneath it, and the one act filled. Someone is waiting on an
            // answer — an invitation that reads like a list row gets treated
            // like one.
            ForEach(social.sharedInvitations) { invitation in
                VStack(alignment: .leading, spacing: 0) {
                    ThickRule().padding(.top, 10)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(invitation.inviterDisplayName.uppercased()) INVITED YOU.")
                            .font(Theme.blocker(19)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invitation.title.uppercased())
                                .font(Theme.metric(22)).foregroundStyle(Theme.ink)
                            Text("\(invitation.terms.label) · by "
                                 + Format.deadline(invitation.terms.deadline, from: store.now))
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                        Text("Your Gate starts only if you accept.")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                        Button("READ THE DEAL") { readingInvitation = invitation }
                            .buttonStyle(PosterButtonStyle())
                            .padding(.top, 4)
                        Button("Decline") {
                            Task { await social.declineSharedInvitation(invitation) }
                        }
                        .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                    }
                    .padding(.vertical, 12)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    /// Shared commitments this user stands on: mutual visibility, printed —
    /// no ranking, no places, no team score.
    private var togetherBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Together").padding(.top, Theme.blockSpacing)
            ForEach(social.sharedCommitments) { shared in
                NavigationLink {
                    SharedCommitmentDetailView(sharedID: shared.id)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HairRule().padding(.top, 8)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shared.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(rosterLine(for: shared))
                                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if let mine = myLine(in: shared) {
                                Text(mine)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rosterLine(for shared: SharedCommitment) -> String {
        let accepted = shared.participants.filter(\.isAccepted)
        let done = accepted.filter(\.isDone).count
        let others = max(0, accepted.count - 1)
        let with = others == 0 ? "just you so far"
            : "you + \(others) other\(others == 1 ? "" : "s")"
        return "\(with) · \(done) of \(accepted.count) done · by "
            + Format.deadline(shared.terms.deadline, from: store.now)
    }

    /// This user's own figure, straight off their ledger — the one line here
    /// the phone can vouch for itself.
    private func myLine(in shared: SharedCommitment) -> String? {
        guard let mine = shared.myCommitmentID,
              let progress = store.state.progress(for: mine) else { return nil }
        return shared.terms.progressLine(progress: progress.achieved)
    }

    // MARK: - You

    @ViewBuilder
    /// You, in one line.
    ///
    /// This used to be a full profile card — avatar, name, handle, two
    /// scoreboard metrics and a sharing footnote — which put self-inspection
    /// above everything Social exists for. The tab answers *what are my people
    /// doing, and is anything waiting on me?*, and the answer to both was
    /// below the fold. The whole card still exists, one tap away, where
    /// looking at yourself is the point.
    private var youBlock: some View {
        if let profile = social.profileState.profile {
            let streaks = store.ledger.state.socialStreaks(now: store.now)
            NavigationLink {
                EditProfileView(profile: profile)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(avatarPath: profile.avatarPath,
                               displayName: profile.displayName, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("@\(profile.handle) · \(streaks.commitmentsKept) kept · "
                             + (streaks.sinceLastOverride == nil
                                ? "no Overrides yet"
                                : "\(streaks.sinceLastOverride!) since last Override"))
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your profile. \(profile.displayName), "
                                + "\(streaks.commitmentsKept) kept.")
        }
    }

    // MARK: - Waiting on you

    /// Override requests waiting on this user, as someone's accountability
    /// partner — the in-app counterpart of the web approval page, rendering
    /// the same frozen snapshot and casting the same vote. Signal color,
    /// because a clock is running on someone's phone.
    private var approvalsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Approvals", color: Theme.signal)
                .padding(.top, Theme.blockSpacing)
            ForEach(account.pendingApprovals) { approval in
                VStack(alignment: .leading, spacing: 0) {
                    ThickRule().padding(.top, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(approval.requesterName) is asking to be let out of a "
                             + "commitment.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(approval.title.uppercased())
                            .font(Theme.blocker(17)).foregroundStyle(Theme.ink)
                        if let achieved = approval.progressAchieved,
                           let required = approval.progressRequired, required > 0 {
                            Text("Progress: \(Int(achieved)) of \(Int(required)) "
                                 + (approval.progressUnit ?? ""))
                                .font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                        if let completed = approval.reliabilityCompleted,
                           let of = approval.reliabilityOf, of > 0 {
                            Text("\(completed) of their last \(of) commitments completed "
                                 + "(as reported by their phone).")
                                .font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                        if let reason = approval.reason {
                            Text("“\(reason)”").font(Theme.footnote).foregroundStyle(Theme.ink)
                        }
                        HStack(spacing: 12) {
                            Button("APPROVE") {
                                Task { await account.castVote(on: approval, approve: true) }
                            }
                            .buttonStyle(UnderlineButtonStyle())
                            Button("DENY") {
                                Task { await account.castVote(on: approval, approve: false) }
                            }
                            .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// People who want this user as *their* accountability partner. Consent
    /// is explicit and in-app — friendship never implied it (invariant 24).
    private var accountabilityBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Accountability").padding(.top, Theme.blockSpacing)
            ForEach(account.partnerRequests) { request in
                VStack(alignment: .leading, spacing: 0) {
                    ThickRule().padding(.top, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(request.requesterDisplayName) wants you as an "
                             + "accountability partner.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("@\(request.requesterHandle) may ask you to approve an "
                             + "Override. Being friends does not give you this role — "
                             + "saying yes here does.")
                            .font(Theme.footnote).foregroundStyle(Theme.muted)
                        HStack(spacing: 12) {
                            Button("I'M IN") {
                                Task { await account.respondToPartnerRequest(request,
                                                                             accept: true) }
                            }
                            .buttonStyle(UnderlineButtonStyle())
                            Button("NO THANKS") {
                                Task { await account.respondToPartnerRequest(request,
                                                                             accept: false) }
                            }
                            .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var requestsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Requests").padding(.top, Theme.blockSpacing)
            ForEach(social.requests.incoming) { person in
                VStack(alignment: .leading, spacing: 0) {
                    HairRule().padding(.top, 8)
                    HStack(spacing: 12) {
                        AvatarView(avatarPath: person.avatarPath,
                                   displayName: person.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text("@\(person.handle) wants to connect")
                                .font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("ACCEPT") {
                            Task { await social.respond(handle: person.handle, accept: true) }
                        }
                        .buttonStyle(UnderlineButtonStyle())
                        Button("DECLINE") {
                            Task { await social.respond(handle: person.handle, accept: false) }
                        }
                        .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                    }
                    .padding(.vertical, 10)
                }
            }
            ForEach(social.requests.outgoing) { person in
                VStack(alignment: .leading, spacing: 0) {
                    HairRule().padding(.top, 8)
                    HStack(spacing: 12) {
                        AvatarView(avatarPath: person.avatarPath,
                                   displayName: person.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text("asked · waiting")
                                .font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("CANCEL") {
                            Task { await social.cancelRequest(handle: person.handle) }
                        }
                        .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - People

    private var peopleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "People").padding(.top, Theme.blockSpacing)
            if social.friends.isEmpty {
                EmptyState(title: "NO FRIENDS YET",
                           message: "Add someone who'll notice when you keep your word.")
                    .padding(.top, 8)
                Button("+ ADD A FRIEND") { showingAdd = true }
                    .buttonStyle(UnderlineButtonStyle())
            } else {
                ForEach(social.friends) { person in
                    NavigationLink {
                        FriendProfileView(handle: person.handle)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HairRule().padding(.top, 8)
                            HStack(spacing: 12) {
                                AvatarView(avatarPath: person.avatarPath,
                                           displayName: person.displayName, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                    HStack(spacing: 6) {
                                        Text("@\(person.handle)")
                                        if let city = person.city { Text("· \(city)") }
                                    }
                                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                                    // A fact Earned observed, never a motive it
                                    // guessed (invariant 27).
                                    if let days = person.quietDays {
                                        Text("Hasn't checked in · \(days) "
                                             + "day\(days == 1 ? "" : "s")")
                                            .font(Theme.footnote)
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(.vertical, 10)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent

    /// The shelf: friends' recent, meaningful events, as the server curates
    /// them — bounded, 30 days, and then it ends. An empty shelf says so
    /// rather than inventing anything (docs/social-architecture.md §9).
    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Recent").padding(.top, Theme.blockSpacing)
            if social.activity.isEmpty {
                Text("Nothing yet. When friends share commitments, what they keep — and "
                     + "what they choose to tell — shows up here.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted)
                    .padding(.top, 8)
            } else {
                ForEach(social.activity) { event in
                    VStack(alignment: .leading, spacing: 0) {
                        HairRule().padding(.top, 8)
                        // Who and what happened, then what it was about, then
                        // when. Three facts, in that order, because a row that
                        // only manages "Someone committed: Run" makes the
                        // person less present rather than more.
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(avatarPath: event.avatarPath,
                                       displayName: event.displayName, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.headline)
                                    .font(.system(size: 13, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = event.detail {
                                    Text(detail)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.ink)
                                }
                                Text(Format.relative(event.occurredAt, from: store.now))
                                    .font(Theme.footnote)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
