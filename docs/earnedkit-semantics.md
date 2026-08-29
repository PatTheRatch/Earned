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
- **Cancelling a plan withdraws only unhardened, unresolved occurrences.** A
  hardened occurrence is a contract in its own right.
- **[open] Editing a plan is not supported** — only cancel and recreate. Editing
  raises questions (does it touch hardened occurrences? already-completed ones?)
  that deserve a deliberate answer rather than an invented one.

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
- A document from a *newer* schema is refused rather than half-read.
