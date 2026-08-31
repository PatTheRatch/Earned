import Foundation
import XCTest
@testable import EarnedKit

/// Verification strength is part of the contract (NORTHSTAR §15).
///
/// The user picks how a commitment gets satisfied: their own word, or only
/// workouts another app vouched for through Apple Health. The section's two
/// sentences carry all the rules here — "Verification strength is part of the
/// contract. Once hardened, verification may become stricter but not weaker" —
/// and this file holds the engine to both.
final class VerificationTests: XCTestCase {

    private let strava = WorkoutEvidence.appVerified(source: "com.strava.stravaride")

    private func ledger(requiring verification: WorkoutVerification,
                        id: UUID) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id,
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalDuration(1800),
                                         verification: verification),
                eligibleFrom: d(22), deadline: d(22, 10), createdAt: d(21, 18))),
            at: d(21, 18))
        return ledger
    }

    // MARK: - What counts

    func testTheHonorSystemCountsEverything() throws {
        let id = UUID()
        var ledger = ledger(requiring: .selfReported, id: id)
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 7), minutes: 15)),
                            at: d(22, 7, 20))
        var verified = workout(start: d(22, 8), minutes: 15)
        verified.evidence = strava
        ledger.expectAppend(.workoutRecorded(verified), at: d(22, 8, 20))

        // A verified workout is not too good for an honor-system commitment;
        // the tiers are a floor, never a ceiling.
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 1800)
        XCTAssertNotNil(ledger.state.commitments[id]?.resolution)
    }

    func testAVerifiedCommitmentIgnoresTheUsersWord() throws {
        let id = UUID()
        var ledger = ledger(requiring: .appVerified, id: id)

        // Thirty self-reported minutes: a true thing the user said, recorded
        // in history, moving this commitment not at all. That is the deal the
        // user chose on the day they trusted themselves least.
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 7), minutes: 30)),
                            at: d(22, 7, 40))
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved ?? 0, 0)
        XCTAssertNil(ledger.state.commitments[id]?.resolution)
        XCTAssertTrue(ledger.state.accessState(now: d(22, 11)).isRestricted,
                      "past the deadline with only self-reported minutes: still locked")

        var verified = workout(start: d(22, 11, 30), minutes: 30)
        verified.evidence = strava
        ledger.expectAppend(.workoutRecorded(verified), at: d(22, 12))
        XCTAssertNotNil(ledger.state.commitments[id]?.resolution,
                        "the vouched-for run resolves it, even late (§16: debt outlives deadlines)")
    }

    // MARK: - Stricter but not weaker

    func testHardenedVerificationCannotBeWeakened() throws {
        let id = UUID()
        var ledger = ledger(requiring: .appVerified, id: id)

        // Well past hardening. "Actually, just take my word for it" is the
        // exact negotiation §15 exists to lose.
        XCTAssertThrowsError(try ledger.append(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalDuration(1800),
                                         verification: .selfReported))),
            at: d(22, 9)))
    }

    func testHardenedVerificationCanBeTightened() throws {
        let id = UUID()
        var ledger = ledger(requiring: .selfReported, id: id)
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalDuration(1800),
                                         verification: .appVerified))),
            at: d(22, 9))
        XCTAssertEqual(ledger.state.commitments[id]?.commitment.requirement.verification,
                       .appVerified)
    }

    func testTighteningDoesNotSmuggleInALooserMetric() throws {
        // isAtLeastAsHard is per-dimension on purpose: stricter verification
        // does not pay for a shorter run.
        let id = UUID()
        var ledger = ledger(requiring: .selfReported, id: id)
        XCTAssertThrowsError(try ledger.append(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalDuration(600),
                                         verification: .appVerified))),
            at: d(22, 9)))
    }

    // MARK: - What was written before tiers existed

    func testOldShapesDecodeAsTheRuleThatWasInForce() throws {
        // A v3 requirement and a v3 workout, verbatim shapes. Everything
        // counted when they were written, and they were manual entries — so
        // .selfReported on both is what they were, not a guess about them.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let requirement = try decoder.decode(Requirement.self, from: Data("""
            {"activity": {"types": {"_0": ["running"]}},
             "metric": {"totalDuration": {"_0": 1800}}}
            """.utf8))
        XCTAssertEqual(requirement.verification, .selfReported)

        let old = try decoder.decode(Workout.self, from: Data("""
            {"id": "A0000000-0000-0000-0000-000000000001", "activity": "running",
             "start": "2026-08-22T07:00:00Z", "end": "2026-08-22T07:30:00Z"}
            """.utf8))
        XCTAssertEqual(old.evidence, .selfReported)

        // The tier survives its own round trip. Requirement has a custom
        // CodingKeys, and a key omitted there is not "defaulted" on write, it
        // is silently gone — decoding back as .selfReported and quietly
        // loosening the contract. This is the test that failure fails.
        let strict = Requirement(activity: .only(.running), metric: .totalDuration(1800),
                                 verification: .appVerified)
        let rereadRequirement = try decoder.decode(Requirement.self,
                                                   from: try encoderFor(strict))
        XCTAssertEqual(rereadRequirement.verification, .appVerified)

        // And the round trip holds provenance: who vouched is part of history.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var vouched = workout(start: d(22, 7), minutes: 30)
        vouched.evidence = strava
        let reread = try decoder.decode(Workout.self, from: try encoder.encode(vouched))
        XCTAssertEqual(reread.evidence, strava)
    }

    func testReimportingTheSameWorkoutCountsItOnce() throws {
        // HealthKit ingestion reuses the HK workout's UUID, so a workout seen
        // again on the next foreground is a duplicate id — accepted and
        // deduplicated by the reducer (CommitmentTests pins that semantic),
        // never double-counted. Accepted rather than refused on purpose: a
        // ledger that already holds the duplicate event must keep replaying
        // forever, and an append that starts throwing where it used to
        // succeed would rewrite history's rules retroactively.
        let id = UUID()
        var ledger = ledger(requiring: .selfReported, id: id)
        let run = workout(start: d(22, 7), minutes: 10)
        ledger.expectAppend(.workoutRecorded(run), at: d(22, 7, 20))
        ledger.expectAppend(.workoutRecorded(run), at: d(22, 7, 21))
        XCTAssertEqual(ledger.state.workouts.count, 1)
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 600,
                       "ten minutes, not twenty: seen twice is counted once")
    }

    private func encoderFor(_ requirement: Requirement) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(requirement)
    }

    func testReplayIsIdentical() throws {
        let id = UUID()
        var ledger = ledger(requiring: .appVerified, id: id)
        ledger.expectAppend(.workoutRecorded(workout(start: d(22, 7), minutes: 30)),
                            at: d(22, 7, 40))
        var verified = workout(start: d(22, 8), minutes: 30)
        verified.evidence = strava
        ledger.expectAppend(.workoutRecorded(verified), at: d(22, 8, 40))

        let replayed = try Ledger(replaying: ledger.entries)
        XCTAssertEqual(replayed.state.commitments[id]?.resolution,
                       ledger.state.commitments[id]?.resolution)
        XCTAssertEqual(replayed.state.progress(for: id), ledger.state.progress(for: id))
    }
}
