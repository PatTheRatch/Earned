import AuthenticationServices
import SwiftUI

/// The Social tab: people, and — later — meaningful recent activity.
///
/// Deliberately a printed roster, not a feed (NORTHSTAR §45). It holds the
/// user's identity, their friends, and the requests in flight; the Recent
/// area ships empty and honest until commitment sharing exists. Nothing here
/// is required for Earned to work — the Gates neither know nor care.
struct SocialView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore

    @State private var showingAdd = false
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            Group {
                switch account.session {
                case .notConfigured:
                    explainer("No backend is configured for this build, so there is nobody to "
                              + "connect to yet. Everything else works as normal.")
                case .signedOut, .failed:
                    signedOut
                case .signingIn:
                    ProgressView()
                case .signedIn:
                    signedIn
                }
            }
            .background(Theme.paper)
            .navigationTitle("Social")
            .sheet(isPresented: $showingAdd) { AddFriendView() }
            .sheet(isPresented: $showingSetup) { ProfileSetupView() }
        }
        .task {
            await social.refreshProfile()
            await social.refreshSocial()
        }
    }

    // MARK: - Pre-profile states

    private func explainer(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Social")
            Text("Make a promise visible, and walking away from it starts to weigh something.")
                .font(Theme.blocker())
                .foregroundStyle(Theme.ink)
            Text(message).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Social")
            Text("Make a promise visible, and walking away from it starts to weigh something.")
                .font(Theme.blocker())
                .foregroundStyle(Theme.ink)
            Text("Friends are people you choose. They see what you choose to share — and "
                 + "nothing gives anyone authority over your commitments. Sign in to set up "
                 + "your profile.")
                .foregroundStyle(Theme.muted)
            SignInWithAppleButton(.signIn,
                                  onRequest: account.prepareRequest,
                                  onCompletion: handleSignIn)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 46)
            if case .failed(let message) = account.session {
                Text(message).font(.footnote).foregroundStyle(Theme.signal)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(text: "Your profile")
                Text("YOU NEED A NAME FIRST.")
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.ink)
                Text("A profile is a display name and a handle. A photo and a city are "
                     + "optional. That's it — this is an identity card, not a questionnaire.")
                    .foregroundStyle(Theme.muted)
                Button("SET UP YOUR PROFILE") { showingSetup = true }
                    .buttonStyle(PosterButtonStyle())
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List {
                myProfileSection
                if !social.requests.isEmpty { requestsSection }
                friendsSection
                recentSection
            }
            .paperList()
            .refreshable {
                await social.refreshProfile()
                await social.refreshSocial()
            }
            .toolbar {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add friend", systemImage: "plus")
                }
            }
            .overlay(alignment: .bottom) {
                if let failure = social.failure {
                    Text(failure)
                        .font(.footnote).foregroundStyle(Theme.paper)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Theme.signal)
                }
            }
        }
    }

    @ViewBuilder
    private var myProfileSection: some View {
        if let profile = social.profileState.profile {
            Section {
                NavigationLink {
                    EditProfileView(profile: profile)
                } label: {
                    HStack(spacing: 14) {
                        AvatarView(avatarPath: profile.avatarPath,
                                   displayName: profile.displayName, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName).font(Theme.blocker(17))
                            Text("@\(profile.handle)")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("My profile")
            }
        }
    }

    private var requestsSection: some View {
        Section {
            ForEach(social.requests.incoming) { person in
                HStack(spacing: 12) {
                    AvatarView(avatarPath: person.avatarPath,
                               displayName: person.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName)
                        Text("@\(person.handle)").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Accept") {
                        Task { await social.respond(handle: person.handle, accept: true) }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                    Button("Decline") {
                        Task { await social.respond(handle: person.handle, accept: false) }
                    }
                    .buttonStyle(.bordered).tint(Theme.muted)
                }
                .buttonStyle(.borderless)  // keep row tap from swallowing both
            }
            ForEach(social.requests.outgoing) { person in
                HStack(spacing: 12) {
                    AvatarView(avatarPath: person.avatarPath,
                               displayName: person.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName)
                        Text("asked · waiting").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Cancel") {
                        Task { await social.cancelRequest(handle: person.handle) }
                    }
                    .buttonStyle(.borderless).tint(Theme.muted)
                }
            }
        } header: {
            Text("Requests")
        }
    }

    private var friendsSection: some View {
        Section {
            if social.friends.isEmpty {
                Text("Nobody yet. A friend is someone who'll notice when you keep your word — "
                     + "add one by their handle.")
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(social.friends) { person in
                    NavigationLink {
                        FriendProfileView(handle: person.handle)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(avatarPath: person.avatarPath,
                                       displayName: person.displayName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                HStack(spacing: 6) {
                                    Text("@\(person.handle)")
                                    if let city = person.city { Text("· \(city)") }
                                }
                                .font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Friends")
        }
    }

    /// S1 ships this empty, and says so. No events exist yet, and none are
    /// invented here — commitment sharing is the next milestone
    /// (docs/social-architecture.md §9).
    private var recentSection: some View {
        Section {
            Text("Nothing yet. When commitment sharing ships, the promises your friends "
                 + "choose to share will show up here — kept, missed, and overridden alike.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        } header: {
            Text("Recent")
        }
    }
}
