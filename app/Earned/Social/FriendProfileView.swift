import SwiftUI

/// Another person's identity card, as this user is allowed to see it. What
/// shows depends on the relationship; what never shows is anything they did
/// not choose to share.
struct FriendProfileView: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    let handle: String

    @State private var profile: PublicProfile?
    @State private var loaded = false
    @State private var confirmingRemove = false
    @State private var confirmingBlock = false
    @State private var confirmingNomination = false

    var body: some View {
        Group {
            if let profile {
                card(profile)
            } else if loaded {
                VStack(spacing: 12) {
                    Text("NOBODY HERE")
                        .font(Theme.display(34)).foregroundStyle(Theme.ink)
                    + Text(".").font(Theme.display(34)).foregroundStyle(Theme.signal)
                    Text("No profile by that handle.")
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .task { await refresh() }
    }

    private func refresh() async {
        profile = await social.profile(handle: handle)
        loaded = true
    }

    private func card(_ profile: PublicProfile) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    AvatarView(avatarPath: profile.avatarPath,
                               displayName: profile.displayName, size: 88)
                    Text(profile.displayName)
                        .font(Theme.display(34)).foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        Text("@\(profile.handle)")
                        if let city = profile.city { Text("· \(city)") }
                    }
                    .font(Theme.blocker(16))
                    .foregroundStyle(Theme.muted)
                    // Present only when this friend shares their figures —
                    // literal wording, no ranking, no score.
                    if let kept = profile.commitmentsKept {
                        ThickRule()
                        Text("\(kept) COMMITMENT" + (kept == 1 ? "" : "S") + " KEPT")
                            .font(Theme.blocker(16))
                            .foregroundStyle(Theme.ink)
                        Text(profile.sinceLastOverride.map { "\($0) since last Override" }
                             ?? "No Overrides yet")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    // The quiet block: what Earned observed, and nothing about
                    // why. "Deleted the app to escape" is a sentence this
                    // screen cannot honestly render, so it never will
                    // (docs/social-architecture.md §10).
                    if let days = profile.quietDays {
                        ThickRule()
                        Text("HASN'T CHECKED IN")
                            .font(Theme.blocker(16))
                            .foregroundStyle(Theme.ink)
                        Text("Last seen by Earned \(days) day\(days == 1 ? "" : "s") ago.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                        if let open = profile.openSharedCommitments, open > 0 {
                            Text("\(open) shared commitment\(open == 1 ? " was" : "s were") "
                                 + "still open at their last check-in.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    SectionLabel(text: relationshipLabel(profile.relationship))
                }
                .padding(.vertical, 8)
            }

            accountabilitySection(profile)

            actions(profile)
        }
        .paperList()
        .navigationTitle("@\(profile.handle)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func relationshipLabel(_ relationship: PublicProfile.Relationship) -> String {
        switch relationship {
        case .friend: return "Friend"
        case .pendingIncoming: return "Wants to connect"
        case .pendingOutgoing: return "Asked · waiting"
        case .blocked: return "Blocked"
        case .none: return "Not connected"
        }
    }

    /// Where this friend stands on the *other* axis. Friendship gives social
    /// visibility; this block is about override authority, granted only by
    /// their explicit yes (invariant 24) — so an ordinary friend is never
    /// labelled a partner here, only offered as one.
    @ViewBuilder
    private func accountabilitySection(_ profile: PublicProfile) -> some View {
        if profile.relationship == .friend {
            Section {
                switch account.earnedPartnerState(handle: profile.handle) {
                case .active:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ACCOUNTABILITY PARTNER ✓").font(Theme.blocker(15))
                        Text("Can approve your Overrides.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                case .invited:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("REQUEST SENT").font(Theme.blocker(15))
                        Text("\(profile.displayName) hasn't accepted yet.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                default:
                    Button("Make accountability partner") { confirmingNomination = true }
                        .confirmationDialog(
                            "Make \(profile.displayName) an accountability partner?",
                            isPresented: $confirmingNomination,
                            titleVisibility: .visible
                        ) {
                            Button("Send request") {
                                Task {
                                    await account.nominateEarnedPartner(handle: profile.handle)
                                }
                            }
                        } message: {
                            Text("\(profile.displayName) will be able to approve "
                                 + "Accountability Overrides when you ask. Being friends "
                                 + "does not give them this authority automatically.")
                        }
                }
            } header: {
                Text("Accountability")
            }
        }
    }

    @ViewBuilder
    private func actions(_ profile: PublicProfile) -> some View {
        Section {
            switch profile.relationship {
            case .none:
                Button("Send friend request") {
                    Task { await social.sendRequest(handle: profile.handle); await refresh() }
                }
            case .pendingOutgoing:
                Button("Cancel request", role: .destructive) {
                    Task { await social.cancelRequest(handle: profile.handle); await refresh() }
                }
            case .pendingIncoming:
                Button("Accept") {
                    Task { await social.respond(handle: profile.handle, accept: true)
                           await refresh() }
                }
                Button("Decline", role: .destructive) {
                    Task { await social.respond(handle: profile.handle, accept: false)
                           await refresh() }
                }
            case .friend:
                Button("Remove friend", role: .destructive) { confirmingRemove = true }
                    .confirmationDialog("Remove @\(profile.handle)?",
                                        isPresented: $confirmingRemove) {
                        Button("Remove friend", role: .destructive) {
                            Task { await social.removeFriend(handle: profile.handle)
                                   await refresh() }
                        }
                    } message: {
                        Text("You stop seeing each other's shared things. No message is sent.")
                    }
            case .blocked:
                Button("Unblock") {
                    Task { await social.unblock(handle: profile.handle); await refresh() }
                }
            }

            if profile.relationship != .blocked {
                Button("Block", role: .destructive) { confirmingBlock = true }
                    .confirmationDialog("Block @\(profile.handle)?",
                                        isPresented: $confirmingBlock) {
                        Button("Block", role: .destructive) {
                            Task { await social.block(handle: profile.handle)
                                   dismiss() }
                        }
                    } message: {
                        Text("You disappear from each other entirely — search, profiles, "
                             + "requests. They are not told.")
                    }
            }
        }
    }
}
