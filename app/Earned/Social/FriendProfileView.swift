import SwiftUI

/// Another person's identity card, as this user is allowed to see it. What
/// shows depends on the relationship; what never shows is anything they did
/// not choose to share.
struct FriendProfileView: View {
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    let handle: String

    /// Nil until the first lookup returns. The three loaded answers are
    /// distinct on purpose: a network failure that rendered as "NOBODY HERE"
    /// told a user their friend had vanished when the truth was a bad
    /// connection.
    @State private var lookup: SocialStore.ProfileLookup?
    @State private var confirmingRemove = false
    @State private var confirmingBlock = false
    @State private var confirmingNomination = false
    @State private var confirmingRevoke = false

    var body: some View {
        Group {
            switch lookup {
            case .found(let profile):
                card(profile)
            case .notFound:
                notice(title: "NOBODY HERE",
                       message: "No profile by that handle.")
            case .failed(let message):
                notice(title: "COULDN'T ASK",
                       message: "Earned couldn't reach the server, so it doesn't know "
                                + "whether this profile exists.",
                       detail: message,
                       retry: true)
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .task { await refresh() }
    }

    private func notice(title: String,
                        message: String,
                        detail: String? = nil,
                        retry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyState(title: title, message: message)
            if let detail {
                Text(detail).font(Theme.footnote).foregroundStyle(Theme.signal)
            }
            if retry {
                Button("TRY AGAIN") { Task { await refresh() } }
                    .buttonStyle(UnderlineButtonStyle())
            }
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func refresh() async {
        lookup = await social.lookUpProfile(handle: handle)
    }

    /// Give back the authority this person granted. A no-op if the row has
    /// already gone, which is the case when two devices do it at once.
    private func revokePartner(_ profile: PublicProfile) async {
        guard let partner = account.earnedPartner(handle: profile.handle) else { return }
        await account.revokePartner(partner)
    }

    /// Another person, in the same visual system as everything else.
    ///
    /// This was the last screen still built out of grouped-`List` chrome —
    /// a white profile card, then a white accountability card, then a white
    /// card of buttons — which made a friend look like a settings page. Open
    /// layout, hairlines and type instead; containers only where a container
    /// means something, which here is nowhere.
    private func card(_ profile: PublicProfile) -> some View {
        PosterPage {
            AvatarView(avatarPath: profile.avatarPath,
                       displayName: profile.displayName, size: 76)
                .padding(.top, 12)
            Text(profile.displayName.uppercased())
                .font(Theme.display(38)).foregroundStyle(Theme.ink)
                .lineLimit(2).minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Text("@\(profile.handle)" + (profile.city.map { " · \($0)" } ?? ""))
                .font(.system(size: 15)).foregroundStyle(Theme.muted)

            // Present only when this friend shares their figures — literal
            // wording, no ranking, no score.
            if let kept = profile.commitmentsKept {
                HairRule().padding(.top, Theme.blockSpacing)
                Metric(value: "\(kept) KEPT",
                       caption: profile.sinceLastOverride
                                    .map { "\($0) since last Override" } ?? "No Overrides yet",
                       size: 30)
                    .padding(.top, 14)
            }

            // What Earned observed, and nothing about why. "Deleted the app to
            // escape" is a sentence this screen cannot honestly render, so it
            // never will (docs/social-architecture.md §10).
            if let days = profile.quietDays {
                HairRule().padding(.top, Theme.blockSpacing)
                Text("HASN'T CHECKED IN")
                    .font(Theme.blocker(15)).foregroundStyle(Theme.ink)
                    .padding(.top, 14)
                Text("Last seen by Earned \(days) day\(days == 1 ? "" : "s") ago."
                     + (profile.openSharedCommitments.map { open in
                            open > 0 ? " \(open) shared commitment\(open == 1 ? " was" : "s were") "
                                     + "still open then." : "" } ?? ""))
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HairRule().padding(.top, Theme.blockSpacing)
            SectionLabel(text: relationshipLabel(profile.relationship))
                .padding(.top, 14)

            accountabilityBlock(profile)
            actionsBlock(profile)
        }
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
    private func accountabilityBlock(_ profile: PublicProfile) -> some View {
        if profile.relationship == .friend {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Accountability")
                switch account.earnedPartnerState(handle: profile.handle) {
                case .active:
                    Text("ACCOUNTABILITY PARTNER")
                        .font(Theme.blocker(15)).foregroundStyle(Theme.ink)
                    Text("Can approve your Overrides.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                    // Offered here because here is where you are thinking
                    // about this person. It existed only under You →
                    // Accountability partners, which is a different tab and a
                    // different mental model, so in practice the authority
                    // looked permanent once granted.
                    Button("Remove as accountability partner") {
                        confirmingRevoke = true
                    }
                    .buttonStyle(UnderlineButtonStyle(color: Theme.signal))
                    .padding(.top, 2)
                    .confirmationDialog(
                        "Remove \(profile.displayName) as an accountability partner?",
                        isPresented: $confirmingRevoke, titleVisibility: .visible
                    ) {
                        Button("Remove partner", role: .destructive) {
                            Task { await revokePartner(profile) }
                        }
                    } message: {
                        Text("They stop being able to approve your Overrides. This never "
                             + "makes an existing commitment easier — a commitment that "
                             + "drops below its agreed number of approvers loses the "
                             + "accountability route entirely rather than lowering it. "
                             + "You stay friends.")
                    }
                case .invited:
                    Text("REQUEST SENT")
                        .font(Theme.blocker(15)).foregroundStyle(Theme.ink)
                    Text("\(profile.displayName) hasn't accepted yet.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted)
                default:
                    Button("Make accountability partner") { confirmingNomination = true }
                        .buttonStyle(UnderlineButtonStyle())
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
            }
            .padding(.top, Theme.blockSpacing)
        }
    }

    @ViewBuilder
    private func actionsBlock(_ profile: PublicProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HairRule()
            switch profile.relationship {
            case .none:
                Button("Send friend request") {
                    Task { await social.sendRequest(handle: profile.handle); await refresh() }
                }
                .buttonStyle(UnderlineButtonStyle())
            case .pendingOutgoing:
                Button("Cancel request") {
                    Task { await social.cancelRequest(handle: profile.handle); await refresh() }
                }
                .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
            case .pendingIncoming:
                Button("ACCEPT") {
                    Task { await social.respond(handle: profile.handle, accept: true)
                           await refresh() }
                }
                .buttonStyle(PosterButtonStyle())
                Button("Decline") {
                    Task { await social.respond(handle: profile.handle, accept: false)
                           await refresh() }
                }
                .buttonStyle(UnderlineButtonStyle(color: Theme.muted))
            case .friend:
                Button("Remove friend") { confirmingRemove = true }
                    .buttonStyle(UnderlineButtonStyle(color: Theme.signal))
                    .confirmationDialog("Remove @\(profile.handle)?",
                                        isPresented: $confirmingRemove,
                                        titleVisibility: .visible) {
                        // Asked, not assumed. Friendship and override authority
                        // are consented to separately and on purpose
                        // (invariant 24), so unfriending cannot silently strip
                        // a permission this person gave you — but it must not
                        // silently keep it either, which is what happened: a
                        // friend removed and re-added came back still holding
                        // authority nobody had thought about since.
                        if account.earnedPartnerState(handle: profile.handle) == .active {
                            Button("Remove friend and partner", role: .destructive) {
                                Task {
                                    await revokePartner(profile)
                                    await social.removeFriend(handle: profile.handle)
                                    await refresh()
                                }
                            }
                            Button("Remove friend only", role: .destructive) {
                                Task { await social.removeFriend(handle: profile.handle)
                                       await refresh() }
                            }
                        } else {
                            Button("Remove friend", role: .destructive) {
                                Task { await social.removeFriend(handle: profile.handle)
                                       await refresh() }
                            }
                        }
                    } message: {
                        Text(account.earnedPartnerState(handle: profile.handle) == .active
                             ? "You stop seeing each other's shared things. "
                               + "\(profile.displayName) is also an accountability partner, "
                               + "which is a separate permission they gave you — removing "
                               + "the friendship does not take it back unless you say so. "
                               + "No message is sent either way."
                             : "You stop seeing each other's shared things. "
                               + "No message is sent.")
                    }
            case .blocked:
                Button("Unblock") {
                    Task { await social.unblock(handle: profile.handle); await refresh() }
                }
                .buttonStyle(UnderlineButtonStyle())
            }

            if profile.relationship != .blocked {
                Button("Block") { confirmingBlock = true }
                    .buttonStyle(UnderlineButtonStyle(color: Theme.signal))
                    .confirmationDialog("Block @\(profile.handle)?",
                                        isPresented: $confirmingBlock) {
                        Button("Block", role: .destructive) {
                            // Dismissing regardless was the worst version of
                            // this bug: the screen closed and the user believed
                            // they had blocked someone who could still see
                            // them. Staying put leaves the error on screen and
                            // the button to try again.
                            Task {
                                if await social.block(handle: profile.handle) {
                                    dismiss()
                                } else {
                                    await refresh()
                                }
                            }
                        }
                    } message: {
                        Text("You disappear from each other entirely — search, profiles, "
                             + "requests. They are not told.")
                    }
            }
        }
    }
}
