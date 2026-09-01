import SwiftUI
import FamilyControls
import EarnedKit

/// First run: make Earned functional, with informed consent, and stop.
///
/// **Phase 1 is setup; Phase 2 is the product teaching itself** (see
/// `docs/onboarding.md`). This flow used to be ten pages, four of them pure
/// explanation, delivered to somebody who had not yet watched a single app go
/// dark. Vocabulary learned against nothing is vocabulary forgotten, and the
/// price of front-loading it is paid by every user who quits before granting the
/// one permission the product runs on.
///
/// What stayed is what a person must knowingly have seen *before* Earned starts
/// removing access: that it blocks apps they choose, through Screen Time, that
/// calls and messages never go; that a commitment hardens after a correction
/// window and a missed deadline does not erase it; that there is always a way
/// out; and that the permission is theirs to withdraw. Everything else — the
/// word "Gate", Health provenance, the Override ladder, passcode strategy —
/// moved to `Teachings`, to arrive the first time it means something.
///
/// The order is a dependency, not a preference: explain restriction, then ask
/// for the permission, then choose what it applies to. A permission asked
/// before its reason is a permission refused, and a picker shown before the
/// permission is a dead control.
struct OnboardingView: View {
    @EnvironmentObject private var store: EarnedStore

    private enum Page: Int, CaseIterable {
        case product, blocked, screenTime, picker, hydration, deal
    }

    @State private var page: Page = .product
    @State private var showingHowItWorks = false

    // Hydration keeps sensible defaults and hides its dials. A first-time user
    // should not have to operate three sliders to finish setup, and every value
    // here is changeable later in You → Hydration.
    @State private var hydrationOn = true
    @State private var showingHydrationDetail = false
    @State private var interval = 60.0
    @State private var startHour = 8.0
    @State private var endHour = 22.0

    @State private var picking = false
    @State private var selection = FamilyActivitySelection()
    /// What the user chose to lose. Becomes the Hydration Gate's own profile
    /// *and* the default for new commitments — one decision, made once,
    /// carefully, and not asked for again two screens later.
    @State private var restrictions: RestrictionProfile = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
            Spacer()
            navigation
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .rejectionAlert()
        .sheet(isPresented: $showingHowItWorks) { howItWorks }
        .sheet(isPresented: $showingHydrationDetail) { hydrationDetail }
        .familyActivityPicker(isPresented: $picking, selection: $selection)
        .onChange(of: picking) { wasPicking, isPicking in
            // Commit when the picker closes, not on every tap inside it.
            if wasPicking && !isPicking {
                restrictions = RestrictionBridge.profile(from: selection)
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .product:   productPage
        case .blocked:   blockedPage
        case .screenTime: screenTimePage
        case .picker:    pickerPage
        case .hydration: hydrationPage
        case .deal:      dealPage
        }
    }

    /// One idea: you make a promise, and until you keep it the phone is smaller.
    /// The word "Gate" is deliberately absent — it is the internal noun for
    /// something the user cannot see yet, and it is not needed to decide whether
    /// to grant Screen Time.
    private var productPage: some View {
        Page1(
            word: "DO WHAT\nMATTERS FIRST",
            lines: ["Make a commitment.",
                    "Until you keep it, Earned can block the apps you chose.",
                    "Calls, messages, maps and music stay available."],
            secondary: ("How Earned works", { showingHowItWorks = true }))
    }

    private var blockedPage: some View {
        Page1(
            word: "YOU CHOOSE\nWHAT GOES",
            lines: ["Earned only restricts apps and categories you select.",
                    "Apple's picker keeps those choices private. Earned receives "
                        + "opaque selections, not a readable list of your apps.",
                    "Calls, messages, maps and music remain available."],
            secondary: nil)
    }

    /// The pivotal permission, and the only screen whose filled button is a
    /// system dialog. Declining is a first-class outcome with its own state,
    /// never a dead end and never shamed.
    private var screenTimePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch store.shielding {
            case .denied:
                StateWord(word: "SCREEN TIME IS OFF", size: 40, lines: 2)
                Text("Earned cannot enforce restrictions until you turn it on.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OPEN SETTINGS") { openSystemSettings() }
                    .buttonStyle(PosterButtonStyle())
            case .approved:
                StateWord(word: "BLOCKING IS ON", size: 40, lines: 2)
                Text("Earned can apply the restrictions you choose next.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .notDetermined:
                StateWord(word: "TURN ON BLOCKING", size: 40, lines: 2)
                Text("Earned uses Apple Screen Time to apply the restrictions you choose.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Without this permission, Earned can remember your commitments but "
                     + "cannot hold the apps closed.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // Apple's dialog appears only after this, never on arrival.
                Button("TURN ON SCREEN TIME") {
                    Task { await store.requestShieldingAuthorization() }
                }
                .buttonStyle(PosterButtonStyle())
            }
            if let failure = store.shieldingFailure {
                Text(failure).font(.footnote).foregroundStyle(Theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 36)
    }

    /// Three honest states, because a picker with no permission behind it is a
    /// control that does nothing and an empty selection is not a configured app.
    private var pickerPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.shielding.canShield {
                StateWord(word: "BLOCKING ISN'T ON YET", size: 36, lines: 2)
                Text("Turn on Screen Time before choosing restricted apps.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("TURN ON SCREEN TIME") {
                    Task { await store.requestShieldingAuthorization() }
                }
                .buttonStyle(PosterButtonStyle())
            } else if shieldableCount > 0 {
                StateWord(word: "RESTRICTIONS SET", size: 40, lines: 2)
                Text("\(shieldableCount) selected. These become the default for new "
                     + "commitments, and what an unmet water check takes away.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Change selection") { beginPicking() }
                    .buttonStyle(UnderlineButtonStyle())
            } else {
                StateWord(word: "WHAT DO YOU LOSE?", size: 36, lines: 2)
                Text("Choose the distractions Earned should hold back while something "
                     + "is owed. You can change this later.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("CHOOSE APPS") { beginPicking() }
                    .buttonStyle(PosterButtonStyle())
            }
        }
        .padding(.top, 36)
    }

    /// Optional, and framed as optional. Hydration is a useful first Gate, not
    /// the product thesis, and the dials are behind a disclosure because
    /// precision configuration is not a first-run decision.
    private var hydrationPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            StateWord(word: "WATER CHECKS", size: 44)
            Text("Earned can periodically ask you to confirm you drank water. If a check "
                 + "becomes overdue, your chosen restrictions apply until you confirm.")
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Water checks", isOn: $hydrationOn)
                .font(.system(size: 16, weight: .semibold))
                .tint(Theme.ink)
            if hydrationOn {
                HairRule()
                ReceiptRow(label: "EVERY", value: "\(Int(interval)) min")
                ReceiptRow(label: "ACTIVE",
                           value: "\(Format.timeOfDay(Int(startHour) * 60)) – "
                                + "\(Format.timeOfDay(Int(endHour) * 60))")
                HairRule()
                Button("Customize") { showingHydrationDetail = true }
                    .buttonStyle(UnderlineButtonStyle())
            } else {
                Text("Fine to leave off. You can turn it on later in You → Hydration.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 36)
    }

    /// The contract, and a receipt of what is about to be switched on. Nothing
    /// here truncates: these are the terms being agreed to, right now.
    private var dealPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            StateWord(word: "THE DEAL", size: 48)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(dealTerms, id: \.self) { term in
                    Text(term)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            ThickRule().padding(.top, 6)
            ReceiptRow(label: "BLOCKING", value: store.shielding.canShield ? "On" : "Off")
            // "RESTRICTED" does not fit ReceiptRow's label column at this
            // tracking and wraps to "RESTRICTE / D". The row already sits under
            // BLOCKING, so the shorter word loses nothing.
            ReceiptRow(label: "APPS",
                       value: shieldableCount > 0 ? "\(shieldableCount) selected" : "None")
            ReceiptRow(label: "WATER",
                       value: hydrationOn ? "Every \(Int(interval)) min" : "Off")
            ThickRule()
        }
        .padding(.top, 32)
    }

    private var dealTerms: [String] {
        ["You can correct a new commitment for a short time. After it hardens, you can "
            + "make it harder — not easier.",
         "Miss the deadline and the obligation stays open.",
         "If you need out, Earned has Overrides. You are never dependent on another "
            + "person or our servers to regain access.",
         "Screen Time permission remains yours. You can revoke it in iOS Settings at any "
            + "time, and Earned will stop enforcing rather than pretend it still can."]
    }

    // MARK: - Disclosures

    /// The Gate paragraph, on demand. Required by nobody to advance, because
    /// the word is taught properly the first time one is actually open.
    private var howItWorks: some View {
        TeachingSheet(
            word: "HOW IT WORKS",
            lines: ["An unfinished obligation is a Gate.",
                    "If more than one Gate is open, all of their restrictions apply.",
                    "A Gate closes when you satisfy it — or when you use an Override."],
            acknowledgement: "CLOSE")
        .presentationDetents([.medium])
    }

    private var hydrationDetail: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every \(Int(interval)) minutes").font(.headline)
                    Slider(value: $interval, in: 15...240, step: 15)
                        .accessibilityLabel("Minutes between water checks")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active \(Format.timeOfDay(Int(startHour) * 60)) – "
                         + "\(Format.timeOfDay(Int(endHour) * 60))").font(.headline)
                    HStack {
                        Slider(value: $startHour, in: 0...12, step: 1)
                            .accessibilityLabel("Hour water checks begin")
                        Slider(value: $endHour, in: 13...24, step: 1)
                            .accessibilityLabel("Hour water checks end")
                    }
                    Text("Outside these hours the Gate rests — no 3 AM nagging. Inside "
                         + "them it opens closed: the day starts locked until the first "
                         + "glass of water.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(Theme.pagePadding)
            .background(Theme.paper)
            .navigationTitle("Water checks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingHydrationDetail = false }
                }
            }
        }
    }

    // MARK: - Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressRule(step: page.rawValue + 1, of: Page.allCases.count)
            HStack(spacing: 16) {
                if page != .product {
                    // Back never claims to undo an OS permission — it moves
                    // between screens, and each screen re-reads the real
                    // authorization state when it draws.
                    Button("Back") { withAnimation { step(-1) } }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
                if pageOwnsItsAction {
                    Button(advanceTitle) { advance() }
                        .buttonStyle(UnderlineButtonStyle())
                } else {
                    Button(advanceTitle) { advance() }
                        .buttonStyle(PosterButtonStyle())
                }
            }
        }
    }

    /// True while a page is still asking for something. The filled button on
    /// screen is then the *ask*, never the way past it — two ink blocks side by
    /// side would make "move on" compete with "grant the permission the app
    /// runs on", and the louder would be wrong.
    private var pageOwnsItsAction: Bool {
        switch page {
        case .screenTime: return store.shielding != .approved
        case .picker:     return shieldableCount == 0
        default:          return false
        }
    }

    private var advanceTitle: String {
        switch page {
        case .deal: return "ACTIVATE EARNED"
        case .screenTime where pageOwnsItsAction: return "Continue without blocking"
        case .picker where pageOwnsItsAction:
            return store.shielding.canShield ? "Do this later" : "Continue without blocking"
        default: return "CONTINUE"
        }
    }

    private var shieldableCount: Int { RestrictionBridge.shieldableCount(in: restrictions) }

    private func beginPicking() {
        selection = RestrictionBridge.selection(from: restrictions)
        picking = true
    }

    private func advance() {
        if page == .deal { activate() } else { withAnimation { step(1) } }
    }

    private func step(_ delta: Int) {
        page = Page(rawValue: page.rawValue + delta) ?? (delta > 0 ? .deal : .product)
    }

    private func activate() {
        let hours = ActiveHours(startMinuteOfDay: Int(startHour) * 60,
                                endMinuteOfDay: Int(endHour) * 60,
                                timeZoneIdentifier: TimeZone.current.identifier)
        let config = HydrationConfig(enabled: hydrationOn,
                                     interval: interval * 60,
                                     activeHours: hours,
                                     // So the first locked day locks something.
                                     restrictions: restrictions,
                                     warningLead: 10 * 60)
        guard store.configureHydration(config) else { return }
        if shieldableCount > 0 { store.setDefaultRestrictions(restrictions) }
        store.hasOnboarded = true
    }

    // MARK: - Pieces

    /// A page that is one declaration and a few factual lines. Display type is
    /// punctuation, so there is exactly one per screen.
    private struct Page1: View {
        let word: String
        let lines: [String]
        let secondary: (String, () -> Void)?

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                StateWord(word: word, size: 44, lines: 2)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let secondary {
                    Button(secondary.0) { secondary.1() }
                        .buttonStyle(UnderlineButtonStyle())
                        .padding(.top, 4)
                }
            }
            .padding(.top, 36)
        }
    }

    /// Setup is finite, and says so without counting out loud. "STEP 3 OF 10"
    /// tells a user how much of their evening this is going to take; a rule
    /// that is mostly filled tells them it is nearly done.
    private struct ProgressRule: View {
        let step: Int
        let of: Int

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.divider)
                    Rectangle().fill(Theme.ink)
                        .frame(width: geometry.size.width * CGFloat(step) / CGFloat(of))
                }
            }
            .frame(height: 2)
            .accessibilityElement()
            .accessibilityLabel("Setup step \(step) of \(of)")
        }
    }
}
