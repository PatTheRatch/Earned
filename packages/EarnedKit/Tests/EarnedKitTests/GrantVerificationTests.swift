import Foundation
import XCTest
@testable import EarnedKit

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Whether to believe a grant (§§9, 10).
///
/// Three different things are being checked here and they are worth keeping
/// apart, because each catches a failure the others cannot:
///
/// 1. **Policy**, with a fake primitive — revocation, key lifecycle, the
///    monotonic version rule. A fake also proves something a real signer
///    cannot: *which bytes reached it*, which is where verify-before-parse
///    either holds or silently doesn't.
/// 2. **Format**, against documents Postgres actually emitted. Every silent
///    failure this project has had was a disagreement about bytes rather than
///    about logic, and Swift tested against Swift would never see one.
/// 3. **Crypto**, on macOS, where CryptoKit exists. That is the only place
///    Postgres, OpenSSL and Swift are ever checked against each other.
final class GrantVerificationTests: XCTestCase {

    // MARK: - Stand-ins for the primitive

    /// Says yes, and remembers exactly what it was asked. Used where the
    /// question is "what did we hand it", not "is this signature good".
    final class Recorder: SignatureVerifier, @unchecked Sendable {
        struct Call: Equatable { let signature: Data, message: Data, publicKey: Data }
        private(set) var calls: [Call] = []
        var answer = true

        func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool {
            calls.append(Call(signature: signature, message: message, publicKey: publicKey))
            return answer
        }
    }

    /// `accept` is mutating, and XCTAssertThrowsError takes an autoclosure.
    /// The combination compiles, but reads like a trick; a plain closure does
    /// the same job and names the failure that was expected.
    private func assertRefuses(_ expected: TrustFailure, _ body: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TrustFailure, expected, file: file, line: line)
        }
    }

    private func trusting(_ document: String, _ signature: Data = Data(repeating: 1, count: 64),
                          anchor: Data = Data(repeating: 9, count: 32)) throws -> GrantTrust {
        var trust = GrantTrust(rootPublicKey: anchor, verifier: Recorder())
        try trust.accept(keySetDocument: Data(document.utf8), rootSignature: signature)
        return trust
    }

    // MARK: - 1. What reaches the primitive

    func testTheKeySetIsVerifiedOverExactlyTheBytesServed() throws {
        let recorder = Recorder()
        let anchor = Data(repeating: 9, count: 32)
        var trust = GrantTrust(rootPublicKey: anchor, verifier: recorder)
        let document = Data(GrantVectors.keySetV2.utf8)

        try trust.accept(keySetDocument: document,
                         rootSignature: GrantVectors.keySetV2Signature)

        // Not "a document with the same fields" — the same bytes. Re-encoding
        // anywhere on this path is the bug that makes a signature check
        // meaningless while every test about signatures still passes.
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.message, document)
        XCTAssertEqual(recorder.calls.first?.publicKey, anchor)
        XCTAssertEqual(recorder.calls.first?.signature, GrantVectors.keySetV2Signature)
    }

    func testTheGrantIsVerifiedOverExactlyTheBytesServed() throws {
        let recorder = Recorder()
        var trust = GrantTrust(rootPublicKey: Data(repeating: 9, count: 32), verifier: recorder)
        try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                         rootSignature: GrantVectors.keySetV2Signature)
        let document = Data(GrantVectors.grant.utf8)

        _ = try trust.verifyGrant(document: document, signature: GrantVectors.grantSignature,
                                  kid: "g1", expectedPolicyDigest: GrantVectors.policyDigest)

        let call = try XCTUnwrap(recorder.calls.last)
        XCTAssertEqual(call.message, document)
        XCTAssertEqual(call.signature, GrantVectors.grantSignature)
        // The key came from the key set, not from the grant. A grant that
        // could nominate its own key would be self-signed permission.
        XCTAssertEqual(call.publicKey, trust.keySet?.key("g1")?.publicKey)
    }

    func testNothingIsParsedUntilItHasBeenVerified() throws {
        // Bytes that no parser could survive, and a primitive that says no.
        // The refusal must be about the signature; a parse error here would
        // mean the parser ran on unauthenticated input, which is the one
        // ordering mistake this whole file exists to prevent.
        let recorder = Recorder()
        recorder.answer = false
        var trust = GrantTrust(rootPublicKey: Data(repeating: 9, count: 32), verifier: recorder)
        let junk = Data([0xFF, 0x00, 0xFE, 0x7B, 0x7B, 0x7B])

        assertRefuses(.rootSignatureInvalid) {
            try trust.accept(keySetDocument: junk, rootSignature: Data())
        }

        recorder.answer = true
        try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                         rootSignature: GrantVectors.keySetV2Signature)
        recorder.answer = false
        XCTAssertThrowsError(
            try trust.verifyGrant(document: junk, signature: Data(), kid: "g1",
                                  expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure, .signatureInvalid)
        }
    }

    // MARK: - 2. Policy

    func testWithoutAnAnchorNothingIsBelieved() {
        var trust = GrantTrust(rootPublicKey: Data(), verifier: Recorder())
        // Fails closed. An app with no trust anchor can still be used — the
        // Solo route is local and untouched (§11, S8) — but it cannot be
        // talked into accepting a grant by anyone at all.
        assertRefuses(.noTrustAnchor) {
            try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                             rootSignature: GrantVectors.keySetV2Signature)
        }
    }

    func testAKeySetCannotGoBackwards() throws {
        var trust = try trusting(GrantVectors.keySetV5)
        // The replay that matters: v2 is genuine and root-signed, and serving
        // it now would resurrect g1 after its revocation. Authenticity is not
        // freshness (§10.4).
        assertRefuses(.keySetWentBackwards(offered: 2, held: 5)) {
            try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                             rootSignature: GrantVectors.keySetV2Signature)
        }
        XCTAssertEqual(trust.keySet?.version, 5)
    }

    func testTheSameVersionAgainIsNotAnEvent() throws {
        var trust = try trusting(GrantVectors.keySetV2)
        let again = try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                                     rootSignature: GrantVectors.keySetV2Signature)
        // A cache re-serving what it has is ordinary, and must not look like
        // an attack or like news.
        XCTAssertEqual(again.version, 2)
        XCTAssertEqual(trust.keySet?.version, 2)
    }

    func testAKeyOnTheKillListIsRefused() throws {
        let trust = try trusting(GrantVectors.keySetV5)
        XCTAssertNil(trust.keySet?.key("g1"), "a revoked kid is not a trusted key")
        XCTAssertEqual(trust.keySet?.revoked, Set(["g1"]))
        XCTAssertThrowsError(
            try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                  signature: GrantVectors.grantSignature, kid: "g1",
                                  expectedPolicyDigest: GrantVectors.policyDigest)) {
            // Revocation reaches backwards. Once a key may have leaked there
            // is no telling which of its signatures were ours, so a grant it
            // signed last week is no longer evidence of anything.
            XCTAssertEqual($0 as? TrustFailure, .revokedKey("g1"))
        }
    }

    func testAKeyNobodyPublishedIsUnknown() throws {
        let trust = try trusting(GrantVectors.keySetV2)
        XCTAssertThrowsError(
            try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                  signature: GrantVectors.grantSignature, kid: "g7",
                                  expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure, .unknownKey("g7"))
        }
    }

    func testAKeyStillWaitingAsNextCannotSign() throws {
        // Key set v1 is the document published *before* g1 was promoted, so it
        // shows g1 as `next`. A signature from it is the server using a key it
        // never told anyone it would use, and refusing is §10.3 working.
        //
        // This is also why migration 0012 exists: the runbook used to stop at
        // promotion, so the newest published set said `next` forever and this
        // rule would have rejected every real grant. That gap is now closed on
        // the server, where an operator can see it.
        let trust = try trusting(GrantVectors.keySetV1)
        XCTAssertEqual(trust.keySet?.key("g1")?.state, .next)
        XCTAssertThrowsError(
            try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                  signature: GrantVectors.grantSignature, kid: "g1",
                                  expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure, .keyNotInService("g1"))
        }
    }

    func testARetiredKeyStillVerifiesWhatItSignedInService() throws {
        // Key set v4: g2 has taken over and g1 is retired with a cutoff. The
        // grant below was signed while g1 was current, and it stays good —
        // otherwise every rotation would silently invalidate history, and
        // rotation is supposed to be routine.
        let trust = try trusting(GrantVectors.keySetV4)
        XCTAssertEqual(trust.keySet?.key("g1")?.state, .retired)
        let grant = try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                          signature: GrantVectors.grantSignature, kid: "g1",
                                          expectedPolicyDigest: GrantVectors.policyDigest)
        XCTAssertEqual(grant.roster.count, 2)
    }

    func testAGrantForAContractThisAppDoesNotHoldIsRefused() throws {
        let trust = try trusting(GrantVectors.keySetV2)
        XCTAssertThrowsError(
            try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                  signature: GrantVectors.grantSignature, kid: "g1",
                                  expectedPolicyDigest: "sha256:0000")) {
            // The partners approved specific terms (§4.5). A grant against
            // different terms answers a question nobody was asked.
            guard case .contractMismatch = $0 as? TrustFailure else {
                return XCTFail("expected a contract mismatch, got \($0)")
            }
        }
    }

    func testAGrantLabelledWithADifferentKeyThanItNamesIsRefused() throws {
        let trust = try trusting(GrantVectors.keySetV2)
        let document = try rewritten(GrantVectors.grant) { $0["kid"] = "g2" }
        XCTAssertThrowsError(
            try trust.verifyGrant(document: document, signature: GrantVectors.grantSignature,
                                  kid: "g1", expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure,
                           .keyIdentifierMismatch(labelled: "g1", document: "g2"))
        }
    }

    func testASignedDenialIsNotPermission() throws {
        let trust = try trusting(GrantVectors.keySetV2)
        let document = try rewritten(GrantVectors.grant) { $0["decision"] = "denied" }
        XCTAssertThrowsError(
            try trust.verifyGrant(document: document, signature: GrantVectors.grantSignature,
                                  kid: "g1", expectedPolicyDigest: GrantVectors.policyDigest)) {
            // A denial verifies exactly as well as a grant does. Only reading
            // the field tells them apart.
            XCTAssertEqual($0 as? TrustFailure, .notAGrant("denied"))
        }
    }

    func testAPublicKeyOfTheWrongLengthIsNotAKey() throws {
        var trust = GrantTrust(rootPublicKey: Data(repeating: 9, count: 32), verifier: Recorder())
        let document = try rewritten(GrantVectors.keySetV2) { object in
            var keys = object["keys"] as! [[String: Any]]
            keys[0]["public"] = Data(repeating: 7, count: 31).base64EncodedString()
            object["keys"] = keys
        }
        do {
            try trust.accept(keySetDocument: document, rootSignature: Data())
            XCTFail("a 31-byte public key was accepted")
        } catch {
            guard case .malformedKeySet = error as? TrustFailure else {
                return XCTFail("expected a malformed key set, got \(error)")
            }
        }
    }

    // MARK: - 3. Format, against what Postgres actually emitted

    func testTheRealKeySetReadsAsItWasWritten() throws {
        let trust = try trusting(GrantVectors.keySetV4)
        let keySet = try XCTUnwrap(trust.keySet)
        XCTAssertEqual(keySet.version, 4)
        XCTAssertEqual(keySet.keys.map(\.kid), ["g2", "g1"], "current first, then the rest")
        XCTAssertEqual(keySet.keys.map(\.state), [.current, .retired])
        XCTAssertTrue(keySet.keys.allSatisfy { $0.publicKey.count == 32 })
        XCTAssertTrue(keySet.keys.allSatisfy { $0.algorithm == "ed25519" })
        XCTAssertNil(keySet.key("g2")?.notAfter, "a current key has no cutoff")
        XCTAssertNotNil(keySet.key("g1")?.notAfter, "a retired one does")
        XCTAssertEqual(keySet.document, Data(GrantVectors.keySetV4.utf8))
    }

    func testTheRealGrantReadsAsItWasWritten() throws {
        let trust = try trusting(GrantVectors.keySetV2)
        let grant = try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                          signature: GrantVectors.grantSignature, kid: "g1",
                                          expectedPolicyDigest: GrantVectors.policyDigest)
        XCTAssertEqual(grant.roster.map(\.partnerDisplayName), ["Mom", "Dave"])
        XCTAssertTrue(grant.roster.allSatisfy { $0.vote == .approve })
        XCTAssertEqual(grant.policyDigest, GrantVectors.policyDigest)
        // The roster is ordered by when people voted, and the decision lands
        // with the vote that met the threshold.
        XCTAssertEqual(grant.roster[0].at.timeIntervalSince1970,
                       grant.roster[1].at.timeIntervalSince1970, accuracy: 60)
        XCTAssertEqual(grant.decidedAt, grant.roster[1].at)
    }

    func testTheTimestampShapesPostgresActuallyProduces() throws {
        // All three of these come out of the same timestamptz column. Postgres
        // trims trailing zeros from the fraction and drops the fraction
        // entirely on a whole second, so one ISO8601DateFormatter option set
        // parses some of them and silently returns nil for the rest — which
        // reads, downstream, as a malformed document rather than as a parser
        // that was only ever half right.
        let whole = try XCTUnwrap(PostgresTimestamp.parse("2026-08-31T11:39:02+00:00"))
        let five = try XCTUnwrap(PostgresTimestamp.parse("2026-08-31T11:39:02.04729+00:00"))
        let six = try XCTUnwrap(PostgresTimestamp.parse("2026-08-31T11:39:02.191614+00:00"))
        XCTAssertEqual(five.timeIntervalSince(whole), 0.04729, accuracy: 1e-6)
        XCTAssertEqual(six.timeIntervalSince(whole), 0.191614, accuracy: 1e-6)
        XCTAssertEqual(PostgresTimestamp.parse("2026-08-31T11:39:02Z"), whole)
        XCTAssertNil(PostgresTimestamp.parse("not a timestamp"))

        // And none of those shapes is hypothetical: every timestamp in every
        // vector the server produced has to come back out.
        var seen = 0
        for vector in [GrantVectors.keySetV1, GrantVectors.keySetV2, GrantVectors.keySetV3,
                       GrantVectors.keySetV4, GrantVectors.keySetV5, GrantVectors.grant] {
            for match in vector.split(whereSeparator: { $0 == "\"" })
            where match.hasSuffix("+00:00") {
                XCTAssertNotNil(PostgresTimestamp.parse(String(match)),
                                "the server emitted \(match) and we cannot read it")
                seen += 1
            }
        }
        XCTAssertGreaterThan(seen, 10, "the vectors should be full of timestamps")
    }

    // MARK: - 4. Real crypto, where there is any

    #if canImport(CryptoKit)
    struct CryptoKitVerifier: SignatureVerifier {
        func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            else { return false }
            return key.isValidSignature(signature, for: message)
        }
    }

    /// The only place Postgres, OpenSSL and Swift are checked against one
    /// another. Everything else in this file would still pass if Swift had
    /// quietly come to disagree with the server about what the bytes are.
    func testRealSignaturesFromTheRealServerVerifyHere() throws {
        var trust = GrantTrust(rootPublicKey: GrantVectors.rootPublicKey,
                               verifier: CryptoKitVerifier())
        try trust.accept(keySetDocument: Data(GrantVectors.keySetV1.utf8),
                         rootSignature: GrantVectors.keySetV1Signature)
        try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                         rootSignature: GrantVectors.keySetV2Signature)

        let grant = try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                          signature: GrantVectors.grantSignature,
                                          kid: GrantVectors.grantKid,
                                          expectedPolicyDigest: GrantVectors.policyDigest)
        XCTAssertEqual(grant.roster.map(\.partnerDisplayName), ["Mom", "Dave"])
    }

    func testTheNegativeControls() throws {
        var trust = GrantTrust(rootPublicKey: GrantVectors.rootPublicKey,
                               verifier: CryptoKitVerifier())
        try trust.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                         rootSignature: GrantVectors.keySetV2Signature)

        // A real Ed25519 signature over the right bytes by the wrong key. If
        // this is ever accepted, nothing above proves anything.
        XCTAssertThrowsError(
            try trust.verifyGrant(document: Data(GrantVectors.grant.utf8),
                                  signature: GrantVectors.grantSignatureByWrongKey,
                                  kid: "g1",
                                  expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure, .signatureInvalid)
        }

        // One character of the document, changed in a way that means nothing.
        let tampered = Data(GrantVectors.grant.replacingOccurrences(of: "\"Mom\"",
                                                                    with: "\"Bob\"").utf8)
        XCTAssertThrowsError(
            try trust.verifyGrant(document: tampered, signature: GrantVectors.grantSignature,
                                  kid: "g1", expectedPolicyDigest: GrantVectors.policyDigest)) {
            XCTAssertEqual($0 as? TrustFailure, .signatureInvalid)
        }

        // And a key set whose root signature is not the root's.
        var fresh = GrantTrust(rootPublicKey: GrantVectors.rootPublicKey,
                               verifier: CryptoKitVerifier())
        assertRefuses(.rootSignatureInvalid) {
            try fresh.accept(keySetDocument: Data(GrantVectors.keySetV2.utf8),
                             rootSignature: GrantVectors.keySetV3Signature)
        }
    }
    #endif

    // MARK: - Helpers

    /// Rebuild a document with one field changed. Only ever used with a fake
    /// primitive: a rewritten document has no valid signature, which is the
    /// point of every test that uses it.
    private func rewritten(_ source: String,
                           _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
