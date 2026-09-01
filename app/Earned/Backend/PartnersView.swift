import SwiftUI

/// Managing accountability partners.
///
/// The screen's job beyond the list is to make one rule obvious before it bites:
/// a partner has to accept before they can be counted on. Someone who has been
/// asked and hasn't answered is *not* someone who will approve an override, and
/// a contract built on them would be dead from birth (invariant 22).
struct PartnersView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showingAdd = false

    var body: some View {
        List {
            if account.partners.isEmpty {
                Section {
                    Text("No accountability partners yet. Until someone accepts, your only way "
                         + "out of a hardened commitment is the Solo Override.")
                        .foregroundStyle(Theme.muted)
                }
            }

            if !account.partnerRequests.isEmpty {
                Section {
                    ForEach(account.partnerRequests) { request in
                        PartnerRequestRow(request: request)
                    }
                } header: {
                    Text("They're asking you")
                } footer: {
                    Text("These people want you as their accountability partner — able to "
                         + "approve an Override when they ask. Nothing happens until you answer.")
                }
            }

            ForEach(Partner.State.allDisplayed, id: \.self) { state in
                let group = account.partners.filter { $0.state == state }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { partner in PartnerRow(partner: partner) }
                    } header: {
                        Text(state.label)
                    } footer: {
                        Text(state.explanation)
                    }
                }
            }

            Section {
                Button("Add accountability partner") { showingAdd = true }
            } footer: {
                Text(Partner.contactInvitationsDeliverable
                     ? "A friend on Earned can be asked in-app. Anyone else gets one message "
                       + "with a link — Earned sends it itself, so the link never passes "
                       + "through your phone."
                     : "A friend on Earned can be asked in-app. Inviting someone who isn't "
                       + "on Earned isn't in this build.")
            }

            if let failure = account.partnerFailure {
                Section { Text(failure).foregroundStyle(Theme.signal) }
            }
        }
        .paperList()
        .navigationTitle("Partners")
        .sheet(isPresented: $showingAdd) { AddPartnerPickerView() }
        .task { await account.refreshPartners() }
        .refreshable { await account.refreshPartners() }
    }
}

/// An incoming ask, answerable here as well as on the Social tab — consent is
/// the whole decision, so it lives wherever the person is.
struct PartnerRequestRow: View {
    @EnvironmentObject private var account: AccountStore
    let request: PartnerRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(request.requesterDisplayName) wants you as an accountability partner.")
                .font(.headline)
            Text("@\(request.requesterHandle) may ask you to approve an Override on a "
                 + "commitment. Being friends does not give you this role automatically — "
                 + "saying yes here does.")
                .font(.footnote).foregroundStyle(Theme.muted)
            HStack(spacing: 12) {
                Button("I'm in") {
                    Task { await account.respondToPartnerRequest(request, accept: true) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.ink)
                Button("No thanks") {
                    Task { await account.respondToPartnerRequest(request, accept: false) }
                }
                .buttonStyle(.bordered).tint(Theme.muted)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private struct PartnerRow: View {
    @EnvironmentObject private var account: AccountStore
    let partner: Partner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(partner.displayName).font(.headline)
                Spacer()
                Text(partner.state.label)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(partner.state == .active ? Theme.ink : Theme.muted)
            }
            Text(partner.kind == .earnedUser
                 ? "Earned user" + (partner.handle.map { " · @\($0)" } ?? "")
                 : partner.channel.label)
                .font(.footnote).foregroundStyle(Theme.muted)

            HStack(spacing: 16) {
                if partner.canResend {
                    Button("Send a reminder") {
                        Task { await account.resendInvitation(to: partner) }
                    }
                    .font(.footnote)
                }
                if partner.state == .invited || partner.state == .active {
                    Button("Remove", role: .destructive) {
                        Task { await account.revokePartner(partner) }
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The two first-class ways in: a friend on Earned, asked in-app by their
/// authenticated identity — no number, no address — or anyone else, invited
/// by one message with a secure link. Both end at the same place: an explicit
/// yes, and only then a partner (invariant 22).
///
/// Deliberately not a search box: Social owns friend discovery, and the
/// candidate pool here is exactly the accepted friends it already produced.
struct AddPartnerPickerView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingExternal = false
    @State private var confirming: SocialPerson?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if social.profileState.profile == nil {
                        Text("Set up your profile on the Social tab to ask friends in-app."
                             + (Partner.contactInvitationsDeliverable
                                ? " Anyone can still be invited by text or email below." : ""))
                            .foregroundStyle(Theme.muted)
                    } else if social.friends.isEmpty {
                        Text("No friends on Earned yet. Add some from the Social tab"
                             + (Partner.contactInvitationsDeliverable
                                ? " — or invite anyone by text or email below." : "."))
                            .foregroundStyle(Theme.muted)
                    } else {
                        ForEach(social.friends) { friend in
                            friendRow(friend)
                        }
                    }
                } header: {
                    Text("People you know on Earned")
                } footer: {
                    Text("Asked in-app, by who they are — no phone number, no email. "
                         + "Being friends doesn't give anyone this authority; accepting does.")
                }

                Section {
                    if Partner.contactInvitationsDeliverable {
                        Button("Invite by text or email") { showingExternal = true }
                    } else {
                        Text("Not in this build. Earned can't send the invitation yet, and "
                             + "an ask nobody receives is a way out that was never going to "
                             + "open. Only friends on Earned can be partners for now.")
                            .foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Someone else")
                } footer: {
                    Text(Partner.contactInvitationsDeliverable
                         ? "They don't need an Earned account or the app — they can consent "
                           + "and approve from the web."
                         : "The Solo Override is unaffected: it needs nobody's permission and "
                           + "works with no signal at all.")
                }

                if let failure = account.partnerFailure {
                    Section { Text(failure).foregroundStyle(Theme.signal) }
                }
            }
            .paperList()
            .navigationTitle("Add partner")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingExternal) { InvitePartnerView() }
            .confirmationDialog(
                "Make \(confirming?.displayName ?? "this friend") an accountability partner?",
                isPresented: Binding(get: { confirming != nil },
                                     set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                Button("Send request") {
                    if let friend = confirming {
                        Task { await account.nominateEarnedPartner(handle: friend.handle) }
                    }
                    confirming = nil
                }
            } message: {
                Text("\(confirming?.displayName ?? "They") will be able to approve "
                     + "Accountability Overrides when you ask. Being friends does not give "
                     + "them this authority automatically.")
            }
        }
    }

    @ViewBuilder
    private func friendRow(_ friend: SocialPerson) -> some View {
        HStack(spacing: 12) {
            AvatarView(avatarPath: friend.avatarPath,
                       displayName: friend.displayName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                Text("@\(friend.handle) · Friend")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            switch account.earnedPartnerState(handle: friend.handle) {
            case .active:
                Text("PARTNER ✓")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.ink)
            case .invited:
                Text("REQUEST SENT")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.muted)
            default:
                // Never asked, declined, or revoked: a fresh ask is on offer.
                Button("Ask") { confirming = friend }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Nominating someone. The contact address is typed here, sent once, and never
/// comes back — the server normalises, encrypts and blind-indexes it, and the
/// app works in names and ids from then on.
private struct InvitePartnerView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var channel: Partner.Channel = .sms
    @State private var contact = ""
    @State private var sending = false

    private var canSend: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !contact.trimmingCharacters(in: .whitespaces).isEmpty
            && !sending
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Their name", text: $name)
                        .textContentType(.name)
                    Picker("Reach them by", selection: $channel) {
                        ForEach(Partner.Channel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField(channel.placeholder, text: $contact)
                        .keyboardType(channel == .sms ? .phonePad : .emailAddress)
                        .textContentType(channel == .sms ? .telephoneNumber : .emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(channel == .sms
                         ? "Include the country code, starting with +. Earned would rather "
                           + "refuse a number than guess at one and text a stranger."
                         : "They don't need the app or an account — just a link to tap.")
                }

                Section {
                    Button(sending ? "Sending…" : "Send invitation") { send() }
                        .disabled(!canSend)
                } footer: {
                    Text("They'll get one message asking whether they're in. If they say no, "
                         + "that's final: Earned won't contact them again, from this account "
                         + "or any other.")
                }

                if let failure = account.partnerFailure {
                    Section { Text(failure).foregroundStyle(Theme.signal) }
                }
            }
            .paperList()
            .navigationTitle("Invite a partner")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() {
        sending = true
        Task {
            await account.nominatePartner(displayName: name.trimmingCharacters(in: .whitespaces),
                                          channel: channel,
                                          contact: contact.trimmingCharacters(in: .whitespaces))
            sending = false
            if account.partnerFailure == nil { dismiss() }
        }
    }
}

extension Partner.State {
    static var allDisplayed: [Partner.State] { [.active, .invited, .declined, .revoked] }

    var explanation: String {
        switch self {
        case .active:
            return "Accepted. These are the only people a commitment can be built on."
        case .invited:
            return "Asked, no answer yet. They can't be added to a commitment until they "
                 + "accept — a threshold that counts on someone who never agreed isn't a "
                 + "way out, it just looks like one."
        case .declined:
            return "They said no. Earned won't contact them again, from any account."
        case .revoked:
            return "You removed them. Commitments already made keep the threshold you "
                 + "agreed to — removing someone never makes a standing deal easier."
        }
    }
}
