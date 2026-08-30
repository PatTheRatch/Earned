import SwiftUI
import EarnedKit

/// What tapping the Water card opens: the Hydration Gate's contract, editable
/// in place. Loosening it is only accepted while the gate is currently
/// satisfied — EarnedKit enforces that; this view just reflects the outcome.
struct HydrationDetailView: View {
    @EnvironmentObject private var store: EarnedStore

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Now", value: statusText)
            }

            if let config = store.state.hydration {
                Section {
                    Toggle("Enabled", isOn: Binding(
                        get: { config.enabled },
                        set: { enabled in
                            var updated = config
                            updated.enabled = enabled
                            store.configureHydration(updated)
                        }))
                    HStack {
                        Text("Every \(Int(config.interval / 60)) min")
                        Spacer()
                        Button("−15 min") { setInterval(max(15 * 60, config.interval - 15 * 60), from: config) }
                            .buttonStyle(.bordered)
                        Button("+15 min") { setInterval(config.interval + 15 * 60, from: config) }
                            .buttonStyle(.bordered)
                    }
                    LabeledContent("Active",
                                  value: "\(Format.timeOfDay(config.activeHours.startMinuteOfDay)) – "
                                       + "\(Format.timeOfDay(config.activeHours.endMinuteOfDay))")
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("The window opens closed: from the start of active hours this Gate is "
                         + "unsatisfied until you drink. Loosening anything — a longer interval, "
                         + "narrower hours, turning it off — is only allowed while the Gate is "
                         + "currently satisfied. Tightening always works.")
                }
            } else {
                Section {
                    Text("Not configured. Set this up during onboarding, or in Settings.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                let profile = store.state.restrictions(of: .hydration)
                if profile.isEmpty {
                    Text("Nothing").foregroundStyle(.secondary)
                } else {
                    ForEach(profile.sortedTokens, id: \.self) { RestrictionTokenLabel(token: $0) }
                }
                NavigationLink("Edit") {
                    GateRestrictionsView(gate: .hydration, title: "Hydration Gate")
                }
            } header: {
                Text("What this Gate takes")
            } footer: {
                Text("The Hydration Gate's own profile — deliberately the most severe. Before the "
                     + "first water of the day this is what the phone is reduced to.")
            }
        }
        .paperList()
        .navigationTitle("Hydration")
        .navigationBarTitleDisplayMode(.inline)
        .rejectionAlert()
    }

    private var statusText: String {
        switch store.hydration {
        case .satisfied(let expiresAt):
            return "Good — locks again \(Format.relative(expiresAt, from: store.now))"
        case .unsatisfied(let since):
            return "Locked since \(Format.deadline(since, from: store.now)) — drink some water"
        case .dormant:
            return "Resting (outside active hours, or off)"
        }
    }

    private func setInterval(_ interval: TimeInterval, from config: HydrationConfig) {
        var updated = config
        updated.interval = interval
        store.configureHydration(updated)
    }
}
