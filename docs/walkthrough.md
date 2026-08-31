# Earned — What Actually Happens

**End-to-end walkthrough · 29 August 2026**

Every screen you'd hit from a fresh install to a live commitment, traced against the code
that runs it. Each claim cites the file it comes from, so this can be checked rather than
trusted. Re-verify against the code when it drifts.

> Rewritten after the product-model correction pass. The previous version described a
> single global restricted-app list, a hydration gate that woke up satisfied, and no
> recurrence at all. All three have changed. See `docs/earnedkit-semantics.md` for the
> decisions behind them, including the ones still marked open.

---

## Status at a glance

| Area | Status | Notes |
|---|---|---|
| Gate engine — hydration, exercise, hardening, debt, overrides | **Real** | EarnedKit, 94 tests on Linux + macOS |
| Per-Gate restrictions, eligibility windows, recurring plans | **Real** | Added in the correction pass |
| All six screens, poster identity, persistence | **Real** | Ledger saved as versioned JSON, replayed and re-validated on launch |
| Deadline warnings | **Real** | Local notifications; no entitlement needed. Informational only — no snooze |
| Workout verification | **Real** | HealthKit import with provenance; per-commitment tiers (NORTHSTAR §15) — your word, or an app has to vouch |
| What "done" means | **Real** | Show up, total time, total distance, or **active calories** — the one target a minute of standing still cannot satisfy |
| Restriction tokens | **Real** | Apple's picker; opaque tokens Earned itself cannot read |
| Enforcement — apps actually blocked | **Real** | `ManagedSettingsStore` shields the union of closed Gates |
| Enforcement while the app is closed | **Missing** | A Gate closing with Earned not running waits for next launch; needs `DeviceActivityMonitor` |
| Enforcement integrity — noticing a revocation | **Partial** | Detected the next time Earned runs. iOS never tells a backgrounded app its authorization went away, so a revocation is invisible until launch |
| Deleting and reinstalling erases what is owed | **Hole** | The ledger is a file in the app's container, so a reinstall wipes commitments, debt and bypass records. Cheaper than any Override; needs account-authoritative state |
| Enforcement can be revoked | **By design, unfixable** | iOS Settings → Screen Time → Apps With Screen Time Access. No app can prevent this; a Screen Time passcode is the only friction |
| Custom shield screen (`NICE TRY.`) | **Missing** | Blocked apps show Apple's default shield; needs a `ShieldConfiguration` extension |
| Accountability partners | **Missing** | State machine exists; no way to send or collect approvals; step 5 |

**One-sentence version:** the contract machinery is real, the identity is real, and Earned
now actually takes apps away when a Gate is closed — the remaining holes are that a Gate
closing while the app isn't running waits for the next launch, workouts are still logged
by hand, and deleting the app still erases everything it was holding you to.

---

## 1. Getting it on the phone

No App Store or TestFlight yet, so installation means building it:

```sh
git pull
xcodegen generate --spec app/project.yml --project app
open app/Earned.xcodeproj
```

Pick the iPhone in Xcode's toolbar destination menu and run. The project requests the
**Family Controls** entitlement, so the Apple ID signing it must be enrolled in the Apple
Developer Program — a free account can't provision it. Family Controls (Development) is
self-serve once enrolled; shipping needs the Distribution entitlement, reviewed by hand.

> Source: `app/project.yml`, `app/Earned/Earned.entitlements`, `app/README.md`

Every `git pull` needs that `xcodegen generate` or Xcode won't see new files.

---

## 2. First launch

The app checks one flag — `earned.hasOnboarded` in UserDefaults — and shows onboarding if
it's unset. It also tries to load `ledger.json` from Documents; if that file exists but
can't be replayed, it is moved aside rather than deleted and the user is told, because a
commitment they made is in there.

A ledger written by an older build is migrated on load rather than rejected: the file is a
versioned document, and a v1 payload runs through `LedgerMigration` before replay.

Golden fixtures — raw v1 and v2 JSON checked in as literals, never regenerated — pin both
on-disk formats in CI, so a build that would quarantine your existing history fails its
tests instead of shipping.

> Source: `app/Earned/Store/EarnedStore.swift`, `app/Earned/Store/LedgerStorage.swift`,
> `packages/EarnedKit/Sources/EarnedKit/Migration.swift`

### Onboarding — five screens, Next / Back

| Screen | What it says |
|---|---|
| **DO WHAT MATTERS FIRST.** | The pitch: you decide the deal while thinking clearly, Earned remembers it later. |
| **GATES** | Every active Gate must be satisfied for full access. Calls, messages, maps, music never go behind one. |
| **HYDRATION** | The only screen that collects input. Two sliders. |
| **WHAT GETS RESTRICTED** | Each Gate takes away its own things; whatever is unsatisfied, you lose the sum of it. Points at Settings to grant Screen Time and pick apps. |
| **THE DEAL** | Correction window, harder-only edits, missing a deadline doesn't clear it. |

Only the hydration screen writes anything. Defaults are a **60-minute** interval
(slider 15–240) and active hours **08:00–22:00**, with a 10-minute warning lead.

> Source: `app/Earned/Onboarding/OnboardingView.swift` — `activate()`

Tapping **ACTIVATE EARNED** appends one `hydrationConfigured` event and flips the flag.

**What doesn't happen:** onboarding never asks for a first commitment, never asks which apps
to restrict, and never requests Screen Time — all three happen later in Settings. NORTHSTAR
§28 puts them in the onboarding journey, so this is still a gap; now that app picking is real
it is a gap worth closing.

---

## 3. Today, first thing in the morning

Here is the first place the corrected model shows up, and it is not a small change.

**The hydration window opens unsatisfied.** There is no free interval at 08:00. Yesterday's
water does not open today.

```swift
guard let acknowledged = lastAcknowledgment, acknowledged >= windowOpen else {
    return .unsatisfied(since: windowOpen)
}
```

> Source: `packages/EarnedKit/Sources/EarnedKit/Hydration.swift` — `status(lastAcknowledgment:now:)`

So a fresh day looks like this, not like EARNED:

```
EARNED
LOCKED.

WATER
Drink some water. Now.
────────────────────────
Nothing owed. Make a commitment when you know what you owe yourself.

[ I DRANK SOME WATER ]
+ NEW COMMITMENT
```

One tap clears it and starts the rolling timer; the row flips to `Fine. 60 min left.`
Outside active hours the Gate goes dormant — `Resting until active hours.` — so the day
ends unlocked and the next one starts closed.

Everything here is derived, not stored: `accessState(now:)` recomputes from the ledger on a
one-second tick.

> Source: `app/Earned/Today/TodayView.swift`,
> `packages/EarnedKit/Sources/EarnedKit/Queries.swift`

---

## 4. Making a commitment

Five screens, one decision each.

| Step | Asks | Default |
|---|---|---|
| 1 | **WHAT WILL YOU DO?** Free text title. Required — Next stays disabled until non-empty. | empty |
| 2 | **WHAT COUNTS AS COMPLETION?** Activity (any / running / walking / cycling / strength) **and** amount (just show up / a total time / a total distance). | Any workout, just show up |
| 3 | **BY WHEN?** Date + Morning (08:00) / Afternoon (14:00) / Evening (20:00) / Custom, then **Just once** or **Repeat weekly**. | today, 08:00, once |
| 4 | **WHAT ARE THE OVERRIDE RULES?** Approvals needed, solo wait, correction window, warning, Free Override eligibility. | 2 approvals · 30 min · 2 h · warn on · eligible |
| 5 | **THE DEAL** Every term listed back, including exactly when it hardens. | — |

> Source: `app/Earned/Commitment/NewCommitmentView.swift`

### Activity and amount are two questions, not one

Step 2 builds a `Requirement { activity, metric }`. "Run 30 minutes" is
`Requirement(activity: .only(.running), metric: .totalDuration(1800))` — and thirty minutes
on a bike does not touch it, because eligibility checks the filter before any accumulation
happens.

Monotonicity follows the same split: narrowing the filter (any → running) is *harder* and
allowed after hardening; widening is easier and refused; swapping running for cycling is
neither, so it's refused too.

> Source: `packages/EarnedKit/Sources/EarnedKit/Activity.swift`

### Mon/Wed/Fri is now one thing

Choosing **Repeat weekly** shows a weekday picker and a 1–12 week slider. Committing
appends a `planCreated` event and then one ordinary `commitmentCreated` per scheduled day.

```swift
let created = store.createPlan(title:, requirement:, weekdays:, deadlineMinuteOfDay:,
                               startDate:, endDate: CommitmentPlan.weeks(Int(weeks), from: start), …)
```

The plan is a **template, not a source of truth**. It expands once, at creation, into real
events. Nothing re-derives a schedule at read time, so replay stays deterministic and every
occurrence has its own deadline, hardening clock, progress and resolution.

**But it reads as one thing.** Twelve occurrences would otherwise be twelve near-identical
rows on Today, which is exactly what making it a plan was meant to avoid. Today folds a
plan's *upcoming* occurrences into a single row headlined by the next one —
`Run 30 min by 10:00 AM · Mon/Wed/Fri · 3 of 12 done` — and tapping it opens the plan, with
every day and its outcome. Overdue occurrences are deliberately **not** folded: each one is
a Gate holding the phone closed, and the lock notice has to name every one (§19).

Rows also say when a day isn't live yet — `counts from wednesday` — because
`eligibleFrom` means a run today does nothing for Friday's obligation, and the row
shouldn't imply otherwise.

Occurrences whose deadline has already passed at creation are skipped — a commitment cannot
be born overdue.

> Source: `packages/EarnedKit/Sources/EarnedKit/Plan.swift` — `occurrences(idProvider:)`

### The hardening number

The correction window is `min(chosen window, time-to-deadline ÷ 8)` — so a commitment due
in two hours hardens in fifteen minutes, not two hours. That's what stops a short-fuse
commitment from being editable right up to its own deadline.

Tapping **COMMIT** appends the events. Before it hardens anything can change; after it
hardens the app only offers changes that make it harder.

---

## 5. Living with it

### The deadline passes

Nothing "runs" — the commitment stops counting as pending and starts counting as overdue on
the next tick, and the state word flips.

```
EARNED
LOCKED.

WATER
Fine. 42 min left.
────────────────────────
RUN 30 MINUTES
18 / 30 min. 12 minutes to go.
was due today 10:00
────────────────────────
[ I DRANK SOME WATER ]
```

### Tapping LOCKED.

The red notice — itemized, factual. `NICE TRY.` is deliberately held back for the real
shield in step 3, so it lands when the user has actually just opened Instagram.

```
STILL LOCKED.

Drink some water                    NOW
Run 30 minutes                18/30 MIN

THE DEAL STILL STANDS.
You set this one.
```

Each row is a `LockReason`, which now carries the restrictions that Gate is taking away —
so the notice can eventually name what each unmet Gate costs rather than lumping it all
together.

> Source: `app/Earned/Today/LockScreenView.swift`,
> `packages/EarnedKit/Sources/EarnedKit/Queries.swift` — `LockReason`, `AccessState`

### Restrictions belong to Gates

There is no single global blocked list any more. Every Gate — hydration, and one per
commitment — carries its own `RestrictionProfile`, and what is actually in force is the
**union across every unsatisfied Gate**:

```swift
public struct AccessState {
    public var lockReasons: [LockReason]
    public var effectiveRestrictions: RestrictionProfile
}
```

So unmet water can strip the phone back to calls and messages while an unmet workout only
takes social apps — and both unsatisfied is automatically stricter than either alone, with
no special case anywhere.

Settings → Restrictions edits each Gate's profile and the default profile applied to new
commitments. Loosening any Gate's profile needs Full Access and nothing hardened
outstanding; tightening is always allowed. The default profile is *not* a Gate, so editing
it is free — it restricts nothing currently in force.

EarnedKit never learns an app name. A `RestrictionToken` is an opaque string; the app puts
typed-in names in today and will put real `ApplicationToken`s in later without the engine
changing.

> Source: `packages/EarnedKit/Sources/EarnedKit/Restrictions.swift`,
> `app/Earned/Settings/SettingsView.swift` — `GateRestrictionsView`, `DefaultRestrictionsView`

### Doing the thing

Settings → Testing → *Log a workout by hand*. Activity, duration, optional distance, how
long ago it finished; stays open across entries so several can be backfilled. Each entry
appends `workoutRecorded`, and the engine re-checks every commitment in **deadline order**,
so the oldest debt clears first.

### The eligibility window

This is the bug the correction pass existed to fix. Eligibility used to be
`start >= createdAt` with no upper bound, so three commitments made on Sunday were all
completed by Monday's run. Now:

```swift
func isEligible(for commitment: Commitment) -> Bool {
    start >= commitment.eligibleFrom && commitment.requirement.activity.accepts(activity)
}
```

- For a one-off, `eligibleFrom` is creation time — you cannot commit to a workout you've
  already done.
- For a plan occurrence it is **midnight at the start of its own calendar day**, clamped
  never to precede the plan's creation. Monday's run cannot reach forward into Wednesday.
- There is still **no upper bound**, which is what makes debt work: a late workout still
  reaches back and clears an overdue commitment.

A workout can still satisfy several commitments at once where their windows genuinely
overlap — that's yesterday's debt and today's requirement cleared together, which is
correct. `eligibleFrom` only stops it reaching *forward*.

> Source: `packages/EarnedKit/Sources/EarnedKit/Workout.swift`,
> `packages/EarnedKit/Sources/EarnedKit/State.swift` — `resolveIfSatisfied`

### Missing it entirely

The obligation follows you. Debt is capped at one, so missing Saturday and Sunday still
means one workout owed — and a single qualifying workout clears the backlog and that day's
requirement together.

Hydration is different on purpose: it goes dormant at window close rather than accruing.
It's an in-the-moment interrupt, not a debt.

### Getting out of it

Open the commitment → **Ways out**. Three rungs, two of which work today:

- **Free Override** — works now. Earned by consecutive on-time completions (default 5,
  max 2 banked). Instant, no explanation. The grant is an immutable ledger event: it's
  written the moment the streak completes and is never recomputed, so changing the reward
  policy later cannot revoke one you already earned.
- **Accountability** — creates the request, but there's nobody to send it to until the
  backend exists.
- **Solo** — works now, and now costs something. Unavailable until the accountability
  window elapses, then requires **effort *and* elapsed time**: 60 units against a 10-minute
  floor the first time, 180/30 min the second, 360/60 min the third within a rolling 30
  days. Neither alone completes it — the screen will say *"Effort done. The clock is not."*
  The requirement is frozen when the challenge starts, so a mid-challenge edit can't make
  an in-flight escape cheaper.

  The on-screen tap mechanic is a deliberately plain test implementation. The real friction
  UX is an open design surface.

> Source: `packages/EarnedKit/Sources/EarnedKit/Override.swift`,
> `app/Earned/Today/LockScreenView.swift` — `SoloFrictionRow`

---

## 6. Warnings

Turning on **"Warn me 30 minutes before"** now does something. Until this build it stored
`warningLead` on the commitment and nothing ever read it — the app collected a promise and
dropped it.

EarnedKit decides what to warn about and when (`upcomingWarnings(now:)`); the app renders
the words and hands them to `UNUserNotificationCenter`. These are local notifications, so
they need no entitlement and work on a free account.

**A warning is information, never a reprieve.** No actions, no snooze, nothing to tap for
more time — anything that could buy time would be the grace period §7 and §20 both rule
out. A test asserts the Gate closes at exactly the same instant whether a warning was
configured or not.

Two more properties worth knowing:

- **Hydration warns only while the Gate is satisfied**, and is re-derived every time you
  drink, so the warning follows the rolling timer instead of a fixed clock.
- **Permission is asked for the first time a warning is actually due** — in practice, the
  first time you tap I DRANK SOME WATER — rather than at launch, when there'd be nothing
  behind the prompt to judge it by.

If notifications are refused, Earned says so in both places it made the promise: the
creation flow's toggle and Settings → Warnings. Turning them off makes Earned quieter, not
more forgiving.

**Open question:** nothing is announced at the moment a Gate actually *closes* — only
before. Once real enforcement lands the shield is arguably that announcement; until then a
Gate can close with the phone in a pocket. §20 covers warnings and doesn't answer this.

> Source: `app/Earned/Store/NotificationScheduler.swift`,
> `app/Earned/Store/EarnedStore.swift` — `plannedWarnings`,
> `packages/EarnedKit/Sources/EarnedKit/Queries.swift` — `upcomingWarnings`

---

## 7. A plan hardens as a whole

Making a plan is one act of commitment to the whole thing, not twelve small ones. Every
occurrence's correction window runs from *plan creation*, not from its own day — so a
four-week plan with a two-hour window is completely hardened two hours after you make it.
You cannot adjust week three of a plan on the Monday of week three. That's deliberate: if
you weren't ready to follow through on the whole plan, you shouldn't have made it.

The creation flow says so before you commit — the weekly-repeat step warns about it, and
the review screen's **Fully hardens** line shows exactly when the last occurrence locks in,
computed from the plan's real occurrences rather than a guess.

Settings → Repeating plans lists active plans and lets you cancel one. Because every
occurrence hardens so quickly, cancellation would otherwise withdraw nothing at all — so it
also withdraws any occurrence whose eligible window hasn't opened yet, on top of the
ordinary still-in-correction-window case. An occurrence that's already live survives,
hardened or not: once a day has arrived, its contract stands like any other.

Editing a plan isn't supported at all yet; cancel and recreate.

> Source: `packages/EarnedKit/Sources/EarnedKit/State.swift` — `case .planCancelled`,
> `docs/earnedkit-semantics.md` § Plans

---

## 8. Where that leaves us

Against the north star's MVP list (§35):

| MVP requirement | Status |
|---|---|
| Hydration gate — rolling timer, self-attested, hard restriction | Logic done, restriction missing |
| Exercise — deadline, verification, persistent debt | Logic done, verification stubbed |
| Correction window, hardened commitments, harder-only edits | Done |
| Per-Gate restriction profiles | Done, with real Screen Time tokens |
| Recurring commitments | Done |
| User-selected restricted apps + shielding | Done (app-driven; background transitions pending) |
| Guided onboarding, Today, lock explanation, history | Done |
| Per-Gate warnings before a deadline (§20) | Done |
| Apple Health workout verification | Done — with per-commitment verification tiers (§15) |
| Direct Strava integration | Tabled — Apple Health covers it; see [`strava.md`](strava.md) |

**The Developer Program enrollment landed, and enforcement went in with it.** Earned now
takes apps away rather than describing what it would take away. What remains:

1. **`DeviceActivityMonitor` extension.** The one real hole in enforcement: a Gate that
   closes while Earned isn't running isn't shielded until the app next opens. This also
   moves the ledger to a shared App Group container so the extension can read gate state —
   `Store/LedgerStorage.swift` exists to make that a one-file change.
2. **`ShieldConfiguration` extension.** Blocked apps currently show Apple's default shield.
   The `NICE TRY.` surface has been reserved in `docs/design-language.md` since the identity
   pass for exactly this moment — the one place the loud voice is earned, because the user
   just reached for a restricted app.
3. ~~**HealthKit verification.**~~ Done. `Health/HealthImporter.swift` reads finished
   workouts (one type, read-only, only while something unresolved could be moved by them),
   keeps HealthKit's own workout UUID so re-imports are duplicates rather than
   double-counts, and records *who vouched* — iOS's user-entered flag and the writing
   app's identity decide whether a workout is the user's word or an app's. On top of it,
   NORTHSTAR §15's verification tiers: each commitment chooses whether your word counts
   or only vouched-for workouts do, frozen at hardening, tightenable after, never
   loosenable — the same lattice as every other term of the deal.

The backend (accountability partners) is still fully buildable, but it unblocks the rung
nobody can use alone anyway.
