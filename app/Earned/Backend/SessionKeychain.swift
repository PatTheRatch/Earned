import Foundation
import Security

/// Where the refresh token lives between launches.
///
/// Sign in with Apple cannot be replayed silently — Apple only hands over an
/// identity token in response to a deliberate user gesture — so without
/// something persisted here, every cold launch left the app signed out until
/// the user happened to tap the button again. Which quietly broke the thing
/// accounts exist for: a partner's approval, a friend's invitation and a shared
/// commitment's roster all arrive on the foreground sync pass, and that pass
/// does nothing while signed out. The user opens Earned to find out whether
/// they have been let off, and Earned does not ask.
///
/// **Keychain rather than `UserDefaults`,** which is where the Apple user id
/// and display name live. Those are identifiers; this is a credential that
/// mints access tokens. `UserDefaults` is a plist in the app container, plain
/// text and included in unencrypted backups.
///
/// `AfterFirstUnlock` rather than `WhenUnlocked`: the refresh happens as the
/// app launches, which can be before the user has looked at the screen, and
/// there is nothing here worth protecting against an attacker who has the
/// device unlocked.
enum SessionKeychain {
    private static let service = "com.pattheratch.earned.session"
    private static let account = "supabase.refreshToken"

    /// Stores the token, replacing any existing one. Returns whether it
    /// landed.
    ///
    /// Update-then-add rather than delete-then-add: the delete half always
    /// succeeds and the add half can fail, so the pair could remove a working
    /// credential and store nothing in its place — a sign-out on the next
    /// launch, from a token that had been perfectly good. The status is
    /// returned rather than discarded for the same reason; a credential that
    /// quietly failed to store is the hardest kind of bug report to answer.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
