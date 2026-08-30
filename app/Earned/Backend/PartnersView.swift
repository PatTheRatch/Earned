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
                Button("Invite someone") { showingAdd = true }
            } footer: {
                Text("Earned sends the invitation itself. The link never passes through your "
                     + "phone — if it did, you could accept on their behalf, and the whole "
                     + "thing would be for show.")
            }

            if let failure = account.partnerFailure {
                Section { Text(failure).foregroundStyle(Theme.signal) }
            }
        }
        .paperList()
        .navigationTitle("Partners")
        .sheet(isPresented: $showingAdd) { InvitePartnerView() }
        .task { await account.refreshPartners() }
        .refreshable { await account.refreshPartners() }
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
            Text(partner.channel.label).font(.footnote).foregroundStyle(Theme.muted)

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
