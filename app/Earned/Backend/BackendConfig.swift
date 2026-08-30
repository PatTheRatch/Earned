import Foundation

/// Where the backend lives, if it lives anywhere yet.
///
/// Earned works completely without a backend and must keep working: gates,
/// hardening, debt, restrictions and the Solo Override are all local and none
/// of them may start depending on our uptime (accountability-architecture §9,
/// S8). Until a project is configured, the account and envelope features simply
/// report themselves as unavailable rather than failing, retrying or nagging.
///
/// Read from `Backend.plist`, which is deliberately **not** in the repository —
/// the anon key is public by design but the project URL is still Patrick's, and
/// a checked-in file is one accidental fork away from strangers writing to it.
/// See backend/README.md for the two keys it needs.
struct BackendConfig: Sendable {
    let url: URL
    let anonKey: String

    static let shared: BackendConfig? = load()

    private static func load() -> BackendConfig? {
        guard let path = Bundle.main.url(forResource: "Backend", withExtension: "plist"),
              let data = try? Data(contentsOf: path) else { return nil }
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = parsed as? [String: String],
              let rawURL = plist["SupabaseURL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = plist["SupabaseAnonKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty, !key.isEmpty,
              let url = URL(string: rawURL)
        else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }
}
