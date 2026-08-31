import SwiftUI

/// Where a commitment stands with the server, on the commitment's own screen.
///
/// Never presented as a sync spinner. The only thing the user needs from this
/// is whether the accountability route is available for *this* obligation, and
/// `late` is the case that actually costs them something.
///
/// (The old AccountSection this file was named for dissolved into the You tab
/// in the v2 rebuild; this row is what remains, where it was always used.)
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
