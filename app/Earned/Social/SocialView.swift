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
        }
        .task {
            await social.refreshProfile()
            await social.refreshSocial()
            await social.refreshActivity()
            await account.refreshPartners()
        }
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

            if !account.pendingApprovals.isEmpty { approvalsBlock }
            if !account.partnerRequests.isEmpty { accountabilityBlock }
            if !social.requests.isEmpty { requestsBlock }
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
            await social.refreshActivity()
            await account.refreshPartners()
        }
    }

    // MARK: - You

    @ViewBuilder
    private var youBlock: some View {
        if let profile = social.profileState.profile {
            let streaks = store.ledger.state.socialStreaks(now: store.now)
            NavigationLink {
                EditProfileView(profile: profile)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        AvatarView(avatarPath: profile.avatarPath,
                                   displayName: profile.displayName, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(Theme.blocker(18)).foregroundStyle(Theme.ink)
                            Text("@\(profile.handle)")
                                .font(Theme.footnote).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(alignment: .top, spacing: Theme.blockSpacing) {
                        Metric(value: "\(streaks.commitmentsKept) KEPT",
                               caption: "in a row, on time", size: 26)
                        Metric(value: streaks.sinceLastOverride.map { "\($0)" } ?? "—",
                               caption: streaks.sinceLastOverride == nil
                                        ? "no Overrides yet" : "since last Override",
                               size: 26)
                    }
                    .padding(.top, 14)
                    Text(profile.shareStreaks
                         ? "Friends see these numbers."
                         : "Only you see these numbers.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                        .padding(.top, 6)
                }
                .padding(.top, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(avatarPath: event.avatarPath,
                                       displayName: event.displayName, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                (Text(event.displayName).fontWeight(.semibold)
                                 + Text(" \(event.phrase)"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.ink)
                                Text(Format.relative(event.occurredAt, from: store.now))
                                    .font(Theme.footnote)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}
