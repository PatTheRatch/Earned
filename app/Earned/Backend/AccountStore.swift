import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import EarnedKit
import Security

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
    @Published private(set) var partners: [Partner] = []
    /// Incoming asks: people who want this user as *their* partner.
    @Published private(set) var partnerRequests: [PartnerRequest] = []
    /// Override requests waiting on this user's decision, as an earned partner.
    @Published private(set) var pendingApprovals: [PendingApproval] = []
    /// The server's own words when it refuses a nomination — "Earned can't send
    /// messages to this contact", "you have already invited this contact".
    /// Shown as written rather than flattened into a generic failure.
    @Published var partnerFailure: String?
    /// Anything that stopped a grant being believed — a build with no trust
    /// anchor, a signature that did not check out, a network that was not
    /// there. Separate from `syncFailure` because the answers are different:
    /// one means try again later, the other means something is wrong.
    @Published private(set) var grantFailure: String?
    /// Grants this device is keeping because it could not check them yet
    /// (§11). Surfaced so "waiting to hear back" can be honest about the
    /// difference between nobody answering and us not being able to tell.
    @Published private(set) var heldGrants: Int = 0
    /// The server's answer to the last override request, so the UI can say
    /// how many people were actually asked rather than guessing from the
    /// roster — a partner who has since revoked is on the roster and is not
    /// asked.
    @Published private(set) var lastRequest: OverrideRequestReceipt?
    @Published private(set) var requestFailure: String?
    /// When the envelope and grant passes last ran, for the diagnostics screen.
    /// `syncFailure`/`grantFailure` say *what* went wrong; these say *when*,
    /// which is the half that distinguishes a broken sync from one that has
    /// simply never been attempted on this phone.
    @Published private(set) var lastEnvelopeSync: SyncStamp?
    @Published private(set) var lastGrantSync: SyncStamp?

    /// Shared with `SocialStore`, which rides the same session rather than
    /// holding a second one. Internal, not private, for exactly that reader.
    let client: BackendClient?
    private let storage: EnvelopeRegistryStorage
    private let grants: GrantStore
    private var currentNonce: String?

    private static let appleUserKey = "earned.appleUserID"
    private static let displayNameKey = "earned.displayName"

    init(storage: EnvelopeRegistryStorage = .documents(),
         grants: GrantStore = .documents()) {
        self.storage = storage
        self.grants = grants
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

    // MARK: - Partners

    /// Partners who may be counted on in a contract roster.
    ///
    /// Invariant 22: only a partner who has already consented is eligible. An
    /// invitation nobody answered is not a person who will approve anything,
    /// and a contract built on one is dead from birth.
    var eligiblePartners: [Partner] { partners.filter { $0.state.isEligibleForRoster } }

    /// Partners who have been asked and have not answered. Surfaced so the
    /// reason a name is missing from the picker is visible rather than puzzling.
    var awaitingConsent: [Partner] { partners.filter { $0.state == .invited } }

    /// Where a friend stands as an accountability partner, by handle. Nil
    /// means no relationship has ever been asked for — the friend-picker's
    /// "ask" state. This is the earned-partner lookup, and it works because
    /// `my_partners()` carries the live handle for earned rows.
    func earnedPartnerState(handle: String) -> Partner.State? {
        partners.first { $0.kind == .earnedUser && $0.handle == handle }?.state
    }

    func refreshPartners() async {
        guard let client, case .signedIn = session else { return }
        do {
            partners = try await client.loadPartners()
            // The two things other people may be waiting on this user for:
            // asks to *be* a partner, and override approvals to decide.
            partnerRequests = try await client.loadPartnerRequests()
            pendingApprovals = try await client.loadPendingApprovals()
        }
        catch { partnerFailure = error.localizedDescription }
    }

    /// Ask an accepted friend to be an accountability partner. Friendship is
    /// the channel the ask travels through; it is never the consent
    /// (invariant 24) — the friend answers in-app, or the ask stays pending.
    func nominateEarnedPartner(handle: String) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            try await client.nominateEarnedPartner(handle: handle)
            await refreshPartners()
        } catch { partnerFailure = error.localizedDescription }
    }

    func respondToPartnerRequest(_ request: PartnerRequest, accept: Bool) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            try await client.respondToPartnerRequest(id: request.id, accept: accept)
            partnerRequests.removeAll { $0.id == request.id }
        } catch { partnerFailure = error.localizedDescription }
    }

    /// Decide someone else's override request, as their earned partner. The
    /// same vote the web page casts, with the session as the credential.
    func castVote(on approval: PendingApproval, approve: Bool) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            try await client.castOverrideVote(recipientID: approval.recipientID,
                                              approve: approve)
            pendingApprovals.removeAll { $0.recipientID == approval.recipientID }
        } catch { partnerFailure = error.localizedDescription }
    }

    func nominatePartner(displayName: String, channel: Partner.Channel, contact: String) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            _ = try await client.nominatePartner(displayName: displayName,
                                                 channel: channel, contact: contact)
            await refreshPartners()
        } catch {
            partnerFailure = error.localizedDescription
        }
    }

    func resendInvitation(to partner: Partner) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            try await client.resendInvitation(partnerID: partner.id)
            await refreshPartners()
        } catch { partnerFailure = error.localizedDescription }
    }

    /// Removing a partner. Never a refusal on their behalf: no suppression row
    /// is written, because this person declined nothing. It also never lowers a
    /// threshold already agreed — a contract that loses too many partners
    /// becomes unavailable rather than easier (§4.3).
    func revokePartner(_ partner: Partner) async {
        guard let client, case .signedIn = session else { return }
        partnerFailure = nil
        do {
            try await client.revokePartner(partnerID: partner.id)
            await refreshPartners()
        } catch { partnerFailure = error.localizedDescription }
    }

    // MARK: - Envelope sync

    /// Registers every hardened-or-not commitment the server has not been told
    /// about, or whose terms have changed since it was told.
    ///
    /// Idempotent and safe to call often — on creation, on foreground, after
    /// signing in. Anything already registered on the same terms is skipped
    /// without a request.
    func syncEnvelopes(for commitments: [CommitmentRecord],
                       rosters: [UUID: [UUID]] = [:],
                       now: Date) async {
        guard let client, case .signedIn = session else { return }
        var failure: String?

        for record in commitments where record.resolution == nil {
            let envelope = ContractEnvelope(record.commitment,
                                            partnerIDs: rosters[record.commitment.id]
                                                ?? registry[record.commitment.id]?.partnerIDs ?? [],
                                            version: nextVersion(for: record.commitment.id))
            if let existing = registry[record.commitment.id],
               existing.termsSignature == envelope.termsSignature,
               existing.status != .failed {
                // Registered on these exact terms already. Its *standing* can
                // still have changed since — a roster member may have revoked —
                // so re-read rather than re-register.
                if let receipt = try? await client.envelopeStatus(commitmentID: record.commitment.id) {
                    registry.record(receipt, terms: envelope.termsSignature,
                                    partnerIDs: envelope.partnerIDs, at: now)
                }
                continue
            }
            do {
                let receipt = try await client.registerEnvelope(envelope)
                registry.record(receipt, terms: envelope.termsSignature,
                                partnerIDs: envelope.partnerIDs, at: now)
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
        lastEnvelopeSync = failure.map { SyncStamp.failed($0) } ?? .succeeded()
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

    /// Whether the server currently says this commitment has a working way
    /// out through its partners. The server's answer, re-read on every sync —
    /// a partner can revoke while Earned isn't running, and an app still
    /// showing the answer it got at registration would be offering a route
    /// that no longer exists.
    func hasAccountabilityRoute(for commitmentID: UUID) -> Bool {
        guard case .signedIn = session else { return false }
        return registry[commitmentID]?.accountabilityAvailable == true
    }

    // MARK: - Asking the roster

    /// Ask this commitment's partners to let the user out.
    ///
    /// Called *after* the local `overrideRequested` event, never instead of
    /// it, and never conditional on this succeeding. The Solo Override's clock
    /// starts on the local one and its availability depends on nothing we run
    /// (§11, S8) — a user must never be trapped by our downtime, which is the
    /// only defensible behaviour for a product that takes away access to
    /// someone's phone.
    ///
    /// `requestID` is the ledger's own request id and is reused verbatim as
    /// the server's `client_request_id`. That is what lets a grant find its
    /// way back to the request it answers, and it is also the idempotency key
    /// (§9.4): a retry after a lost response returns the same request rather
    /// than messaging five people twice.
    func requestOverride(requestID: UUID,
                         commitmentID: UUID,
                         progress: CommitmentProgress?,
                         reliability: ReliabilityStats,
                         reason: String? = nil) async {
        guard let client, case .signedIn = session else { return }
        guard registry[commitmentID]?.accountabilityAvailable == true else {
            // No live route: not registered, registered late (S13), or the
            // roster has fallen below the threshold that was agreed. Silent
            // here because the UI already shows which routes exist — what it
            // must not do is claim partners were asked when they were not.
            return
        }
        // Labels on the fallback too: an unlabelled tuple on either side of
        // `??` collapses the whole expression to an unlabelled type, and the
        // three arguments below are all Doubles that would then be positional.
        let shown = progress.map(Self.forPartners)
            ?? (achieved: 0, required: 0, unit: "")
        do {
            let receipt = try await client.createOverrideRequest(
                clientRequestID: requestID,
                commitmentID: commitmentID,
                progressAchieved: shown.achieved,
                progressRequired: shown.required,
                progressUnit: shown.unit,
                reliability: (completed: reliability.completed,
                              // The server wants "8 of 10". EarnedKit counts
                              // outcomes rather than a total, so the total is
                              // the outcomes that happened — a commitment
                              // still live is not yet part of either number.
                              of: reliability.completed + reliability.missedDeadlines,
                              overrideRequests: reliability.overrideRequests,
                              missed: reliability.missedDeadlines),
                reason: reason)
            lastRequest = receipt
            requestFailure = nil
        } catch {
            requestFailure = error.localizedDescription
        }
    }

    /// Progress as a partner should read it, not as the engine stores it.
    ///
    /// "1080 of 1800 seconds" is a number about our data model; "18 of 30
    /// minutes" is the thing the partner is being asked to judge (§13). The
    /// conversion is here rather than on the page because the page renders
    /// whatever it is given and must not have to know our units.
    private static func forPartners(_ progress: CommitmentProgress)
        -> (achieved: Double, required: Double, unit: String) {
        switch progress.unit {
        case .workouts:
            return (progress.achieved, progress.required, "workouts")
        case .seconds:
            return ((progress.achieved / 60).rounded(), (progress.required / 60).rounded(),
                    "minutes")
        case .meters:
            guard progress.required >= 1000 else {
                return (progress.achieved.rounded(), progress.required.rounded(), "metres")
            }
            return (((progress.achieved / 100).rounded() / 10),
                    ((progress.required / 100).rounded() / 10), "km")
        case .kilocalories:
            return (progress.achieved.rounded(), progress.required.rounded(), "cal")
        }
    }

    // MARK: - Grants

    /// Ask what we have been granted, and check it.
    ///
    /// Returns the events to append rather than appending them: the ledger's
    /// own rules decide whether a grant is still meaningful — the commitment
    /// may have been finished while a partner was tapping approve (§12) — and
    /// that decision belongs to EarnedKit, not to a networking type.
    ///
    /// A receipt is written only after the caller reports the ledger accepted
    /// the event, so the audit trail never claims something the domain refused.
    func syncGrants() async -> [GrantSync.Verified] {
        guard let client, case .signedIn = session else { return [] }
        // Only commitments whose terms this device actually knows. A grant is
        // checked against the digest the server gave us when it acknowledged
        // the contract; without it there is nothing to compare (§4.5).
        let digests = registry.records.compactMapValues(\.policyDigest)

        let outcome = await GrantSync(client: client, store: grants).run(policyDigests: digests)
        heldGrants = outcome.held
        grantFailure = outcome.failure ?? outcome.refused.first
        lastGrantSync = grantFailure.map { SyncStamp.failed($0) } ?? .succeeded()
        return outcome.verified
    }

    /// Called back once the ledger has accepted a grant's event.
    func recordReceipt(for verified: GrantSync.Verified) {
        guard let client else { return }
        grants.record(GrantSync(client: client, store: grants).receipt(for: verified))
    }

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }
}
