import Foundation
import CryptoKit
import EarnedKit

/// The one immortal value in Earned, and the Ed25519 primitive it is used with
/// (docs/accountability-architecture.md §10.1).
///
/// The root public key is **compiled in, not configured**. `Backend.plist`
/// says which server to talk to; this says whom to believe, and those must not
/// be the same lever — a file that could point the app at another server *and*
/// tell it which key to trust would be no boundary at all. It is a public key,
/// so there is nothing here to keep secret; what matters is that it cannot be
/// swapped without shipping a build.
///
/// Its private half never touches any server (§10.1). It signs key sets and
/// only key sets, which is what makes staying offline practical: serving a
/// grant needs a grant key, and grant keys rotate without it.
enum TrustAnchor {

    /// Base64 of the raw 32-byte Ed25519 public key — the second line of
    /// `openssl pkey -in root.pem -pubout`, or more exactly:
    ///
    ///     openssl pkey -in root.pem -pubout -outform DER | tail -c 32 | openssl base64 -A
    ///
    /// Empty would mean every grant is refused, which is the correct failure
    /// for a build with no anchor: an app that trusts nothing still works —
    /// commitments, hardening, restrictions and the Solo Override are all
    /// local and owe our servers nothing (§11, S8) — whereas an app that
    /// trusts anything is worse than one with no accountability route at all.
    ///
    /// Replacing this is an app release, deliberately. There is no in-band
    /// recovery from a compromised root key and never should be (§10.4).
    static let rootPublicKeyBase64 = "B34GQSHMiPqHbYeA2eOMklYXKnKfykttSQ1Z0Sr+ADU="

    static var rootPublicKey: Data { Data(base64Encoded: rootPublicKeyBase64) ?? Data() }

    static var isConfigured: Bool { rootPublicKey.count == 32 }

    /// CryptoKit, behind EarnedKit's protocol so the domain package stays free
    /// of a dependency it cannot have on Linux — and so its tests can use a
    /// fake that reports which bytes it was handed, which is the property that
    /// actually goes wrong.
    struct Verifier: SignatureVerifier {
        func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            else { return false }
            return key.isValidSignature(signature, for: message)
        }
    }

    static func trust(keySet: VerifiedKeySet? = nil) -> GrantTrust {
        GrantTrust(rootPublicKey: rootPublicKey, verifier: Verifier(), keySet: keySet)
    }
}
