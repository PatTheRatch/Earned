import Combine
import Foundation
import EarnedKit
import EarnedMedia

/// The social layer's state: the user's own profile, their friends, and the
/// requests in flight.
///
/// Rides `AccountStore`'s session and transport rather than holding its own.
/// Everything here is optional to the running of Earned — with no backend, or
/// signed out, every method is a quiet no-op, because a social outage must
/// never touch Gate enforcement or the Solo Override (S8, invariant 25).
@MainActor
final class SocialStore: ObservableObject {

    enum ProfileState: Equatable {
        /// Not asked yet, or not signed in.
        case unknown
        case loading
        /// Signed in, no profile — setup is the next step.
        case missing
        case ready(SocialProfile)

        var profile: SocialProfile? {
            if case .ready(let profile) = self { return profile }
            return nil
        }
    }

    @Published private(set) var profileState: ProfileState = .unknown
    @Published private(set) var friends: [SocialPerson] = []
    @Published private(set) var requests = FriendRequests()
    @Published private(set) var blocked: [SocialPerson] = []
    /// The last thing that went wrong, in the server's own words. Cleared by
    /// the next successful call.
    @Published var failure: String?
    /// When the social pass last ran, and whether it worked. `failure` says
    /// what broke; this says whether anything has been attempted at all, which
    /// is the difference between "no friends yet" and "never reached the
    /// server" — indistinguishable on screen, and the first thing a beta
    /// report needs to separate.
    @Published private(set) var lastSync: SyncStamp?
    /// Set once when a fresh sign-in finds no profile, so the setup flow can
    /// be offered immediately rather than waiting to be discovered in a tab.
    @Published var setupOffered = false

    /// Friends' recent events, as the server curates them: bounded, 30-day
    /// horizon, meaningful only. Empty is a normal answer, rendered honestly.
    @Published private(set) var activity: [SocialEvent] = []
    /// Which commitments this user shares, and what was last published.
    @Published private(set) var sharing: SharingRegistry
    /// Shared commitments this user stands on, roster and all, as the server
    /// curates them. Presentation only — no Gate reads any of this.
    @Published private(set) var sharedCommitments: [SharedCommitment] = []
    /// Invitations waiting on this user. Obligations of nobody's (invariant 31).
    @Published private(set) var sharedInvitations: [SharedInvitation] = []
    /// Which of this user's own commitments belong to shared agreements.
    @Published private(set) var sharedRegistry: SharedCommitmentRegistry

    private let account: AccountStore
    private let sharingStorage: SharingRegistryStorage
    private let sharedStorage: SharedCommitmentRegistryStorage
    /// Fetched avatars, by object path. Paths are random per upload, so a
    /// stale entry can only be an image nobody points at any more.
    private var avatarCache: [String: Data] = [:]
    private var accountID: String?

    init(account: AccountStore,
         sharingStorage: SharingRegistryStorage = .documents(),
         sharedStorage: SharedCommitmentRegistryStorage = .documents()) {
        self.account = account
        self.sharingStorage = sharingStorage
        self.sharedStorage = sharedStorage
        self.sharing = sharingStorage.load()
        self.sharedRegistry = sharedStorage.load()
    }

    private var client: BackendClient? {
        guard case .signedIn = account.session else { return nil }
        return account.client
    }

    var needsSetup: Bool { profileState == .missing }

    // MARK: - Profile

    /// Re-reads the caller's profile. `offeringSetup` is passed after a
    /// sign-in, where finding nothing should surface the setup flow once.
    func refreshProfile(offeringSetup: Bool = false) async {
        guard let client else {
            profileState = .unknown
            return
        }
        if case .unknown = profileState { profileState = .loading }
        do {
            if let profile = try await client.myProfile() {
                profileState = .ready(profile)
            } else {
                profileState = .missing
                if offeringSetup { setupOffered = true }
            }
            failure = nil
        } catch {
            // Leave the state as it was: a network failure is not "no profile",
            // and it must never look like one.
            if case .loading = profileState { profileState = .unknown }
            failure = error.localizedDescription
        }
    }

    /// Create or update the profile. Returns whether the save landed, so the
    /// setup flow can advance only on success.
    @discardableResult
    func saveProfile(handle: String, displayName: String, city: String?) async -> Bool {
        guard let client else { return false }
        do {
            let saved = try await client.upsertProfile(
                handle: handle.normalizedHandle,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                city: city?.trimmingCharacters(in: .whitespacesAndNewlines),
                // Private system information, refreshed on every save — the
                // user moves, the device knows, nobody else ever sees it.
                timezone: TimeZone.current.identifier)
            if let saved { profileState = .ready(saved) }
            failure = nil
            return saved != nil
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    func setDiscoverable(_ discoverable: Bool) async {
        guard let client else { return }
        do {
            try await client.setDiscoverability(discoverable)
            await refreshProfile()
        } catch { failure = error.localizedDescription }
    }

    // MARK: - Avatar

    /// Re-encodes whatever the picker produced and uploads the derivative.
    /// The original bytes never leave this method (docs/social-architecture.md
    /// §6.1); the replaced object is deleted once the pointer has moved.
    func setAvatar(pickedData: Data) async {
        guard let client else { return }
        do {
            let jpeg = try AvatarEncoder.encode(pickedData)
            if accountID == nil { accountID = try await client.myAccountID() }
            guard let accountID else { return }
            let path = "\(accountID)/\(UUID().uuidString.lowercased()).jpg"
            let previous = try await client.uploadAvatar(path: path, jpeg: jpeg)
            avatarCache[path] = jpeg
            if let previous {
                // Cleanup, not the boundary: the old object stopped being
                // visible to anyone else the moment the profile repointed.
                try? await client.deleteAvatarObject(path: previous)
                avatarCache[previous] = nil
            }
            await refreshProfile()
        } catch is AvatarEncoder.Failure {
            failure = "That image couldn't be used. Try a different photo."
        } catch {
            failure = error.localizedDescription
        }
    }

    func removeAvatar() async {
        guard let client else { return }
        do {
            if let previous = try await client.clearAvatar() {
                try? await client.deleteAvatarObject(path: previous)
                avatarCache[previous] = nil
            }
            await refreshProfile()
        } catch { failure = error.localizedDescription }
    }

    /// An avatar's bytes, if this caller is allowed them. Nil renders as
    /// initials — including when the server says no, which is not an error.
    func avatarData(path: String?) async -> Data? {
        guard let path, let client else { return nil }
        if let cached = avatarCache[path] { return cached }
        guard let data = try? await client.fetchAvatar(path: path) else { return nil }
        avatarCache[path] = data
        return data
    }

    // MARK: - Friends

    func refreshSocial() async {
        guard let client else { return }
        do {
            friends = try await client.loadFriends()
            requests = try await client.loadFriendRequests()
            blocked = try await client.loadBlocked()
            failure = nil
            lastSync = .succeeded()
        } catch {
            failure = error.localizedDescription
            lastSync = .failed(error.localizedDescription)
        }
    }

    func sendRequest(handle: String) async {
        await perform { try await $0.sendFriendRequest(handle: handle) }
    }

    func respond(handle: String, accept: Bool) async {
        await perform { try await $0.respondToFriendRequest(handle: handle, accept: accept) }
    }

    func cancelRequest(handle: String) async {
        await perform { try await $0.cancelFriendRequest(handle: handle) }
    }

    func removeFriend(handle: String) async {
        await perform { try await $0.removeFriend(handle: handle) }
    }

    func block(handle: String) async {
        await perform { try await $0.blockUser(handle: handle) }
    }

    func unblock(handle: String) async {
        await perform { try await $0.unblockUser(handle: handle) }
    }

    func search(query: String) async -> [SocialPerson] {
        guard let client, query.normalizedHandle.count >= 2 else { return [] }
        do {
            let results = try await client.searchProfiles(query: query)
            failure = nil
            return results
        } catch {
            failure = error.localizedDescription
            return []
        }
    }

    /// A profile as this user may see it. Nil means not found — deliberately
    /// also the answer for blocked and undiscoverable (§5.3).
    func profile(handle: String) async -> PublicProfile? {
        guard let client else { return nil }
        return try? await client.loadProfile(handle: handle)
    }

    /// The three answers a profile lookup can actually have.
    ///
    /// `profile(handle:)` collapses the last two, which is wrong on a screen:
    /// "no such person" and "we could not ask" look identical and mean
    /// opposite things. A friend whose phone is on a bad train connection must
    /// not read as a friend who blocked you.
    enum ProfileLookup: Equatable {
        case found(PublicProfile)
        /// Not found — deliberately also the answer for blocked and
        /// undiscoverable (§5.3). The server does not distinguish them and
        /// neither may this.
        case notFound
        case failed(String)
    }

    func lookUpProfile(handle: String) async -> ProfileLookup {
        guard let client else { return .failed("Sign in to look up profiles.") }
        do {
            guard let profile = try await client.loadProfile(handle: handle) else {
                return .notFound
            }
            return .found(profile)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Commitment sharing (docs/social-architecture.md §7, §9)

    func isShared(_ commitmentID: UUID) -> Bool { sharing.isShared(commitmentID) }

    /// Choose to share a commitment with friends, and tell the server now.
    /// The choice is the registry entry; the publish is distribution.
    func share(_ record: CommitmentRecord, now: Date) async {
        sharing.share(record.commitment.id)
        sharingStorage.save(sharing)
        await syncSharing(commitments: [record], now: now)
    }

    /// Stop sharing. The server withdraws the commitment and every event it
    /// generated — nothing survives because a friend once saw it (§7.2).
    func unshare(_ commitmentID: UUID) async {
        sharing.unshare(commitmentID)
        sharingStorage.save(sharing)
        guard let client else { return }
        do {
            try await client.unshareCommitment(commitmentID: commitmentID)
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    /// Publish whatever changed since the server last heard: state
    /// transitions, edited titles, nothing else. Safe to call every
    /// foreground; publishing is idempotent on both ends.
    func syncSharing(commitments: [CommitmentRecord], now: Date) async {
        guard let client, !sharing.records.isEmpty else { return }

        for commitment in commitments {
            let id = commitment.commitment.id
            guard let record = sharing[id] else { continue }
            guard let story = Self.story(of: commitment) else {
                // Cancelled inside its correction window: a withdrawn
                // commitment is withdrawn socially too.
                try? await client.unshareCommitment(commitmentID: id)
                sharing.unshare(id)
                continue
            }
            let title = commitment.commitment.title.isEmpty
                ? "A workout" : commitment.commitment.title
            guard story.state != record.lastPublishedState
                    || title != record.lastPublishedTitle else { continue }
            do {
                try await client.publishSharedCommitment(
                    commitmentID: id, title: title,
                    deadline: commitment.commitment.deadline,
                    state: story.state, resolvedAt: story.resolvedAt)
                sharing.recordPublished(id, state: story.state, title: title)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
        sharingStorage.save(sharing)
    }

    /// What a friend may be told about a commitment's standing — and only
    /// that. The server further quiets 'overridden' to 'ended' unless the
    /// owner shares Override usage; nothing else ever leaves the ledger.
    private static func story(of record: CommitmentRecord) -> (state: String, resolvedAt: Date?)? {
        switch record.resolution {
        case .completed(let at):
            return (at <= record.commitment.deadline ? "kept" : "kept_late", at)
        case .overridden(_, let at):
            return ("overridden", at)
        case .cancelled:
            return nil
        case nil:
            return ("open", nil)
        }
    }

    // MARK: - Shared commitments (NORTHSTAR §46, docs/shared-commitments.md)

    func refreshShared() async {
        guard let client else { return }
        do {
            sharedCommitments = try await client.loadSharedCommitments()
            sharedInvitations = try await client.loadSharedInvitations()
            // The server is authoritative for the link between agreement and
            // personal commitment; the local registry only caches it, so it
            // heals here after a reinstall or a lost write.
            for shared in sharedCommitments {
                if let mine = shared.myCommitmentID {
                    sharedRegistry.link(mine, toAgreement: shared.id)
                }
            }
            sharedStorage.save(sharedRegistry)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The shared commitment one of this user's own commitments belongs to.
    func sharedCommitment(for commitmentID: UUID) -> SharedCommitment? {
        guard let agreementID = sharedRegistry.agreementID(for: commitmentID) else { return nil }
        return sharedCommitments.first { $0.id == agreementID }
    }

    /// Registers a just-created commitment as a shared one and sends the
    /// invitations. The creator's own Deal was already signed locally — this
    /// distributes the promise, never the punishment.
    func createShared(for record: CommitmentRecord, invitees: [String], now: Date) async {
        guard let client else { return }
        let commitment = record.commitment
        let terms = SharedTerms(requirement: commitment.requirement,
                                windowStart: commitment.eligibleFrom,
                                deadline: commitment.deadline)
        do {
            let agreementID = try await client.createSharedCommitment(
                commitmentID: commitment.id,
                title: commitment.title.isEmpty ? "A workout" : commitment.title,
                terms: terms,
                handles: invitees.map(\.normalizedHandle),
                verification: commitment.requirement.verification.sharedWireValue)
            sharedRegistry.link(commitment.id, toAgreement: agreementID)
            sharedStorage.save(sharedRegistry)
            failure = nil
            await refreshShared()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Accepts an invitation and creates the participant's own personal
    /// commitment — their Gate, their rules — in that order: the server
    /// records the binding first, and only a recorded acceptance creates
    /// anything locally. Returns whether both halves landed.
    ///
    /// The server repeats back the commitment id that stands, so a retried
    /// acceptance (timeout, crash, double-tap) converges on one commitment
    /// instead of minting a second.
    @discardableResult
    func acceptSharedInvitation(_ invitation: SharedInvitation,
                                into store: EarnedStore,
                                verification: WorkoutVerification,
                                correctionWindow: TimeInterval,
                                overridePolicy: OverridePolicy,
                                rewardEligible: Bool,
                                warningLead: TimeInterval?) async -> Bool {
        guard let client else { return false }
        guard let requirement = invitation.terms.requirement(verification: verification) else {
            failure = "This build can't enforce that requirement. Update Earned first."
            return false
        }
        do {
            let minted = UUID()
            let recorded = try await client.respondToSharedInvitation(
                id: invitation.id, accept: true, commitmentID: minted,
                verification: verification.sharedWireValue)
            let commitmentID = recorded ?? minted
            sharedRegistry.link(commitmentID, toAgreement: invitation.id)
            sharedStorage.save(sharedRegistry)
            failure = nil
            // A retry that converged on an earlier acceptance may find the
            // commitment already in the ledger; that is success, not a
            // duplicate to create.
            if store.state.commitments[commitmentID] == nil {
                // Their own hardening clock starts now, at their acceptance —
                // never at the inviter's creation (invariant 31). A shared
                // window that opens later than today opens later for them too.
                guard store.createCommitment(
                    id: commitmentID,
                    title: invitation.title,
                    requirement: requirement,
                    eligibleFrom: invitation.terms.windowStart,
                    deadline: invitation.terms.deadline,
                    correctionWindow: correctionWindow,
                    overridePolicy: overridePolicy,
                    rewardEligible: rewardEligible,
                    warningLead: warningLead) else { return false }
            }
            await refreshShared()
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    func declineSharedInvitation(_ invitation: SharedInvitation) async {
        guard let client else { return }
        do {
            _ = try await client.respondToSharedInvitation(
                id: invitation.id, accept: false, commitmentID: nil, verification: nil)
            failure = nil
        } catch { failure = error.localizedDescription }
        await refreshShared()
    }

    /// Leave the roster. A social act only: the personal commitment is exactly
    /// as escapable afterwards as before (invariant 32).
    func leaveShared(_ shared: SharedCommitment) async {
        guard let client else { return }
        do {
            try await client.leaveSharedCommitment(id: shared.id)
            failure = nil
        } catch { failure = error.localizedDescription }
        await refreshShared()
    }

    /// Cancel the unstarted future of an agreement the user created. Everyone
    /// already bound keeps exactly the commitment they accepted.
    func cancelShared(_ shared: SharedCommitment) async {
        guard let client else { return }
        do {
            try await client.cancelSharedCommitment(id: shared.id)
            failure = nil
        } catch { failure = error.localizedDescription }
        await refreshShared()
    }

    /// Publish this user's own lines: progress against each shared target and
    /// how each commitment stands. Safe to call every foreground — only
    /// changes are sent, and the server is idempotent about the rest.
    func syncSharedProgress(commitments: [CommitmentRecord],
                            state earnedState: EarnedState, now: Date) async {
        guard let client, !sharedRegistry.records.isEmpty else { return }
        for record in commitments {
            let id = record.commitment.id
            guard sharedRegistry[id] != nil else { continue }
            guard let story = Self.story(of: record) else { continue }
            let achieved = earnedState.progress(for: id)?.achieved ?? 0
            let cached = sharedRegistry[id]
            guard story.state != cached?.lastPublishedState
                    || achieved != cached?.lastPublishedProgress else { continue }
            do {
                try await client.publishSharedProgress(
                    commitmentID: id, progress: achieved,
                    state: story.state, resolvedAt: story.resolvedAt)
                sharedRegistry.recordPublished(id, progress: achieved, state: story.state)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
        sharedStorage.save(sharedRegistry)
    }

    // MARK: - Streaks and activity

    /// Publish the ledger's two figures, if the owner shares them. The server
    /// no-ops when the switch is off, so racing a toggle costs nothing.
    func publishStreaks(_ streaks: SocialStreaks) async {
        guard let client, profileState.profile?.shareStreaks == true else { return }
        try? await client.setSocialStreaks(commitmentsKept: streaks.commitmentsKept,
                                           sinceLastOverride: streaks.sinceLastOverride)
    }

    func setSharing(shareStreaks: Bool? = nil, shareOverrideUsage: Bool? = nil,
                    shareLastCheckin: Bool? = nil) async {
        guard let client else { return }
        do {
            try await client.setSocialSharing(shareStreaks: shareStreaks,
                                              shareOverrideUsage: shareOverrideUsage,
                                              shareLastCheckin: shareLastCheckin)
            await refreshProfile()
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    /// Tell the server Earned heard from this phone. Called on every
    /// foreground pass; the server records it only while the owner shares
    /// check-ins, so this is safe to call unconditionally. A failure is
    /// silence about silence — there is nothing useful to surface.
    func checkIn() async {
        guard let client, case .ready = profileState else { return }
        try? await client.recordCheckin()
    }

    func refreshActivity() async {
        guard let client else { return }
        do {
            activity = try await client.friendActivity()
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func perform(_ action: (BackendClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await refreshSocial()
    }
}
