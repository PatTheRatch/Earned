import Foundation

/// Deciding whether to believe a grant (docs/accountability-architecture.md
/// §§9, 10).
///
/// This is the whole point of the server half. A grant is the server saying
/// "these people let this person out", and the reason it is signed is that the
/// app must be able to check that claim without trusting the network, the CDN,
/// the database, or a copy of the app running on a jailbroken phone next to
/// this one. So the rule the rest of the app depends on is short:
///
/// **Nothing here parses a document it has not already verified.** Every
/// function in this file takes bytes, checks a signature over exactly those
/// bytes, and only then looks inside. That ordering is not a style preference:
/// a parser is the largest attack surface in the file, and running it on
/// unauthenticated input is how a signature check gets bypassed without ever
/// being wrong.
///
/// It also means no canonicalisation scheme has to be agreed between Postgres,
/// Deno and Swift and then kept agreed forever. Postgres composes the bytes,
/// the edge function signs those bytes, the app verifies those bytes. Nobody
/// re-serialises anything, so nobody can disagree.
///
/// The actual Ed25519 primitive is injected rather than imported, for two
/// reasons: CryptoKit does not exist on Linux, where this package's tests run,
/// and a fake verifier can assert something a real one cannot — *which bytes
/// it was handed*. That is the property that actually goes wrong in practice.

// MARK: - The primitive

/// Ed25519 verification, supplied by whoever is hosting this code.
///
/// The app passes CryptoKit. Tests pass a recorder, so they can assert that
/// the message handed to the primitive was the served document verbatim and
/// not something re-encoded on the way.
public protocol SignatureVerifier: Sendable {
    /// `publicKey` is the raw 32-byte Ed25519 key, `signature` the raw 64
    /// bytes. Returns false for anything it cannot make sense of; it must
    /// never throw its way into looking like a pass.
    func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool
}

// MARK: - Refusals

/// Why something was not believed.
///
/// Every case is a refusal — there is no "warn and continue". A grant that
/// cannot be verified is not a weaker grant, it is not a grant, and the user
/// still has the Solo route (§11, S8).
public enum TrustFailure: Error, Equatable, Sendable {
    /// No root public key was compiled in. Fails closed: an app that trusts
    /// nothing can still be used, an app that trusts anything cannot.
    case noTrustAnchor
    case rootSignatureInvalid
    /// A key set older than the one already held. The only defence against
    /// someone replaying a stale key set to resurrect a revoked key (§10.4).
    case keySetWentBackwards(offered: Int, held: Int)
    case malformedKeySet(String)
    case unknownKey(String)
    /// On the kill list. Absolute, and retroactive: once a key may have leaked
    /// there is no way to tell which of its signatures were the server's.
    case revokedKey(String)
    /// Signed by a key that had not been promoted, or had expired, when it
    /// signed. A `next` key signing means the server used a key it had not yet
    /// told anyone about (§10.3).
    case keyNotInService(String)
    case unsupportedAlgorithm(String)
    case signatureInvalid
    case malformedGrant(String)
    /// The document names a different key than the one it arrived labelled
    /// with. Sounds impossible; it is exactly what a substituted document
    /// looks like, and the check costs one comparison.
    case keyIdentifierMismatch(labelled: String, document: String)
    /// A grant against a different contract than the one this app holds. The
    /// partners approved a specific set of terms (§4.5); different terms are a
    /// different question than the one they answered.
    case contractMismatch(expected: String, granted: String)
    case notAGrant(String)
}

// MARK: - Keys

public struct SigningKey: Equatable, Sendable {
    /// Lifecycle from migration 0008. `revoked` never appears here — revoked
    /// kids are served in their own list and become the kill list.
    public enum State: String, Sendable { case current, next, retired }

    public let kid: String
    public let algorithm: String
    public let publicKey: Data
    public let notBefore: Date
    public let notAfter: Date?
    public let state: State

    /// Whether this key was in service at `moment`.
    ///
    /// `moment` is the time the server *decided*, not now. A retired key
    /// legitimately signed grants while it was current, and those grants stay
    /// good — retirement stops new signatures, it does not disown old ones.
    /// That distinction is the entire difference between retiring a key and
    /// revoking one.
    func wasInService(at moment: Date) -> Bool {
        guard state != .next else { return false }
        guard moment >= notBefore else { return false }
        if let notAfter, moment > notAfter { return false }
        return true
    }
}

/// A key set the app has verified and is willing to act on.
///
/// Holds the bytes it was verified from, not just the parsed form, so that a
/// cached key set can be re-verified on load rather than trusted because it is
/// on disk. Disk is not a trust boundary.
public struct VerifiedKeySet: Equatable, Sendable {
    public let version: Int
    public let issuedAt: Date
    public let keys: [SigningKey]
    public let revoked: Set<String>
    public let document: Data
    public let rootSignature: Data

    public func key(_ kid: String) -> SigningKey? { keys.first { $0.kid == kid } }
}

// MARK: - The trust anchor

/// Holds the root public key and the newest key set the app has accepted.
///
/// The root key signs key sets and never signs grants, which is what lets it
/// stay offline: publishing a new key set is a deliberate human act, and
/// nothing about serving a grant requires it. A server that is fully
/// compromised can still not introduce a key this app will trust.
public struct GrantTrust: Sendable {
    private let rootPublicKey: Data
    private let verifier: any SignatureVerifier
    public private(set) var keySet: VerifiedKeySet?

    /// `rootPublicKey` is the raw 32 bytes. Empty means no anchor was
    /// configured, and every verification below refuses — deliberately, and
    /// loudly, rather than degrading into accepting whatever arrives.
    public init(rootPublicKey: Data, verifier: any SignatureVerifier,
                keySet: VerifiedKeySet? = nil) {
        self.rootPublicKey = rootPublicKey
        self.verifier = verifier
        self.keySet = keySet
    }

    // MARK: Key sets

    /// Verify a served key set and adopt it if it is newer than the one held.
    ///
    /// Returns the key set now in force, which on a replayed-but-valid older
    /// document is the one already held rather than an error: re-serving an
    /// old key set is what a cache does, not necessarily what an attacker
    /// does. Going *backwards* is refused; standing still is not an event.
    @discardableResult
    public mutating func accept(keySetDocument document: Data,
                                rootSignature: Data) throws -> VerifiedKeySet {
        guard !rootPublicKey.isEmpty else { throw TrustFailure.noTrustAnchor }
        guard verifier.isValid(signature: rootSignature, of: document,
                               publicKey: rootPublicKey) else {
            throw TrustFailure.rootSignatureInvalid
        }

        let parsed = try Self.parseKeySet(document: document, rootSignature: rootSignature)
        if let held = keySet {
            if parsed.version < held.version {
                throw TrustFailure.keySetWentBackwards(offered: parsed.version,
                                                       held: held.version)
            }
            if parsed.version == held.version { return held }
        }
        keySet = parsed
        return parsed
    }

    // MARK: Grants

    /// Verify one grant, then read it.
    ///
    /// `kid` and `signature` travel *beside* the document rather than inside
    /// it, because a field inside an object cannot be part of what signs that
    /// object. `kid` is therefore unauthenticated when it is used to pick a
    /// key — which is safe, since picking the wrong key makes verification
    /// fail — and is checked against the document's own `kid` afterwards.
    ///
    /// `expectedPolicyDigest` is the digest of the contract envelope this app
    /// holds for the commitment. It is not optional on purpose: a grant that
    /// matches no contract is a grant for terms the partners were never shown.
    public func verifyGrant(document: Data,
                            signature: Data,
                            kid: String,
                            expectedPolicyDigest: String) throws -> VerifiedGrant {
        guard !rootPublicKey.isEmpty else { throw TrustFailure.noTrustAnchor }
        guard let keySet else { throw TrustFailure.unknownKey(kid) }
        guard !keySet.revoked.contains(kid) else { throw TrustFailure.revokedKey(kid) }
        guard let key = keySet.key(kid) else { throw TrustFailure.unknownKey(kid) }
        guard key.algorithm == "ed25519" else {
            throw TrustFailure.unsupportedAlgorithm(key.algorithm)
        }

        // Verify first. Everything below this line is parsing, and parsing is
        // the part that must never run on bytes nobody vouched for.
        guard verifier.isValid(signature: signature, of: document,
                               publicKey: key.publicKey) else {
            throw TrustFailure.signatureInvalid
        }

        let grant = try Self.parseGrant(document: document)

        guard grant.kid == kid else {
            throw TrustFailure.keyIdentifierMismatch(labelled: kid, document: grant.kid)
        }
        // Checked against the moment of decision, not now, so that a key
        // retiring tomorrow does not invalidate what it signed today.
        guard key.wasInService(at: grant.decidedAt) else {
            throw TrustFailure.keyNotInService(kid)
        }
        guard grant.policyDigest == expectedPolicyDigest else {
            throw TrustFailure.contractMismatch(expected: expectedPolicyDigest,
                                                granted: grant.policyDigest)
        }
        return grant
    }
}

// MARK: - What a verified grant says

/// A grant that has been checked, in the form the app may act on.
///
/// Note what is absent: the signature, the key id, the document bytes. Those
/// belong to the receipt store, not here and never to the ledger — §9.2 is
/// emphatic, and the reason is durability. Keys rotate and get revoked;
/// permanent history cannot be allowed to stop meaning what it meant.
public struct VerifiedGrant: Equatable, Sendable {
    public let serverGrantID: UUID
    public let clientRequestID: UUID
    public let decidedAt: Date
    public let policyDigest: String
    public let roster: [PartnerVote]
    let kid: String
}

// MARK: - Parsing (only ever reached after a signature checked out)

extension GrantTrust {
    static func parseKeySet(document: Data, rootSignature: Data) throws -> VerifiedKeySet {
        let object = try json(document, or: TrustFailure.malformedKeySet("not an object"))
        guard let version = object["version"] as? Int else {
            throw TrustFailure.malformedKeySet("no version")
        }
        guard let issuedAtText = object["issued_at"] as? String,
              let issuedAt = PostgresTimestamp.parse(issuedAtText) else {
            throw TrustFailure.malformedKeySet("no issued_at")
        }
        guard let rawKeys = object["keys"] as? [[String: Any]] else {
            throw TrustFailure.malformedKeySet("no keys")
        }

        var keys: [SigningKey] = []
        for raw in rawKeys {
            guard let kid = raw["kid"] as? String,
                  let algorithm = raw["alg"] as? String,
                  let publicText = raw["public"] as? String,
                  let publicKey = Data(base64Encoded: publicText),
                  let stateText = raw["state"] as? String,
                  let state = SigningKey.State(rawValue: stateText),
                  let notBeforeText = raw["not_before"] as? String,
                  let notBefore = PostgresTimestamp.parse(notBeforeText) else {
                throw TrustFailure.malformedKeySet("unreadable key entry")
            }
            // 32 bytes or it is not an Ed25519 public key, whatever it claims.
            guard publicKey.count == 32 else {
                throw TrustFailure.malformedKeySet("\(kid): public key is not 32 bytes")
            }
            var notAfter: Date?
            if let text = raw["not_after"] as? String {
                guard let parsed = PostgresTimestamp.parse(text) else {
                    throw TrustFailure.malformedKeySet("\(kid): unreadable not_after")
                }
                notAfter = parsed
            }
            keys.append(SigningKey(kid: kid, algorithm: algorithm, publicKey: publicKey,
                                   notBefore: notBefore, notAfter: notAfter, state: state))
        }

        // A kid that is both listed and revoked is a contradiction, and the
        // safe reading of a contradiction about revocation is the revoked one.
        let revoked = Set((object["revoked"] as? [[String: Any]] ?? [])
            .compactMap { $0["kid"] as? String })

        return VerifiedKeySet(version: version, issuedAt: issuedAt,
                              keys: keys.filter { !revoked.contains($0.kid) },
                              revoked: revoked,
                              document: document, rootSignature: rootSignature)
    }

    static func parseGrant(document: Data) throws -> VerifiedGrant {
        let object = try json(document, or: TrustFailure.malformedGrant("not an object"))
        guard let decision = object["decision"] as? String else {
            throw TrustFailure.malformedGrant("no decision")
        }
        // The server only ever signs grants today, but a signed *denial* would
        // verify just as well, and treating one as permission because the code
        // never looked is precisely the bug this line exists to not have.
        guard decision == "granted" else { throw TrustFailure.notAGrant(decision) }

        guard let grantText = object["server_grant_id"] as? String,
              let serverGrantID = UUID(uuidString: grantText),
              let requestText = object["client_request_id"] as? String,
              let clientRequestID = UUID(uuidString: requestText),
              let decidedText = object["decided_at"] as? String,
              let decidedAt = PostgresTimestamp.parse(decidedText),
              let policyDigest = object["policy_digest"] as? String,
              let kid = object["kid"] as? String else {
            throw TrustFailure.malformedGrant("missing fields")
        }

        var roster: [PartnerVote] = []
        for raw in (object["roster"] as? [[String: Any]] ?? []) {
            guard let name = raw["partner_display_name"] as? String,
                  let voteText = raw["vote"] as? String,
                  let vote = PartnerVote.Kind(rawValue: voteText),
                  let atText = raw["at"] as? String,
                  let at = PostgresTimestamp.parse(atText) else {
                throw TrustFailure.malformedGrant("unreadable roster entry")
            }
            roster.append(PartnerVote(partnerDisplayName: name, vote: vote, at: at))
        }

        return VerifiedGrant(serverGrantID: serverGrantID, clientRequestID: clientRequestID,
                             decidedAt: decidedAt, policyDigest: policyDigest,
                             roster: roster, kid: kid)
    }

    private static func json(_ data: Data, or failure: TrustFailure) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure
        }
        return object
    }
}

// MARK: - Timestamps

/// Parsing the timestamps Postgres actually emits.
///
/// `jsonb` renders a `timestamptz` as `2026-08-24T10:00:00+00:00` — and as
/// `2026-08-24T10:00:00.123456+00:00` when there are microseconds, dropping
/// the fraction entirely when there are none. So the same column produces two
/// shapes depending on the value, `ISO8601DateFormatter` needs a different
/// option set for each, and picking one gives you a parser that works until a
/// timestamp lands on a whole second.
///
/// Six fractional digits is also more than `ISO8601DateFormatter` will accept
/// on every platform, so the fraction is separated out and applied by hand.
enum PostgresTimestamp {
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return whole.date(from: text) }

        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let zone = text[text.index(dot, offsetBy: 1 + digits.count)...]
        guard let base = whole.date(from: String(text[..<dot]) + String(zone)),
              let value = Double(digits) else { return nil }
        return base.addingTimeInterval(value / pow(10, Double(digits.count)))
    }
}
