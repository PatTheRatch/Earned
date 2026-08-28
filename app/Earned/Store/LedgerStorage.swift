import Foundation
import EarnedKit

/// Persists the event ledger as JSON. Only events are stored; state is rebuilt
/// and re-validated by replay on load (see ARCHITECTURE.md §2).
///
/// MVP writes to the app's Documents directory. When the Screen Time extensions
/// arrive (roadmap step 3) this moves to a shared App Group container so the
/// shield extension can read gate state — that migration is why every path goes
/// through this type rather than being scattered through the app.
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
