import Foundation

/// Explicit, auditable migration of persisted ledgers between schema versions.
///
/// The rule this file exists to honour: **historical semantics are never
/// silently rewritten.** Where a v1 ledger cannot be replayed under v2 rules,
/// the migration inserts a visible, attributed event rather than quietly
/// changing what an old event meant.
public enum LedgerMigration {

    public enum MigrationError: Error, CustomStringConvertible {
        case unknownVersion(Int)

        public var description: String {
            switch self {
            case .unknownVersion(let version):
                return "Ledger schema version \(version) is newer than this build understands "
                    + "(\(Ledger.currentSchemaVersion)). Refusing to guess."
            }
        }
    }

    public static func migrate(_ document: LedgerDocument) throws -> LedgerDocument {
        switch document.version {
        case Ledger.currentSchemaVersion:
            return document
        case 1:
            return LedgerDocument(
                version: Ledger.currentSchemaVersion,
                entries: migrateV5ToV6(migrateV4ToV5(
                    migrateV3ToV4(migrateV2ToV3(migrateV1ToV2(document.entries))))))
        case 2:
            return LedgerDocument(
                version: Ledger.currentSchemaVersion,
                entries: migrateV5ToV6(migrateV4ToV5(migrateV3ToV4(migrateV2ToV3(document.entries)))))
        case 3:
            return LedgerDocument(
                version: Ledger.currentSchemaVersion,
                entries: migrateV5ToV6(migrateV4ToV5(migrateV3ToV4(document.entries))))
        case 4:
            return LedgerDocument(version: Ledger.currentSchemaVersion,
                                  entries: migrateV5ToV6(migrateV4ToV5(document.entries)))
        case 5:
            return LedgerDocument(version: Ledger.currentSchemaVersion,
                                  entries: migrateV5ToV6(document.entries))
        case let version where version > Ledger.currentSchemaVersion:
            throw MigrationError.unknownVersion(version)
        default:
            throw MigrationError.unknownVersion(document.version)
        }
    }

    /// v2 → v3: nothing to do, and that is the point.
    ///
    /// v3 adds `accountabilityOverrideGranted`, which no v2 ledger can
    /// contain. The events already written keep meaning exactly what they
    /// meant — including `overrideApprovalRecorded`, which counted approvals
    /// on the device. Rewriting those into grants would be inventing server
    /// decisions that were never made, and this file's rule is that historical
    /// semantics are never silently rewritten.
    ///
    /// The version bump is therefore not about the past; it is so that an
    /// older build refuses a ledger containing events it cannot replay,
    /// rather than dropping them and quietly losing an override.
    private static func migrateV2ToV3(_ entries: [LedgerEntry]) -> [LedgerEntry] { entries }

    /// v3 → v4: nothing to rewrite, deliberately.
    ///
    /// v4 adds workout evidence and requirement verification tiers (NORTHSTAR
    /// §15). Tolerant decoding already reads old shapes truthfully — a v3
    /// workout was a manual entry, so it decodes `.selfReported`, and a v3
    /// requirement decodes `.selfReported` because everything counted when it
    /// was written. Stamping those into the entries here would add nothing the
    /// decoder does not already say.
    ///
    /// The bump earns its keep in the other direction: a v3 build handed a v4
    /// ledger refuses it whole, rather than silently ignoring the `evidence`
    /// keys it has never heard of — which would let a manual entry satisfy a
    /// commitment whose whole point was that it must not.
    private static func migrateV3ToV4(_ entries: [LedgerEntry]) -> [LedgerEntry] { entries }

    /// v4 → v5: nothing to rewrite.
    ///
    /// v5 adds `CompletionMetric.totalActiveEnergy` and the active-energy
    /// figure on a workout. No v4 ledger contains either, and workouts that
    /// never recorded energy decode as nil — *not reported*, which counts as
    /// nothing rather than as an unknown quantity.
    ///
    /// Again the bump is for the other direction, and here it is not merely
    /// tidiness: a v4 build cannot decode `totalActiveEnergy` at all, so
    /// without the version it would quarantine the ledger with a parse error
    /// about an unknown case. Refusing by version says what actually happened.
    private static func migrateV4ToV5(_ entries: [LedgerEntry]) -> [LedgerEntry] { entries }

    /// v5 → v6: nothing to rewrite.
    ///
    /// v6 adds `CompletionMetric.sessionCount` — "run 3× this week" as a
    /// first-class requirement. No v5 ledger contains one, and every metric a
    /// v5 ledger does contain means exactly what it meant.
    ///
    /// The bump, as with v5, is for the other direction: a v5 build cannot
    /// decode `sessionCount` and without the version would quarantine the
    /// ledger with a parse error about an unknown case. Refusing by version
    /// says what actually happened.
    private static func migrateV5ToV6(_ entries: [LedgerEntry]) -> [LedgerEntry] { entries }

    /// v1 → v2.
    ///
    /// Most of the shape change is handled by tolerant decoding on the types
    /// themselves (a v1 `Requirement` decodes as `.any` activity with the same
    /// metric; a v1 commitment gets `eligibleFrom = createdAt`; a v1 workout's
    /// free-form activity string maps onto `ActivityType`). Two things need real
    /// migration:
    ///
    /// 1. **Free Overrides became explicit events.** In v1 the balance was
    ///    recomputed from history against the current reward policy, so a
    ///    `freeOverrideSpent` entry has nothing funding it under v2 rules and
    ///    replay would reject it. Each unfunded spend is funded by inserting a
    ///    `freeOverrideEarned(source: .migration)` immediately before it —
    ///    visible in history, attributed to migration, never mistaken for a
    ///    streak reward.
    ///
    /// 2. **Solo overrides gained active friction.** A v1 `soloOverrideCompleted`
    ///    was earned by waiting out a timer, which v2 alone would reject for want
    ///    of recorded effort. Migration inserts the effort the v1 flow never
    ///    asked for, immediately before the completion, so old history replays
    ///    without pretending the user did something they didn't.
    ///
    /// The v1 `restrictedAppsChanged` events are *not* rewritten: that case is
    /// still carried on `Event` and still replays, applying to the default
    /// profile for new commitments — the closest honest reading of what a single
    /// global set meant. It deliberately does not retro-fit profiles onto
    /// commitments created before Gates owned restrictions; those Gates genuinely
    /// had no profile, and inventing one would be a silent rewrite.
    private static func migrateV1ToV2(_ entries: [LedgerEntry]) -> [LedgerEntry] {
        var result: [LedgerEntry] = []
        var unspentGrants = 0

        for entry in entries {
            switch entry.event {
            case .soloOverrideCompleted(let requestID):
                // v1 completed a solo override by waiting out a timer; v2 also
                // requires recorded effort. The historical wait did satisfy v2's
                // elapsed floor (the same 10/30/60 minutes), so migration
                // supplies the effort that the v1 flow never asked for. The
                // reducer clamps to whatever the frozen requirement actually is.
                result.append(LedgerEntry(
                    date: entry.date,
                    event: .soloOverrideProgressRecorded(requestID: requestID, units: 1_000_000)))
                result.append(entry)

            case .freeOverrideSpent:
                if unspentGrants == 0 {
                    result.append(LedgerEntry(
                        date: entry.date,
                        event: .freeOverrideEarned(id: UUID(), source: .migration)))
                    unspentGrants += 1
                }
                unspentGrants -= 1
                result.append(entry)

            case .freeOverrideEarned:
                unspentGrants += 1
                result.append(entry)

            default:
                result.append(entry)
            }
        }
        return result
    }
}
