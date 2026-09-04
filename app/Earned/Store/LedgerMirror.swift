import CloudKit
import Foundation
import EarnedKit

/// A copy of the ledger in the user's own iCloud, so deleting the app stops
/// being the cheapest way out of a commitment.
///
/// **The ledger stays local and stays authoritative.** Nothing on the phone
/// waits on this, reads from it during normal use, or behaves differently when
/// it fails — Gates, hardening, debt and the Solo Override remain functions of
/// the file in the app container (S8). This is a backup, written after the fact
/// and read exactly once: on a launch that finds no local history.
///
/// **Why CloudKit rather than our own backend.** The ledger holds things the
/// server has never been allowed to see and should not start seeing now: the
/// requirement behind a commitment, the restriction profile, and every imported
/// workout — activity, duration, distance, energy. `contract_envelope` carries
/// the title, the times and the roster and deliberately stops there, and
/// "Health data never leaves the phone" is a promise made to testers. A private
/// CloudKit database keeps that promise intact: the copy goes from the user's
/// phone to the user's iCloud, and Earned's servers are not party to it.
///
/// It also removes the key-management problem. Encrypting a blob for our own
/// backend needs a key that survives a reinstall, which means the iOS keychain,
/// which for a *new* device means iCloud Keychain — so the dependency lands on
/// iCloud either way, with more moving parts and a key a user can permanently
/// lose.
///
/// **What it cannot do.** A backup the user controls can always be rolled back
/// to shed debt — as can deleting the app, which is the situation today. What
/// closes that is the Contract Envelope: the server's record of *terms*, which
/// the client cannot write, and against which a restored ledger can be checked.
@MainActor
final class LedgerMirror: ObservableObject {

    enum Status: Equatable {
        case idle
        case unavailable(String)
        case saved(at: Date)
        case restored(entries: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let database: CKDatabase?
    private static let recordType = "Ledger"
    /// One record per user, in their own private database, so the id is fixed.
    private static let recordID = CKRecord.ID(recordName: "ledger")

    /// The last history uploaded, so an unchanged ledger is not re-sent on
    /// every append. The mirror is best-effort; it is not a reason to spend the
    /// user's battery.
    private var lastSaved: [LedgerEntry]?
    private var inFlight = false

    init(containerIdentifier: String = "iCloud.com.pattheratch.earned") {
        // A build without the iCloud entitlement, or a simulator with no
        // account, must not crash — it simply has no mirror.
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: - Saving

    /// Best-effort, and deliberately silent about success.
    ///
    /// Called after the ledger changes. Failure is recorded for Diagnostics and
    /// nowhere else: a user whose iCloud is full or switched off has an app
    /// that works exactly as it did before this existed, which is the whole
    /// contract of a backup.
    func save(_ ledger: Ledger) {
        guard let database, !inFlight, ledger.entries != lastSaved else { return }
        inFlight = true
        let entries = ledger.entries
        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }
            do {
                let record = try await Self.fetchOrCreate(in: database)
                // Merge before writing rather than overwriting: another device
                // may hold events this one has never seen, and last-write-wins
                // on an append-only history silently loses commitments.
                let remote = Self.decode(record)
                let merged = try (remote.map { try Ledger(replaying: entries).merged(with: $0) }
                                  ?? Ledger(replaying: entries))
                record[Self.payloadKey] = try Self.encode(merged) as CKRecordValue
                _ = try await database.save(record)
                await MainActor.run {
                    self?.lastSaved = entries
                    self?.status = .saved(at: Date())
                }
            } catch {
                await MainActor.run { self?.status = Self.describe(error) }
            }
        }
    }

    // MARK: - Restoring

    /// The copy in iCloud, or nil when there is nothing to restore.
    ///
    /// Called on a launch that found no local history — a reinstall, a new
    /// phone. Returns the ledger rather than adopting it, so the caller decides
    /// what to do with it and this type never writes to the app's own store.
    func restore() async -> Ledger? {
        guard let database else { return nil }
        do {
            let record = try await database.record(for: Self.recordID)
            guard let ledger = Self.decode(record) else { return nil }
            status = .restored(entries: ledger.entries.count)
            return ledger
        } catch let error as CKError where error.code == .unknownItem {
            // Nothing has ever been backed up. Not a failure — the ordinary
            // state of a first install.
            return nil
        } catch {
            status = Self.describe(error)
            return nil
        }
    }

    #if DEBUG
    /// Throw the backup away too.
    ///
    /// Only ever called by the debug reset. Without it, clearing history on the
    /// phone lasts until the next launch, when the mirror faithfully hands back
    /// everything that was just deleted — correct behaviour, and maddening
    /// while testing.
    func forget() async {
        guard let database else { return }
        lastSaved = nil
        _ = try? await database.deleteRecord(withID: Self.recordID)
        status = .idle
    }
    #endif

    // MARK: - Encoding

    private static let payloadKey = "entries"

    private static func encode(_ ledger: Ledger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ledger)
    }

    /// Nil rather than throwing: a payload this build cannot read is a backup
    /// from a newer version, and refusing to start is the wrong response to it.
    private static func decode(_ record: CKRecord) -> Ledger? {
        guard let data = record[payloadKey] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Replay happens inside `Ledger`'s decoder, so a tampered or corrupt
        // payload is refused here rather than becoming state the rules would
        // never have produced.
        return try? decoder.decode(Ledger.self, from: data)
    }

    private static func fetchOrCreate(in database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: recordType, recordID: recordID)
        }
    }

    /// iCloud's own words are not for a person to read, and a tester
    /// screenshots Diagnostics — so the states worth acting on are named and
    /// the rest is trimmed.
    private static func describe(_ error: Error) -> Status {
        guard let ckError = error as? CKError else {
            return .failed(String(describing: error).prefix(100).description)
        }
        switch ckError.code {
        case .notAuthenticated:
            return .unavailable("Not signed in to iCloud")
        case .quotaExceeded:
            return .unavailable("iCloud storage is full")
        case .networkUnavailable, .networkFailure:
            return .unavailable("No connection")
        case .permissionFailure:
            return .unavailable("iCloud Drive is off for Earned")
        default:
            return .failed("iCloud error \(ckError.errorCode)")
        }
    }
}
