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

    private func rpc(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard accessToken != nil else { throw Failure.notSignedIn }
        return try await post(path: "/rest/v1/rpc/\(name)", body: params, authorized: true)
    }

    private func post(path: String, body: Any, authorized: Bool) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: config.url) else {
            throw Failure.transport("Bad backend path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            // PostgREST puts a raised exception's message in `message`. Those
            // messages are written to be read by a person — "this contract has
            // hardened; its accountability terms are frozen" — so pass them
            // through rather than inventing a worse one.
            let message = json["message"] as? String
                ?? json["error_description"] as? String
                ?? "The server refused the request (\(status))."
            throw Failure.refused(status: status, message: message)
        }
        return json
    }
}
