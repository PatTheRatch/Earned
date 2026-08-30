# EarnedKit semantics — decisions beyond the north star

Implementing the gate engine forced precise answers to questions NORTHSTAR.md
leaves open. Each is cheap to change and encoded in tests; overrule freely.

Decisions marked **[open]** are ones I made to keep moving and would like
reviewed — they are not settled product intent.

## Gates and restrictions

- **A Gate is: hydration (singleton), or one per commitment.** Restrictions live
  on the Gate, and effective restrictions are the union across unsatisfied ones.
- **[open] Per-commitment profiles rather than one shared "Exercise Gate"
  profile.** This is strictly more general — giving every exercise commitment the
  same profile reproduces the simpler model exactly — but it means the creation
  flow has a per-commitment choice to make. If that turns out to be friction
  rather than power, the fix is to make the default authoritative and hide the
  per-commitment control.
- **Loosening any Gate's profile requires Full Access and no hardened unresolved
  commitment.** Tightening is always allowed. Same rule as the old global set.
- **The default profile for new commitments is not a Gate** and can be edited
  freely: changing it restricts nothing that is currently in force.

## Hydration

- **The active window opens unsatisfied.** No free morning interval; the day
  starts owing water. Only an acknowledgment inside the current window counts.
- **An expired gate goes dormant at window close.** End the day locked on
  hydration and the lock lifts when active hours end; the next day starts fresh
  (and closed). Hydration is an in-the-moment interrupt, not a debt — only
  exercise carries debt across days.
- **Easier config changes require a satisfied gate**, including loosening the
  hydration profile. A locked user cannot unlock by editing the contract.
- **Acknowledgment is accepted at any time**, including outside active hours; it
  simply anchors the rolling timer.

## Eligibility

- **`eligibleFrom` defaults to creation time for a one-off.** You cannot commit
  to a workout you have already done.
- **A plan occurrence's window opens at midnight of its own calendar day**,
  clamped never to precede the plan's creation. The clamp is mine, and preserves
  the "already done" rule for a plan made mid-day.
- **No upper bound.** A late workout still clears an overdue commitment; this is
  what makes debt work at all.
- **A workout can satisfy multiple commitments simultaneously** where their
  windows genuinely overlap — that is what clears yesterday's debt and today's
  requirement together. `eligibleFrom` is what stops it reaching forward.
- **Resolution runs in deadline order**, so the oldest debt is cleared first.

## Activity and completion

- **Activity filter and completion metric are separate dimensions.** A running
  commitment cannot be satisfied by cycling.
- **Monotonicity:** narrowing the activity filter is harder, widening is easier,
  and swapping one specific type for another is *incomparable* — rejected after
  hardening, because it is neither harder nor easier.
- **Cross-metric changes (duration ↔ distance) are likewise incomparable.**
- **[open] `ActivityType` is a small closed set** (`running`, `walking`,
  `cycling`, `strength`, `swimming`, `other`) rather than mirroring HealthKit's
  full enumeration. The adapter maps `HKWorkoutActivityType` onto it. If the
  first user wants finer distinctions, the set grows.

## Commitments

- **Hardening fraction = 1/8.** Effective correction window =
  min(configured, time-to-deadline / 8).
- **Reward eligibility is fixed at creation** — neither harder nor easier, so it
  may not change after hardening.
- **A later `eligibleFrom` is harder**; widening the window after hardening is
  refused.
- **Late completion resolves the commitment** (access is restored) but counts as
  a miss for streak purposes.

## Plans

- **A plan is a template, not a source of truth.** It expands once, at creation,
  into ordinary `commitmentCreated` events. Nothing re-derives a schedule at read
  time, so replay stays deterministic.
- **Occurrences whose deadline has already passed at creation are skipped** — a
  commitment cannot be born overdue.
- **A plan hardens as a whole, shortly after it is made — not one occurrence at
  a time as each day arrives.** Every occurrence's correction window runs from
  *plan creation*, not from its own day. This was flagged as an open question
  (should week three hardening wait until the Monday of week three?) and the
  answer is no: making a plan is one act of commitment to the whole thing,
  not twelve small ones you can quietly soften as you go. A plan is not
  meant to be softer than the same commitments entered by hand — if you
  weren't ready to follow through on the whole plan, you shouldn't have made
  it. The creation flow warns about this explicitly before the user commits
  (`NewCommitmentView` — the weekly-repeat step and the review screen's
  "Fully hardens" line, computed from the plan's own occurrences so it can't
  drift from what gets created).
- **Cancelling a plan withdraws an unresolved occurrence when it is either
  still inside its correction window *or* its eligible window has not opened
  yet.** The second clause is load-bearing given the rule above: with every
  occurrence hardening within hours of plan creation, cancellation would
  otherwise withdraw nothing at all. An occurrence whose day has not arrived
  is not yet a live obligation — there has been no moment at which it could
  have been honoured — so withdrawing it takes nothing away. Occurrences
  already in their window survive, hardened or not: once a day is live, its
  contract stands like any other.
- **[open] Editing a plan is not supported** — only cancel and recreate. Editing
  raises questions (does it touch hardened occurrences? already-completed ones?)
  that deserve a deliberate answer rather than an invented one.

## Warnings

- **A warning is information, never a reprieve.** Notifications carry no
  actions, no snooze and nothing to tap for more time (NORTHSTAR §7, §20). Gate
  state is computed from the ledger and is identical whether a warning was
  delivered, ignored, or never authorised — a test asserts exactly this.
- **Warnings are scheduled, not stored.** EarnedKit's `upcomingWarnings(now:)`
  derives them from configured leads; nothing about a warning enters the ledger.
  Delivery is an app concern, so the engine stays portable and testable.
- **Hydration warns only while the Gate is satisfied**, since a closed Gate has
  nothing pending to warn about. It is re-derived on every acknowledgment, which
  is what makes a rolling timer's warning follow the timer.
- **An overdue commitment is not warned about** — its Gate has already closed.
- **[open] Nothing is announced at the moment a Gate actually closes.** Only the
  warning before it is. Once real enforcement lands, the shield is arguably the
  announcement; until then a Gate can close with the phone in a pocket and the
  user finds out on next unlock. Whether a closing Gate deserves its own
  notification is a real product question — it is not a warning, so §20 does not
  answer it, and I have not invented an answer.
- **Permission is asked for at the first moment a warning is actually due**, not
  at launch: a prompt with nothing behind it is one the user cannot evaluate.
  Where permission is refused, the app says so at both places it made the
  promise (the creation flow's toggle and Settings) rather than letting a
  configured warning quietly never arrive.

## Overrides

- **Overrides target commitments only.** The Hydration Gate has no override path;
  drinking water is always cheaper than any escape route.
- **Solo Override requires effort *and* elapsed time.** `FrictionRequirement`
  carries `effortUnits` and `minimumElapsed`; neither alone completes it.
- **The requirement is frozen when the challenge starts**, so a mid-challenge
  edit cannot make an in-flight escape cheaper.
- **[open] The effort unit is abstract.** Defaults assume a unit costs roughly
  ten seconds of deliberate action (60/180/360 units against 10/30/60-minute
  floors). The on-screen mechanic in the app is a deliberately plain test
  implementation — *the real friction UX is an open product-design surface.*
- **"Recent" for solo escalation = rolling 30 days**, measured when the solo
  challenge starts.
- **Late partner approvals still count**: the accountability window gates when
  *solo* becomes available, not when partners stop mattering.
- **A completed workout moots any open override request.**

## Rewards

- **A Free Override is an immutable ledger event.** Earned once, at the moment a
  streak completes; never recomputed. Balance = unspent grants.
- **The streak counts on-time completions since the last earned grant**, with any
  miss in that span resetting it.
- **Earning at the cap is forfeited, not banked.**
- **An overridden commitment breaks the streak** (it was not completed),
  including one cleared by a Free Override. Spending is still guilt-free; it just
  isn't a completion.
- **Easing the reward policy requires Full Access and no hardened unresolved
  commitment.** Stricter — a longer streak, a smaller cap — is allowed anytime.
- **Changing the policy is never retroactive** in either direction.

## Ledger

- Events are strictly non-decreasing in time; out-of-order appends are rejected.
- Duplicate workout deliveries (same id) are silent no-ops.
- **Engine-derived events are appended at write time, never re-derived on
  replay.** That is what makes an earned reward immutable.
- Persistence stores a **versioned document** (`{version, entries}`); a bare
  array reads as v1.

### v1 → v2 migration

Nothing is silently reinterpreted:

- Shape changes ride on tolerant decoding — a v1 `Requirement` becomes the same
  metric with an unrestricted activity filter; a v1 commitment gets
  `eligibleFrom = createdAt`; a v1 workout's free-form activity string maps onto
  `ActivityType` (unknown → `other`).
- **v1's global `restrictedAppsChanged` events still replay**, applying to the
  default profile for new commitments. They are not retro-fitted onto
  commitments created before Gates owned restrictions: those Gates genuinely had
  no profile, and inventing one would be a rewrite.
- **Historical free-override spends are funded** by an inserted
  `freeOverrideEarned(source: .migration)` — visible, attributed, never mistaken
  for a streak reward.
- **Historical solo completions are funded** by an inserted progress event: the
  v1 wait did satisfy v2's elapsed floor, so migration supplies only the effort
  the old flow never asked for.
- **A v1 escalation's wait durations decode as wait-only requirements** —
  `effortUnits: 0` with the same elapsed floors. That is the contract the user
  actually agreed to when the commitment was made; adding effort to a hardened
  commitment's escape route would be a silent rewrite in the harder direction,
  which migration is no more entitled to than the easier one. Commitments
  created under v2 carry full effort + floor steps.
- **Golden fixtures guard the on-disk formats.** Raw v1 and v2 JSON is checked
  in as literals (`GoldenLedgerTests`) and must decode, migrate and replay
  forever. They are never regenerated from current types — a regenerated
  fixture guards nothing. A failing golden test means the build broke its
  ability to read a user's existing history: fix the decoder, or bump the
  schema version and write a migration.
- A document from a *newer* schema is refused rather than half-read.

## Clocks

- **An event is recorded no earlier than the ledger's newest entry.** Real
  clocks go backwards — NTP corrections, manual changes — and the chronology
  invariant would otherwise turn a legitimate tap into a baffling rejection.
  The app clamps each event's timestamp to `max(wall clock, ledger frontier)`.
- **This is not tamper resistance.** Gate state is computed against the wall
  clock, so setting the phone's clock back could reopen a closed window.
  Defending against deliberate clock manipulation is an enforcement-layer
  problem (the shield lives outside the app's own clock) and is deliberately
  not attempted here.
