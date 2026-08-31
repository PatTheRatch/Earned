import Foundation

/// The transport to Supabase: sign in, and call the two functions that are the
/// only write path into a Contract Envelope.
///
/// Deliberately thin. There is no ORM here and no table access, because the
/// schema grants the app none — every write goes through a `SECURITY DEFINER`
/// function that re-derives the account from the JWT and enforces the contract
/// rules itself (backend/migrations/0003, 0004). If this type ever grows a
/// method that writes a table directly, the trust boundary has moved.
actor BackendClient {
    enum Failure: LocalizedError {
        case notConfigured
        case notSignedIn
        /// The server refused. `message` is its own words — a monotonicity
        /// violation, a frozen contract — and is shown rather than flattened
        /// into "something went wrong".
        case refused(status: Int, message: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No backend is configured."
            case .notSignedIn: return "Not signed in."
            case .refused(_, let message): return message
            case .transport(let message): return message
            }
        }
    }

    private let config: BackendConfig
    private let session: URLSession
    private var accessToken: String?

    init?(config: BackendConfig? = BackendConfig.shared, session: URLSession = .shared) {
        guard let config else { return nil }
        self.config = config
        self.session = session
    }

    var isSignedIn: Bool { accessToken != nil }

    func clearSession() { accessToken = nil }

    // MARK: - Auth

    /// Exchanges an Apple identity token for a Supabase session.
    ///
    /// The identity token is Apple's, signed by Apple, and verified by Supabase
    /// — the app never asserts who it is, it forwards a claim someone else can
    /// check. Same shape as every other trust boundary here.
    @discardableResult
    func signInWithApple(identityToken: String, nonce: String?) async throws -> String {
        var body: [String: String] = ["provider": "apple", "id_token": identityToken]
        if let nonce { body["nonce"] = nonce }
        let json = try await post(path: "/auth/v1/token?grant_type=id_token",
                                  body: body, authorized: false)
        guard let token = json["access_token"] as? String else {
            throw Failure.refused(status: 200, message: "Sign-in returned no session.")
        }
        accessToken = token
        return token
    }

    // MARK: - Account

    @discardableResult
    func ensureAccount(appleUserID: String, displayName: String) async throws -> [String: Any] {
        try await rpc("ensure_account", [
            "p_apple_user_id": appleUserID,
            "p_display_name": displayName,
        ])
    }

    // MARK: - Contract Envelope

    /// Registers or updates one commitment's accountability terms.
    ///
    /// Note what is *not* sent: the requirement, the restriction profile, any
    /// workout, any progress. And note what is not sent back as authoritative —
    /// the app does not tell the server when the commitment hardens, it is told
    /// (accountability-architecture §4.2).
    @discardableResult
    func registerEnvelope(_ envelope: ContractEnvelope) async throws -> EnvelopeReceipt {
        var params: [String: Any] = [
            "p_commitment_id": envelope.commitmentID.uuidString,
            "p_title": envelope.title,
            "p_created_at": Self.timestamp(envelope.createdAt),
            "p_eligible_from": Self.timestamp(envelope.eligibleFrom),
            "p_deadline": Self.timestamp(envelope.deadline),
            "p_correction_window": envelope.correctionWindow,
            "p_approvals_required": envelope.approvalsRequired,
            "p_accountability_window": envelope.accountabilityWindow,
            "p_partner_ids": envelope.partnerIDs.map(\.uuidString),
            "p_version": envelope.version,
        ]
        if let planID = envelope.planID { params["p_plan_id"] = planID.uuidString }
        let json = try await rpc("register_contract_envelope", params)
        return try EnvelopeReceipt(json: json)
    }

    @discardableResult
    func withdrawPlanEnvelopes(planID: UUID) async throws -> [String: Any] {
        try await rpc("withdraw_plan_envelopes", ["p_plan_id": planID.uuidString])
    }

    /// A contract's standing *now*, not when it was registered.
    ///
    /// Needed because a roster member can revoke afterwards: the threshold
    /// stands and the route quietly goes unavailable, and an app still showing
    /// the answer it got at registration would be claiming a way out that no
    /// longer exists.
    func envelopeStatus(commitmentID: UUID) async throws -> EnvelopeReceipt? {
        let json = try await rpc("envelope_status", ["p_commitment_id": commitmentID.uuidString])
        guard json["registered"] as? Bool == true else { return nil }
        return try EnvelopeReceipt(json: json)
    }

    // MARK: - Partners

    /// Sends a contact address to the server exactly once. Everything after
    /// this — normalising it, encrypting it, deriving its blind index, deciding
    /// whether it is suppressed, and composing the invitation — happens there.
    /// The consent token is never returned here, because an app that could see
    /// it could consent on its partner's behalf.
    func nominatePartner(displayName: String,
                         channel: Partner.Channel,
                         contact: String) async throws -> UUID {
        let json = try await rpc("nominate_partner", [
            "p_display_name": displayName,
            "p_channel": channel.rawValue,
            "p_contact": contact,
        ])
        guard let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            throw Failure.refused(status: 200, message: "The server did not confirm the partner.")
        }
        return id
    }

    func resendInvitation(partnerID: UUID) async throws {
        _ = try await rpc("resend_partner_invitation", ["p_partner_id": partnerID.uuidString])
    }

    func revokePartner(partnerID: UUID) async throws {
        _ = try await rpc("revoke_partner", ["p_partner_id": partnerID.uuidString])
    }

    /// Reads the partner list from the table directly — the one place the app
    /// has any table access at all, and it is SELECT-only on its own rows.
    func loadPartners() async throws -> [Partner] {
        guard accessToken != nil else { throw Failure.notSignedIn }
        let query = "/rest/v1/partner?select=id,display_name,channel,status,consent_asked_at,"
            + "consented_at,consent_resent_at&order=created_at.asc"
        let rows: [[String: Any]] = try await get(path: query)
        return rows.compactMap(Partner.init(row:))
    }

    // MARK: - Social: profile

    /// The caller's own account id — needed only to address their avatar
    /// folder in Storage. Read from the one table the app can SELECT its own
    /// row of; no other user's id is ever learnable this way.
    func myAccountID() async throws -> String {
        let rows: [[String: Any]] = try await get(path: "/rest/v1/account?select=id")
        guard let id = rows.first?["id"] as? String else {
            throw Failure.refused(status: 200, message: "No account row for this session.")
        }
        return id.lowercased()
    }

    /// The caller's profile, or nil when setup hasn't happened — which is the
    /// profile-completion check itself (docs/social-architecture.md §4.2).
    func myProfile() async throws -> SocialProfile? {
        SocialProfile(json: try await rpc("my_profile", [:]))
    }

    @discardableResult
    func upsertProfile(handle: String, displayName: String,
                       city: String?, timezone: String?) async throws -> SocialProfile? {
        var params: [String: Any] = ["p_handle": handle, "p_display_name": displayName]
        if let city { params["p_city"] = city }
        if let timezone { params["p_timezone"] = timezone }
        return SocialProfile(json: try await rpc("upsert_my_profile", params))
    }

    func setDiscoverability(_ discoverable: Bool) async throws {
        _ = try await rpc("set_my_discoverability", ["p_discoverable": discoverable])
    }

    // MARK: - Social: friends

    func sendFriendRequest(handle: String) async throws {
        _ = try await rpc("send_friend_request", ["p_handle": handle])
    }

    func respondToFriendRequest(handle: String, accept: Bool) async throws {
        _ = try await rpc("respond_to_friend_request",
                          ["p_handle": handle, "p_accept": accept])
    }

    func cancelFriendRequest(handle: String) async throws {
        _ = try await rpc("cancel_friend_request", ["p_handle": handle])
    }

    func removeFriend(handle: String) async throws {
        _ = try await rpc("remove_friend", ["p_handle": handle])
    }

    func blockUser(handle: String) async throws {
        _ = try await rpc("block_user", ["p_handle": handle])
    }

    func unblockUser(handle: String) async throws {
        _ = try await rpc("unblock_user", ["p_handle": handle])
    }

    func loadFriends() async throws -> [SocialPerson] {
        (try await rpcValue("my_friends", [:]) as? [[String: Any]] ?? [])
            .compactMap(SocialPerson.init(json:))
    }

    func loadFriendRequests() async throws -> FriendRequests {
        let json = try await rpc("my_friend_requests", [:])
        var requests = FriendRequests()
        requests.incoming = (json["incoming"] as? [[String: Any]] ?? [])
            .compactMap(SocialPerson.init(json:))
        requests.outgoing = (json["outgoing"] as? [[String: Any]] ?? [])
            .compactMap(SocialPerson.init(json:))
        return requests
    }

    func loadBlocked() async throws -> [SocialPerson] {
        (try await rpcValue("my_blocked", [:]) as? [[String: Any]] ?? [])
            .compactMap(SocialPerson.init(json:))
    }

    func searchProfiles(query: String) async throws -> [SocialPerson] {
        (try await rpcValue("search_profiles", ["p_query": query]) as? [[String: Any]] ?? [])
            .compactMap(SocialPerson.init(json:))
    }

    /// A profile as the caller may see it. Nil is an answer, not an error:
    /// not found, blocked, and undiscoverable are one indistinguishable nil.
    func loadProfile(handle: String) async throws -> PublicProfile? {
        PublicProfile(json: try await rpc("get_profile", ["p_handle": handle]))
    }

    // MARK: - Social: avatar storage

    /// Uploads the re-encoded derivative under the caller's own folder, then
    /// points the profile at it. Returns the replaced object's path, which the
    /// caller should delete — its visibility already died with the repoint.
    func uploadAvatar(path: String, jpeg: Data) async throws -> String? {
        try await storage(method: "POST", path: path,
                          body: jpeg, contentType: "image/jpeg")
        let json = try await rpc("set_my_avatar", ["p_path": path])
        return json["previous"] as? String
    }

    func clearAvatar() async throws -> String? {
        (try await rpc("clear_my_avatar", [:]))["previous"] as? String
    }

    func deleteAvatarObject(path: String) async throws {
        try await storage(method: "DELETE", path: path, body: nil, contentType: nil)
    }

    /// Fetches an avatar through the authenticated route; RLS decides whether
    /// this caller may see this object.
    func fetchAvatar(path: String) async throws -> Data {
        guard accessToken != nil else { throw Failure.notSignedIn }
        guard let url = URL(string: "/storage/v1/object/authenticated/avatars/\(path)",
                            relativeTo: config.url) else {
            throw Failure.transport("Bad backend path.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.refused(status: status, message: "The avatar could not be fetched.")
        }
        return data
    }

    private func storage(method: String, path: String,
                         body: Data?, contentType: String?) async throws {
        guard accessToken != nil else { throw Failure.notSignedIn }
        guard let url = URL(string: "/storage/v1/object/avatars/\(path)",
                            relativeTo: config.url) else {
            throw Failure.transport("Bad backend path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw Failure.refused(status: status,
                                  message: Self.failureMessage(json, status: status))
        }
    }

    // MARK: - Overrides and grants

    /// Ask the roster. Everything that decides the answer — the threshold, who
    /// is on it, whether the contract has hardened — comes from the envelope
    /// the server holds; what is sent here is only what the *partners* will be
    /// shown (§7), and it is labelled self-reported because it is.
    ///
    /// `clientRequestID` is the idempotency key (§9.4). It must be the same on
    /// a retry, or a user who lost the response gets a second request and five
    /// people get a second message.
    @discardableResult
    func createOverrideRequest(clientRequestID: UUID,
                               commitmentID: UUID,
                               progressAchieved: Double,
                               progressRequired: Double,
                               progressUnit: String,
                               reliability: (completed: Int, of: Int,
                                             overrideRequests: Int, missed: Int),
                               reason: String?) async throws -> OverrideRequestReceipt {
        var params: [String: Any] = [
            "p_client_request_id": clientRequestID.uuidString,
            "p_commitment_id": commitmentID.uuidString,
            "p_progress_achieved": progressAchieved,
            "p_progress_required": progressRequired,
            "p_progress_unit": progressUnit,
            "p_reliability_completed": reliability.completed,
            "p_reliability_of": reliability.of,
            "p_reliability_override_requests": reliability.overrideRequests,
            "p_reliability_missed": reliability.missed,
        ]
        if let reason, !reason.isEmpty { params["p_reason"] = reason }
        return try OverrideRequestReceipt(json: await rpc("create_override_request", params))
    }

    /// The published key set, with the root signature beside it.
    ///
    /// Deliberately callable signed out: it is public by design (§10.2), and
    /// an app that could only learn about key rotation while authenticated
    /// would be least able to verify anything exactly when it most needs to.
    func fetchKeySet() async throws -> (document: Data, rootSignature: Data) {
        let json = try await post(path: "/rest/v1/rpc/current_key_set",
                                  body: [String: String](), authorized: accessToken != nil)
        guard let document = json["document"] as? String,
              let signature = json["root_signature"] as? String,
              let rootSignature = Data(base64Encoded: signature) else {
            throw Failure.refused(status: 200, message: "The key set came back unreadable.")
        }
        // `.utf8` of the string the server sent is the byte sequence the root
        // signed. JSON transport escapes bytes losslessly and Swift does not
        // normalise strings it decodes, so this round-trips exactly — which it
        // must, because verification is over these bytes and nothing else.
        return (Data(document.utf8), rootSignature)
    }

    /// Everything this account has been granted, signed.
    ///
    /// Goes to the edge function rather than the RPC because signing happens
    /// there: the key lives in that function's environment and nowhere the
    /// database can reach (§9, migration 0011). The function calls `my_grants`
    /// with this caller's own JWT, so RLS applies here exactly as anywhere.
    func fetchGrants() async throws -> [SignedGrant] {
        guard accessToken != nil else { throw Failure.notSignedIn }
        let json = try await post(path: "/functions/v1/grants",
                                  body: [String: String](), authorized: true)
        guard let rows = json["grants"] as? [[String: Any]] else { return [] }
        return rows.compactMap(SignedGrant.init(row:))
    }

    // MARK: - Plumbing

    /// ISO-8601 with fractional seconds. The server parses microseconds and the
    /// hardening arithmetic is done in seconds on both sides, so dropping the
    /// fraction here would be a real, if small, divergence.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String { formatter.string(from: date) }

    /// The most useful sentence in a refusal, wherever this project's three
    /// services happen to have put it.
    ///
    /// PostgREST puts a raised exception's message in `message`. Those are
    /// written to be read by a person — "this contract has hardened; its
    /// accountability terms are frozen" — so pass them through rather than
    /// inventing a worse one.
    ///
    /// Supabase Auth answers with `msg`, and it is the one that matters at the
    /// very first step a user takes: "Unacceptable audience in id_token" names
    /// a misconfigured provider exactly, where "the server refused the request
    /// (400)" sends you looking at the app instead.
    private static func failureMessage(_ json: [String: Any], status: Int) -> String {
        json["message"] as? String
            ?? json["msg"] as? String
            ?? json["error_description"] as? String
            ?? json["error"] as? String
            ?? "The server refused the request (\(status))."
    }

    private func rpc(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard accessToken != nil else { throw Failure.notSignedIn }
        return try await post(path: "/rest/v1/rpc/\(name)", body: params, authorized: true)
    }

    /// For functions that return something other than a JSON object — an
    /// array, a scalar, or SQL null (which arrives as NSNull).
    private func rpcValue(_ name: String, _ params: [String: Any]) async throws -> Any {
        guard accessToken != nil else { throw Failure.notSignedIn }
        return try await postValue(path: "/rest/v1/rpc/\(name)", body: params, authorized: true)
    }

    private func get<T>(path: String) async throws -> [T] {
        guard let url = URL(string: path, relativeTo: config.url) else {
            throw Failure.transport("Bad backend path.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw Failure.refused(status: status,
                                  message: Self.failureMessage(json, status: status))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [T] ?? []
    }

    private func post(path: String, body: Any, authorized: Bool) async throws -> [String: Any] {
        try await postValue(path: path, body: body, authorized: authorized) as? [String: Any] ?? [:]
    }

    private func postValue(path: String, body: Any, authorized: Bool) async throws -> Any {
        guard let url = URL(string: path, relativeTo: config.url) else {
            throw Failure.transport("Bad backend path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Supabase's publishable key. Identifies the project and selects the
        // `anon` role; the user's own JWT below is what promotes a request to
        // `authenticated`, and RLS keys off that, never off this.
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if authorized, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? JSONSerialization.jsonObject(with: data,
                                                       options: [.fragmentsAllowed])) ?? [:] as Any
        guard (200..<300).contains(status) else {
            let json = value as? [String: Any] ?? [:]
            throw Failure.refused(status: status,
                                  message: Self.failureMessage(json, status: status))
        }
        return value
    }
}
