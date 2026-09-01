import Foundation

/// What the app tells the extension, and the only thing they share.
///
/// The `DeviceActivityMonitor` extension runs in its own process, on its own
/// tiny memory budget, woken by the system at a scheduled moment with the app
/// nowhere in sight. It needs to know what to shield and nothing else.
///
/// **The ledger deliberately stays where it is.** Moving it into the shared
/// container so the extension could replay it was the obvious design and is
/// the wrong one: the ledger is the one file in Earned that must never be
/// corrupted, replay is not something to attempt under an extension's memory
/// ceiling, and none of it is necessary — every transition is a function of
/// state the app already has, computed ahead of time. What crosses the
/// boundary is a few dozen bytes of already-decided answer.
///
/// Tokens cross **already sorted into their three kinds**, rather than in
/// EarnedKit's `kind:base64` string form. That is on purpose: it leaves the
/// extension with no knowledge of how Earned encodes a token, so the encoding
/// can change without a second implementation silently failing to keep up. The
/// extension's whole job becomes mechanical — decode, apply.
struct ShieldPlan: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// Matches the `DeviceActivityName` the schedule was registered under,
        /// which is how the extension knows which window it was woken for.
        var id: String
        var opensAt: Date
        /// Each entry is one JSON-encoded FamilyControls token. Opaque here as
        /// everywhere else — Earned shields what it cannot identify (§34).
        var applications: [Data]
        var categories: [Data]
        var webDomains: [Data]

        var isEmpty: Bool {
            applications.isEmpty && categories.isEmpty && webDomains.isEmpty
        }
    }

    var generatedAt: Date
    var windows: [Window]

    func window(named id: String) -> Window? { windows.first { $0.id == id } }
}

/// The shared container both processes reach through.
///
/// An App Group is the only route between them, and it has to be created in
/// the developer portal and listed in both entitlement files. When it is
/// missing the container URL is nil — so every read returns nothing and every
/// write is dropped, and the visible symptom is a monitor that wakes on time
/// and shields nothing. Hence `isAvailable`, and hence the app surfacing it
/// rather than discovering it in a support conversation.
enum SharedContainer {
    static let identifier = "group.com.pattheratch.earned"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isAvailable: Bool { url != nil }

    private static var planURL: URL? { url?.appendingPathComponent("shield-plan.json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func loadPlan() -> ShieldPlan? {
        guard let planURL, let data = try? Data(contentsOf: planURL) else { return nil }
        return try? decoder.decode(ShieldPlan.self, from: data)
    }

    @discardableResult
    static func save(_ plan: ShieldPlan) -> Bool {
        guard let planURL, let data = try? encoder.encode(plan) else { return false }
        return (try? data.write(to: planURL, options: .atomic)) != nil
    }
}
