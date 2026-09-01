import Foundation

/// The append-only event ledger and its projected state. Appending validates the
/// event against every product invariant; invalid events never enter history.
///
/// Serialization stores only the entries — state is rebuilt (and re-validated)
/// by replay on decode, so a persisted ledger can never disagree with the rules
/// that produced it.
public struct Ledger: Equatable, Sendable {
    /// Bumped when the meaning of stored events changes in a way that needs an
    /// explicit migration rather than tolerant decoding. See `LedgerMigration`.
    public static let currentSchemaVersion = 6

    public private(set) var entries: [LedgerEntry]
    public private(set) var state: EarnedState

    public init() {
        entries = []
        state = EarnedState()
    }

    /// Rebuilds a ledger by replaying persisted entries. Throws if history is
    /// invalid — a corrupted or tampered store fails loudly rather than loading
    /// a state the rules would never have produced.
    ///
    /// Replay applies events exactly as recorded and never derives new ones:
    /// anything the engine produced originally (a `freeOverrideEarned`, say) is
    /// already in `entries`, and re-deriving would let today's policy rewrite
    /// yesterday's rewards.
    public init(replaying entries: [LedgerEntry]) throws {
        self.entries = []
        self.state = EarnedState()
        for entry in entries {
            state = try state.applying(entry.event, at: entry.date)
            self.entries.append(entry)
        }
    }

    /// Validates and appends one event, followed by any events the engine
    /// derives from it (currently: earning a Free Override). Returns every entry
    /// written, in order.
    @discardableResult
    public mutating func append(_ event: Event, at date: Date, id: UUID = UUID()) throws -> [LedgerEntry] {
        let before = state
        let after = try state.applying(event, at: date)

        var written = [LedgerEntry(id: id, date: date, event: event)]
        state = after
        entries.append(written[0])

        for derived in after.derivedEvents(from: before, at: date) {
            // A derived event is engine-produced and must not be able to fail;
            // if it somehow does, the primary event still stands.
            guard let next = try? state.applying(derived, at: date) else { continue }
            state = next
            let entry = LedgerEntry(date: date, event: derived)
            entries.append(entry)
            written.append(entry)
        }
        return written
    }
}

/// What gets written to disk: a versioned envelope around the entries.
public struct LedgerDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [LedgerEntry]

    public init(version: Int = Ledger.currentSchemaVersion, entries: [LedgerEntry]) {
        self.version = version
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public enum DocumentError: Error, CustomStringConvertible {
        case envelopeWithoutVersion

        public var description: String {
            "A ledger envelope with no schema version is not a format Earned has "
                + "ever written. Refusing to guess which one it is."
        }
    }

    /// Reads either the current envelope or a v1 file, which was a bare array of
    /// entries with no envelope at all.
    ///
    /// An envelope *with* entries but *without* a version is refused rather than
    /// read as v1. No build has ever written that shape — v1 had no envelope at
    /// all, and every version since writes the key — so assuming v1 would be
    /// guessing, and this is the one guess that is not free: the v1 migration is
    /// the only one that rewrites history, and it would stamp a million effort
    /// units in front of every solo override in the file. A file we cannot
    /// identify is quarantined intact (`LedgerStorage.load`), which is
    /// recoverable; a file silently rewritten is not.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.entries) {
            guard let stated = try container.decodeIfPresent(Int.self, forKey: .version) else {
                throw DocumentError.envelopeWithoutVersion
            }
            version = stated
            entries = try container.decode([LedgerEntry].self, forKey: .entries)
            return
        }
        version = 1
        entries = try decoder.singleValueContainer().decode([LedgerEntry].self)
    }
}

extension Ledger: Codable {
    public init(from decoder: Decoder) throws {
        let document = try LedgerDocument(from: decoder)
        let migrated = try LedgerMigration.migrate(document)
        try self.init(replaying: migrated.entries)
    }

    public func encode(to encoder: Encoder) throws {
        try LedgerDocument(version: Ledger.currentSchemaVersion, entries: entries).encode(to: encoder)
    }
}
