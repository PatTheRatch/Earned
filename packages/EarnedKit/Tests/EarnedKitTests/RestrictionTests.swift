import XCTest
@testable import EarnedKit

/// Restrictions belong to Gates, and what is in force is the union over the
/// unsatisfied ones (NORTHSTAR §5, §6).
final class RestrictionTests: XCTestCase {

    private func ledgerWithBothGates(commitmentID: UUID) -> Ledger {
        var ledger = Ledger()
        // Exercise commitment due Saturday 10:00, made Friday evening.
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: commitmentID,
                                              title: "Run 30 minutes",
                                              deadline: d(22, 10),
                                              createdAt: d(21, 18),
                                              restrictions: exerciseProfile)),
            at: d(21, 18))
        ledger.expectAppend(.hydrationConfigured(patrickHydration()), at: d(22, 7))
        return ledger
    }

    func testFullAccessRestrictsNothing() throws {
        let id = UUID()
        var ledger = ledgerWithBothGates(commitmentID: id)
        ledger.expectAppend(.waterAcknowledged, at: d(22, 9))
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 9, 10), minutes: 30)), at: d(22, 9, 45))

        let access = ledger.state.accessState(now: d(22, 9, 50))
        XCTAssertTrue(access.isFullAccess)
        XCTAssertTrue(access.effectiveRestrictions.isEmpty)
    }

    /// Hydration alone closed: the severe profile applies — even email and music,
    /// which the Exercise Gate leaves alone.
    func testHydrationAloneAppliesItsOwnProfile() throws {
        let id = UUID()
        var ledger = ledgerWithBothGates(commitmentID: id)
        // Exercise satisfied before its deadline; hydration never acknowledged.
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 8, 10), minutes: 30)), at: d(22, 8, 45))

        let access = ledger.state.accessState(now: d(22, 9))
        XCTAssertTrue(access.isRestricted)
        XCTAssertEqual(access.lockReasons.map(\.gate), [.hydration])
        XCTAssertEqual(access.effectiveRestrictions, hydrationProfile)
        XCTAssertTrue(access.restricts(RestrictionToken("email")))
        XCTAssertTrue(access.restricts(RestrictionToken("spotify")))
    }

    /// Exercise alone closed: useful-life apps survive, optional consumption does not.
    func testExerciseAloneLeavesUsefulAppsAlone() throws {
        let id = UUID()
        var ledger = ledgerWithBothGates(commitmentID: id)
        ledger.expectAppend(.waterAcknowledged, at: d(22, 9, 50))

        // 10:01 — deadline passed with no workout; hydration still good until 10:50.
        let access = ledger.state.accessState(now: d(22, 10, 1))
        XCTAssertEqual(access.lockReasons.map(\.gate), [.commitment(id)])
        XCTAssertEqual(access.effectiveRestrictions, exerciseProfile)
        XCTAssertFalse(access.restricts(RestrictionToken("email")), "email is useful-life")
        XCTAssertFalse(access.restricts(RestrictionToken("spotify")), "workout audio is useful-life")
        XCTAssertTrue(access.restricts(RestrictionToken("balatro")))
    }

    /// Both closed: the union, which is at least as strict as either alone.
    func testBothGatesUnionToTheStricterResult() throws {
        let id = UUID()
        var ledger = ledgerWithBothGates(commitmentID: id)

        let access = ledger.state.accessState(now: d(22, 10, 1))
        XCTAssertEqual(Set(access.lockReasons.map(\.gate)), [.hydration, .commitment(id)])

        let union = hydrationProfile.union(exerciseProfile)
        XCTAssertEqual(access.effectiveRestrictions, union)
        XCTAssertTrue(access.effectiveRestrictions.isAtLeastAsStrict(as: hydrationProfile))
        XCTAssertTrue(access.effectiveRestrictions.isAtLeastAsStrict(as: exerciseProfile))
        XCTAssertTrue(access.restricts(RestrictionToken("email")))
        XCTAssertTrue(access.restricts(RestrictionToken("balatro")))
    }

    /// Two commitments with different profiles both contribute when both overdue.
    func testEachCommitmentContributesItsOwnProfile() throws {
        var ledger = Ledger()
        let strict = UUID(), loose = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: strict, title: "Long run",
                                              deadline: d(22, 9), createdAt: d(21, 12),
                                              restrictions: RestrictionProfile(["a", "b"]))),
            at: d(21, 12))
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: loose, title: "Walk",
                                              deadline: d(22, 10), createdAt: d(21, 12, 1),
                                              restrictions: RestrictionProfile(["b", "c"]))),
            at: d(21, 12, 1))

        XCTAssertEqual(ledger.state.accessState(now: d(22, 9, 30)).effectiveRestrictions,
                       RestrictionProfile(["a", "b"]))
        XCTAssertEqual(ledger.state.accessState(now: d(22, 11)).effectiveRestrictions,
                       RestrictionProfile(["a", "b", "c"]))
    }

    /// Tightening a Gate is always allowed; loosening needs Full Access and
    /// nothing hardened outstanding.
    func testLooseningRequiresFullAccess() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(22, 10), createdAt: d(21, 18),
                                              restrictions: RestrictionProfile(["instagram"]))),
            at: d(21, 18))

        // Still inside the correction window: tightening is fine.
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                restrictions: RestrictionProfile(["instagram", "youtube"]))),
            at: d(21, 18, 30))

        // Overdue — the Gate is closed, so it cannot be made cheaper.
        expectThrows {
            try ledger.append(.commitmentEdited(id: id, edit: CommitmentEdit(
                restrictions: RestrictionProfile(["instagram"]))), at: d(22, 11))
        }
    }

    /// A hardened commitment's profile may only grow (NORTHSTAR §12).
    func testHardenedProfileIsMonotonic() throws {
        var ledger = Ledger()
        let id = UUID()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(id: id, deadline: d(29, 10), createdAt: d(24, 8),
                                              restrictions: RestrictionProfile(["instagram"]))),
            at: d(24, 8))
        // Hardens at 10:00. Adding is allowed after that.
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                restrictions: RestrictionProfile(["instagram", "youtube"]))),
            at: d(24, 11))
        // Removing is not.
        expectThrows {
            try ledger.append(.commitmentEdited(id: id, edit: CommitmentEdit(
                restrictions: RestrictionProfile(["youtube"]))), at: d(24, 12))
        }
    }
}
