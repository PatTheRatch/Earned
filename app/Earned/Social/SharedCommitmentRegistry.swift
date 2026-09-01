import Foundation

/// Which of this user's personal commitments belong to shared-commitment
/// agreements, and what progress the server was last told — cached locally,
/// next to the sharing registry and for the same reason.
///
/// **Deliberately not domain state.** The ledger records the deal; that other
/// people are doing the same thing is social metadata about it (NORTHSTAR
/// invariant 30 — sharedness never changes what the user owes). Losing this
/// file costs re-publishing and a refetch of `my_shared_commitments()`, both
/// idempotent; the server remains authoritative for the roster and the link.
struct SharedCommitmentRecord: Codable, Equatable, Sendable {
    var agreementID: UUID
    /// What the server last acknowledged, so a foreground pass publishes
    /// changes rather than chatter. Nil until the first publish lands.
    var lastPublishedProgress: Double?
    var lastPublishedState: String?
}

struct SharedCommitmentRegistry: Codable, Equatable, Sendable {
    private(set) var records: [UUID: SharedCommitmentRecord] = [:]

    /// Membership: this personal commitment is the user's half of an agreement.
    func agreementID(for commitmentID: UUID) -> UUID? {
        records[commitmentID]?.agreementID
    }

    subscript(commitmentID: UUID) -> SharedCommitmentRecord? { records[commitmentID] }

    mutating func link(_ commitmentID: UUID, toAgreement agreementID: UUID) {
        if records[commitmentID] == nil {
            records[commitmentID] = SharedCommitmentRecord(agreementID: agreementID)
        }
    }

    mutating func recordPublished(_ commitmentID: UUID, progress: Double, state: String) {
        guard var record = records[commitmentID] else { return }
        record.lastPublishedProgress = progress
        record.lastPublishedState = state
        records[commitmentID] = record
    }

    mutating func unlink(_ commitmentID: UUID) { records[commitmentID] = nil }
}

struct SharedCommitmentRegistryStorage {
    let url: URL

    static func documents(filename: String = "shared-commitments.json") -> SharedCommitmentRegistryStorage {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SharedCommitmentRegistryStorage(url: dir.appendingPathComponent(filename))
    }

    func load() -> SharedCommitmentRegistry {
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(SharedCommitmentRegistry.self, from: data)
        else { return SharedCommitmentRegistry() }
        return registry
    }

    /// Swallowed on purpose: a bookkeeping failure must never stop a
    /// commitment being made or kept; the worst it costs is a redundant
    /// publish and one refetch.
    func save(_ registry: SharedCommitmentRegistry) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
