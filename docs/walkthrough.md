# Earned — What Actually Happens

**End-to-end walkthrough · 29 August 2026 · commit `8a29028`**

Every screen you'd hit from a fresh install to a live commitment, traced against the code
that runs it. Each claim cites the file it comes from, so this can be checked rather than
trusted. Re-verify against the code when it drifts.

---

## Status at a glance

| Area | Status | Notes |
|---|---|---|
| Gate engine — hydration, exercise, hardening, debt, overrides | **Real** | EarnedKit, 32 tests green on Linux + macOS |
| All six screens, poster identity, persistence | **Real** | Ledger saved as JSON, replayed and re-validated on launch |
| Workout verification | *Stub* | Logged by hand in Settings; HealthKit is step 4 |
| Restricted app list | *Stub* | Typed-in names, not real app tokens; the rules around them do work |
| Enforcement — anything actually being blocked | **Missing** | Needs FamilyControls entitlement + paid account; step 3 |
| Accountability partners | **Missing** | State machine exists; no way to send or collect approvals; step 5 |
| Recurring commitments (Mon/Wed/Fri as one thing) | **Missing** | No recurrence concept, and the workaround is broken — see §6 |

**One-sentence version:** the contract machinery is real and correct, the identity is real,
and the entire loop can be driven by hand — but nothing is enforced yet, so today the app
*tells you* you're locked rather than locking anything.

---

## 1. Getting it on the phone

No App Store or TestFlight yet, so installation means building it:

```sh
git pull
xcodegen generate --spec app/project.yml --project app
open app/Earned.xcodeproj
```

Pick the iPhone in Xcode's toolbar destination menu and run. The project deliberately
declares **no** Screen Time or HealthKit capabilities, which is why it installs on a free
Apple account with no entitlement paperwork.

> Source: `app/project.yml`, `app/README.md`

Two consequences already in play: builds signed with a free account stop launching after
**7 days**, and every `git pull` needs that `xcodegen generate` or Xcode won't see new files.

---

## 2. First launch

The app checks one flag — `earned.hasOnboarded` in UserDefaults — and shows onboarding if
it's unset. It also tries to load `ledger.json` from Documents; if that file exists but
can't be replayed, it is moved aside rather than deleted and the user is told, because a
commitment they made is in there.

> Source: `app/Earned/Store/EarnedStore.swift`, `app/Earned/Store/LedgerStorage.swift`

### Onboarding — five screens, Next / Back

| Screen | What it says |
|---|---|
| **DO WHAT MATTERS FIRST.** | The pitch: you decide the deal while thinking clearly, Earned remembers it later. |
| **GATES** | Every active Gate must be satisfied for full access. Calls, messages, maps, music never go behind one. |
| **HYDRATION** | The only screen that collects input. Two sliders. |
| **WHAT GETS RESTRICTED** | Explains the idea and admits app-picking arrives with the next build. |
| **THE DEAL** | Correction window, harder-only edits, missing a deadline doesn't clear it. |

Only the hydration screen writes anything. Defaults are a **60-minute** interval
(slider 15–240) and active hours **08:00–22:00**, with a 10-minute warning lead.

> Source: `app/Earned/Onboarding/OnboardingView.swift` — `activate()`

Tapping **ACTIVATE EARNED** appends one `hydrationConfigured` event and flips the flag.

**What doesn't happen:** onboarding never asks for a first commitment, and never asks which
apps to restrict. You land on Today with a hydration gate and nothing else. NORTHSTAR §28
lists both in the onboarding journey — a deliberate gap to close once app-picking is real.

---

## 3. Today, empty

Fresh out of onboarding, hydration is satisfied (the gate wakes with a full interval), so
the state word reads EARNED and nothing is owed.

```
EARNED
EARNED.

WATER
Fine. 60 min left.
────────────────────────
Nothing owed. Make a commitment when you know what you owe yourself.

[ I DRANK SOME WATER ]
+ NEW COMMITMENT
```

Everything here is derived, not stored — `accessState(now:)` recomputes from the ledger on
a one-second tick. Tapping the state word opens the lock notice; tapping the water row
opens its detail screen.

> Source: `app/Earned/Today/TodayView.swift`, `packages/EarnedKit/Sources/EarnedKit/Queries.swift`

---

## 4. Making a commitment

Five screens, one decision each.

| Step | Asks | Default |
|---|---|---|
| 1 | **WHAT WILL YOU DO?** Free text title. Required — Next stays disabled until non-empty. | empty |
| 2 | **WHAT COUNTS AS COMPLETION?** Any workout / total time / total distance. Time and distance accumulate across sessions. | Any workout |
| 3 | **BY WHEN?** One date picker + Morning (08:00) / Afternoon (14:00) / Evening (20:00) / Custom. | today, 08:00 |
| 4 | **WHAT ARE THE OVERRIDE RULES?** Approvals needed, solo wait, correction window, warning, Free Override eligibility. | 2 approvals · 30 min · 2 h · warn on · eligible |
| 5 | **THE DEAL** Every term listed back, including exactly when it hardens. | — |

> Source: `app/Earned/Commitment/NewCommitmentView.swift`

**The hardening number is the interesting one.** The correction window is
`min(chosen window, time-to-deadline ÷ 8)` — so a commitment due in two hours hardens in
fifteen minutes, not two hours. That's what stops a short-fuse commitment from being
editable right up to its own deadline.

Tapping **COMMIT** appends `commitmentCreated`. Before it hardens anything can change;
after it hardens the app only offers changes that make it harder.

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

### Doing the thing

Settings → Testing → *Log a workout by hand*. Duration, optional distance, how long ago it
finished; stays open across entries so several can be backfilled. Each entry appends
`workoutRecorded`, and the engine re-checks every commitment.

A 30-minute workout closes a 30-minute commitment instantly and the state word flips back
to EARNED. Partial credit accumulates — 18 minutes now, 12 later.

> Source: `app/Earned/Settings/SettingsView.swift`, `packages/EarnedKit/Sources/EarnedKit/State.swift`

### Missing it entirely

The obligation follows you. Debt is capped at one, so missing Saturday and Sunday still
means one workout owed — and a single qualifying workout clears the backlog and that day's
requirement together.

### Getting out of it

Open the commitment → **Ways out**. Three rungs, two of which work today:

- **Free Override** — works now. Earned by consecutive on-time completions (default 5,
  max 2 banked). Instant, no explanation.
- **Accountability** — creates the request, but there's nobody to send it to until the
  backend exists.
- **Solo** — works now. Unavailable until the accountability window elapses, then real
  friction: 10 minutes the first time, 30 the second, 60 the third within a rolling 30 days.

---

## 6. The Mon/Wed/Fri problem

There is no way to say "run Monday, Wednesday and Friday" as one commitment. No recurrence
concept exists anywhere in the engine — a `Commitment` has exactly one `deadline`. Today the
only option is three separate commitments.

### That workaround doesn't work either

A workout is eligible for a commitment if it started after the commitment was *created* —
with no upper bound at all. Every workout is checked against every unresolved commitment.

```swift
func isEligible(for commitment: Commitment) -> Bool {
    start >= commitment.createdAt        // no upper bound
}
```

So setting up all three on Sunday and running on Monday:

```
C_mon  Mon 08:00 >= Sun  ->  COMPLETED   ✓ correct
C_wed  Mon 08:00 >= Sun  ->  COMPLETED   ✗ two days early
C_fri  Mon 08:00 >= Sun  ->  COMPLETED   ✗ four days early
```

**One Monday run silently satisfies the whole week.**

> Source: `packages/EarnedKit/Sources/EarnedKit/Workout.swift`,
> `packages/EarnedKit/Sources/EarnedKit/State.swift` — `resolveIfSatisfied`

### Why it's like that, and the fix

This is a rule that was right for one case and wrong for another. The open-ended window is
exactly what makes debt work — a workout today has to be able to clear the commitment missed
on Saturday. But the same openness lets it reach *forward* into commitments whose day hasn't
arrived.

**The fix is one field.** Give each commitment an `eligibleFrom` alongside its deadline — the
moment its window opens:

- For a one-off, `eligibleFrom` is creation time. Identical behaviour to today.
- For Wednesday's occurrence in a recurring plan, it's Tuesday's deadline, so Monday's run
  can't count toward it.
- Debt keeps working, because the window still has no upper bound: a late workout still
  reaches back.

Recurrence then becomes a thin layer on top — one plan ("run 30 min, Mon/Wed/Fri, next 4
weeks") generating occurrences, each with its own window, deadline and hardening clock. One
thing to create, one thing to edit, one thing to cancel.

**Open design question:** when Wednesday's window opens — Tuesday's deadline (a Tuesday-night
run counts toward Wednesday) or midnight Wednesday (stricter)?

---

## 7. Where that leaves us

Against the north star's MVP list (§35):

| MVP requirement | Status |
|---|---|
| Hydration gate — rolling timer, self-attested, hard restriction | Logic done, restriction missing |
| Exercise — deadline, verification, persistent debt | Logic done, verification stubbed |
| Correction window, hardened commitments, harder-only edits | Done |
| User-selected restricted apps + shielding | Not started (step 3) |
| Guided onboarding, Today, lock explanation, history | Done |
| Apple Health workout verification | Not started (step 4) |

**Every remaining hard problem is on the far side of the Apple Developer Program.** Family
Controls won't provision on a free account at all, so enforcement — the actual product —
can't be tested until enrollment. Everything built so far was deliberately chosen to be
buildable without it.

Three candidates for what's next:

1. **Recurring commitments + the eligibility fix.** No account needed, fixes a real
   correctness bug, removes friction hit in real use.
2. **Enforcement.** The one that makes it a product rather than a tracker. Blocked on the
   $99 enrollment.
3. **The backend.** Fully buildable and testable from this environment; unblocks the
   accountability rung.
