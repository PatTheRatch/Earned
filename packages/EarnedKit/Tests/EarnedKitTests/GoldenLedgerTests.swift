import Foundation
import XCTest
@testable import EarnedKit

/// Golden on-disk fixtures.
///
/// The other ledger tests encode with the *current* build's coder and decode
/// with it, which proves today's code reads what today's code writes — and
/// nothing about the files already sitting on real phones, written by earlier
/// builds. These fixtures are raw JSON captured as literals. **Never regenerate
/// them from the current types**: the moment a fixture is re-encoded it stops
/// guarding anything. If one of these tests fails, the build has broken its
/// ability to read a user's existing history; fix the decoder, not the fixture.
final class GoldenLedgerTests: XCTestCase {

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - v1

    /// A ledger exactly as the pre-correction build wrote it: a bare entries
    /// array, no envelope, legacy `Requirement` enum, free-form workout
    /// `activityType`, wait-only `frictionSteps`, a global restricted-app set,
    /// an unfunded Free Override spend, and a wait-earned solo override.
    private let v1Fixture = """
    [
      {
        "id": "E0000000-0000-0000-0000-000000000001",
        "date": "2026-08-22T07:00:00Z",
        "event": {
          "hydrationConfigured": {
            "_0": {
              "enabled": true,
              "interval": 3600,
              "activeHours": {
                "startMinuteOfDay": 480,
                "endMinuteOfDay": 1320,
                "timeZoneIdentifier": "UTC"
              },
              "warningLead": 600
            }
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000002",
        "date": "2026-08-22T07:05:00Z",
        "event": {
          "restrictedAppsChanged": {
            "added": ["instagram", "youtube"],
            "removed": []
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000003",
        "date": "2026-08-22T08:00:00Z",
        "event": { "waterAcknowledged": {} }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000004",
        "date": "2026-08-22T08:30:00Z",
        "event": {
          "commitmentCreated": {
            "_0": {
              "id": "C0000000-0000-0000-0000-00000000000A",
              "title": "Run 30 minutes",
              "requirement": { "totalDuration": { "_0": 1800 } },
              "deadline": "2026-08-22T20:00:00Z",
              "createdAt": "2026-08-22T08:30:00Z",
              "configuredCorrectionWindow": 7200,
              "overridePolicy": {
                "approvalsRequired": 2,
                "accountabilityWindow": 1800,
                "soloEscalation": {
                  "recentWindow": 2592000,
                  "frictionSteps": [600, 1800, 3600]
                }
              },
              "rewardEligible": true,
              "warningLead": 1800
            }
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000005",
        "date": "2026-08-22T09:35:00Z",
        "event": {
          "workoutRecorded": {
            "_0": {
              "id": "A0000000-0000-0000-0000-000000000001",
              "activityType": "Manual entry",
              "start": "2026-08-22T09:00:00Z",
              "end": "2026-08-22T09:30:00Z"
            }
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000006",
        "date": "2026-08-23T08:00:00Z",
        "event": {
          "commitmentCreated": {
            "_0": {
              "id": "C0000000-0000-0000-0000-00000000000B",
              "title": "Lift",
              "requirement": { "anyWorkout": {} },
              "deadline": "2026-08-23T10:00:00Z",
              "createdAt": "2026-08-23T08:00:00Z",
              "configuredCorrectionWindow": 7200,
              "overridePolicy": {
                "approvalsRequired": 2,
                "accountabilityWindow": 1800,
                "soloEscalation": {
                  "recentWindow": 2592000,
                  "frictionSteps": [600, 1800, 3600]
                }
              },
              "rewardEligible": true
            }
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000007",
        "date": "2026-08-23T12:00:00Z",
        "event": {
          "freeOverrideSpent": { "commitmentID": "C0000000-0000-0000-0000-00000000000B" }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000008",
        "date": "2026-08-24T08:00:00Z",
        "event": {
          "commitmentCreated": {
            "_0": {
              "id": "C0000000-0000-0000-0000-00000000000C",
              "title": "Swim",
              "requirement": { "anyWorkout": {} },
              "deadline": "2026-08-24T09:00:00Z",
              "createdAt": "2026-08-24T08:00:00Z",
              "configuredCorrectionWindow": 7200,
              "overridePolicy": {
                "approvalsRequired": 2,
                "accountabilityWindow": 1800,
                "soloEscalation": {
                  "recentWindow": 2592000,
                  "frictionSteps": [600, 1800, 3600]
                }
              },
              "rewardEligible": true
            }
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-000000000009",
        "date": "2026-08-24T10:00:00Z",
        "event": {
          "overrideRequested": {
            "id": "D0000000-0000-0000-0000-000000000001",
            "commitmentID": "C0000000-0000-0000-0000-00000000000C"
          }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-00000000000A",
        "date": "2026-08-24T10:30:00Z",
        "event": {
          "soloOverrideStarted": { "requestID": "D0000000-0000-0000-0000-000000000001" }
        }
      },
      {
        "id": "E0000000-0000-0000-0000-00000000000B",
        "date": "2026-08-24T10:45:00Z",
        "event": {
          "soloOverrideCompleted": { "requestID": "D0000000-0000-0000-0000-000000000001" }
        }
      }
    ]
    """

    func testV1GoldenFixtureStillLoads() throws {
        let ledger = try Self.decoder.decode(Ledger.self, from: Data(v1Fixture.utf8))

        let runID = UUID(uuidString: "C0000000-0000-0000-0000-00000000000A")!
        let liftID = UUID(uuidString: "C0000000-0000-0000-0000-00000000000B")!
        let swimID = UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!

        // The run was completed by the 30-minute workout, on time.
        XCTAssertEqual(ledger.state.commitments[runID]?.resolution,
                       .completed(at: d(22, 9, 30)))

        // The unfunded spend was funded by an inserted, attributed grant.
        XCTAssertEqual(ledger.state.commitments[liftID]?.resolution,
                       .overridden(.free, at: d(23, 12)))
        XCTAssertEqual(ledger.state.freeOverrideGrants.count, 1)
        XCTAssertEqual(ledger.state.freeOverrideGrants.first?.source, .migration)
        XCTAssertEqual(ledger.state.freeOverrideGrants.first?.spentOn, liftID)

        // The wait-earned solo override replays, funded by inserted effort.
        XCTAssertEqual(ledger.state.commitments[swimID]?.resolution,
                       .overridden(.solo, at: d(24, 10, 45)))

        // v1's wait-only escalation decodes as elapsed floors with zero effort:
        // that is the contract the user agreed to, and migration must not
        // quietly add effort to a hardened commitment's escape route.
        XCTAssertEqual(ledger.state.commitments[runID]?.commitment
                        .overridePolicy.soloEscalation.steps,
                       [FrictionRequirement(effortUnits: 0, minimumElapsed: 600),
                        FrictionRequirement(effortUnits: 0, minimumElapsed: 1800),
                        FrictionRequirement(effortUnits: 0, minimumElapsed: 3600)])
        let request = ledger.state.overrideRequests[
            UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!]
        XCTAssertEqual(request?.soloRequirement,
                       FrictionRequirement(effortUnits: 0, minimumElapsed: 600))

        // The global restricted-app set replays as the default profile.
        XCTAssertEqual(ledger.state.defaultCommitmentRestrictions,
                       RestrictionProfile(["instagram", "youtube"]))

        // A v1 commitment's window opens at creation, as the rule then was.
        XCTAssertEqual(ledger.state.commitments[runID]?.commitment.eligibleFrom, d(22, 8, 30))

        // 11 recorded events + 2 migration insertions (a grant and effort).
        XCTAssertEqual(ledger.entries.count, 13)
    }

    // MARK: - v2

    /// A ledger exactly as the current build writes it. Guards files written
    /// from today onward: envelope, activity + metric requirement, restriction
    /// profiles, plans, `eligibleFrom`, `planID`, effort-based escalation.
    private let v2Fixture = """
    {
      "version": 2,
      "entries": [
        {
          "id": "E0000000-0000-0000-0000-000000000001",
          "date": "2026-08-23T17:00:00Z",
          "event": {
            "hydrationConfigured": {
              "_0": {
                "enabled": true,
                "interval": 3600,
                "activeHours": {
                  "startMinuteOfDay": 480,
                  "endMinuteOfDay": 1320,
                  "timeZoneIdentifier": "UTC"
                },
                "restrictions": { "tokens": ["instagram"] },
                "warningLead": 600
              }
            }
          }
        },
        {
          "id": "E0000000-0000-0000-0000-000000000002",
          "date": "2026-08-23T17:30:00Z",
          "event": {
            "defaultCommitmentRestrictionsChanged": {
              "_0": { "tokens": ["youtube"] }
            }
          }
        },
        {
          "id": "E0000000-0000-0000-0000-000000000003",
          "date": "2026-08-23T18:00:00Z",
          "event": {
            "planCreated": {
              "_0": {
                "id": "B0000000-0000-0000-0000-000000000001",
                "title": "Run 30 min",
                "requirement": {
                  "activity": { "types": { "_0": ["running"] } },
                  "metric": { "totalDuration": { "_0": 1800 } }
                },
                "weekdays": [2],
                "deadlineMinuteOfDay": 600,
                "startDate": "2026-08-24T00:00:00Z",
                "endDate": "2026-08-24T00:00:00Z",
                "timeZoneIdentifier": "UTC",
                "configuredCorrectionWindow": 7200,
                "overridePolicy": {
                  "approvalsRequired": 2,
                  "accountabilityWindow": 1800,
                  "soloEscalation": {
                    "recentWindow": 2592000,
                    "steps": [
                      { "effortUnits": 60, "minimumElapsed": 600 },
                      { "effortUnits": 180, "minimumElapsed": 1800 },
                      { "effortUnits": 360, "minimumElapsed": 3600 }
                    ]
                  }
                },
                "restrictions": { "tokens": ["youtube"] },
                "rewardEligible": true,
                "createdAt": "2026-08-23T18:00:00Z"
              }
            }
          }
        },
        {
          "id": "E0000000-0000-0000-0000-000000000004",
          "date": "2026-08-23T18:00:00Z",
          "event": {
            "commitmentCreated": {
              "_0": {
                "id": "C0000000-0000-0000-0000-000000000001",
                "title": "Run 30 min",
                "requirement": {
                  "activity": { "types": { "_0": ["running"] } },
                  "metric": { "totalDuration": { "_0": 1800 } }
                },
                "eligibleFrom": "2026-08-24T00:00:00Z",
                "deadline": "2026-08-24T10:00:00Z",
                "createdAt": "2026-08-23T18:00:00Z",
                "configuredCorrectionWindow": 7200,
                "overridePolicy": {
                  "approvalsRequired": 2,
                  "accountabilityWindow": 1800,
                  "soloEscalation": {
                    "recentWindow": 2592000,
                    "steps": [
                      { "effortUnits": 60, "minimumElapsed": 600 },
                      { "effortUnits": 180, "minimumElapsed": 1800 },
                      { "effortUnits": 360, "minimumElapsed": 3600 }
                    ]
                  }
                },
                "restrictions": { "tokens": ["youtube"] },
                "rewardEligible": true,
                "planID": "B0000000-0000-0000-0000-000000000001"
              }
            }
          }
        },
        {
          "id": "E0000000-0000-0000-0000-000000000005",
          "date": "2026-08-24T08:05:00Z",
          "event": { "waterAcknowledged": {} }
        },
        {
          "id": "E0000000-0000-0000-0000-000000000006",
          "date": "2026-08-24T08:40:00Z",
          "event": {
            "workoutRecorded": {
              "_0": {
                "id": "A0000000-0000-0000-0000-000000000001",
                "activity": "running",
                "start": "2026-08-24T08:00:00Z",
                "end": "2026-08-24T08:30:00Z"
              }
            }
          }
        }
      ]
    }
    """

    /// The reference ledger the fixture must match, built through the same
    /// appends with the same identifiers. Also the diagnostic aid: when the
    /// fixture stops matching, the failure prints what the current encoder
    /// actually writes, so the *decoder* gap is visible immediately.
    private func v2Reference() throws -> Ledger {
        let planID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
        let commitmentID = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        var ledger = Ledger()

        try ledger.append(
            .hydrationConfigured(HydrationConfig(
                enabled: true, interval: 3600, activeHours: utcActiveHours,
                restrictions: RestrictionProfile(["instagram"]), warningLead: 600)),
            at: d(23, 17), id: UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!)
        try ledger.append(
            .defaultCommitmentRestrictionsChanged(RestrictionProfile(["youtube"])),
            at: d(23, 17, 30), id: UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!)

        let plan = CommitmentPlan(id: planID, title: "Run 30 min",
                                  requirement: .run(minutes: 30),
                                  weekdays: [2], deadlineMinuteOfDay: 600,
                                  startDate: d(24), endDate: d(24),
                                  timeZoneIdentifier: "UTC",
                                  configuredCorrectionWindow: 7200,
                                  overridePolicy: patrickPolicy(),
                                  restrictions: RestrictionProfile(["youtube"]),
                                  createdAt: d(23, 18))
        try ledger.append(.planCreated(plan), at: d(23, 18),
                          id: UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!)
        let occurrence = plan.occurrences(idProvider: { commitmentID })[0]
        try ledger.append(.commitmentCreated(occurrence), at: d(23, 18),
                          id: UUID(uuidString: "E0000000-0000-0000-0000-000000000004")!)

        try ledger.append(.waterAcknowledged, at: d(24, 8, 5),
                          id: UUID(uuidString: "E0000000-0000-0000-0000-000000000005")!)
        try ledger.append(
            .workoutRecorded(Workout(
                id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
                activity: .running, start: d(24, 8), end: d(24, 8, 30))),
            at: d(24, 8, 40), id: UUID(uuidString: "E0000000-0000-0000-0000-000000000006")!)
        return ledger
    }

    func testV2GoldenFixtureMatchesTheCurrentCoder() throws {
        let reference = try v2Reference()

        let decoded: Ledger
        do {
            decoded = try Self.decoder.decode(Ledger.self, from: Data(v2Fixture.utf8))
        } catch {
            let written = String(data: (try? Self.encoder.encode(reference)) ?? Data(),
                                 encoding: .utf8) ?? "<encoding failed>"
            XCTFail("""
                v2 golden fixture no longer decodes: \(error)
                Either the decoder regressed (fix the decoder) or the on-disk \
                format legitimately moved on (bump the schema version and write \
                a migration — do NOT just regenerate the fixture).
                The current encoder writes:
                \(written)
                """)
            return
        }

        XCTAssertEqual(decoded, reference)
        let commitmentID = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(decoded.state.commitments[commitmentID]?.resolution,
                       .completed(at: d(24, 8, 30)))
        XCTAssertEqual(decoded.state.commitments[commitmentID]?.commitment.planID,
                       UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(decoded.state.commitments[commitmentID]?.commitment.eligibleFrom, d(24))
    }

    // MARK: - v2 overrides, granted the old way

    /// A v2 ledger whose accountability override was granted by *this engine*
    /// counting approvals — the authority step 8 moved to the server.
    ///
    /// §19 asks for exactly this file. Ledgers like it are on real phones, and
    /// the temptation when the server became authoritative was to reinterpret
    /// these events, or to migrate them into grants. Both would be inventing
    /// server decisions that were never made. They replay under the rules that
    /// were in force when they were written, and this fixture is what stops
    /// that being quietly undone.
    private let v2OverrideFixture = """
    {
      "version": 2,
      "entries": [
        {
          "id": "E1000000-0000-0000-0000-000000000001",
          "date": "2026-08-21T18:00:00Z",
          "event": {
            "commitmentCreated": {
              "_0": {
                "id": "C1000000-0000-0000-0000-000000000001",
                "title": "Run 30 min",
                "requirement": {
                  "activity": { "types": { "_0": ["running"] } },
                  "metric": { "totalDuration": { "_0": 1800 } }
                },
                "eligibleFrom": "2026-08-22T00:00:00Z",
                "deadline": "2026-08-22T10:00:00Z",
                "createdAt": "2026-08-21T18:00:00Z",
                "configuredCorrectionWindow": 7200,
                "overridePolicy": {
                  "approvalsRequired": 2,
                  "accountabilityWindow": 1800,
                  "soloEscalation": {
                    "recentWindow": 2592000,
                    "steps": [
                      { "effortUnits": 60, "minimumElapsed": 600 },
                      { "effortUnits": 180, "minimumElapsed": 1800 },
                      { "effortUnits": 360, "minimumElapsed": 3600 }
                    ]
                  }
                },
                "restrictions": { "tokens": ["youtube"] },
                "rewardEligible": true
              }
            }
          }
        },
        {
          "id": "E1000000-0000-0000-0000-000000000002",
          "date": "2026-08-22T11:00:00Z",
          "event": {
            "overrideRequested": {
              "id": "D1000000-0000-0000-0000-000000000001",
              "commitmentID": "C1000000-0000-0000-0000-000000000001"
            }
          }
        },
        {
          "id": "E1000000-0000-0000-0000-000000000003",
          "date": "2026-08-22T11:05:00Z",
          "event": {
            "overrideApprovalRecorded": {
              "requestID": "D1000000-0000-0000-0000-000000000001",
              "partnerID": "alice"
            }
          }
        },
        {
          "id": "E1000000-0000-0000-0000-000000000004",
          "date": "2026-08-22T11:10:00Z",
          "event": {
            "overrideApprovalRecorded": {
              "requestID": "D1000000-0000-0000-0000-000000000001",
              "partnerID": "bob"
            }
          }
        }
      ]
    }
    """

    func testV2OverrideLedgerStillReplaysIdentically() throws {
        let decoded = try Self.decoder.decode(Ledger.self, from: Data(v2OverrideFixture.utf8))

        let commitmentID = UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!
        let requestID = UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!

        // The second approval resolved it, then and now.
        XCTAssertEqual(decoded.state.commitments[commitmentID]?.resolution,
                       .overridden(.accountability, at: d(22, 11, 10)))
        XCTAssertTrue(decoded.state.accessState(now: d(22, 11, 11)).isFullAccess)

        let request = try XCTUnwrap(decoded.state.overrideRequests[requestID])
        XCTAssertEqual(request.approvals.count, 2)
        XCTAssertEqual(request.grantedKind, .accountability)
        XCTAssertEqual(request.grantedAt, d(22, 11, 10))

        // The fields step 8 added are absent, not defaulted to something
        // misleading: this override had no server grant, because there was no
        // server. A missing grant id is the truth about it.
        XCTAssertNil(request.serverGrantID)
        XCTAssertTrue(request.roster.isEmpty)
    }

    func testAV2LedgerIsRewrittenAsV3WithoutChangingItsEvents() throws {
        let decoded = try Self.decoder.decode(Ledger.self, from: Data(v2OverrideFixture.utf8))
        let reencoded = try Self.encoder.encode(decoded)
        let document = try Self.decoder.decode(LedgerDocument.self, from: reencoded)

        XCTAssertEqual(document.version, 3, "saving an old ledger stamps the current version")
        XCTAssertEqual(document.entries.count, 4, "and invents no events on the way")
        XCTAssertEqual(document.entries.map(\.id), decoded.entries.map(\.id))

        let replayed = try Ledger(replaying: document.entries)
        XCTAssertEqual(replayed.state.commitments, decoded.state.commitments,
                       "a v3 rewrite of a v2 ledger replays to the same state")
    }

    /// Round trip through the exact coder configuration the app uses,
    /// including its ISO-8601 dates, which truncate sub-second precision.
    /// Events stamped with real `Date()` values carry fractional seconds; the
    /// truncated history must still replay rather than tripping a validator.
    func testFractionalSecondDatesSurviveTheAppCoder() throws {
        var ledger = Ledger()
        let base = d(24, 8).addingTimeInterval(0.7)
        try ledger.append(.hydrationConfigured(patrickHydration()), at: base)
        try ledger.append(
            .commitmentCreated(makeCommitment(deadline: d(24, 20),
                                              createdAt: base.addingTimeInterval(0.5))),
            at: base.addingTimeInterval(0.5))
        try ledger.append(.waterAcknowledged, at: base.addingTimeInterval(1.2))

        let data = try Self.encoder.encode(ledger)
        let reloaded = try Self.decoder.decode(Ledger.self, from: data)
        XCTAssertEqual(reloaded.entries.count, 3)
        XCTAssertEqual(reloaded.state.commitments.count, 1)
    }
}
