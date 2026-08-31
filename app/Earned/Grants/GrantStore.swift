import Foundation
import EarnedKit

/// Everything about grants that is kept on this device but is deliberately not
/// domain history (docs/accountability-architecture.md §§9.3, 10.2, 11).
///
/// Three separate things live here, and the reason they are separate is the
/// whole layering decision behind §9.2:
///
/// - **The cached key set**, so an offline app can still verify. Cached as the
///   *bytes it was served*, never as a parsed object, so loading it means
///   verifying it again against the compiled anchor. Disk is not a trust
///   boundary; a file an attacker can write is not evidence.
/// - **Grant receipts**, the audit trail the ledger refuses to carry. Durable,
///   inspectable, exportable — and disposable. Deleting this file costs a
///   support conversation, never correctness, because replay never reads it.
/// - **Held grants**, which arrived while the key set was too old to check
///   them. Held rather than discarded (§11): a grant we cannot verify today
///   may verify perfectly after the next key fetch, and throwing it away would
///   leave a user locked out with no way back in but the Solo route.
struct GrantStore {
    let directory: URL

    static func documents() -> GrantStore {
        GrantStore(directory: FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask)[0])
    }

    private var keySetURL: URL { directory.appendingPathComponent("keyset.json") }
    private var receiptsURL: URL { directory.appendingPathComponent("grant-receipts.json") }
    private var heldURL: URL { directory.appendingPathComponent("grants-held.json") }

    // MARK: - The key set cache

    /// What was served, and nothing derived from it. Storing the parsed form
    /// would mean trusting whatever this file says on next launch.
    struct CachedKeySet: Codable, Equatable, Sendable {
        var document: Data
        var rootSignature: Data
        var fetchedAt: Date
    }

    func loadKeySet() -> CachedKeySet? { read(keySetURL) }

    func saveKeySet(document: Data, rootSignature: Data, at moment: Date = Date()) {
        write(CachedKeySet(document: document, rootSignature: rootSignature,
                           fetchedAt: moment), to: keySetURL)
    }

    /// Rebuild trust from the compiled anchor plus whatever is cached.
    ///
    /// The cached bytes go through the same verification a freshly fetched set
    /// does, so a tampered cache is refused at launch rather than believed.
    /// Refused, not repaired: the app carries on with no key set, which means
    /// no grants verify until the next fetch, which is the safe direction.
    func restoredTrust() -> GrantTrust {
        var trust = TrustAnchor.trust()
        if let cached = loadKeySet() {
            try? trust.accept(keySetDocument: cached.document,
                              rootSignature: cached.rootSignature)
        }
        return trust
    }

    // MARK: - Receipts (§9.3)

    /// Exactly what §9.3 specifies, kept so a user or a support conversation
    /// can answer "why did my phone unlock" months later — a question the
    /// ledger cannot answer, because the ledger holds no cryptography by
    /// design and rotation would eventually make any it did hold unreadable.
    struct Receipt: Codable, Equatable, Sendable, Identifiable {
        var id: UUID { serverGrantID }
        let serverGrantID: UUID
        let commitmentID: UUID
        /// The exact bytes that were verified. Not a re-encoding of them.
        let payload: Data
        let signature: Data
        let kid: String
        let policyDigest: String
        let verifiedAt: Date
        /// Which key set was in force when this was believed, so a later
        /// revocation can be reasoned about after the fact.
        let keySetVersion: Int
        /// Bumped when the verification rules change, so an old receipt is
        /// never mistaken for evidence under today's rules.
        let verifierVersion: Int
    }

    static let verifierVersion = 1

    func receipts() -> [Receipt] { read(receiptsURL) ?? [] }

    func record(_ receipt: Receipt) {
        var all = receipts()
        guard !all.contains(where: { $0.serverGrantID == receipt.serverGrantID }) else { return }
        all.append(receipt)
        write(all, to: receiptsURL)
    }

    /// Deleting the audit trail must change nothing about what the app
    /// believes. §19 asks for that as a test; this exists so it can be one.
    func forgetReceipts() { try? FileManager.default.removeItem(at: receiptsURL) }

    // MARK: - Held grants (§11)

    struct Held: Codable, Equatable, Sendable {
        let commitmentID: UUID
        let document: Data
        let signature: Data
        let kid: String
        let firstSeenAt: Date
        /// Why it could not be verified, in the app's own words, so a support
        /// conversation starts from a fact rather than a guess.
        let reason: String
    }

    func held() -> [Held] { read(heldURL) ?? [] }

    func hold(_ grant: Held) {
        var all = held()
        // Keyed on the bytes: re-polling re-serves the same grant, and a held
        // queue that grew by one per poll would be a slow leak.
        guard !all.contains(where: { $0.document == grant.document }) else { return }
        all.append(grant)
        write(all, to: heldURL)
    }

    func release(documents: Set<Data>) {
        let remaining = held().filter { !documents.contains($0.document) }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: heldURL)
        } else {
            write(remaining, to: heldURL)
        }
    }

    // MARK: - Plumbing

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: url, options: .atomic)
    }
}
