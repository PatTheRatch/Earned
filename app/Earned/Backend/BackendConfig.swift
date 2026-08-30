import Foundation

/// Where the backend lives, if it lives anywhere yet.
///
/// Earned works completely without a backend and must keep working: gates,
/// hardening, debt, restrictions and the Solo Override are all local and none
/// of them may start depending on our uptime (accountability-architecture §9,
/// S8). Until a project is configured, the account and envelope features simply
/// report themselves as unavailable rather than failing, retrying or nagging.
///
/// Read from `Backend.plist`, which is deliberately **not** in the repository.
/// The publishable key is public by design — it ships inside every copy of the
/// app — but the project it points at is Patrick's, and RLS protecting the data
/// is not the same as wanting strangers creating accounts against his quota.
/// See backend/README.md for the two values it needs.
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
              // Supabase renamed the client-side key: `sb_publishable_…`
              // replaces the old anon JWT. Both names are accepted so a file
              // written against either set of docs works.
              let key = (plist["SupabasePublishableKey"] ?? plist["SupabaseAnonKey"])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty, !key.isEmpty,
              let url = URL(string: rawURL)
        else { return nil }
        return BackendConfig(url: url, anonKey: key)
    }
}
