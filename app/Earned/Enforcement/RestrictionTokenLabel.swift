import SwiftUI
import FamilyControls
import ManagedSettings
import EarnedKit

/// One restricted item, rendered the way a human should see it.
///
/// Apple's Screen Time tokens are opaque to Earned by design (NORTHSTAR §34):
/// the app can shield what you picked without ever learning what it is. But
/// FamilyControls ships `Label(_:)` views that the *system* fills in with the
/// item's real name and icon — on screen for the user, still unreadable to the
/// app. This view exists because the alternative, printing the serialized
/// token, shows a person eight lines of base64 where "Games" should be.
struct RestrictionTokenLabel: View {
    let token: RestrictionToken

    var body: some View {
        switch RestrictionBridge.display(token) {
        case .application(let token):
            Label(token)
        case .category(let token):
            Label(token)
        case .webDomain(let token):
            Label(token)
        case .legacy(let name):
            // A pre-picker placeholder: a name the user typed, blocking nothing.
            HStack {
                Text(name).foregroundStyle(Theme.muted)
                Spacer()
                Text("NOT BLOCKING")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.signal)
            }
        }
    }
}
