import AuthenticationServices
import SwiftUI

/// Sign in, and what it is for.
///
/// Framed honestly: signing in does not make Earned work better today. It is
/// what a Contract Envelope hangs off, and the envelope is what stops the
/// approval threshold being something a modified app can simply state. Saying
/// "sync your data" would be selling a feature that does not exist yet.
struct AccountSection: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        Section {
            switch account.session {
            case .notConfigured:
                Text("No backend is configured for this build, so accountability partners "
                     + "aren't available yet. Everything else works as normal.")
                    .foregroundStyle(Theme.muted)

            case .signedOut:
                SignInWithAppleButton(.signIn,
                                      onRequest: account.prepareRequest,
                                      onCompletion: handle)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 46)

            case .signingIn:
                HStack(spacing: 10) { ProgressView(); Text("Signing in…") }

            case .signedIn(let name):
                LabeledContent("Signed in", value: name)
                registrationSummary
                Button("Sign out", role: .destructive) { account.signOut() }

            case .failed(let message):
                Text(message).foregroundStyle(Theme.signal)
                SignInWithAppleButton(.signIn,
                                      onRequest: account.prepareRequest,
                                      onCompletion: handle)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 46)
            }

            if let failure = account.syncFailure {
                Text(failure).font(.footnote).foregroundStyle(Theme.signal)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Accountability partners need an account, because the approval threshold has "
                 + "to be recorded somewhere this app can't edit. Earned registers only the "
                 + "terms — what's due, when it hardens, how many approvals — never your "
                 + "workouts, and never which apps you block.")
        }
    }

    /// A count rather than a list: the per-commitment answer lives on the
    /// commitment, where it can be acted on.
    @ViewBuilder
    private var registrationSummary: some View {
        let live = store.allCommitments.filter { $0.resolution == nil }
        let states = live.map { account.registration(of: $0.commitment) }
        let registered = states.filter { $0 == .registered }.count
        let late = states.filter { $0 == .late }.count
        let pending = states.filter { $0 == .pending }.count

        LabeledContent("Commitments registered",
                       value: "\(registered) of \(states.count)")
        if pending > 0 {
            Text("\(pending) waiting to register.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        if late > 0 {
            Text("\(late) registered too late to use accountability partners. "
                 + "The Solo Override still works for those.")
                .font(.footnote).foregroundStyle(Theme.signal)
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        account.completeSignIn(result)
        Task { await account.syncEnvelopes(for: store.allCommitments, now: store.now) }
    }
}

/// Where a commitment stands with the server, on the commitment's own screen.
///
/// Never presented as a sync spinner. The only thing the user needs from this
/// is whether the accountability route is available for *this* obligation, and
/// `late` is the case that actually costs them something.
struct RegistrationRow: View {
    let registration: AccountStore.Registration

    var body: some View {
        switch registration {
        case .unavailable:
            EmptyView()
        case .registered:
            LabeledContent("Partners", value: "Available")
        case .pending:
            LabeledContent("Partners") {
                Text("Registering…").foregroundStyle(Theme.muted)
            }
        case .late:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Partners") {
                    Text("Unavailable").foregroundStyle(Theme.signal)
                }
                Text("This commitment hardened before Earned could register it, so its terms "
                     + "were never recorded anywhere you can't edit. Asking partners is off "
                     + "for this one. The Solo Override still works.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Partners") {
                    Text("Not registered").foregroundStyle(Theme.signal)
                }
                Text(reason).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}
