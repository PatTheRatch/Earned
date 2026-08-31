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
    public static let currentSchemaVersion = 3

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

    /// Reads either the current envelope or a v1 file, which was a bare array of
    /// entries with no envelope at all.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.entries) {
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
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
