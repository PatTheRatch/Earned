import SwiftUI
import EarnedKit

@main
struct EarnedApp: App {
    @StateObject private var store = EarnedStore()
    @StateObject private var account: AccountStore
    @StateObject private var social: SocialStore
    @StateObject private var health = HealthImporter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // SocialStore rides AccountStore's session and transport, so the two
        // are created together rather than discovering each other later.
        let account = AccountStore()
        _account = StateObject(wrappedValue: account)
        _social = StateObject(wrappedValue: SocialStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(account)
                .environmentObject(social)
                .environmentObject(health)
        }
        .onChange(of: scenePhase) { _, phase in
            // Notification permission can be revoked in iOS Settings while
            // Earned isn't running, so re-check on every return to the
            // foreground rather than trusting what we saw at launch.
            guard phase == .active else { return }
            Task { await store.refreshWarnings() }
            // Health first, before anything network: a run finished ten
            // minutes ago should resolve its Gate here and now, not after a
            // round trip — and a Gate resolved locally is one less override
            // anybody needs to ask for.
            Task { await health.importWorkouts(into: store) }
            // Anything created offline is still owed an envelope. Registering
            // late costs the accountability route for that commitment (S13),
            // so the retry happens at the first opportunity, not the next
            // time the user happens to open a detail screen.
            // A partner can accept or decline while Earned isn't running, and
            // that changes which commitments have a working way out.
            Task {
                await account.refreshPartners()
                // Social is a passenger here, never a dependency: profile and
                // friends refresh on the same foreground pass, and failure
                // changes what the Social tab shows, nothing else.
                await social.refreshProfile()
                // The check-in is the fact the quiet surface is built on:
                // "Earned heard from this phone." Recorded only while the
                // owner shares check-ins; the server no-ops otherwise.
                await social.checkIn()
                await social.refreshSocial()
                // Sharing runs after the health import above, so a run that
                // just resolved its Gate is the story that gets published —
                // and always after the profile, whose switches govern it.
                await social.syncSharing(commitments: store.allCommitments, now: store.now)
                await social.publishStreaks(store.ledger.state.socialStreaks(now: store.now))
                await social.refreshActivity()
                await account.syncEnvelopes(for: store.allCommitments, now: store.now)
                // Grants last, and only after envelopes: a grant is checked
                // against the contract digest the server gave us, so a
                // commitment whose envelope has not synced yet has nothing to
                // check against and its grant would be held for no reason.
                await applyGrants()
            }
        }
    }

    /// A partner's approval only becomes an unlocked phone here.
    ///
    /// Everything cryptographic happened before this point; what is left is a
    /// plain domain fact — these people said yes, at this time — offered to
    /// the ledger, which may still refuse it. Refusal is not an error: the
    /// commitment may have been completed while the partner was tapping
    /// approve, and §12 is explicit that their stale page must not reopen a
    /// resolved commitment.
    @MainActor
    private func applyGrants() async {
        for verified in await account.syncGrants() {
            let grant = verified.grant
            // Idempotent in both directions (§9.4): the server re-serves the
            // same grant on every poll, so a grant already in history is
            // skipped here before the reducer has to be the one to say no.
            if store.ledger.state.overrideRequests[grant.clientRequestID]?
                .serverGrantID == grant.serverGrantID { continue }

            let applied = store.append(
                .accountabilityOverrideGranted(requestID: grant.clientRequestID,
                                               decidedAt: grant.decidedAt,
                                               roster: grant.roster,
                                               serverGrantID: grant.serverGrantID),
                // The moment the *server* decided, not the moment this phone
                // heard about it. A grant can sit undelivered for hours while
                // a user is offline (§11), and dating it now would misdate
                // their own history.
                at: grant.decidedAt)
            if applied { account.recordReceipt(for: verified) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        Group {
            if store.hasOnboarded {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        // A printed notice has one look: light only (docs/design-language.md).
        .preferredColorScheme(.light)
        .tint(Theme.ink)
        .alert("Couldn't load your history",
               isPresented: .constant(store.loadFailure != nil),
               actions: { Button("OK", role: .cancel) { store.loadFailure = nil } },
               message: { Text(store.loadFailure ?? "") })
    }
}

struct MainTabView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore

    var body: some View {
        // Today stays the launch tab and the center of gravity; Social sits
        // between History and Settings and is never the default (NORTHSTAR §45).
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "checkmark.circle") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            SocialView()
                .tabItem { Label("Social", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Offered once, right after a sign-in that found no profile — and only
        // offered: dismissing it costs nothing, and the Social tab repeats the
        // invitation. Nothing local ever waits on this.
        .sheet(isPresented: $social.setupOffered) { ProfileSetupView() }
        // Sign-in resolves asynchronously wherever it was started (Settings or
        // Social), so the moment the session actually lands is watched here.
        .onChange(of: account.session) { _, session in
            guard case .signedIn = session else { return }
            Task {
                await social.refreshProfile(offeringSetup: true)
                await social.refreshSocial()
            }
        }
    }
}
