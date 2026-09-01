# Onboarding

How Earned introduces itself, and — more of the design than it sounds — what it
deliberately does not say yet.

## The two phases

| | |
|---|---|
| **Phase 1 — make Earned functional** | Six screens. Understand the promise, understand restriction, authorize Screen Time, choose what gets blocked, optionally set up water checks, accept the contract. |
| **Phase 2 — learn Earned by using it** | The word "Gate", Health verification, hardening, debt, the Override ladder, anti-circumvention advice. Each arrives the first time it means something. |

Phase 1 is a guided sequence, not a checklist, because Screen Time → app
selection → activation is a real dependency order. A freeform checklist invites
picking apps before there is permission to block them, configuring a Gate before
restrictions exist, and never knowing what "done" means. Phase 2 has no order at
all, because it is driven by whatever the user happens to do next.

## What must be understood before activation

Earned deliberately removes access, so uninformed consent here is a product
failure rather than a UX one. These seven facts are consent-critical and stay in
the flow:

1. Earned can block apps the user explicitly chooses.
2. It does this using Apple Screen Time.
3. Calls, messages, maps and music remain available.
4. The restriction lasts until the obligation is satisfied or an Override is used.
5. A commitment becomes harder to escape after a correction window.
6. Missing the deadline does not erase the obligation.
7. Screen Time permission is voluntary and revocable in iOS Settings.

**Informed consent is not the whole product model.** Everything else has to
justify a screen, and most of it cannot: it is vocabulary, and vocabulary
learned against nothing is vocabulary forgotten.

## The six screens

| | Screen | Does |
|---|---|---|
| 1 | `DO WHAT MATTERS FIRST.` | The promise. "How Earned works" optionally reveals the Gate paragraph — not required to advance. |
| 2 | `YOU CHOOSE WHAT GOES.` | Prepares the permission ask. Selections are opaque to Earned. |
| 3 | `TURN ON BLOCKING.` | The real authorization request. Apple's dialog appears only after the explicit CTA. |
| 4 | `WHAT DO YOU LOSE?` | Apple's `FamilyActivityPicker`. |
| 5 | `WATER CHECKS.` | A toggle and two defaults; dials behind `Customize`. |
| 6 | `THE DEAL.` | The four contract statements, then a receipt of what is about to be switched on. |

Screen 3 sits immediately after screen 2 because a permission asked before its
reason is a permission refused. Screen 4 sits after screen 3 because a picker
with no permission behind it is a dead control.

**Activation** writes the picked profile as the Hydration Gate's own
restrictions *and* as the default for new commitments. One decision, made once,
carefully — asking again two screens later reads as the app not having listened.

## Screen states

Every screen renders the real state rather than an assumed one.

- **Screen 3** has three: not determined (the ask), approved (confirmation),
  denied (iOS will not re-ask, so the only honest next step is Settings).
- **Screen 4** has three: no permission (offers to fix that, never a dead
  picker), nothing selected (says so — an empty selection is not a configured
  app), and a selection (a count, and a way to change it).

**Back never fakes a rollback of an OS permission.** It moves between screens;
each screen re-reads the actual authorization state when it draws.

## Skipping

Both permissions are genuinely optional and every skip says what it costs.
While a screen is still asking, the navigation button yields to a quiet
underlined `Not now` / `Continue without blocking` — so the one filled button on
screen is always the grant, never the way past it. Skipping does not nag inside
onboarding, does not hide the consequence, and does not secretly enable a weaker
equivalent.

## The first Today

Setup hands off to Today rather than to a success screen. No celebration UI.

- If setup completed: `Earned is set up.` / `Make one deal and see how it
  works.` with **MAKE YOUR FIRST DEAL** as the filled button and the water
  acknowledgement quiet beneath it.
- If setup did not complete, that first line is **not shown** — claiming Earned
  is set up directly beneath a notice saying it cannot block anything is the app
  contradicting itself on one screen.

No commitment is created automatically, and nothing forces the user to make one
before looking around.

## Recovery

A skipped step surfaces on Today as `FINISH SETUP`, and opens a sheet holding
the two steps in dependency order — Restrictions stays disabled until Screen
Time is on, so the picker is never dead. This is the checklist arriving *after*
the ordering problem it would have caused, which is the only place it is safe.

Nobody is ever marched back through screens they already completed.

## Just-in-time lessons

Each fires once and is remembered (`Teachings`, `UserDefaults` — a read tooltip
is not a deal, so it does not belong in the ledger). A reinstall re-teaches,
which is the right failure direction.

| Lesson | Trigger | Says |
|---|---|---|
| `THIS IS A GATE.` | First open Gate on Today | An unfinished obligation keeps its restrictions in force; several combine. |
| `OVERDUE.` | First missed deadline | The deadline passed, the deal didn't. Late still counts, as late. |
| `WAYS OUT` | First time the override surface is opened | Free / Ask someone / Solo, and that only the available ones are shown. |
| `WANT A STRONGER DEAL?` | After enforcement has worked at least once | Screen Time passcode advice — Earned never sees it, and cannot stop a revocation. |

**Health is not in this table** because it is not a card: choosing "an app has
to vouch" during commitment creation opens an explanation with
`ALLOW HEALTH ACCESS` and `Use my word instead`, and Apple's sheet appears only
after the first. Declining changes the commitment rather than closing a dialog.

`Teachings.forgetEverything()` re-arms all four, under You → Advanced in DEBUG
builds only.

## What onboarding must never do

- Request HealthKit. Nobody has said anything about a workout yet.
- Show `STEP 3 OF 10`. The progress rule says setup is finite without counting
  out loud.
- Claim a state the app is not in.
- Celebrate.

## Known open question

Onboarding asks for Health at commitment creation for **both** verification
tiers, not only the app-verified one. That is deliberate and is the fix for
beta-readiness R‑1: manual workout logging is `#if DEBUG`, so in a release build
Apple Health is the only route by which any workout reaches the ledger, and a
self-reported commitment created on a phone that was never asked can never be
completed. The explanation sheet is shown only on the app-verified path, where
the permission has an obvious job. See the final report's ambiguity note.
