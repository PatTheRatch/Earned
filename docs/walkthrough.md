# Earned — What Actually Happens

**End-to-end walkthrough · 31 August 2026**

Every screen you'd hit from a fresh install to a live commitment, traced against the code
that runs it. Each claim cites the file it comes from, so this can be checked rather than
trusted. Re-verify against the code when it drifts.

> Rewritten after the product-model correction pass. The previous version described a
> single global restricted-app list, a hydration gate that woke up satisfied, and no
> recurrence at all. All three have changed. See `docs/earnedkit-semantics.md` for the
> decisions behind them, including the ones still marked open.

> **v2 UI rebuild, September 2026:** the surfaces this document narrates were rebuilt to
> `docs/design-language.md` v2. The tabs are now **Today · Progress · Social · You**
> (History became Progress's record; Settings dissolved into You's destinations), the
> creation flow asks visibility and escape as separate questions, THE DEAL prints as a
> receipt, and manual workout logging is debug-only under You → Advanced. Capabilities
> and semantics below remain accurate; screen-by-screen prose describes the v1 layouts
> where it has not yet been re-traced.

---

## Status at a glance

| Area | Status | Notes |
|---|---|---|
| Gate engine — hydration, exercise, hardening, debt, overrides | **Real** | EarnedKit, 175 tests on Linux + macOS |
| Per-Gate restrictions, eligibility windows, recurring plans | **Real** | Added in the correction pass |
| All six screens, poster identity, persistence | **Real** | Ledger saved as versioned JSON, replayed and re-validated on launch |
| Deadline warnings | **Real** | Local notifications; no entitlement needed. Informational only — no snooze |
| Workout verification | **Real** | HealthKit import with provenance; per-commitment tiers (NORTHSTAR §15) — your word, or an app has to vouch |
| What "done" means | **Real** | Show up, total time, total distance, or **active calories** — the one target a minute of standing still cannot satisfy |
| Restriction tokens | **Real** | Apple's picker; opaque tokens Earned itself cannot read |
| Enforcement — apps actually blocked | **Real** | `ManagedSettingsStore` shields the union of closed Gates |
| Enforcement while the app is closed | **Built, unverified on device** | `EarnedMonitor`, a `DeviceActivityMonitor` extension, applies a plan the app computes ahead of each deadline. The App Group is configured in both targets and CI checks the two agree; the extension's own Family Controls (Distribution) approval is a separate Apple review from the app's. Never observed working on hardware — `docs/beta-readiness.md` B‑2 |
| Enforcement integrity — noticing a revocation | **Partial** | Detected the next time Earned runs. iOS never tells a backgrounded app its authorization went away, so a revocation is invisible until launch |
| Deleting and reinstalling erases what is owed | **Hole, narrowed** | The ledger is still a file in the app's container, so a reinstall wipes local commitments, debt and bypass records. The server now holds every registered Contract Envelope, so *terms* survive — but nothing yet rebuilds obligations from them on reinstall |
| Enforcement can be revoked | **By design, unfixable** | iOS Settings → Screen Time → Apps With Screen Time Access. No app can prevent this; a Screen Time passcode is the only friction |
| Actionable push (invitation, partner request, override approval) | **Built, not deployed** | `push_outbox` (0022) gained its sender in S4: claim-once delivery, collapse ids, dead-token removal, a block check before enqueue. Needs an APNs key and cron — deployment §9. Never social-engagement push: the outbox's `kind` is a three-value check constraint |
| Canonical display name | **Fixed in S4** | Apple sends a name once, on first authorization; the app used to substitute `"Someone"` and `ensure_account` wrote it over the name chosen in profile setup. Silence is no longer a name, and unknown renders as `@handle` |
| Custom shield screen (`NICE TRY.`) | **Built, unverified on device** | `EarnedShield`, a `ShieldConfiguration` extension: signal-red ground, `NICE TRY.`, every closed Gate named with its own figures, `THE DEAL STILL STANDS.` as the last line, and `CLOSE` on the one button. The lines are written in advance by the app into the App Group, because the extension has milliseconds and no ledger. A third Screen Time bundle id, so a third Family Controls review. Unviewable in the simulator — Family Controls cannot be authorized there |
| Sign in with Apple + Contract Envelopes | **Real** | `Backend/AccountStore.swift`: nonce-checked sign-in, `ensure_account`, idempotent envelope registration and re-sync on every foreground. Optional to everything local (S8) |
| Accountability partners | **Real for friends already on Earned** (backend deployed per `deployment.md`; end-to-end device verification is the open item) | Nomination by identity, partner list and roster eligibility in-app (`Backend/PartnersView.swift`), override requests with frozen snapshots, the partner approval page, concurrent-safe voting, Ed25519-signed grants verified on-device against a compiled-in root key (`Grants/`), applied to the ledger which may still refuse a stale grant. Inviting someone who is *not* on Earned is switched off — the message cannot be delivered, see the row below |
| Social — profiles, friends, Social tab | **Real** (Milestone S1) | Profile with unique handle + avatar, friend requests/accept/decline/remove/block, handle search, Social tab. See `docs/social-architecture.md` |
| Social — commitment sharing, activity, streaks | **Real** (Milestone S2) | Per-commitment Private/Friends choice (default Private), friends' Recent shelf (bounded, 30-day horizon, meaningful events only), and the two streak figures ("12 commitments kept · 6 since last Override"). Overrides are told only when the owner shares Override usage |
| Social — check-ins and the quiet surface | **Real** (Milestone S3) | Opt-in: friends see "Hasn't checked in · 4 days" (whole days, only past 72 hours, never a live status) and how many shared commitments were open at the last check-in. Facts only — motive is never claimed |
| Earned-user accountability partners | **Real** (migration 0019, applied to the hosted project 1 September 2026) | An accepted friend can be nominated by identity — no number, no email — and consents in-app; their approval requests arrive in-app through the same snapshot and vote transaction as the web page. Block revokes accountability both ways; unblock restores nothing |
| External accountability partners | **Switched off** | The server half is built and tested, but nothing drains `message_outbox` and the consent page has no function behind its route, so an invitation is composed and never delivered. Rather than let a user build a commitment on a partner who will never hear about it, the invite form says so and is disabled (`Partner.contactInvitationsDeliverable`). See `docs/beta-readiness.md` B‑8 |
| Shared Commitments — doing it together | **Real** (Milestone SC1; migrations 0021–0022, applied to the hosted project 1 September 2026) | "With friends" at creation invites accepted Earned friends; each accepts through their own Deal and gets their own ordinary commitment — own Gate, own rules, own hardening clock from their own acceptance. The roster shows everyone's self-reported line against the shared target; no ranking, no shared consequence. See `docs/shared-commitments.md` |

**One-sentence version:** the contract machinery is real, the identity is real, Earned
takes apps away when a Gate is closed, a partner's approval can genuinely unlock a phone,
and there is now a Social tab with real friends on it — the remaining holes are that the
extension which shields while the app is closed has never been watched doing it on a phone,
blocked apps show Apple's shield rather than ours, external partners cannot be reached at
all, and deleting the app still erases the local ledger.

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

### Onboarding — six screens, Continue / Back

Full design and reasoning: [`docs/onboarding.md`](onboarding.md).

| Screen | What it does |
|---|---|
| **DO WHAT MATTERS FIRST.** | The promise, in three lines. "How Earned works" optionally reveals the Gate paragraph; not required to advance. |
| **YOU CHOOSE WHAT GOES.** | Prepares the permission ask: only what you select, kept opaque to Earned, and calls/messages/maps/music never go. |
| **TURN ON BLOCKING.** | **Makes the real Screen Time request.** Three states — ask, granted, denied. Apple's dialog appears only after the explicit CTA. |
| **WHAT DO YOU LOSE?** | **Opens Apple's picker.** Three states — no permission (offers to fix it), nothing selected, a selection with its count. |
| **WATER CHECKS.** | A toggle and two default values; the dials are behind `Customize`. Off is a valid answer. |
| **THE DEAL.** | Correction window, harder-only edits, a missed deadline stays open, Overrides never depend on anyone else, and the permission stays revocable. Then a receipt of what is about to be switched on. |

Hydration defaults are a **60-minute** interval (15–240) and active hours
**08:00–22:00**, with a 10-minute warning lead.

> Source: `app/Earned/Onboarding/OnboardingView.swift` — `activate()`

**ACTIVATE EARNED** appends one `hydrationConfigured` event carrying the picked restriction
profile, writes that same profile as the default for new commitments, and flips the flag.

**What doesn't happen:** onboarding never requests HealthKit — nobody has mentioned a workout
yet — and never creates a first commitment. Today lands on a first-use state whose dominant
button is **MAKE YOUR FIRST DEAL**; nothing is created on the user's behalf. Four concepts
that used to be onboarding screens (the Gate vocabulary, Health provenance, the Override
ladder, Screen Time passcode advice) now arrive the first time each one means something.

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

In a release build, Apple Health. A finished workout imported by `HealthImporter` appends
`workoutRecorded`, and the engine re-checks every commitment in **deadline order**, so the
oldest debt clears first. That import is the *only* route a completed workout has into the
ledger, which is why Health authorization is now requested whenever a workout commitment is
created rather than only on the app-verified tier.

Debug builds keep a manual entry at You → Advanced → *Log a workout by hand* — activity,
duration, optional distance, how long ago it finished; stays open across entries so several
can be backfilled. It appends exactly the same event.

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

1. ~~**`DeviceActivityMonitor` extension.**~~ Built (`app/EarnedMonitor/`), and built without
   moving the ledger: rather than teach a second process to replay an event log, the app
   computes a `ShieldPlan` ahead of each deadline and leaves it in the App Group, and the
   extension's whole job on waking is to apply it. One file compiled into both targets, so
   the format cannot drift. `intervalDidEnd` is empty on purpose — the extension never lifts
   a shield, because only the app knows whether the commitment was met.

   **What it still needs is a phone.** DeviceActivity schedules do not run in the simulator
   and CI signs nothing, so nobody has yet watched a restricted app go dark at a deadline
   with Earned force-quit. The failure mode is quiet — the app shields on next launch and
   everything looks fine — so it will not be noticed by accident. `docs/beta-readiness.md`
   B‑2 is the nine-step test that would settle it.
2. ~~**`ShieldConfiguration` extension.**~~ Built (`app/EarnedShield/`). The `NICE TRY.`
   surface reserved in `docs/design-language.md` since the identity pass now exists on the
   one screen that earned the loud voice, because the user just reached for a restricted
   app: signal-red ground, `NICE TRY.`, each closed Gate with its own figures,
   `THE DEAL STILL STANDS.` as the closing line, and `CLOSE` on the single button.

   The extension decides nothing. It is handed an opaque token and a few milliseconds, so
   the app writes the lines into the App Group ahead of time (`ShieldCopy`) and this process
   reads them — the same division of labour as the monitor and the shield plan, for the same
   reason. Nothing it says counts down, because it can be read hours after it was written;
   progress figures are safe only because the sole route by which they change is a Health
   import inside the app.

   Three limits worth naming. Apple's layout is fixed and `ShieldConfiguration.Label` takes
   text and a colour but no font, so the poster face does not survive here — the brand
   carries on colour, capitals and the full stop. There is one button, not two, because a
   shield action extension cannot open its host app: a "ways out" button would be a promise
   the app cannot keep at the exact moment it matters most.

   And the brand line is the last line of the subtitle rather than the button label, which
   is where it started. Apple sizes that pill and twenty-two characters is long for it: a
   shield whose one button reads `THE DEAL STILL STAND…` is worse than a plain one, and it
   would break first on a narrow device or at an accessibility text size — the two cases
   least likely to be noticed before a tester meets them. The subtitle wraps, so the phrase
   is safe there at any width, and the button says `CLOSE`, which is what it does.

   **What it still needs is a phone.** Family Controls cannot be authorized in the simulator
   at all, so this has never been seen. Unlike B‑2 it does not wait on Apple's review queue:
   Family Controls (Development) is self-serve, so a development build shows it as soon as
   the capability is added to the new App ID.
3. ~~**HealthKit verification.**~~ Done. `Health/HealthImporter.swift` reads finished
   workouts (one type, read-only, only while something unresolved could be moved by them),
   keeps HealthKit's own workout UUID so re-imports are duplicates rather than
   double-counts, and records *who vouched* — iOS's user-entered flag and the writing
   app's identity decide whether a workout is the user's word or an app's. On top of it,
   NORTHSTAR §15's verification tiers: each commitment chooses whether your word counts
   or only vouched-for workouts do, frozen at hardening, tightenable after, never
   loosenable — the same lattice as every other term of the deal.

The accountability backend is no longer a future: partners can be nominated and consent,
requests go out with frozen snapshots, votes resolve concurrently-safely, and a signed
grant comes back, verifies on the phone against the compiled-in root key, and unlocks the
commitment it names. What that rung still needs is the end-to-end device pass — a real
partner, a real link, a real unlock — recorded here once it happens.

### Social (Milestone S1)

A fourth tab sits between History and Settings. Today remains the default and the center
of gravity — Social is deliberately not the launch tab.

Signed out (or with no backend configured), the tab says what it is for and, where
possible, offers the same Sign in with Apple button as Settings. Signed in without a
profile, it offers the four-step setup — name (prefilled from Apple's one-time offer),
handle, optional photo, optional city — ending on `WELCOME TO EARNED.` Nothing about
Gates, commitments, or the Solo Override waits on any of this (S8).

With a profile, the screen is a printed roster, not a feed: **MY PROFILE** (avatar or
initials, name, @handle, and the two figures — `12 COMMITMENTS KEPT` over
`6 since last Override`, or `No Overrides yet` — with a footer saying who else sees
them), **REQUESTS** (incoming with accept/decline, outgoing with cancel — only when
there are any), **FRIENDS** (or an honest empty state pointing at ADD FRIEND), and
**RECENT** — friends' shared events, bounded to 50 and 30 days, or one line saying
nothing has happened. Adding a friend is handle search; a friend's profile screen shows
avatar, name, handle, city if they set one, their streak figures if they share them, and
REMOVE FRIEND / BLOCK at the bottom. Blocking is mutual invisibility from that moment on.

### Sharing a commitment (Milestone S2)

Every commitment is born private. A one-off commitment offers "Share with friends" on
the override-rules step (only when a profile exists), and any commitment — plan
occurrences included — has the same toggle on its detail screen, changeable any time in
either direction: visibility is a privacy choice, not a contract term, so hardening
never freezes it. Friends learn the title, the deadline, and how it ended — kept, kept
late, or (only if Override sharing is on) overridden; with it off, an overridden
commitment just quietly ends in their view. Unsharing withdraws the commitment and every
event it generated. The app republishes on every foreground; the server emits at most
one event per real transition, so nothing is minted per app-open, and hydration never
appears at all.

### A friend becomes a partner (or doesn't)

Settings → Partners → **Add accountability partner** now offers two roads. PEOPLE YOU
KNOW ON EARNED lists accepted friends with their state — Ask / REQUEST SENT /
PARTNER ✓ — and asking shows the deal plainly: *"Maya will be able to approve
Accountability Overrides when you ask. Being friends does not give her this authority
automatically."* SOMEONE ELSE is the untouched external flow: name, text or email, one
server-sent link, no account or app needed on their end. A friend's profile screen
carries the same ACCOUNTABILITY block, and never labels a friend a partner before they
explicitly accept.

The ask lands on the friend's Social tab (and their Partners screen): *"Patrick wants
you as an accountability partner"* — I'M IN / NO THANKS. Once active, their override
requests arrive the same way: an APPROVALS section rendering the identical frozen
snapshot the web page shows, casting the identical vote, with their signed-in session as
the credential instead of a link. Blocking a friend revokes any accountability between
the two accounts in both directions on the spot; unblocking brings none of it back.

> Source: `app/Earned/Backend/PartnersView.swift` (`AddPartnerPickerView`),
> `app/Earned/Social/SocialView.swift`, `backend/migrations/0019_earned_partners.sql`

### Doing it together (Milestone SC1)

The creation flow gains one question — WHO'S DOING THIS WITH YOU? (JUST ME / WITH
FRIENDS) — offered only for one-off commitments when a profile and at least one accepted
friend exist; it never blocks the ordinary path. Choosing friends sends invitations: the
creator's own commitment is already made either way, and nothing exists on anyone else's
phone. The ask lands on each friend's Social tab — *"Maya invited you to a commitment ·
Your own Gate will apply if you accept"* — with READ THE DEAL and NO THANKS. Accepting
opens the invitee's own Deal: the shared terms (title, requirement, deadline) printed
frozen, and every enforcement term theirs to set — verification, escape rules, correction
window — hardening from *their* acceptance, not the inviter's clock. COMMIT records the
acceptance server-side first, then creates a completely ordinary local commitment
(`eligibleFrom` = max(shared window start, acceptance)).

The Social tab's TOGETHER block lists shared commitments; the detail screen is a printed
roster in join order — each person's own line against the shared target, DONE ✓ / DONE
LATE where earned, verification tiers stated only when they differ, an Override shown
only as its owner shares Overrides. Nobody's line moves anybody else's Gate. Leaving is a
social act (the commitment stays, with its usual ways out); the creator can close the
unstarted future, which expires unanswered invitations and takes nothing from anyone
bound. Blocking withdraws pending asks between the pair and severs their mutual roster
visibility — obligations stand untouched.

The follow-up pass (migration 0022, ledger schema v6) made "Run 3× this week" literal:
**A number of times** is a first-class completion choice — each qualifying workout counts
once, accumulating like any metric, harder-only after hardening. Roster moments (joined,
finished, finished late, the window opening, everyone made it) now appear on friends'
Recent shelves; a creator deleting their account orphans the agreement rather than
dissolving it; and the actionable asks — a shared invitation, a partner request, an
approval request — are queued for push under the revised rule (no social-engagement
push, commitment-relevant push allowed), with APNs delivery itself a deployment step.

> Source: `app/Earned/Social/SharedCommitmentViews.swift`, `SharedCommitmentModels.swift`,
> `SharedCommitmentRegistry.swift`, `app/Earned/Commitment/NewCommitmentView.swift`,
> `backend/migrations/0021_shared_commitments.sql`,
> `backend/migrations/0022_shared_commitment_followups.sql`,
> `packages/EarnedKit/Sources/EarnedKit/Activity.swift`, `docs/shared-commitments.md`

### Going quiet (Milestone S3)

With "Share check-ins with friends" on (off by default, like every switch), the app tells
the server it was heard from on each foreground pass. Friends see nothing until three
whole days of silence, then a factual line on the roster — `Hasn't checked in · 4 days` —
and, on the profile, `HASN'T CHECKED IN / Last seen by Earned 4 days ago`, plus how many
shared commitments were still open at that last check-in. No live presence, no raw
timestamp, and no guessed motive — a deleted app, a dead battery and a good week offline
all read identically, because to Earned they are identical. Turning the switch off
deletes the stored fact; turning it back on starts from now.

> Source: `app/Earned/Social/` (`SocialStore.swift`, `SharingRegistry.swift`),
> `backend/migrations/0013–0018`, `docs/social-architecture.md`
