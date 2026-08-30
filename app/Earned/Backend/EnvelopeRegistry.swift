import Foundation

/// What the server has been told about each commitment, cached locally.
///
/// **Deliberately not domain state.** Enforcement integrity went into the
/// ledger because whether Earned could enforce a Gate is a fact about the deal
/// (ARCHITECTURE.md). Registration is not: it is a fact about *another
/// system's* knowledge, and the client's copy of it is advisory by
/// construction. The server does not consult this file when it decides whether
/// an override request is against a hardened contract — it consults its own
/// row. A tampered copy here therefore buys nothing, which is exactly why it
/// does not belong in a ledger whose whole purpose is to be authoritative.
///
/// So this is a cache: losing it costs one re-registration, and re-registering
/// is idempotent.
struct RegistrationRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Registered before hardening. The ordinary state.
        case registered
        /// The server did not hear about this commitment until it had already
        /// hardened, so the accountability route is shut for it (S13). Never
        /// inferred locally — only ever the server's answer.
        case late
        /// Tried and refused or unreachable. Carries the reason.
        case failed
    }

    var status: Status
    /// The terms the server acknowledged, so a later edit shows as unsynced
    /// rather than silently diverging.
    var termsSignature: String
    /// The roster this commitment was registered with. Persisted because a
    /// later sync that did not know it would re-register the commitment with an
    /// empty roster and silently strip its accountability route.
    var partnerIDs: [UUID]
    var version: Int
    var hardensAt: Date?
    var accountabilityAvailable: Bool
    var partnerCount: Int
    var updatedAt: Date
    var failure: String?
}

extension RegistrationRecord {
    /// `partnerIDs` arrived after Milestone A shipped this file, so a registry
    /// written by the earlier build decodes with an empty roster — which is
    /// what it had. Same rule as the ledger: read what was written, don't
    /// refuse it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        termsSignature = try container.decode(String.self, forKey: .termsSignature)
        partnerIDs = try container.decodeIfPresent([UUID].self, forKey: .partnerIDs) ?? []
        version = try container.decode(Int.self, forKey: .version)
        hardensAt = try container.decodeIfPresent(Date.self, forKey: .hardensAt)
        accountabilityAvailable = try container.decode(Bool.self, forKey: .accountabilityAvailable)
        partnerCount = try container.decode(Int.self, forKey: .partnerCount)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
    }
}

/// A small JSON file next to the ledger. Never merged into it.
struct EnvelopeRegistry: Codable, Equatable, Sendable {
    private(set) var records: [UUID: RegistrationRecord] = [:]

    subscript(commitmentID: UUID) -> RegistrationRecord? { records[commitmentID] }

    mutating func record(_ receipt: EnvelopeReceipt, terms: String,
                         partnerIDs: [UUID], at date: Date) {
        records[receipt.commitmentID] = RegistrationRecord(
            status: receipt.isLate ? .late : .registered,
            termsSignature: terms,
            partnerIDs: partnerIDs,
            version: receipt.version,
            hardensAt: receipt.hardensAt,
            accountabilityAvailable: receipt.accountabilityAvailable,
            partnerCount: receipt.partnerCount,
            updatedAt: date,
            failure: nil)
    }

    mutating func recordFailure(_ commitmentID: UUID, terms: String,
                                reason: String, at date: Date) {
        // A failure never downgrades a `late` verdict the server already gave:
        // being unable to reach the server does not un-say what it said.
        var record = records[commitmentID] ?? RegistrationRecord(
            status: .failed, termsSignature: terms, partnerIDs: [], version: 0, hardensAt: nil,
            accountabilityAvailable: false, partnerCount: 0, updatedAt: date, failure: reason)
        if record.status != .late { record.status = .failed }
        record.failure = reason
        record.updatedAt = date
        records[commitmentID] = record
    }

    mutating func forget(_ commitmentID: UUID) { records[commitmentID] = nil }
}

/// Persistence for the registry, alongside the ledger but separate from it.
struct EnvelopeRegistryStorage {
    let url: URL

    static func documents(filename: String = "envelopes.json") -> EnvelopeRegistryStorage {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return EnvelopeRegistryStorage(url: dir.appendingPathComponent(filename))
    }

    func load() -> EnvelopeRegistry {
        guard let data = try? Data(contentsOf: url),
              let registry = try? Self.decoder.decode(EnvelopeRegistry.self, from: data)
        else { return EnvelopeRegistry() }
        return registry
    }

    /// Failure is swallowed on purpose: this is a cache, and a commitment must
    /// never fail to be made because a cache could not be written.
    func save(_ registry: EnvelopeRegistry) {
        guard let data = try? Self.encoder.encode(registry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
