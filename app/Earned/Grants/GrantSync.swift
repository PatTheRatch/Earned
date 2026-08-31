import Foundation
import EarnedKit

/// Fetching grants and deciding what to believe about them
/// (docs/accountability-architecture.md §§9, 10.2, 11).
///
/// The order matters and is the reason this is one type rather than two calls
/// from a view: **the key set is fetched first, every time**. A grant signed
/// by a key this device has not yet heard of is unverifiable, and a grant
/// signed by a key that has since been revoked must stop being believed. Both
/// of those are answered by the key set, so asking for grants before refreshing
/// it would mean holding grants that were verifiable all along, and honouring
/// ones that no longer are.
///
/// Nothing here touches the ledger. It reports what it verified and what it
/// could not, and the caller decides what to append — because appending is a
/// domain act with its own rules (§9.4) and this type has no business knowing
/// them.
struct GrantSync {
    let client: BackendClient
    let store: GrantStore

    struct Verified {
        let signed: SignedGrant
        let grant: VerifiedGrant
        let keySetVersion: Int
    }

    struct Outcome {
        var verified: [Verified] = []
        /// Grants that could not be checked yet and are being kept. Not a
        /// failure count: a held grant is the system working (§11).
        var held: Int = 0
        /// Grants refused outright — a bad signature, a revoked key, terms
        /// this app never agreed to. These are worth seeing.
        var refused: [String] = []
        var failure: String?
    }

    /// `policyDigests` is what this app believes each commitment's terms are.
    /// A commitment missing from it cannot have a grant checked against it, so
    /// its grant is held rather than accepted — the partners approved specific
    /// terms, and a device that does not know which terms cannot confirm that
    /// the terms it is being shown are the ones they saw (§4.5).
    func run(policyDigests: [UUID: String], now: Date = Date()) async -> Outcome {
        var outcome = Outcome()
        var trust = store.restoredTrust()

        guard TrustAnchor.isConfigured else {
            // No root key was compiled in, so nothing can ever be verified.
            // Said plainly and once: the Solo route is untouched, and quietly
            // holding every grant forever would look like a network problem.
            outcome.failure = "This build has no trust anchor, so approvals cannot be verified."
            return outcome
        }

        // 1. The key set, first and regardless.
        do {
            let (document, signature) = try await client.fetchKeySet()
            _ = try trust.accept(keySetDocument: document, rootSignature: signature)
            store.saveKeySet(document: document, rootSignature: signature, at: now)
        } catch let failure as TrustFailure {
            // A served key set that does not verify, or that goes backwards,
            // is not a reason to stop: the cached one is still good, and
            // carrying on with it is exactly what rollback resistance is for.
            outcome.refused.append("key set: \(failure)")
        } catch {
            // Offline. The cache carries on (§11).
            outcome.failure = error.localizedDescription
        }

        // 2. Everything held from a previous attempt gets another chance
        //    against the key set as it now stands — which is the entire reason
        //    those grants were kept.
        var incoming = store.held().map {
            SignedGrant(commitmentID: $0.commitmentID, document: $0.document,
                        signature: $0.signature, kid: $0.kid)
        }
        let heldBefore = Set(incoming.map(\.document))

        do {
            let fetched = try await client.fetchGrants()
            incoming += fetched.filter { !heldBefore.contains($0.document) }
        } catch {
            if outcome.failure == nil { outcome.failure = error.localizedDescription }
        }

        // 3. Verify each, and sort into believed, held, or refused.
        var resolved: Set<Data> = []
        for signed in incoming {
            guard let expected = policyDigests[signed.commitmentID] else {
                hold(signed, reason: "no contract on this device to check it against", now: now)
                outcome.held += 1
                continue
            }
            do {
                let grant = try trust.verifyGrant(document: signed.document,
                                                  signature: signed.signature,
                                                  kid: signed.kid,
                                                  expectedPolicyDigest: expected)
                outcome.verified.append(Verified(signed: signed, grant: grant,
                                                 keySetVersion: trust.keySet?.version ?? 0))
                resolved.insert(signed.document)
            } catch let failure as TrustFailure {
                // Held or dropped, and EarnedKit decides which — it is a rule
                // about the trust model, and it is switched exhaustively over
                // there where there are tests for it.
                if failure.isWorthRetryingAfterAKeyRefresh {
                    hold(signed, reason: String(describing: failure), now: now)
                    outcome.held += 1
                } else {
                    resolved.insert(signed.document)
                    outcome.refused.append(String(describing: failure))
                }
            } catch {
                outcome.refused.append(error.localizedDescription)
            }
        }
        store.release(documents: resolved)
        return outcome
    }

    /// The receipt is written by the caller, after the ledger has accepted the
    /// event — so a receipt never claims something the domain refused.
    func receipt(for verified: Verified, at moment: Date = Date()) -> GrantStore.Receipt {
        GrantStore.Receipt(serverGrantID: verified.grant.serverGrantID,
                           commitmentID: verified.signed.commitmentID,
                           payload: verified.signed.document,
                           signature: verified.signed.signature,
                           kid: verified.signed.kid,
                           policyDigest: verified.grant.policyDigest,
                           verifiedAt: moment,
                           keySetVersion: verified.keySetVersion,
                           verifierVersion: GrantStore.verifierVersion)
    }

    private func hold(_ signed: SignedGrant, reason: String, now: Date) {
        store.hold(GrantStore.Held(commitmentID: signed.commitmentID,
                                   document: signed.document,
                                   signature: signed.signature,
                                   kid: signed.kid,
                                   firstSeenAt: now,
                                   reason: reason))
    }
}
