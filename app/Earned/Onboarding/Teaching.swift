import SwiftUI
import EarnedKit

/// The lessons onboarding no longer gives, and where they went instead.
///
/// Onboarding used to teach the whole product model before the user had seen
/// any of it: ten screens, four of them pure explanation, delivered to somebody
/// who had not yet watched a single app go dark. Most of that is not consent —
/// it is vocabulary, and vocabulary learned against nothing is vocabulary
/// forgotten. What genuinely has to be understood *before* Earned starts taking
/// access away stayed in the flow (docs/onboarding.md); the rest moved here, to
/// fire once, at the moment it first means something.
///
/// Each lesson is shown once and remembered. Deliberately in `UserDefaults`
/// rather than the ledger: the ledger is an append-only record of the deals a
/// person made, and "has read a tooltip" is not one of them. A reinstall
/// re-teaches, which is the right failure direction — repeating a card the user
/// has seen once costs a tap, and skipping one they have never seen costs them
/// the explanation entirely.
@MainActor
final class Teachings: ObservableObject {

    /// `Identifiable` so a lesson can drive a `sheet(item:)` directly — the
    /// raw value is already a stable unique key.
    enum Lesson: String, CaseIterable, Identifiable {
        var id: String { rawValue }

        /// The word "Gate", taught the first time one is actually open.
        case gate = "earned.taught.gate"
        /// What a missed deadline does — at the first missed deadline.
        case overdue = "earned.taught.overdue"
        /// The Override ladder, the first time somebody goes looking for a way out.
        case waysOut = "earned.taught.waysOut"
        /// Anti-circumvention advice, once enforcement has been felt to work.
        case passcode = "earned.taught.passcode"
        /// Why notifications are worth allowing — offered the first time this
        /// user has a relationship where somebody else is waiting on them, and
        /// never at launch, where there is nothing to be reachable *for*.
        case reachable = "earned.taught.reachable"
    }

    @Published private(set) var seen: Set<Lesson> = []

    init() {
        seen = Set(Lesson.allCases.filter { UserDefaults.standard.bool(forKey: $0.rawValue) })
    }

    func hasSeen(_ lesson: Lesson) -> Bool { seen.contains(lesson) }

    /// Idempotent, and safe to call from a view's `onAppear`.
    func markSeen(_ lesson: Lesson) {
        guard !seen.contains(lesson) else { return }
        UserDefaults.standard.set(true, forKey: lesson.rawValue)
        seen.insert(lesson)
    }

    #if DEBUG
    /// So the just-in-time cards can be walked more than once while testing.
    func forgetEverything() {
        Lesson.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.rawValue) }
        seen = []
    }
    #endif
}

/// One lesson, in the poster voice: a single declaration, a few factual lines,
/// one way out. Never more than one per screen, and never blocking anything the
/// user was trying to do — every one of these is dismissible and appears after
/// the thing it explains, not before.
struct TeachingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let word: String
    let lines: [String]
    var acknowledgement = "GOT IT"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Earned", color: Theme.ink)
                .padding(.top, 36)
            StateWord(word: word, size: 52)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        // Explanations are the one thing a card like this is
                        // for, so they wrap rather than shrink.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 20)
            Spacer()
            Button(acknowledgement) { dismiss() }
                .buttonStyle(PosterButtonStyle())
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }
}

/// Whether Earned can actually do the thing it exists to do.
///
/// Both halves are skippable in onboarding and both are genuinely optional, so
/// this is not a nag — it is the difference between an app that is enforcing
/// and an app that is only remembering, which Today must never blur
/// (NORTHSTAR §33).
struct SetupStatus: Equatable {
    var screenTimeOn: Bool
    var restrictionCount: Int

    var hasRestrictions: Bool { restrictionCount > 0 }
    /// Enforcement is only real when both are true: permission without a
    /// selection blocks nothing, and a selection without permission is a list
    /// nobody can act on.
    var isComplete: Bool { screenTimeOn && hasRestrictions }
}
