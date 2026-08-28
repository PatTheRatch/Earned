import SwiftUI
import EarnedKit

/// First launch teaches the mental model, one concept per screen, and ends with
/// a configured Hydration Gate (NORTHSTAR §28).
struct OnboardingView: View {
    @EnvironmentObject private var store: EarnedStore

    private enum Page: Int, CaseIterable {
        case idea, gates, hydration, restrictions, activate
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
                Button(page == .activate ? "Activate Earned 🔒" : "Next") {
                    if page == .activate {
                        activate()
                    } else {
                        withAnimation { page = Page(rawValue: page.rawValue + 1) ?? .activate }
                    }
                }
                .buttonStyle(CommitButtonStyle(tint: .primary))
            }
        }
        .padding(28)
        .background(Theme.canvas)
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
                Text("💧 Hydration Gate").font(.title.weight(.semibold))
                Text("A behavioural interrupt, not a tracker. You just say you drank some water.")
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
                    Text("Outside these hours the Gate rests — no 3 AM nagging, and mornings "
                         + "start with a full interval.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

        case .restrictions:
            Screen(title: "What gets restricted",
                   message: "Instagram, YouTube, games, browsers, delivery apps — whatever you'd "
                       + "rather not reach for instead of living.\n\nChoosing the actual apps needs "
                       + "Apple's Screen Time permissions, which arrive in the next build. Until "
                       + "then Earned tracks your Gates and tells you exactly what would be locked.")

        case .activate:
            Screen(title: "The deal",
                   message: "Commitments can be corrected for a short window after you make them. "
                       + "After that they can get harder, never easier.\n\nMissing a deadline "
                       + "doesn't clear the obligation — it follows you until it's done or "
                       + "overridden.")
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
                Text(title).font(.largeTitle.weight(.semibold))
                Text(message).foregroundStyle(.secondary)
            }
            .padding(.top, 40)
        }
    }
}
