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

A dependency-free package builds on Linux. This development environment has no Swift toolchain, so verification runs through **GitHub Actions on a macOS runner** (build + full EarnedKit test suite on every push), with Patrick's Mac for on-device work. The enforcement UI can only be tested by hand on a phone; the gate engine — the part where a logic bug means being wrongly locked out — gets exhaustive automated tests.

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
├── app/                  # iOS app + extensions (Xcode project)
├── packages/
│   └── EarnedKit/        # pure domain engine (Swift package)
├── backend/              # Supabase: schema, migrations, edge functions
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

1. ~~**EarnedKit core**~~ — *done.* Event ledger, gate engine (hydration + exercise), hardening/monotonicity, debt, override state machine. 32 tests green on Linux and macOS.
2. ~~**App shell**~~ — *done.* XcodeGen-generated project, onboarding, Today, lock-screen receipt, commitment creation, history, settings. EarnedKit wired in; CI compiles the app on every push.
3. **Enforcement** — FamilyControls authorization, app selection, ManagedSettings shields, DeviceActivity schedules, shield UI ("the receipt").
4. **Verification** — HealthKit workout observation → ledger events.
5. **Overrides** — Free Override, Supabase-backed accountability links, Solo Override friction flow.
6. **Live on Patrick's phone** — six-week success test (NORTHSTAR §41).

Steps 1 and 2 are complete. Steps 3–4 need on-device iteration; step 5's backend is buildable from here.

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
