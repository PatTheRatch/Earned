import Foundation
import SwiftUI
import UIKit
import EarnedKit

/// What build this is, read from the bundle rather than hardcoded.
///
/// A tester says "it did the wrong thing" and the first question is always
/// which binary they were holding. Guessing from a TestFlight upload date is
/// how two people end up debugging different apps, so the numbers live on a
/// screen the tester can reach and read aloud.
struct AppBuild {
    let marketingVersion: String
    let buildNumber: String

    static let current = AppBuild(
        marketingVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "?",
        buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")

    /// `0.1 (87)` — the form a tester should quote.
    var short: String { "\(marketingVersion) (\(buildNumber))" }
}

/// When a background pass last ran, and whether it worked.
///
/// Deliberately not an error log: one timestamp and one message, overwritten
/// each pass. Enough to tell "the Social tab is empty because nothing has
/// synced" from "it synced fine and you have no friends yet", which is the
/// class of question a private beta actually generates.
struct SyncStamp: Equatable {
    let at: Date
    let failure: String?

    var ok: Bool { failure == nil }

    static func succeeded(at date: Date = Date()) -> SyncStamp {
        SyncStamp(at: date, failure: nil)
    }

    static func failed(_ message: String, at date: Date = Date()) -> SyncStamp {
        SyncStamp(at: date, failure: message)
    }
}

extension Optional where Wrapped == SyncStamp {
    /// One line, in the tester's words rather than the network's.
    var summary: String {
        guard let stamp = self else { return "Not yet" }
        let ago = Format.relative(stamp.at, from: Date())
        return stamp.ok ? "OK \(ago)" : "Failed \(ago)"
    }

    var failureMessage: String? { self?.failure }

    var didFail: Bool { self?.ok == false }
}

/// The one screen a beta tester can be asked to read out, and the text they can
/// paste into a bug report.
///
/// **What is deliberately absent matters more than what is here:** no access
/// token, no Apple subject, no JWT, no contact ciphertext, no Vault secret, no
/// Health sample, no commitment title, no friend handle, no restriction token.
/// Counts and states only. A summary a tester might paste into a group chat has
/// to be safe to paste into a group chat.
struct DiagnosticsReport {
    struct Line: Identifiable {
        let label: String
        let value: String
        /// True when the value names a problem rather than stating a fact.
        var problem: Bool = false
        var id: String { label }
    }

    /// A titled run of lines. Not called `Section` because SwiftUI owns that
    /// name and this type is used beside it.
    struct Segment: Identifiable {
        let title: String
        let lines: [Line]
        var id: String { title }
    }

    let segments: [Segment]

    /// Plain text, one `label: value` per line, titles in caps.
    var text: String {
        segments.map { segment in
            ([segment.title.uppercased()]
             + segment.lines.map { "  \($0.label): \($0.value)" })
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    @MainActor
    static func build(store: EarnedStore,
                      account: AccountStore,
                      social: SocialStore,
                      health: HealthImporter) -> DiagnosticsReport {
        DiagnosticsReport(segments: [
            Segment(title: "App", lines: appLines(store: store)),
            Segment(title: "Enforcement", lines: enforcementLines(store: store)),
            Segment(title: "Sync", lines: syncLines(account: account, social: social,
                                                    health: health)),
        ])
    }

    @MainActor
    private static func appLines(store: EarnedStore) -> [Line] {
        let build = AppBuild.current
        var lines = [
            Line(label: "Version", value: build.marketingVersion),
            Line(label: "Build", value: build.buildNumber),
            Line(label: "iOS", value: UIDevice.current.systemVersion),
            Line(label: "Device", value: hardwareModel()),
            Line(label: "Ledger schema", value: "v\(Ledger.currentSchemaVersion)"),
            Line(label: "Events recorded", value: "\(store.ledger.entries.count)"),
            Line(label: "Commitments", value: "\(store.state.commitments.count)"),
            Line(label: "Workouts", value: "\(store.state.workouts.count)"),
        ]
        if store.loadFailure != nil {
            lines.append(Line(label: "History", value: "Set aside on launch", problem: true))
        }
        return lines
    }

    /// Enforcement while Earned is closed is two processes agreeing through a
    /// shared container, and every way that can fail fails silently — the
    /// monitor wakes on time and shields nothing. These lines are the
    /// difference between noticing that during a beta and discovering it after.
    @MainActor
    private static func enforcementLines(store: EarnedStore) -> [Line] {
        let plan = SharedContainer.loadPlan()
        var lines = [
            Line(label: "Screen Time", value: screenTimeLabel(store.shielding),
                 problem: store.shielding != .approved),
            Line(label: "App Group", value: SharedContainer.isAvailable ? "Reachable" : "Missing",
                 problem: !SharedContainer.isAvailable),
            Line(label: "Scheduled changes", value: "\(plan?.windows.count ?? 0)"),
            Line(label: "Blocked right now", value: "\(store.effectiveRestrictions.count)"),
            Line(label: "Notifications", value: notificationLabel(store.warningDelivery),
                 problem: store.warningDelivery == .denied),
        ]
        if let plan {
            lines.append(Line(label: "Plan written",
                              value: Format.relative(plan.generatedAt, from: store.now)))
        }
        if let next = plan?.windows.first {
            lines.append(Line(label: "Next change",
                              value: Format.deadline(next.opensAt, from: store.now)))
        }
        if let failure = store.shieldingFailure {
            lines.append(Line(label: "Screen Time error", value: failure, problem: true))
        }
        return lines
    }

    @MainActor
    private static func syncLines(account: AccountStore,
                                  social: SocialStore,
                                  health: HealthImporter) -> [Line] {
        var lines = [
            Line(label: "Backend", value: backendLabel(account)),
            Line(label: "Session", value: sessionLabel(account.session),
                 problem: account.session.isFailed),
            Line(label: "Health access", value: healthLabel(health.access)),
            Line(label: "Health import", value: health.lastImport.summary,
                 problem: health.lastImport.didFail),
            Line(label: "Envelope sync", value: account.lastEnvelopeSync.summary,
                 problem: account.lastEnvelopeSync.didFail),
            Line(label: "Grant sync", value: account.lastGrantSync.summary,
                 problem: account.lastGrantSync.didFail),
            Line(label: "Social sync", value: social.lastSync.summary,
                 problem: social.lastSync.didFail),
        ]
        if account.heldGrants > 0 {
            lines.append(Line(label: "Grants held", value: "\(account.heldGrants)",
                              problem: true))
        }
        // The failure sentences last, so the screen leads with state and a
        // pasted report still carries what the server actually said.
        let errors: [(String, String?)] = [
            ("Health error", health.lastImport.failureMessage),
            ("Envelope error", account.lastEnvelopeSync.failureMessage),
            ("Grant error", account.lastGrantSync.failureMessage),
            ("Social error", social.lastSync.failureMessage),
        ]
        for (label, message) in errors {
            if let message {
                lines.append(Line(label: label, value: message, problem: true))
            }
        }
        return lines
    }

    /// The project's host — never the publishable key, never a token. Enough to
    /// tell a tester pointed at the wrong project from one pointed at none.
    private static func backendLabel(_ account: AccountStore) -> String {
        guard account.isConfigured else { return "Not configured" }
        return BackendConfig.shared?.url.host ?? "Configured"
    }

    private static func sessionLabel(_ session: AccountStore.Session) -> String {
        switch session {
        case .notConfigured: return "No backend"
        case .signedOut: return "Signed out"
        case .signingIn: return "Signing in"
        case .signedIn: return "Signed in"
        case .failed: return "Sign-in failed"
        }
    }

    private static func screenTimeLabel(_ status: ScreenTimeController.Authorization) -> String {
        switch status {
        case .approved: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        }
    }

    private static func notificationLabel(
        _ status: NotificationScheduler.Authorization) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        }
    }

    private static func healthLabel(_ access: HealthImporter.Access) -> String {
        switch access {
        case .unavailable: return "No Health on this device"
        case .notDetermined: return "Not asked"
        // Health hides read denials by design, so "asked" is the most this can
        // honestly claim — see HealthImporter.Access.
        case .requested: return "Asked"
        }
    }

    /// `iPhone15,2` — the identifier, not a name. Nothing here identifies a
    /// person, and the model is the first thing an OS-specific bug needs.
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "Unknown" : machine
    }
}

extension AccountStore.Session {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - About

/// Which binary is this. That is the whole screen.
struct AboutView: View {
    private static let privacyURL = URL(string: "https://earntherest.com/privacy")

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EARNED BETA")
                        .font(Theme.display(30))
                        .foregroundStyle(Theme.ink)
                    Text(AppBuild.current.short)
                        .font(Theme.metric(34))
                        .foregroundStyle(Theme.ink)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Earned Beta, version "
                                    + "\(AppBuild.current.marketingVersion), build "
                                    + "\(AppBuild.current.buildNumber)")
            } footer: {
                Text("Quote both numbers in any bug report — they are the only way to tell "
                     + "which build you were holding.")
            }

            Section {
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Ledger schema", value: "v\(Ledger.currentSchemaVersion)")
            }

            if let url = Self.privacyURL {
                Section {
                    Link("Privacy", destination: url)
                } footer: {
                    Text("Earned is in private beta. What it reads, what leaves the phone, "
                         + "and what other people can see are set out there.")
                }
            }
        }
        .paperList()
        .navigationTitle("About")
    }
}

// MARK: - Diagnostics

/// Everything a bug report needs, and a button that copies it.
struct DiagnosticsView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var health: HealthImporter
    @State private var copied = false

    var body: some View {
        let report = DiagnosticsReport.build(store: store, account: account,
                                             social: social, health: health)
        List {
            ForEach(report.segments) { segment in
                Section(segment.title) {
                    ForEach(segment.lines) { line in
                        LabeledContent(line.label) {
                            Text(line.value)
                                .foregroundStyle(line.problem ? Theme.signal : Theme.muted)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            Section {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    UIPasteboard.general.string = report.text
                    copied = true
                }
                ShareLink(item: report.text) { Text("Share diagnostics") }
            } footer: {
                Text("Counts and states only. No commitment titles, no friend handles, no "
                     + "Health data, nothing that could sign you in — this is safe to paste "
                     + "anywhere.")
            }
        }
        .paperList()
        .navigationTitle("Diagnostics")
    }
}

// MARK: - Report a problem

/// The beta support path: a draft the tester reads before anything is sent.
///
/// Nothing is attached without a tap. Diagnostics are counts and states (see
/// `DiagnosticsReport`) and the description is whatever the tester typed — but
/// they still include it deliberately, because "the app quietly mailed a report
/// about me" is not a sentence a beta tester should ever be able to say
/// truthfully.
struct ReportProblemView: View {
    @EnvironmentObject private var store: EarnedStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var social: SocialStore
    @EnvironmentObject private var health: HealthImporter
    @Environment(\.dismiss) private var dismiss

    /// Where beta reports go. A person, not a helpdesk — there are ten testers.
    static let supportAddress = "beta@earntherest.com"

    @State private var what = ""
    @State private var includeDiagnostics = true

    private var canSend: Bool {
        !what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("What happened?", text: $what, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("What happened")
                } footer: {
                    Text("What you expected, and what it did instead. One sentence is fine.")
                }

                Section {
                    Toggle("Include diagnostics", isOn: $includeDiagnostics)
                    if includeDiagnostics {
                        NavigationLink("See exactly what's included") { DiagnosticsView() }
                    }
                } footer: {
                    Text("Version, build, iOS, permission states, and how many events are "
                         + "stored. Never a commitment title, a friend, Health data, or "
                         + "anything that could sign you in.")
                }

                Section {
                    Button("Open a mail draft") { openMail() }
                        .disabled(!canSend)
                    ShareLink(item: reportBody()) { Text("Share another way") }
                } footer: {
                    Text("Both open a draft you can read and edit. Nothing is sent until you "
                         + "send it, and a screenshot can be attached in the draft.")
                }
            }
            .paperList()
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func reportBody() -> String {
        var parts = [what.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeDiagnostics {
            parts.append(DiagnosticsReport.build(store: store, account: account,
                                                 social: social, health: health).text)
        } else {
            // Even the minimal report carries the build: a report nobody can
            // tie to a binary is a report nobody can act on.
            parts.append("Earned \(AppBuild.current.short) · iOS "
                         + UIDevice.current.systemVersion)
        }
        return parts.joined(separator: "\n\n----\n\n")
    }

    private func openMail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Earned beta \(AppBuild.current.short)"),
            URLQueryItem(name: "body", value: reportBody()),
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
