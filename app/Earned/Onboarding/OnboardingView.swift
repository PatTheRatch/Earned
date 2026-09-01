import SwiftUI
import FamilyControls
import EarnedKit

/// First launch teaches the mental model, one concept per screen, and ends with
/// a Gate that is actually holding something (NORTHSTAR §28).
///
/// **It used to end with an app that did nothing.** Onboarding configured the
/// Hydration Gate and stopped there: Screen Time was never asked for, no apps
/// were ever picked, so the first Today said LOCKED while blocking precisely
/// nothing, and the only way to a working product was for the user to guess
/// that two settings screens existed and go and find them. A commitment app
/// whose first impression is "nothing is owed and nothing is blocked" has
/// argued against itself before it starts.
///
/// So two pages here *do* something rather than explain something: the Screen
/// Time ask, and Apple's own app picker. They sit immediately after the page
/// that explains restriction, because asking for the permission before saying
/// what it is for is how permissions get refused — and because everything
/// after them is easier to agree to once the phone can already enforce.
///
/// Both are skippable and say so. Refusing leaves exactly the app that shipped
/// before: Gates tracked, nothing blocked, and an honest line about it.
struct OnboardingView: View {
    @EnvironmentObject private var store: EarnedStore

    private enum Page: Int, CaseIterable {
        case idea, gates, restrictions, screenTime, blocking, hydration,
             proof, ways, hardening, activate
    }

    @State private var page: Page = .idea
    @State private var interval = 60.0
    @State private var startHour = 8.0
    @State private var endHour = 22.0
    /// Hydration is a choice now, not an assumption. It stays on by default —
    /// it is the one Gate that needs no setup and no permission, and it is what
    /// makes the first day feel like the product works — but a user who does
    /// not want it should not have to go and turn off something they never
    /// agreed to.
    @State private var hydrationOn = true
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()
    /// What the user chose to lose. Applied to the Hydration Gate *and* as the
    /// default for commitments, because at this point in the product they have
    /// made exactly one decision about what optional means and it would be
    /// strange to ask again three screens later.
    @State private var restrictions: RestrictionProfile = .none

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
                // The two action pages own their screen's one filled button, so
                // the navigation yields to a quiet one and says what skipping
                // means. Two ink blocks side by side would make "move on"
                // compete with "grant the permission the app runs on" — and
                // the louder of the two would be the wrong one.
                if pageOwnsItsAction {
                    Button(advanceTitle) { advance() }
                        .buttonStyle(UnderlineButtonStyle())
                } else {
                    Button(advanceTitle) { advance() }
                        .buttonStyle(PosterButtonStyle())
                }
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

        case .screenTime:
            VStack(alignment: .leading, spacing: 18) {
                Text("TURN ON\nBLOCKING").font(Theme.display(44)).foregroundStyle(Theme.ink)
                    .lineSpacing(-4)
                Text("Earned blocks apps through Apple's Screen Time. Without it, Earned "
                     + "can still track every Gate and tell you exactly what would be "
                     + "locked — it just can't lock anything.")
                    .foregroundStyle(Theme.muted)
                switch store.shielding {
                case .approved:
                    Text("Screen Time is on. Earned can enforce your Gates.")
                        .font(.headline).foregroundStyle(Theme.ink)
                case .denied:
                    // Never dead-ended: iOS will not re-ask once refused, so
                    // the only honest next step is the Settings app.
                    Text("Screen Time is off. You can turn it on in iOS Settings, now or "
                         + "any time later.")
                        .foregroundStyle(Theme.signal)
                    Button("Open iOS Settings") { openSystemSettings() }
                        .buttonStyle(UnderlineButtonStyle())
                case .notDetermined:
                    Button("ALLOW SCREEN TIME") {
                        Task { await store.requestShieldingAuthorization() }
                    }
                    .buttonStyle(PosterButtonStyle())
                    Text("Apple asks, not us. You can withdraw it in iOS Settings at any "
                         + "time, and Earned will stop enforcing rather than pretend it "
                         + "still can.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                if let failure = store.shieldingFailure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                }
            }
            .padding(.top, 40)

        case .blocking:
            VStack(alignment: .leading, spacing: 18) {
                Text("WHAT YOU\nLOSE").font(Theme.display(44)).foregroundStyle(Theme.ink)
                    .lineSpacing(-4)
                Text("Pick the apps and sites that should go behind your Gates. Apple's "
                     + "picker keeps the choices private — Earned can block them without "
                     + "ever learning which ones they are.")
                    .foregroundStyle(Theme.muted)
                if store.shielding.canShield {
                    Button(shieldableCount == 0 ? "CHOOSE APPS" : "CHANGE SELECTION") {
                        selection = RestrictionBridge.selection(from: restrictions)
                        picking = true
                    }
                    .buttonStyle(shieldableCount == 0 ? PosterButtonStyle()
                                                      : PosterButtonStyle(background: Theme.field,
                                                                          foreground: Theme.ink))
                    Text(shieldableCount == 0
                         ? "Nothing picked yet. You can skip this and choose later."
                         : "\(shieldableCount) blocked while a Gate is unsatisfied.")
                        .font(.footnote)
                        .foregroundStyle(shieldableCount == 0 ? Theme.muted : Theme.ink)
                } else {
                    // One sentence of consequence, then the reassurance in the
                    // ordinary voice. A whole paragraph in signal red spends
                    // the loudest colour in the system on mostly-good news.
                    Text("Screen Time isn't on, so there's nothing to pick yet.")
                        .font(.headline).foregroundStyle(Theme.signal)
                    Text("Earned will still track your Gates and show you what would be "
                         + "locked. Come back to You → Restrictions when you're ready.")
                        .foregroundStyle(Theme.muted)
                }
                Text("Calls, messages, maps and music never go behind a Gate, whatever you "
                     + "pick here.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            .padding(.top, 40)
            .familyActivityPicker(isPresented: $picking, selection: $selection)
            .onChange(of: picking) { wasPicking, isPicking in
                // Commit when the picker closes, not on every tap inside it.
                if wasPicking && !isPicking {
                    restrictions = RestrictionBridge.profile(from: selection)
                }
            }

        case .hydration:
            VStack(alignment: .leading, spacing: 18) {
                Text("HYDRATION").font(Theme.display(44)).foregroundStyle(Theme.ink)
                Text("A behavioural interrupt, not a tracker. You just say you drank some water — "
                     + "and the day begins owing it.")
                    .foregroundStyle(.secondary)
                Toggle("Start with this Gate on", isOn: $hydrationOn)
                    .font(.headline)
                    .tint(Theme.ink)
                if hydrationOn {
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
                } else {
                    Text("You can turn it on later in You → Hydration. Without it, nothing "
                         + "is owed until you make your first commitment.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            }

        case .restrictions:
            Screen(title: "What gets restricted",
                   message: "Every Gate takes away its own things. An unmet workout can leave maps "
                       + "and music alone; unmet water can strip the phone back to calls and "
                       + "messages. Whatever is unsatisfied, you lose the sum of it.\n\nYou pick "
                       + "the apps in Apple's own picker, so Earned can block them without ever "
                       + "learning which ones they are.\n\nThe next two screens set that up. "
                       + "Both are optional, and Earned works without them — it just can't "
                       + "lock anything until they're done.")

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

    private var shieldableCount: Int { RestrictionBridge.shieldableCount(in: restrictions) }

    /// True while the page is asking for something the user has not yet done.
    /// Once they have, the page is finished and NEXT becomes the act again.
    private var pageOwnsItsAction: Bool {
        switch page {
        case .screenTime: return store.shielding == .notDetermined
        case .blocking:   return store.shielding.canShield && shieldableCount == 0
        default:          return false
        }
    }

    private var advanceTitle: String {
        if pageOwnsItsAction { return page == .screenTime ? "Not now" : "Skip for now" }
        return page == .activate ? "ACTIVATE EARNED" : "NEXT"
    }

    private func advance() {
        if page == .activate {
            activate()
        } else {
            withAnimation { page = Page(rawValue: page.rawValue + 1) ?? .activate }
        }
    }

    private func activate() {
        let hours = ActiveHours(startMinuteOfDay: Int(startHour) * 60,
                                endMinuteOfDay: Int(endHour) * 60,
                                timeZoneIdentifier: TimeZone.current.identifier)
        let config = HydrationConfig(enabled: hydrationOn,
                                     interval: interval * 60,
                                     activeHours: hours,
                                     // The picked apps are what the Hydration
                                     // Gate takes away, so the first locked day
                                     // locks something. Before this the Gate
                                     // was configured with `.none` and the
                                     // first Today read LOCKED over an empty
                                     // restriction profile.
                                     restrictions: restrictions,
                                     warningLead: 10 * 60)
        guard store.configureHydration(config) else { return }
        // And the same choice becomes the default for commitments. Asking again
        // three screens later, for a decision the user has just made once and
        // carefully, would read as the app not having listened.
        if shieldableCount > 0 { store.setDefaultRestrictions(restrictions) }
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
