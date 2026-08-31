import Foundation

/// What the server says back when a request is created
/// (docs/accountability-architecture.md §§5, 9.4).
///
/// Note what is absent: any token, and any partner identity beyond a count.
/// The requesting device learns that its request exists and how many people
/// were asked — never who, and never how they are answering (S1, S6). A device
/// that could see a token could vote on its own behalf.
struct OverrideRequestReceipt: Equatable, Sendable {
    let id: UUID
    let state: String
    /// False when this was an idempotent replay of a request that already
    /// existed (§9.4). Worth surfacing: it is the difference between "five
    /// people were just messaged" and "nobody was messaged again".
    let created: Bool
    let approvalsRequired: Int
    let partnersNotified: Int
    let requestedAt: Date?
    let expiresAt: Date?

    init(json: [String: Any]) throws {
        guard let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            throw BackendClient.Failure.refused(
                status: 200, message: "The server did not confirm the request.")
        }
        self.id = id
        self.state = json["state"] as? String ?? "open"
        self.created = json["created"] as? Bool ?? false
        self.approvalsRequired = json["approvals_required"] as? Int ?? 0
        self.partnersNotified = json["partners_notified"] as? Int ?? 0
        self.requestedAt = (json["requested_at"] as? String).flatMap(Self.parse)
        self.expiresAt = (json["expires_at"] as? String).flatMap(Self.parse)
    }

    private static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}

/// A grant exactly as served: bytes, a signature beside them, and the key id
/// they arrived labelled with.
///
/// Nothing here is parsed. That is the point — the document stays an opaque
/// blob until EarnedKit has checked a signature over it, and the `kid` is used
/// only to pick which key to check against (§9.1, §10.2). Picking the wrong
/// key makes verification fail, which is why an unauthenticated label is safe
/// to use for that and for nothing else.
struct SignedGrant: Equatable, Sendable {
    let commitmentID: UUID
    let document: Data
    let signature: Data
    let kid: String

    init(commitmentID: UUID, document: Data, signature: Data, kid: String) {
        self.commitmentID = commitmentID
        self.document = document
        self.signature = signature
        self.kid = kid
    }

    init?(row: [String: Any]) {
        guard let idString = row["commitment_id"] as? String,
              let commitmentID = UUID(uuidString: idString),
              let document = row["document"] as? String,
              let signatureText = row["signature"] as? String,
              let signature = Data(base64Encoded: signatureText),
              let kid = row["kid"] as? String else { return nil }
        self.commitmentID = commitmentID
        // The bytes the server signed. Not a re-encoding of a parsed object:
        // JSON transport escapes losslessly and Swift does not normalise
        // decoded strings, so `.utf8` here is the same byte sequence Postgres
        // composed and OpenSSL signed. Anything that reconstructed this
        // document from fields would break verification for reasons nobody
        // could see.
        self.document = Data(document.utf8)
        self.signature = signature
        self.kid = kid
    }
}
