import Foundation
import XCTest
@testable import EarnedKit

/// Folding a backup back into a phone.
///
/// The ledger is the only record of what somebody owes, and it lives in the app
/// container — so deleting the app has always cleared every commitment and all
/// debt, which is a cheaper escape than any Override in the product. The mirror
/// exists to close that; this is the arithmetic underneath it.
final class LedgerMergeTests: XCTestCase {

    private let social = RestrictionProfile(["app:social"])

    private func ledger(commitmentsAt dates: [(Int, Int)]) throws -> Ledger {
        var ledger = Ledger()
        for (day, hour) in dates {
            ledger.expectAppend(
                .commitmentCreated(makeCommitment(id: UUID(),
                                                  deadline: d(day + 1, hour),
                                                  createdAt: d(day, hour),
                                                  restrictions: social)),
                at: d(day, hour))
        }
        return ledger
    }

    func testTheUnionKeepsEverythingFromBothSides() throws {
        let phone = try ledger(commitmentsAt: [(1, 9)])
        let backup = try ledger(commitmentsAt: [(2, 9)])

        let merged = try phone.merged(with: backup)
        XCTAssertEqual(merged.entries.count, 2)
        XCTAssertEqual(merged.state.commitments.count, 2,
                       "a reinstall gets back what the phone forgot, and keeps what it has")
    }

    func testAnOverlappingPrefixIsNotCountedTwice() throws {
        let phone = try ledger(commitmentsAt: [(1, 9)])
        // The backup is this same history plus one more event — the ordinary
        // case, because the mirror is a copy of the phone taken earlier.
        var backup = phone
        backup.expectAppend(
            .commitmentCreated(makeCommitment(id: UUID(), deadline: d(3, 9),
                                              createdAt: d(2, 9), restrictions: social)),
            at: d(2, 9))

        let merged = try phone.merged(with: backup)
        XCTAssertEqual(merged.entries.count, 2, "the shared prefix appears once")
        XCTAssertEqual(merged.state.commitments.count, 2)
    }

    func testMergingIsTheSameInEitherDirection() throws {
        let a = try ledger(commitmentsAt: [(1, 9), (3, 9)])
        let b = try ledger(commitmentsAt: [(2, 9)])

        // Two devices merging the same pair must reach identical history, or
        // they diverge permanently and each keeps re-uploading its own version.
        XCTAssertEqual(try a.merged(with: b).entries.map(\.id),
                       try b.merged(with: a).entries.map(\.id))
    }

    func testMergingIsIdempotent() throws {
        let phone = try ledger(commitmentsAt: [(1, 9), (2, 9)])
        let once = try phone.merged(with: phone)
        XCTAssertEqual(once.entries, phone.entries,
                       "syncing a device against its own backup changes nothing")
    }

    /// The point of restoring at all: a commitment made days ago comes back
    /// past its correction window, because hardening is computed from the
    /// event's own `createdAt` and the mirror replays the real events. A
    /// reinstall that reopened the window would hand back exactly the escape
    /// this exists to close.
    func testRestoredCommitmentsComeBackHardened() throws {
        var backup = Ledger()
        let id = UUID()
        backup.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(9, 20),
                                              createdAt: d(1, 9),
                                              correctionWindow: 2 * 3600,
                                              restrictions: social)),
            at: d(1, 9))

        let restored = try Ledger().merged(with: backup)
        let commitment = try XCTUnwrap(restored.state.commitments[id]?.commitment)
        XCTAssertTrue(commitment.isHardened(at: d(2, 9)),
                      "a commitment restored days later is still hard; reinstalling is "
                      + "not a way back into the correction window")
    }

    /// A corrupt backup cannot even be built into a `Ledger`, which is the
    /// point: `entries` is `private(set)` and the only way in is `replaying`,
    /// so a tampered blob from iCloud is refused at the decode boundary and
    /// never reaches the merge. Adopting a history the rules would not have
    /// produced would be worse than losing the backup.
    func testACorruptBackupCannotBeBuiltAtAll() throws {
        let phone = try ledger(commitmentsAt: [(1, 9)])
        // Two creations of the same commitment id — something no engine ever
        // produced.
        let forged = LedgerEntry(id: UUID(), date: d(2, 9), event: phone.entries[0].event)

        XCTAssertThrowsError(try Ledger(replaying: phone.entries + [forged]),
                             "replay is what makes a restored ledger trustworthy")
    }
}
