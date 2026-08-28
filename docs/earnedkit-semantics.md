# EarnedKit semantics — decisions beyond the north star

Implementing the gate engine forced precise answers to questions NORTHSTAR.md
leaves open. Each is cheap to change now and encoded in tests; overrule freely.

## Hydration

- **Easier config changes require a satisfied gate.** Interval, active hours,
  and enabled/disabled can be tightened anytime, but loosened only while the
  gate is currently satisfied — a locked user cannot unlock by editing the
  hydration contract. (Analogue of §12 for the one gate that never hardens.)
- **Acknowledgment is accepted at any time**, including outside active hours;
  it simply anchors the rolling timer.
- **An expired gate goes dormant at window close.** If you end the day locked
  on hydration, the lock lifts when active hours end and the next day starts
  fresh. Hydration is an in-the-moment interrupt, not a debt (§17); only
  exercise carries debt across days.

## Commitments

- **Hardening fraction = 1/8.** Effective correction window =
  min(configured, time-to-deadline / 8). The §11 example (2h away → ~15 min)
  falls out exactly.
- **Reward eligibility is fixed at creation** (cannot be edited after
  hardening in either direction — it is neither harder nor easier, so it may
  not change).
- **Requirement dimension changes (duration ↔ distance) are incomparable**
  and rejected after hardening; upgrading `anyWorkout` to a quantified
  requirement is harder and allowed.
- **A workout can satisfy multiple commitments simultaneously.** This is what
  makes the §16 debt example work (one Monday workout clears Saturday's debt
  and Monday's requirement). Consequence: two overlapping 30-minute
  commitments are both satisfied by one 30-minute run. If that ever feels
  like a loophole, the fix is a per-commitment "exclusive credit" flag —
  deliberately not built yet.
- **Eligibility = workout started at or after commitment creation.** No upper
  bound: obligations persist past the deadline until resolved, and a workout
  synced late by HealthKit counts based on when it happened, not when it
  arrived.
- **Late completion still resolves the commitment** (access is restored) but
  counts as a miss for streak purposes — only on-time completions build the
  Free Override streak.

## Restricted apps

- Modeled as one global set of opaque tokens. Additions are allowed anytime;
  **removals require Full Access and no hardened unresolved commitment**.

## Overrides

- **Overrides target commitments only.** The Hydration Gate has no override
  path — drinking water is always cheaper than any escape route.
- **An overridden commitment breaks the completion streak** (it was not
  completed), including a Free Override spend. Spending is still guilt-free —
  it just doesn't count as a completion.
- **Earning at the stored cap (2) is forfeited**, not banked.
- **Streak threshold defaults to 5** consecutive on-time completions per Free
  Override — configurable (`RewardPolicy`), per §22's "determine later".
- **"Recent" for solo escalation = rolling 30 days** (configurable per
  policy), measured at the moment the solo override starts.
- **Late partner approvals still count**: an approval arriving after the
  accountability window (but before the request is otherwise resolved) grants
  the override. The window gates when solo becomes *available*, not when
  partners stop mattering.
- **A completed workout moots any open override request** for that
  commitment; late votes against a moot request are rejected.

## Ledger

- Events are strictly non-decreasing in time; an out-of-order append is
  rejected. Late-arriving external facts (workouts) are appended at arrival
  time and carry their own occurrence times.
- Duplicate workout deliveries (same id) are silent no-ops — HealthKit
  re-syncs must be harmless.
- Persistence stores only the event history; state is rebuilt and
  re-validated by replay on load. Tampered or corrupted history fails loudly.
