# app/

The iOS application: a SwiftUI shell around [`EarnedKit`](../packages/EarnedKit/), which owns
every product rule. Views read projected state and append events; they never decide what is
allowed.

## Building

The Xcode project is generated from [`project.yml`](project.yml) rather than committed, so
project-file merge conflicts can't happen.

```sh
brew install xcodegen          # once
xcodegen generate --spec app/project.yml --project app
open app/Earned.xcodeproj
```

Then pick your iPhone (or a simulator) and run. A free Apple developer account is enough for
now — builds expire after 7 days; enrolling in the Developer Program removes that.

CI builds this target on every push, so a compile break shows up without a Mac in the loop.

## What's here now

| Screen | Purpose |
|---|---|
| Onboarding | Teaches Gates one concept per screen, configures the Hydration Gate |
| Today | What do I need to do right now — gate status, overdue work, upcoming commitments |
| Lock screen | The receipt: exactly which Gates are closed and what's left |
| New Commitment | One decision per screen, ending in a hardening deadline |
| History | Streak, debt, 30-day reliability, every commitment and its outcome |
| Settings | Hydration config, reward policy, restricted-app placeholders, manual workout logging |

## What's deliberately missing

This build has **no enforcement**. It tracks Gates and tells you exactly what *would* be
locked, but nothing is shielded yet, because that needs Apple's Screen Time entitlements:

- **FamilyControls / ManagedSettings / DeviceActivity** — app selection and real shielding
  (roadmap step 3). Requires the Family Controls capability and, for TestFlight, Apple's
  approval of the distribution entitlement.
- **HealthKit** — workout verification (step 4). Until then, Settings → Testing logs a
  workout by hand so the full loop can be exercised.
- **Accountability partners** — the approve/deny links need the Supabase backend (step 5).
  Free and Solo overrides work today.

Keeping those capabilities out of the project means this target builds and runs on a free
account with no entitlement paperwork. They arrive with the steps that need them.

## Where state lives

The ledger is JSON in the app's Documents directory. When the Screen Time extensions land it
moves to a shared App Group container so the shield can read gate state — every path goes
through `Store/LedgerStorage.swift` to make that a one-file change.
