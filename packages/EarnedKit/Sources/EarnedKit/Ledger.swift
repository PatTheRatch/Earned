import Foundation

/// The append-only event ledger and its projected state. Appending validates the
/// event against every product invariant; invalid events never enter history.
///
/// Serialization stores only the entries — state is rebuilt (and re-validated)
/// by replay on decode, so a persisted ledger can never disagree with the rules
/// that produced it.
public struct Ledger: Equatable, Sendable {
    public private(set) var entries: [LedgerEntry]
    public private(set) var state: EarnedState

    public init() {
        entries = []
        state = EarnedState()
    }

    /// Rebuilds a ledger by replaying persisted entries. Throws if history is
    /// invalid — a corrupted or tampered store fails loudly rather than loading
    /// a state the rules would never have produced.
    public init(replaying entries: [LedgerEntry]) throws {
        self.entries = []
        self.state = EarnedState()
        for entry in entries {
            state = try state.applying(entry.event, at: entry.date)
            self.entries.append(entry)
        }
    }

    /// Validates and appends one event.
    @discardableResult
    public mutating func append(_ event: Event, at date: Date, id: UUID = UUID()) throws -> LedgerEntry {
        state = try state.applying(event, at: date)
        let entry = LedgerEntry(id: id, date: date, event: event)
        entries.append(entry)
        return entry
    }
}

extension Ledger: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([LedgerEntry].self)
        try self.init(replaying: entries)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
