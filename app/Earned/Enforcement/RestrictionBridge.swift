import Foundation
import FamilyControls
import ManagedSettings
import EarnedKit

/// Translates between EarnedKit's opaque `RestrictionToken`s and the
/// FamilyControls tokens the system actually shields with.
///
/// EarnedKit deliberately knows nothing about apps: a `RestrictionToken` is an
/// opaque string, and this is the only place that gives one meaning. That
/// separation is what lets the domain engine build and test on Linux while the
/// real enforcement lives here.
///
/// **Apple's tokens are opaque to us too.** `ApplicationToken` carries no name,
/// no bundle id, nothing readable — that is the privacy guarantee of the Screen
/// Time API (NORTHSTAR §34). Earned can shield an app it cannot identify, and
/// that is by design: the picker runs in a system process, and only the user
/// ever sees which apps they chose.
enum RestrictionBridge {

    /// Tokens are stored as `kind:base64`, so one profile can carry
    /// applications, categories and web domains together and still round-trip.
    private enum Kind: String {
        case application = "app"
        case category = "cat"
        case webDomain = "web"
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func encode<T: Codable>(_ token: T, kind: Kind) -> RestrictionToken? {
        guard let data = try? encoder.encode(token) else { return nil }
        return RestrictionToken("\(kind.rawValue):\(data.base64EncodedString())")
    }

    private static func decode<T: Codable>(_ token: RestrictionToken, kind: Kind, as: T.Type) -> T? {
        let parts = token.rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == kind.rawValue,
              let data = Data(base64Encoded: String(parts[1])) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Selection → profile

    /// What the user picked, as a profile the ledger can store.
    static func profile(from selection: FamilyActivitySelection) -> RestrictionProfile {
        var tokens: Set<RestrictionToken> = []
        for token in selection.applicationTokens {
            if let encoded = encode(token, kind: .application) { tokens.insert(encoded) }
        }
        for token in selection.categoryTokens {
            if let encoded = encode(token, kind: .category) { tokens.insert(encoded) }
        }
        for token in selection.webDomainTokens {
            if let encoded = encode(token, kind: .webDomain) { tokens.insert(encoded) }
        }
        return RestrictionProfile(tokens)
    }

    // MARK: - Profile → selection

    /// A stored profile, back in the shape the picker wants so it opens showing
    /// what is already chosen.
    static func selection(from profile: RestrictionProfile) -> FamilyActivitySelection {
        var selection = FamilyActivitySelection()
        selection.applicationTokens = Set(profile.tokens.compactMap {
            decode($0, kind: .application, as: ApplicationToken.self)
        })
        selection.categoryTokens = Set(profile.tokens.compactMap {
            decode($0, kind: .category, as: ActivityCategoryToken.self)
        })
        selection.webDomainTokens = Set(profile.tokens.compactMap {
            decode($0, kind: .webDomain, as: WebDomainToken.self)
        })
        return selection
    }

    // MARK: - Shielding

    static func applications(in profile: RestrictionProfile) -> Set<ApplicationToken> {
        Set(profile.tokens.compactMap { decode($0, kind: .application, as: ApplicationToken.self) })
    }

    static func categories(in profile: RestrictionProfile) -> Set<ActivityCategoryToken> {
        Set(profile.tokens.compactMap { decode($0, kind: .category, as: ActivityCategoryToken.self) })
    }

    static func webDomains(in profile: RestrictionProfile) -> Set<WebDomainToken> {
        Set(profile.tokens.compactMap { decode($0, kind: .webDomain, as: WebDomainToken.self) })
    }

    // MARK: - Legacy

    /// Tokens written before real app picking existed: typed-in names like
    /// "Instagram" that were always placeholders and can shield nothing.
    ///
    /// They are **not** deleted. They are a record of what the user said they
    /// wanted blocked, and throwing that away to tidy up would be the app
    /// discarding a decision the user made. Instead they are shown as needing
    /// to be re-picked, and they shield nothing in the meantime — which is what
    /// they always did.
    static func isLegacyPlaceholder(_ token: RestrictionToken) -> Bool {
        let parts = token.rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])) else { return true }
        switch kind {
        case .application: return decode(token, kind: kind, as: ApplicationToken.self) == nil
        case .category: return decode(token, kind: kind, as: ActivityCategoryToken.self) == nil
        case .webDomain: return decode(token, kind: kind, as: WebDomainToken.self) == nil
        }
    }

    static func legacyPlaceholders(in profile: RestrictionProfile) -> [RestrictionToken] {
        profile.sortedTokens.filter(isLegacyPlaceholder)
    }

    /// How many real, shieldable things a profile carries.
    static func shieldableCount(in profile: RestrictionProfile) -> Int {
        profile.tokens.filter { !isLegacyPlaceholder($0) }.count
    }
}
