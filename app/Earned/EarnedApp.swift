import SwiftUI

@main
struct EarnedApp: App {
    @StateObject private var store = EarnedStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { _, phase in
            // Notification permission can be revoked in iOS Settings while
            // Earned isn't running, so re-check on every return to the
            // foreground rather than trusting what we saw at launch.
            guard phase == .active else { return }
            Task { await store.refreshWarnings() }
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
