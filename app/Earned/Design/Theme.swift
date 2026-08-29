import SwiftUI
import UIKit

/// The Deadpan Poster system (docs/design-language.md): printed notice, boxing
/// poster, legal document. One loud voice — display type is reserved for state
/// words (LOCKED. / EARNED. / OVERDUE.); everything else stays quiet.
enum Theme {
    // Palette. Consequences get signal red; nothing else does.
    static let paper = Color(red: 0.949, green: 0.937, blue: 0.914)   // #F2EFE9
    static let ink = Color(red: 0.078, green: 0.071, blue: 0.063)     // #141210
    static let signal = Color(red: 0.910, green: 0.267, blue: 0.180)  // #E8442E
    static let muted = Color(red: 0.435, green: 0.416, blue: 0.380)   // #6F6A61
    static let field = Color(red: 0.918, green: 0.902, blue: 0.863)   // #EAE6DC

    /// Level 1: the state word. Compressed heavy caps — swap in a licensed
    /// condensed face here later without touching call sites.
    static func display(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .heavy).width(.compressed)
    }

    /// Level 2: the thing stopping you.
    static func blocker(_ size: CGFloat = 20) -> Font {
        Font.system(size: size, weight: .bold)
    }

    /// Small-caps section label (pair with .tracking(2.5) and uppercased text).
    static let label = Font.system(size: 11, weight: .bold)
}

/// The state word with the brand's red full stop: LOCKED. / EARNED. / OVERDUE.
struct StateWord: View {
    let word: String
    var size: CGFloat = 84

    var body: some View {
        (Text(word) + Text(".").foregroundStyle(Theme.signal))
            .font(Theme.display(size))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The thick ink rule that separates blocker rows. Used sparingly.
struct ThickRule: View {
    var color: Color = Theme.ink
    var body: some View {
        Rectangle().fill(color).frame(height: 4)
    }
}

struct SectionLabel: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(2.5)
            .foregroundStyle(color)
    }
}

/// Square-cornered ink block button, paper text. The one call to action per screen.
struct PosterButtonStyle: ButtonStyle {
    var background: Color = Theme.ink
    var foreground: Color = Theme.paper

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .tracking(2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(foreground)
            .contentShape(Rectangle())
    }
}

/// The Free Override as a physical-feeling ticket with perforation notches.
/// The 🎟 is the one emoji in the system — it's the brand's.
struct TicketView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("🎟").font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text("FREE OVERRIDE × \(count)")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.ink)
                Text("EARNED, NOT GIVEN.")
                    .font(Theme.label)
                    .tracking(2)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.field)
        .overlay(
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .foregroundStyle(Theme.muted)
        )
        .overlay(alignment: .leading) {
            Circle().fill(Theme.paper).frame(width: 14, height: 14).offset(x: -7)
        }
        .overlay(alignment: .trailing) {
            Circle().fill(Theme.paper).frame(width: 14, height: 14).offset(x: 7)
        }
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

    /// Paper background for native List screens.
    func paperList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.paper)
    }
}
