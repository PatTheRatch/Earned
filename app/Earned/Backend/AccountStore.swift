import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import EarnedKit

/// Sign in with Apple, and the sync of Contract Envelopes that depends on it.
///
/// Everything here is optional to the running of Earned. With no backend
/// configured, or nobody signed in, every method is a no-op and the app behaves
/// exactly as it did before this existed. That is not politeness — the Solo
/// Override and every Gate must keep working through any outage of ours (S8).
@MainActor
final class AccountStore: ObservableObject {

    enum Session: Equatable {
        /// No `Backend.plist`. The honest state for a build with no project yet.
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(displayName: String)
        case failed(String)
    }

    @Published private(set) var session: Session
    @Published private(set) var registry: EnvelopeRegistry
    /// Set when a sync attempt failed, so the UI can say so once rather than
    /// per-commitment. Cleared by the next successful pass.
    @Published private(set) var syncFailure: String?

    private let client: BackendClient?
    private let storage: EnvelopeRegistryStorage
    private var currentNonce: String?

    private static let appleUserKey = "earned.appleUserID"
    private static let displayNameKey = "earned.displayName"

    init(storage: EnvelopeRegistryStorage = .documents()) {
        self.storage = storage
        self.registry = storage.load()
        let client = BackendClient()
        self.client = client
        self.session = client == nil ? .notConfigured : .signedOut
    }

    var isConfigured: Bool { client != nil }

    var appleUserID: String? { UserDefaults.standard.string(forKey: Self.appleUserKey) }

    // MARK: - Sign in with Apple

    /// Apple wants the SHA-256 of a nonce in the request and the raw nonce at
    /// verification, so a captured identity token cannot be replayed.
    func prepareRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        guard let client else { return }
        switch result {
        case .failure(let error):
            // A user cancelling is not a failure worth shouting about.
            if (error as? ASAuthorizationError)?.code == .canceled {
                session = .signedOut
            } else {
                session = .failed(error.localizedDescription)
            }
        case .success(let authorization):
            guard let credential = authorization.credential
                    as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                session = .failed("Apple returned no identity token.")
                return
            }
            // Apple sends the name exactly once, on first authorization, so it
            // is kept when offered and reused forever after.
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            let displayName = name.isEmpty
                ? (UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "Someone")
                : name
            UserDefaults.standard.set(credential.user, forKey: Self.appleUserKey)
            UserDefaults.standard.set(displayName, forKey: Self.displayNameKey)

            session = .signingIn
            let nonce = currentNonce
            Task {
                do {
                    try await client.signInWithApple(identityToken: token, nonce: nonce)
                    try await client.ensureAccount(appleUserID: credential.user,
                                                   displayName: displayName)
                    self.session = .signedIn(displayName: displayName)
                } catch {
                    self.session = .failed(error.localizedDescription)
                }
            }
        }
    }

    func signOut() {
        guard let client else { return }
        Task { await client.clearSession() }
        session = .signedOut
    }

    // MARK: - Envelope sync

    /// Registers every hardened-or-not commitment the server has not been told
    /// about, or whose terms have changed since it was told.
    ///
    /// Idempotent and safe to call often — on creation, on foreground, after
    /// signing in. Anything already registered on the same terms is skipped
    /// without a request.
    func syncEnvelopes(for commitments: [CommitmentRecord], now: Date) async {
        guard let client, case .signedIn = session else { return }
        var failure: String?

        for record in commitments where record.resolution == nil {
            let envelope = ContractEnvelope(record.commitment,
                                            version: nextVersion(for: record.commitment.id))
            if let existing = registry[record.commitment.id],
               existing.termsSignature == envelope.termsSignature,
               existing.status != .failed {
                continue
            }
            do {
                let receipt = try await client.registerEnvelope(envelope)
                registry.record(receipt, terms: envelope.termsSignature, at: now)
            } catch {
                // A frozen contract is not an error to retry forever: the
                // server is telling us the terms it holds are final, which is
                // the system working. Record it and stop asking.
                let message = error.localizedDescription
                registry.recordFailure(record.commitment.id,
                                       terms: envelope.termsSignature,
                                       reason: message, at: now)
                failure = message
            }
        }
        storage.save(registry)
        syncFailure = failure
    }

    /// A new version only when the server already acknowledged an earlier one;
    /// the server requires versions to increase and refuses a repeat.
    private func nextVersion(for commitmentID: UUID) -> Int {
        guard let existing = registry[commitmentID], existing.version > 0 else { return 1 }
        return existing.version + 1
    }

    func withdrawPlan(_ planID: UUID) async {
        guard let client, case .signedIn = session else { return }
        do { try await client.withdrawPlanEnvelopes(planID: planID) }
        catch { syncFailure = error.localizedDescription }
    }

    // MARK: - Status, as the UI asks it

    /// What the server knows about one commitment. The distinction the user
    /// actually needs: is this commitment covered, still in flight, or has it
    /// permanently lost the accountability route?
    enum Registration: Equatable {
        case unavailable        // no backend configured, or signed out
        case pending            // not registered yet, or edited since
        case registered
        case late               // S13 — accountability route shut, Solo remains
        case failed(String)
    }

    func registration(of commitment: Commitment) -> Registration {
        guard isConfigured else { return .unavailable }
        guard case .signedIn = session else { return .unavailable }
        guard let record = registry[commitment.id] else { return .pending }
        let envelope = ContractEnvelope(commitment)
        switch record.status {
        case .late: return .late
        case .failed: return .failed(record.failure ?? "Not registered.")
        case .registered:
            // Registered, but on terms that have since changed. Saying
            // "registered" here would be claiming cover we do not have.
            return record.termsSignature == envelope.termsSignature ? .registered : .pending
        }
    }

    // MARK: -

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }
}
