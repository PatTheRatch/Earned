# Earned — Architecture Decisions

v0.1 · August 2026

This records the technical decisions behind Earned and why they were made. The product vision lives in [NORTHSTAR.md](NORTHSTAR.md); this document is about how we build it. Decisions here are cheap to revisit before code exists and expensive after — anything overturned later should be edited here with a note, not silently contradicted.

---

## 1. Client: native Swift + SwiftUI (forced)

Enforcement is the product. On iOS that means Apple's Screen Time stack:

- **FamilyControls** — authorization and privacy-preserving app selection (the user picks restricted apps via `FamilyActivityPicker`; the app receives opaque tokens, never a readable app list — which also satisfies NORTHSTAR §34).
- **ManagedSettings** — applies and lifts the actual shields.
- **DeviceActivity** — schedules and usage events, running in native app extensions.
- **HealthKit** — workout verification.

All native-only, with the shield/monitor components running as app extensions. A cross-platform framework would wrap a mostly-native app and add nothing. **Decision: Swift + SwiftUI, iOS-native. Not revisited.**

Two consequences:

- **Family Controls distribution entitlement.** Development builds on Patrick's own phone need no approval. TestFlight/App Store distribution requires applying to Apple for the entitlement. Apply early — it's free and takes days to weeks.
- **Personal-use builds** need a paid Apple Developer account ($99/yr) to avoid 7-day build expiry. Plan: enroll when the first on-device build is ready.

## 2. Domain engine: EarnedKit, a pure Swift package

The core scalability requirement is NORTHSTAR §32: commitment state belongs to the account, devices only enforce. The architecture that guarantees this from day one:

**All domain logic lives in `packages/EarnedKit` — a Swift package with zero UI and zero iOS-framework dependencies.** Commitments, gates, hardening, the Monotonic Commitment Principle, debt, override ladders, warning schedules: all deterministic, all testable, all portable. The iOS app, the shield extension, and any future iPad/Mac/server component are thin shells around it.

### Event ledger

Commitment state is modeled as an **append-only event ledger**, not mutable records:

```
CommitmentCreated → CommitmentHardened → WorkoutRecorded(18 min)
→ DeadlinePassed → OverrideRequested → …
```

Current state (gate satisfied? access allowed? why locked?) is a pure function of the ledger. This buys us, structurally rather than by discipline:

- **Monotonicity** (§12) — easier-making events are simply rejected by the reducer after hardening.
- **Explainability** (§39.10) — "why am I locked" is read straight off the ledger.
- **Sync-readiness** (§32–33) — an append-only log is the easiest possible thing to replicate to a server later; no conflict-resolution design debt.
- **Trust metrics** (§24, §30) — reliability stats are queries over history, free.

### Testability

A dependency-free package builds on Linux. Verification runs both locally (development now happens on Patrick's Mac, which has the full toolchain) and through **GitHub Actions** (Linux + macOS: full EarnedKit suite, backend schema/RLS suite against a throwaway Postgres in both layouts, edge-function checks, and an XcodeGen + xcodebuild compile of the app, on every push). The enforcement UI can only be tested by hand on a phone; the gate engine — the part where a logic bug means being wrongly locked out — gets exhaustive automated tests.

## 3. Backend: Supabase

MVP needs a small backend for exactly one feature: accountability-override approvals via SMS/iMessage link (NORTHSTAR §23) — a web page partners open, backed by vote-counting logic. The long-term need is account-authoritative state and cross-device sync.

**Decision: Supabase** (Postgres + auth + edge functions).

- Relational Postgres fits the ledger/contract model naturally.
- Free tier covers single-user scale; scales to real usage without re-architecture.
- Portable: it's standard Postgres and standard APIs — if Earned outgrows it, the data and schema move to a custom API without a rewrite.
- Auth included, for when accounts become real.

Rejected: **Firebase** (NoSQL modeling of contracts is clumsy; deeper lock-in), **CloudKit** (poor fit for the partner web page; forecloses Android/web), **custom API now** (slowest start; the ledger model keeps this door open for later).

### MVP authority model

For the single-user MVP, the phone's ledger is the working copy and the backend sees only what accountability requires. The domain model is account-shaped from day one, so promoting the server to authoritative (§33: deletion shouldn't erase debt) is an incremental step, not a migration.

### Enforcement state is domain state, not app state

Whether Earned holds OS authority to enforce is recorded **in the ledger**, not
just in the app's memory. The app layer owns the Screen Time adapter and is the
only thing that can observe authorization; it reports transitions as ordinary
events (`enforcementUnavailableDetected`, `enforcementRestored`) and EarnedKit
decides what they mean.

That boundary is what lets the consequences be tested at all: EarnedKit builds
on Linux with no FamilyControls, so bypass semantics — does it break a streak,
does it clear debt, is it distinguishable from an Override — are exercised in
CI without a device. The app supplies observation; the domain supplies meaning.

Detection is poll-driven by necessity rather than choice: iOS does not notify a
backgrounded app that Screen Time authorization was revoked, so the app reports
what it sees when it next runs. See NORTHSTAR §33 for the full desired-vs-
enforceable table.

### Ledger schema versioning

The persisted ledger is a versioned document (`{version, entries}`), not a bare array — a
file without an envelope reads as v1. Schema changes ship with an explicit migration rather
than tolerant decoding alone, because tolerant decoding silently reinterprets what an old
event *meant*, and these events are contracts the user made.

The v1→v2 migration is the worked example: shape changes ride on decoding, but a historical
free-override spend that v2 has no grant for is funded by an inserted, attributed
`freeOverrideEarned(source: .migration)` rather than being waved through. What happened to
someone's history stays legible.

Engine-derived events (an earned reward, say) are computed once at append time and written
into the ledger as real entries. Replay never re-derives them, so a policy change cannot
retroactively revoke something already earned.

## 4. Repository: monorepo

```
/
├── NORTHSTAR.md          # product vision
├── ARCHITECTURE.md       # this file
├── app/                  # iOS app (Xcode project, generated from project.yml)
├── packages/
│   ├── EarnedKit/        # pure domain engine (Swift package, builds on Linux)
│   └── EarnedMedia/      # avatar image pipeline (Apple platforms; ImageIO)
├── backend/              # Supabase: schema, migrations, SQL test suite
├── supabase/             # CLI config + edge functions (approval page, grant signer)
├── web/                  # link router (Cloudflare Worker)
├── fixtures/             # cross-language pinned test vectors (hardening cases)
└── docs/                 # design notes, decision records, API notes
```

Everything versions together; a change to gate semantics lands in EarnedKit, app, and backend in one commit.

## 5. Build & verification workflow

| Where | What |
|-------|------|
| This repo / Claude sessions | All source, EarnedKit logic, backend functions, docs |
| GitHub Actions (Linux + macOS) | EarnedKit tests, and an XcodeGen + xcodebuild compile of the iOS app, on every push |
| Patrick's Mac + iPhone | Xcode builds, on-device enforcement testing, HealthKit/Screen Time reality checks |
| Supabase project | Hosted backend (free tier) |

## 6. Roadmap

Statuses here distinguish *built* (code exists), *tested* (automated tests hold it),
*deployed* (running in the hosted project — see `docs/deployment.md`), and
*device-verified* (exercised by hand on Patrick's phone). A migration existing is none of
those on its own.

1. ~~**EarnedKit core**~~ — *built + tested.* Event ledger, gate engine (hydration + exercise), hardening/monotonicity, debt, override state machine, enforcement-integrity semantics, plans, verification tiers. 135 tests green on Linux and macOS.
2. ~~**App shell**~~ — *built.* XcodeGen-generated project, onboarding, Today, lock-screen receipt, commitment creation, history, settings. EarnedKit wired in; CI compiles the app on every push.
3. **Enforcement** — *mostly built.* FamilyControls authorization, `FamilyActivityPicker` app selection, and `ManagedSettingsStore` shields are real (`app/Earned/Enforcement/`); shields fail closed. Still missing: a `DeviceActivityMonitor` extension (a Gate closing while Earned isn't running waits for next launch) and a `ShieldConfiguration` extension (blocked apps show Apple's default shield, not `NICE TRY.`).
4. ~~**Verification**~~ — *built.* `Health/HealthImporter.swift`: HealthKit workout import with provenance (who vouched), duplicate-safe re-import, per-commitment verification tiers.
5. ~~**Overrides**~~ — *built + tested; backend deployed.* Free Override and Solo friction flow in EarnedKit; the accountability backend is complete through signed grants — accounts, partners with real consent (server-sent invitations, global suppression), Contract Envelopes, override requests with frozen snapshots, the partner approval page, concurrent-safe voting, Ed25519-signed grants with key rotation, and on-device grant verification against a compiled-in root key (`app/Earned/Grants/`). Sign in with Apple connects the app to it. The SQL suite plus three drills (key rotation, vote concurrency, grant round-trip) hold it in CI.
6. **Live on Patrick's phone** — six-week success test (NORTHSTAR §41). In progress; the §41 questions are not yet answerable.
7. **Social Accountability, Milestone S1** — *built + tested.* Profiles (handle, avatar, optional city), mutual friendships with block semantics, and the Social tab. Design: `docs/social-architecture.md`; commitment sharing and activity events are deliberately later milestones.

The Xcode project is **generated** from `app/project.yml` and not committed, so there are no
project-file merge conflicts. Screen Time and HealthKit capabilities are deliberately absent
until steps 3 and 4, which keeps the app runnable on a free Apple account with no entitlement
paperwork.

## 7. Known OS-reality constraints (to validate in step 3)

Recorded per NORTHSTAR §33's "product intent vs OS-enforceable reality" mandate; each needs testing on a real device:

- Shields apply mid-use (Hard Interruption is feasible) but the exact latency of gate-state → shield transitions needs measurement.
- Safari can be shielded as an app; per-domain web restriction uses `WebDomain` tokens and is coarser.
- Preventing deletion of Earned itself is weak without Screen Time restrictions the user sets outside the app. Document honestly, don't fake-guarantee.
- DeviceActivity schedules have granularity limits (15-minute minimum intervals in places) that may affect hydration-timer precision — needs a prototype before promising minute-level enforcement.

## 8. Social layer (Milestone S1)

Full design and privacy model: [docs/social-architecture.md](docs/social-architecture.md).
The decisions with architectural weight:

- **Friend ≠ accountability partner, structurally.** Friendship is a new `friendship`
  table; the `partner` table (encrypted contacts, consent, suppression) is not repurposed
  and is never consulted by the social layer. Nothing on the enforcement path reads
  friendship, and nothing social reads the accountability tables.
- **One canonical display name.** `account.display_name` stays authoritative; the
  `profile` table (handle, avatar path, optional city, private timezone, discoverability)
  deliberately has no name column. Profile reads join the name in; profile edits write it
  to `account`. No split-brain identity.
- **Social data is representation, not authority.** The Contract Envelope trust boundary
  is not extended to social claims: a completion shown to friends is the client's
  self-report, and nothing may consume it as enforcement evidence. If server-authoritative
  completion is ever wanted, that is a separate project.
- **Same backend posture.** Default-deny RLS, no client table writes, SECURITY DEFINER
  functions that re-derive the caller from the JWT; cross-account reads (search, friend
  profiles) also go through functions so field exposure is decided in one place. Handles,
  not account ids, are the only discovery mechanism.
- **Avatars in Supabase Storage**, private bucket, `<account_id>/<random>.jpg`, visibility
  delegated from the storage policy to one SQL function that the plain-Postgres test suite
  can exercise. The client re-encodes every image (ImageIO, in `packages/EarnedMedia`)
  before upload — downscaled, fresh JPEG, no EXIF/GPS — so the original never leaves the
  phone.
- **Availability contract unchanged (S8).** Profile setup and the Social tab are wholly
  optional to the running of Earned: a backend outage or an incomplete profile never
  touches local Gate enforcement or the Solo Override.
