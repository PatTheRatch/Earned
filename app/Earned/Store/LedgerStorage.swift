import Foundation
import EarnedKit

/// Persists the event ledger as JSON. Only events are stored; state is rebuilt
/// and re-validated by replay on load (see ARCHITECTURE.md §2).
///
/// Writes to the app's Documents directory, and stays there. The plan used to
/// be to move it into the App Group so a Screen Time extension could read gate
/// state; the extension landed and that plan was deliberately dropped. Replay
/// is not something to attempt under an extension's memory ceiling, this is the
/// one file that must never be corrupted, and none of it is needed — what
/// crosses the process boundary is a `ShieldPlan`, a few dozen bytes of
/// already-decided answer. Every path still goes through this type, which is
/// what made that a decision rather than a rewrite.
struct LedgerStorage {
    let url: URL

    static func documents(filename: String = "ledger.json") -> LedgerStorage {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return LedgerStorage(url: dir.appendingPathComponent(filename))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    enum LoadResult {
        case loaded(Ledger)
        case empty
        /// History exists but failed to replay: it was moved aside rather than
        /// silently discarded, because a commitment the user made is in there.
        case unreadable(backup: URL?, error: Error)
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try Self.decoder.decode(Ledger.self, from: data))
        } catch {
            return .unreadable(backup: quarantine(), error: error)
        }
    }

    func save(_ ledger: Ledger) throws {
        let data = try Self.encoder.encode(ledger)
        try data.write(to: url, options: .atomic)
    }

    private func quarantine() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("ledger-unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        return FileManager.default.fileExists(atPath: backup.path) ? backup : nil
    }
}
