import SwiftUI

@main
struct EarnedApp: App {
    @StateObject private var store = EarnedStore()
    @StateObject private var account = AccountStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(account)
        }
        .onChange(of: scenePhase) { _, phase in
            // Notification permission can be revoked in iOS Settings while
            // Earned isn't running, so re-check on every return to the
            // foreground rather than trusting what we saw at launch.
            guard phase == .active else { return }
            Task { await store.refreshWarnings() }
            // Anything created offline is still owed an envelope. Registering
            // late costs the accountability route for that commitment (S13),
            // so the retry happens at the first opportunity, not the next
            // time the user happens to open a detail screen.
            Task { await account.syncEnvelopes(for: store.allCommitments, now: store.now) }
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
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "checkmark.circle") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
