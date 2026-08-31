import Foundation

/// Which commitments the user shares with friends, and what the server was
/// last told about each — cached locally, next to the envelope registry and
/// for the same reason.
///
/// **Deliberately not domain state.** The ledger records the deal; who may
/// watch it is a privacy preference, revocable at any time in either
/// direction, and monotonicity has no business governing it. Losing this file
/// costs re-publishing, and publishing is idempotent.
struct SharingRecord: Codable, Equatable, Sendable {
    /// The state the server last acknowledged, so a foreground pass publishes
    /// transitions rather than chatter. Nil until the first publish lands.
    var lastPublishedState: String?
    var lastPublishedTitle: String?
}

struct SharingRegistry: Codable, Equatable, Sendable {
    private(set) var records: [UUID: SharingRecord] = [:]

    /// Membership is the choice: a commitment is shared with friends exactly
    /// while it has a record here.
    func isShared(_ commitmentID: UUID) -> Bool { records[commitmentID] != nil }

    subscript(commitmentID: UUID) -> SharingRecord? { records[commitmentID] }

    mutating func share(_ commitmentID: UUID) {
        if records[commitmentID] == nil { records[commitmentID] = SharingRecord() }
    }

    mutating func recordPublished(_ commitmentID: UUID, state: String, title: String) {
        records[commitmentID] = SharingRecord(lastPublishedState: state,
                                              lastPublishedTitle: title)
    }

    mutating func unshare(_ commitmentID: UUID) { records[commitmentID] = nil }
}

struct SharingRegistryStorage {
    let url: URL

    static func documents(filename: String = "sharing.json") -> SharingRegistryStorage {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SharingRegistryStorage(url: dir.appendingPathComponent(filename))
    }

    func load() -> SharingRegistry {
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(SharingRegistry.self, from: data)
        else { return SharingRegistry() }
        return registry
    }

    /// Swallowed on purpose: a sharing choice must never stop a commitment
    /// being made, and the worst a lost write costs is one redundant publish.
    func save(_ registry: SharingRegistry) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
