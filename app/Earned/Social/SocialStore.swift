import Combine
import Foundation
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
    /// Set once when a fresh sign-in finds no profile, so the setup flow can
    /// be offered immediately rather than waiting to be discovered in a tab.
    @Published var setupOffered = false

    private let account: AccountStore
    /// Fetched avatars, by object path. Paths are random per upload, so a
    /// stale entry can only be an image nobody points at any more.
    private var avatarCache: [String: Data] = [:]
    private var accountID: String?

    init(account: AccountStore) {
        self.account = account
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
        } catch {
            failure = error.localizedDescription
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
