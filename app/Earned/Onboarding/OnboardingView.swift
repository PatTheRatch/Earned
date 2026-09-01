import SwiftUI
import EarnedKit

/// First launch teaches the mental model, one concept per screen, and ends with
/// a configured Hydration Gate (NORTHSTAR §28).
struct OnboardingView: View {
    @EnvironmentObject private var store: EarnedStore

    private enum Page: Int, CaseIterable {
        case idea, gates, hydration, restrictions, proof, ways, hardening, activate
    }

    @State private var page: Page = .idea
    @State private var interval = 60.0
    @State private var startHour = 8.0
    @State private var endHour = 22.0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
            Spacer()
            HStack(spacing: 12) {
                if page != .idea {
                    Button("Back") {
                        withAnimation { page = Page(rawValue: page.rawValue - 1) ?? .idea }
                    }
                    .font(.headline)
                    .padding(.vertical, 16).padding(.horizontal, 20)
                }
                Button(page == .activate ? "ACTIVATE EARNED" : "NEXT") {
                    if page == .activate {
                        activate()
                    } else {
                        withAnimation { page = Page(rawValue: page.rawValue + 1) ?? .activate }
                    }
                }
                .buttonStyle(PosterButtonStyle())
            }
        }
        .padding(28)
        .background(Theme.paper)
        .rejectionAlert()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .idea:
            Screen(title: "Do what matters first.",
                   message: "Earned puts the optional parts of your phone behind commitments you make "
                       + "to yourself. You decide the deal while thinking clearly. Earned remembers "
                       + "it later, when you'd rather not.")

        case .gates:
            Screen(title: "Gates",
                   message: "A Gate is something you decided matters more than optional phone use. "
                       + "Drink some water. Complete a workout.\n\nEvery active Gate must be "
                       + "satisfied for full access. Calls, messages, maps and music never go "
                       + "behind a Gate.")

        case .hydration:
            VStack(alignment: .leading, spacing: 18) {
                Text("HYDRATION").font(Theme.display(44)).foregroundStyle(Theme.ink)
                Text("A behavioural interrupt, not a tracker. You just say you drank some water — "
                     + "and the day begins owing it.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every \(Int(interval)) minutes").font(.headline)
                    Slider(value: $interval, in: 15...240, step: 15)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active \(Format.timeOfDay(Int(startHour) * 60)) – "
                         + "\(Format.timeOfDay(Int(endHour) * 60))").font(.headline)
                    HStack {
                        Slider(value: $startHour, in: 0...12, step: 1)
                        Slider(value: $endHour, in: 13...24, step: 1)
                    }
                    Text("Outside these hours the Gate rests — no 3 AM nagging. Inside them it "
                         + "opens closed: the day starts locked until the first glass of water.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

        case .restrictions:
            Screen(title: "What gets restricted",
                   message: "Every Gate takes away its own things. An unmet workout can leave maps "
                       + "and music alone; unmet water can strip the phone back to calls and "
                       + "messages. Whatever is unsatisfied, you lose the sum of it.\n\nYou pick "
                       + "the apps in Apple's own picker, so Earned can block them without ever "
                       + "learning which ones they are. Grant Screen Time access in Settings when "
                       + "you're ready — until you do, Earned tracks your Gates and tells you "
                       + "exactly what would be locked.")

        // Health and the Overrides were both absent from onboarding, and both
        // are things a first-time user has to know before they agree to
        // anything: one is a permission Earned will ask for, the other is the
        // reason agreeing is safe.
        case .proof:
            Screen(title: "Proving you did it",
                   message: "A workout counts when Apple Health has it. Earned will ask to "
                       + "read finished workouts — a run from your watch, the Fitness app, "
                       + "or Strava synced into Health. It reads nothing else and writes "
                       + "nothing back.\n\nPer commitment you choose whether your own word "
                       + "counts or only a workout another app recorded. Without Health "
                       + "access, nothing can complete a commitment — only an Override can "
                       + "end one.")

        case .ways:
            Screen(title: "Ways out",
                   message: "You are never trapped. Every commitment has three exits, and "
                       + "all of them work on this phone with no signal and nobody else "
                       + "involved:\n\nA Free Override, earned by keeping commitments on "
                       + "time.\n\nA Solo Override, available after a wait you choose, "
                       + "behind deliberate effort.\n\nOr asking someone you nominated to "
                       + "release you early — the only exit that needs other people, and "
                       + "the only one Earned's servers touch.\n\nCommitments, water, debt "
                       + "and restrictions all live on this phone. Friends and partners "
                       + "only ever see what you choose to share with them.")

        case .hardening:
            Screen(title: "Make Earned harder to escape",
                   message: "Earned enforces your Gates using Screen Time — but iOS still lets "
                       + "you revoke that permission, and no app can change that. Earned will "
                       + "never pretend otherwise.\n\nFor real accountability, set a Screen "
                       + "Time passcode you can't easily reach for: give it to someone who will "
                       + "hold you to it, store it somewhere deliberately inconvenient, or use a "
                       + "random code you don't memorise.\n\nEarned never sees, stores or "
                       + "transmits that passcode — it's yours alone, and it can't be recovered "
                       + "from here. This is a recommendation, not a requirement.")

        case .activate:
            Screen(title: "The deal",
                   message: "Commitments can be corrected for a short window after you make them. "
                       + "After that they can get harder, never easier.\n\nMissing a deadline "
                       + "doesn't clear the obligation — it follows you until it's done or "
                       + "overridden.\n\nEverything Earned takes away, you are choosing to "
                       + "let it take away. Every permission it asks for is yours to refuse "
                       + "and yours to withdraw in iOS Settings at any time — and if you "
                       + "withdraw one, Earned stops enforcing rather than pretending it "
                       + "still can.")
        }
    }

    private func activate() {
        let hours = ActiveHours(startMinuteOfDay: Int(startHour) * 60,
                                endMinuteOfDay: Int(endHour) * 60,
                                timeZoneIdentifier: TimeZone.current.identifier)
        let config = HydrationConfig(enabled: true,
                                     interval: interval * 60,
                                     activeHours: hours,
                                     warningLead: 10 * 60)
        guard store.configureHydration(config) else { return }
        store.hasOnboarded = true
    }

    private struct Screen: View {
        let title: String
        let message: String

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(title.uppercased())
                    .font(Theme.display(44))
                    .foregroundStyle(Theme.ink)
                Text(message).foregroundStyle(Theme.muted)
            }
            .padding(.top, 40)
        }
    }
}
