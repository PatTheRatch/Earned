import Foundation

/// An opaque handle for one restrictable thing — an app, a web domain, a
/// category. EarnedKit never interprets the value: on iOS the app layer maps
/// these to FamilyControls `ApplicationToken`s, which are themselves opaque and
/// which the app is never allowed to read (NORTHSTAR §34).
///
/// Modelling it as a string keeps the domain portable and the ledger
/// serializable. The mapping to a real platform token is the adapter's job.
public struct RestrictionToken: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// What one Gate takes away while it is unsatisfied.
///
/// Restrictions belong to Gates, not to the account: the Hydration Gate can be
/// far more severe than the Exercise Gate, and the restriction actually in force
/// at any moment is the **union** of the profiles of every currently-unsatisfied
/// Gate (see `EarnedState.accessState`). Two Gates closed at once therefore
/// always produces at least as strict a result as either alone.
public struct RestrictionProfile: Codable, Equatable, Sendable {
    public var tokens: Set<RestrictionToken>

    public init(_ tokens: Set<RestrictionToken> = []) { self.tokens = tokens }

    public init(_ rawValues: [String]) {
        self.tokens = Set(rawValues.map(RestrictionToken.init))
    }

    public static let none = RestrictionProfile()

    public var isEmpty: Bool { tokens.isEmpty }
    public var count: Int { tokens.count }

    /// Tokens in a stable order — for display and for deterministic tests.
    public var sortedTokens: [RestrictionToken] { tokens.sorted() }

    public func union(_ other: RestrictionProfile) -> RestrictionProfile {
        RestrictionProfile(tokens.union(other.tokens))
    }

    /// Whether `self` restricts at least everything `other` does. This is the
    /// monotonicity test for a Gate's profile: a hardened Gate may add tokens,
    /// never drop them.
    public func isAtLeastAsStrict(as other: RestrictionProfile) -> Bool {
        tokens.isSuperset(of: other.tokens)
    }

    public func adding(_ other: Set<RestrictionToken>) -> RestrictionProfile {
        RestrictionProfile(tokens.union(other))
    }

    public func removing(_ other: Set<RestrictionToken>) -> RestrictionProfile {
        RestrictionProfile(tokens.subtracting(other))
    }

    public static func union(_ profiles: [RestrictionProfile]) -> RestrictionProfile {
        profiles.reduce(RestrictionProfile()) { $0.union($1) }
    }
}

/// Which Gate a restriction profile — or a lock — belongs to.
///
/// Hydration is a singleton Gate. Exercise is one Gate per commitment, so that
/// "run 30 min by Saturday" and "any workout by Tuesday" can restrict different
/// things. Giving every exercise commitment the same profile reproduces the
/// simpler "one Exercise Gate" model exactly.
public enum GateID: Hashable, Codable, Sendable {
    case hydration
    case commitment(UUID)
}
