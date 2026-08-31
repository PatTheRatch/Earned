import Foundation
import XCTest
@testable import EarnedKit

/// Requiring effort rather than opportunity (NORTHSTAR §13).
///
/// Duration and distance measure how long you had the app open and how far the
/// phone travelled. Neither asks anything of you. Active energy — calories
/// burned *above* resting — is the one metric here that a minute of standing
/// outside cannot satisfy, which is precisely the hole it was added to close.
///
/// It is a proxy and the tests say so: energy is estimated, better from a
/// watch than a phone, and this raises the cost of negotiating with yourself
/// rather than making it impossible (§15's posture, applied to §13).
final class EffortTests: XCTestCase {

    private func run(minutes: Double, calories: Double?, at start: Date) -> Workout {
        Workout(activity: .running, start: start,
                end: start.addingTimeInterval(minutes * 60),
                distanceMeters: 100, activeEnergyKilocalories: calories)
    }

    private func ledger(requiring metric: CompletionMetric, id: UUID) -> Ledger {
        var ledger = Ledger()
        ledger.expectAppend(
            .commitmentCreated(makeCommitment(
                id: id, requirement: Requirement(activity: .only(.running), metric: metric),
                eligibleFrom: d(22), deadline: d(22, 20), createdAt: d(21, 18))),
            at: d(21, 18))
        return ledger
    }

    // MARK: - The hole this closes

    func testTheOneMinuteRunThatUsedToBeEnough() throws {
        // Exactly what happened on a real phone: start the Workout app, stand
        // still for a minute, stop. Apple records a genuine, app-verified
        // Outdoor Run of 0 active calories — and "just show up" was satisfied.
        let show = UUID()
        var showingUp = ledger(requiring: .anyQualifyingWorkout, id: show)
        showingUp.expectAppend(.workoutRecorded(run(minutes: 1, calories: 0, at: d(22, 18, 50))),
                               at: d(22, 18, 52))
        XCTAssertNotNil(showingUp.state.commitments[show]?.resolution,
                        "one qualifying workout is one qualifying workout — by design")

        // The same minute against an effort target moves nothing at all.
        let effort = UUID()
        var earning = ledger(requiring: .totalActiveEnergy(200), id: effort)
        earning.expectAppend(.workoutRecorded(run(minutes: 1, calories: 0, at: d(22, 18, 50))),
                             at: d(22, 18, 52))
        XCTAssertEqual(earning.state.progress(for: effort)?.achieved, 0)
        XCTAssertNil(earning.state.commitments[effort]?.resolution)
        XCTAssertTrue(earning.state.accessState(now: d(22, 21)).isRestricted)
    }

    func testEnergyAccumulatesLikeEveryOtherQuantity() throws {
        // NORTHSTAR §14: quantitative metrics accumulate. 120 in the morning
        // and 80 in the evening is 200, the same way minutes and kilometres
        // are, because the obligation is a total and not a single session.
        let id = UUID()
        var ledger = ledger(requiring: .totalActiveEnergy(200), id: id)
        ledger.expectAppend(.workoutRecorded(run(minutes: 20, calories: 120, at: d(22, 7))),
                            at: d(22, 7, 30))
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 120)
        XCTAssertNil(ledger.state.commitments[id]?.resolution)

        ledger.expectAppend(.workoutRecorded(run(minutes: 15, calories: 80, at: d(22, 18))),
                            at: d(22, 18, 30))
        XCTAssertNotNil(ledger.state.commitments[id]?.resolution)
    }

    func testAWorkoutThatCannotSayHowHardItWasCountsAsNothing() throws {
        // nil is "not reported", and it gets no benefit of the doubt. A source
        // that never measured energy must not clear a target measured in it —
        // treating unknown as satisfied is how a gate quietly stops existing.
        let id = UUID()
        var ledger = ledger(requiring: .totalActiveEnergy(50), id: id)
        ledger.expectAppend(.workoutRecorded(run(minutes: 90, calories: nil, at: d(22, 7))),
                            at: d(22, 8, 30))
        XCTAssertEqual(ledger.state.progress(for: id)?.achieved, 0)
        XCTAssertNil(ledger.state.commitments[id]?.resolution)
    }

    // MARK: - It is a term of the contract like any other

    func testTheTargetCanOnlyRiseOnceHardened() throws {
        let id = UUID()
        var ledger = ledger(requiring: .totalActiveEnergy(200), id: id)
        XCTAssertThrowsError(try ledger.append(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalActiveEnergy(100)))),
            at: d(22, 9)))
        ledger.expectAppend(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalActiveEnergy(300)))),
            at: d(22, 9))
    }

    func testSwappingDimensionIsNotAHarderEdit() throws {
        // 200 calories and 30 minutes are not comparable quantities, so after
        // hardening neither can replace the other — the same rule that already
        // stops duration becoming distance. Otherwise "make it harder" would
        // be a route to any requirement at all.
        let id = UUID()
        var ledger = ledger(requiring: .totalActiveEnergy(200), id: id)
        XCTAssertThrowsError(try ledger.append(
            .commitmentEdited(id: id, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalDuration(9999)))),
            at: d(22, 9)))

        let other = UUID()
        // `self.`, because the local `ledger` a few lines up shadows the
        // helper by this point in the scope.
        var byTime = self.ledger(requiring: .totalDuration(1800), id: other)
        XCTAssertThrowsError(try byTime.append(
            .commitmentEdited(id: other, edit: CommitmentEdit(
                requirement: Requirement(activity: .only(.running),
                                         metric: .totalActiveEnergy(99_999)))),
            at: d(22, 9)))
    }

    func testAZeroTargetIsNotARequirement() throws {
        var ledger = Ledger()
        XCTAssertThrowsError(try ledger.append(
            .commitmentCreated(makeCommitment(
                requirement: Requirement(metric: .totalActiveEnergy(0)),
                deadline: d(22, 20), createdAt: d(21, 18))),
            at: d(21, 18)))
    }

    // MARK: - History

    func testWorkoutsWrittenBeforeEnergyExistedStillLoad() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(Workout.self, from: Data("""
            {"id": "B0000000-0000-0000-0000-000000000001", "activity": "running",
             "start": "2026-08-22T07:00:00Z", "end": "2026-08-22T07:30:00Z",
             "distanceMeters": 5000}
            """.utf8))
        XCTAssertNil(old.activeEnergyKilocalories, "not reported, and not invented")
        XCTAssertEqual(old.distanceMeters, 5000)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let vigorous = run(minutes: 30, calories: 275, at: d(22, 7))
        let reread = try decoder.decode(Workout.self, from: try encoder.encode(vigorous))
        XCTAssertEqual(reread.activeEnergyKilocalories, 275)
    }

    func testReplayIsIdentical() throws {
        let id = UUID()
        var ledger = ledger(requiring: .totalActiveEnergy(200), id: id)
        ledger.expectAppend(.workoutRecorded(run(minutes: 20, calories: 120, at: d(22, 7))),
                            at: d(22, 7, 30))
        ledger.expectAppend(.workoutRecorded(run(minutes: 15, calories: 90, at: d(22, 18))),
                            at: d(22, 18, 30))

        let replayed = try Ledger(replaying: ledger.entries)
        XCTAssertEqual(replayed.state.progress(for: id), ledger.state.progress(for: id))
        XCTAssertEqual(replayed.state.commitments[id]?.resolution,
                       ledger.state.commitments[id]?.resolution)
    }
}
