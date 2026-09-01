import Foundation
import XCTest
@testable import EarnedKit

/// `CompletionMetric.sessionCount` — "run 3× this week" as a first-class
/// requirement (NORTHSTAR §13/§14, settled for Shared Commitments SC1's
/// follow-up). One qualifying workout record counts as one session; sessions
/// accumulate like every quantitative metric and obey the same harder-only
/// lattice after hardening.
final class SessionCountTests: XCTestCase {

    private func runThreeTimes(deadline: Date = d(30, 20)) -> Commitment {
        makeCommitment(
            title: "Run 3× this week",
            requirement: Requirement(activity: .only(.running), metric: .sessionCount(3)),
            deadline: deadline,
            createdAt: d(24, 8))
    }

    // MARK: - Accumulation and resolution

    func testEachQualifyingWorkoutIsOneSessionAndTheThirdResolves() throws {
        var ledger = Ledger()
        let commitment = runThreeTimes()
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))

        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 20)), at: d(24, 10))
        ledger.expectAppend(.workoutRecorded(workout(start: d(25, 9), minutes: 45)), at: d(25, 10))

        let partway = try XCTUnwrap(ledger.state.progress(for: commitment.id))
        XCTAssertEqual(partway.achieved, 2, "two runs are two sessions, whatever their lengths")
        XCTAssertEqual(partway.required, 3)
        XCTAssertEqual(partway.unit, .workouts)
        XCTAssertNil(ledger.state.commitments[commitment.id]?.resolution,
                     "two of three sessions resolves nothing")

        ledger.expectAppend(.workoutRecorded(workout(start: d(26, 9), minutes: 5)), at: d(26, 10))
        XCTAssertEqual(ledger.state.commitments[commitment.id]?.resolution,
                       .completed(at: d(26, 9, 5)),
                       "the third session completes it, at that workout's end")
    }

    func testTwoSessionsOnOneDayAreTwoSessions() {
        var ledger = Ledger()
        let commitment = makeCommitment(
            requirement: Requirement(metric: .sessionCount(2)),
            deadline: d(24, 20), createdAt: d(24, 8))
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))
        // One qualifying workout record is one session — the calendar is not a
        // dimension of the metric.
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 10)), at: d(24, 10))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 18), minutes: 10)), at: d(24, 18, 30))
        XCTAssertEqual(ledger.state.commitments[commitment.id]?.resolution,
                       .completed(at: d(24, 18, 10)))
    }

    // MARK: - The activity filter still decides what qualifies

    func testANonMatchingActivityIsNotASession() {
        var ledger = Ledger()
        let commitment = runThreeTimes()
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 30,
                                                     activity: .cycling)), at: d(24, 10))
        XCTAssertEqual(ledger.state.progress(for: commitment.id)?.achieved, 0,
                       "half an hour on a bike is zero running sessions")
    }

    func testAWorkoutBeforeTheEligibleWindowIsNotASession() {
        var ledger = Ledger()
        let commitment = makeCommitment(
            requirement: Requirement(metric: .sessionCount(2)),
            eligibleFrom: d(26),
            deadline: d(28, 20), createdAt: d(24, 8))
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(25, 9), minutes: 30)), at: d(25, 10))
        XCTAssertEqual(ledger.state.progress(for: commitment.id)?.achieved, 0,
                       "a session before the window opened counts for nothing")
        ledger.expectAppend(.workoutRecorded(workout(start: d(26, 9), minutes: 30)), at: d(26, 10))
        XCTAssertEqual(ledger.state.progress(for: commitment.id)?.achieved, 1)
    }

    // MARK: - Validity

    func testZeroSessionsIsNotACommitment() {
        XCTAssertFalse(CompletionMetric.sessionCount(0).isValid)
        var ledger = Ledger()
        expectThrows {
            try ledger.append(
                .commitmentCreated(makeCommitment(
                    requirement: Requirement(metric: .sessionCount(0)),
                    deadline: d(24, 20), createdAt: d(24, 8))),
                at: d(24, 8))
        }
    }

    // MARK: - Hardening monotonicity

    func testMoreSessionsIsHarderFewerIsNot() {
        XCTAssertTrue(CompletionMetric.sessionCount(4)
            .isAtLeastAsHard(as: .sessionCount(3)))
        XCTAssertTrue(CompletionMetric.sessionCount(3)
            .isAtLeastAsHard(as: .sessionCount(3)))
        XCTAssertFalse(CompletionMetric.sessionCount(2)
            .isAtLeastAsHard(as: .sessionCount(3)))
    }

    func testSessionsAndOtherDimensionsAreIncomparable() {
        // Neither direction: swapping the dimension is different, not harder.
        XCTAssertFalse(CompletionMetric.sessionCount(3)
            .isAtLeastAsHard(as: .totalDuration(1800)))
        XCTAssertFalse(CompletionMetric.totalDuration(99_999)
            .isAtLeastAsHard(as: .sessionCount(1)))
        // Except "one workout", which anything valid satisfies at least once.
        XCTAssertTrue(CompletionMetric.sessionCount(1)
            .isAtLeastAsHard(as: .anyQualifyingWorkout))
    }

    func testAHardenedSessionCountCanRiseAndNeverFall() {
        var ledger = Ledger()
        let commitment = runThreeTimes(deadline: d(28, 8))
        ledger.expectAppend(.commitmentCreated(commitment), at: d(24, 8))

        // Hardened (2h window, deadline four days out): harder-only edits.
        ledger.expectAppend(
            .commitmentEdited(id: commitment.id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running), metric: .sessionCount(4)))),
            at: d(24, 12))
        expectThrows {
            try ledger.append(
                .commitmentEdited(id: commitment.id, edit: CommitmentEdit(
                    requirement: Requirement(activity: .only(.running), metric: .sessionCount(2)))),
                at: d(24, 13))
        }
        expectThrows {
            try ledger.append(
                .commitmentEdited(id: commitment.id, edit: CommitmentEdit(
                    requirement: Requirement(activity: .only(.running),
                                             metric: .totalDuration(7200)))),
                at: d(24, 13))
        }
    }

    // MARK: - Persistence

    func testASessionCountLedgerRoundTripsAtTheCurrentVersion() throws {
        var ledger = Ledger()
        ledger.expectAppend(.commitmentCreated(runThreeTimes()), at: d(24, 8))
        ledger.expectAppend(.workoutRecorded(workout(start: d(24, 9), minutes: 20)), at: d(24, 10))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(ledger)
        let document = try decoder.decode(LedgerDocument.self, from: data)
        XCTAssertEqual(document.version, 6, "sessionCount ships in schema v6")

        let reloaded = try decoder.decode(Ledger.self, from: data)
        XCTAssertEqual(reloaded.state.commitments, ledger.state.commitments)
    }

    func testAV5DocumentMigratesToV6Unchanged() throws {
        // No v5 ledger can contain a sessionCount, so the migration has
        // nothing to rewrite — the bump exists so a v5 build refuses a v6
        // ledger rather than dropping the case it cannot decode.
        let v5 = Data(#"{"version": 5, "entries": []}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(Ledger.self, from: v5)
        XCTAssertTrue(ledger.entries.isEmpty)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let document = try decoder.decode(LedgerDocument.self,
                                          from: try encoder.encode(ledger))
        XCTAssertEqual(document.version, Ledger.currentSchemaVersion,
                       "saving a v5 ledger stamps v6")
    }
}
