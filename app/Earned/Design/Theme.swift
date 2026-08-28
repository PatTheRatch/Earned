import SwiftUI
import UIKit

/// Earned is firm but playful: plain type, generous space, one accent for
/// "locked" and one for "satisfied". Clarity beats cleverness (NORTHSTAR §31).
enum Theme {
    static let corner: CGFloat = 18

    static let locked = Color(red: 0.83, green: 0.31, blue: 0.26)
    static let satisfied = Color(red: 0.20, green: 0.60, blue: 0.40)
    static let waiting = Color(red: 0.55, green: 0.52, blue: 0.48)

    static let card = Color(uiColor: .secondarySystemBackground)
    static let canvas = Color(uiColor: .systemBackground)
}

/// A filled, full-width button for the one action a screen wants.
struct CommitButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
    }
}

extension View {
    func cardBackground() -> some View {
        padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Surfaces an EarnedKit refusal wherever it happens. Attach to any screen that
/// can append events — an alert only shows on the topmost presented view.
struct RejectionAlert: ViewModifier {
    @EnvironmentObject private var store: EarnedStore

    func body(content: Content) -> some View {
        content.alert("Not allowed",
                      isPresented: .constant(store.rejection != nil),
                      actions: { Button("OK", role: .cancel) { store.rejection = nil } },
                      message: { Text(store.rejection ?? "") })
    }
}

extension View {
    func rejectionAlert() -> some View { modifier(RejectionAlert()) }
}
