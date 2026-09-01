# Shared Commitments — Design

v0.2 · September 2026 · Milestone SC1 (create → invite → accept/decline → own Deal → own
Gate → shared progress → Social surfacing → block/friendship rules → backend + RLS +
tests), plus the four follow-up decisions Patrick settled the same week: a session-count
metric in EarnedKit (§2), creator deletion orphaning rather than dissolving (§9), roster
moments on the Recent shelf (§13), and the revised push rule (§11; migration 0021). The
durable product principle lives in NORTHSTAR §46 and invariants 30–32. This document is
the working design: every state, rule, edge case, and the storage model. Where this
document and the code disagree, one of them is a bug — fix whichever is wrong.

---

## 1. What this is

Three people agree to run three times this week. Each of them still has their own phone,
their own restricted apps, their own verification standards, their own escape rules, and
their own failure. What they gain from each other is exactly one thing: **each can see
whether the others did it.**

> RUN 3× THIS WEEK
>
> Patrick  2 / 3
> Maya     3 / 3 ✓
> Dave     1 / 3

Maya finishing does not unlock Patrick. Patrick failing does not lock Maya. That visible
difference — not a shared consequence, not a team score — is the social pressure. This is
level three of the social layer (witnessing → encouragement → doing it together), and it
obeys every anti-goal the social layer already has (social-architecture §1): no XP, no
leaderboards, no ranking, no places, no pets, no fictional economy, no collectibles, no
engagement quests. Earned stays closer to: *go do the thing; your people can see whether
you did.*

### The mental model

A shared commitment is **not one giant Gate**. It is an **agreement — a template** — that
produces one ordinary personal commitment per accepting participant:

| Layer | Lives where | Owned by |
|---|---|---|
| The shared agreement (title, requirement, window, roster) | Server | The group; frozen once anyone is bound (§6) |
| Each participant's personal commitment | That participant's own ledger | That participant alone |

The personal commitment created by acceptance is a first-class EarnedKit commitment in
every respect: it hardens, gates, accumulates progress, carries debt, and resolves exactly
like a commitment the user created alone. The Gate engine does not know the commitment is
shared — sharedness is social metadata *about* a commitment, never an input to Gate truth
(invariant 25 applies unchanged).

---

## 2. Shared terms vs personal terms

Settled division. **Shared terms** are identical for every participant and frozen by
acceptance (§6):

- title;
- activity filter + completion metric (the requirement, in EarnedKit's two-dimension
  sense — "run", "3 sessions", never fused);
- count/duration/distance target;
- the shared eligible window and deadline (calendar bounds — see §5 for how they meet
  per-participant `eligibleFrom`).

**Personal terms** are each participant's own, chosen at acceptance from their own local
defaults, never visible to and never settable by the inviter:

- FamilyControls restriction profile;
- verification tier;
- Override rules (approval threshold, accountability roster, solo escalation);
- Free Override eligibility;
- warning/notification preferences;
- sharing preferences beyond the roster (§7);
- and, consequently: their progress, their completion state, their debt.

**Personal tightening is allowed.** A participant may hold themselves to a *stricter*
requirement than the shared one (stronger verification, an earlier personal deadline, a
larger personal target) — that is ordinary monotonic strengthening of their own contract
and affects nobody else. The roster view still reports progress **against the shared
target**, so a self-imposed 5× shows as `3 / 3 ✓` to the group when the shared target is 3.
Nobody may *weaken* the shared behavior itself, silently or otherwise: the shared terms are
not theirs alone to change (§6).

The inviter cannot dictate another user's punishment settings. The inviter shares the
promise; each participant chooses how Earned enforces it on their own device
(NORTHSTAR invariant 32).

---

## 3. Who can be invited

**Accepted Earned friends only, v1.** Shared commitments require authenticated Earned
accounts on both sides:

- The invitee list is drawn from the creator's accepted friendships — never from contacts,
  handles of strangers, or external SMS/email accountability contacts. External partners
  (accountability-architecture §14) have no account, no app, and no Gate; there is nothing
  on their side to accept *with*, and the no-account web flow is an approval surface, not
  an enforcement surface. They stay out of Shared Commitments in v1 entirely.
- Blocking already prevents friendship, so a blocked pair can never appear in the picker;
  §9 covers blocks that land mid-flight.

Three relationship concepts now exist, and none is ever inferred from another (extends
invariant 24):

| | Friend | Shared participant | Accountability partner |
|---|---|---|---|
| What it grants | Visibility the owner chooses | Mutual visibility of one shared commitment's progress | Authority to approve an Override |
| Created by | Mutual request/accept | Explicit acceptance of one invitation | Explicit nomination + consent |
| Implies either other | never | never | never |

A shared participant **cannot approve an Override** merely because they are doing the same
challenge. If Patrick wants Maya as an accountability partner too, that is a separate
nomination through the existing flow (migration 0019), with its own consent.

---

## 4. Lifecycle

### 4.1 Creation

Creating a commitment stays exactly as it is for the solo case; sharing is an additional,
optional question — never forced:

> WHAT WILL YOU DO?
> Run 3× this week
>
> WHO'S DOING THIS WITH YOU?
> JUST ME · WITH FRIENDS

Choosing WITH FRIENDS lists accepted friends; the creator selects one or more, is told
each must accept, and is told each accepting friend gets their own Gate with their own
rules. Creation then does two things at once:

1. creates the **creator's own personal commitment** through the normal path — their Deal,
   their correction window, their hardening clock, starting now;
2. registers the shared agreement server-side and sends the invitations.

The creator is a participant like any other from the start; their acceptance is implicit
in creating (they authored the terms and bound themselves through their own Deal screen).

Hydration is excluded — a shared commitment is built from the exercise-commitment shape
only, matching hydration's exclusion from the entire social layer (invariant 26,
social-architecture §7.3).

### 4.2 Invitation states

An invitation is a question, not an obligation. Server-held states per invited
participant:

| State | Meaning | Reached by |
|---|---|---|
| `invited` | Asked, unanswered | creation, or a later re-invite |
| `accepted` | Bound; personal commitment exists | the invitee's explicit in-app acceptance, only ever their own session |
| `declined` | Said no | the invitee |
| `withdrawn` | The creator took the invitation back before acceptance | the creator |
| `expired` | The question outlived its relevance | the shared window closing (or the whole agreement being cancelled) with the invitation still unanswered |

Rules the states must honor:

- **No Gate exists on the invitee's device before acceptance.** An invitation renders as
  a card, not a commitment; it restricts nothing, warns about nothing, and owes nothing.
- **The inviter cannot accept on anyone's behalf**, and the server refuses acceptance
  from any session but the invitee's own (RLS + SECURITY DEFINER, §10).
- **Consent is never inferred** from friendship or from an accountability partnership.
- **Idempotent invitations.** Inviting the same friend twice while an invitation stands
  is the same row, silently; after a decline, a re-invite is allowed (rate limits are the
  abuse defence, as with friend requests) and reuses the row back to `invited`.
- **Declining is quiet** in the same way friendship declines are quiet: the group sees
  the person is not on the roster; no red "DECLINED" badge chases them.
- An unanswered invitation whose shared window has already closed is dead: it renders
  nowhere and accepts nothing.

### 4.3 What acceptance does

Acceptance is one atomic in-app act by the invitee, and it does four things, in order:

1. **Binds them to the shared terms as they stand** — the accepted terms' version is
   recorded on their participant row (§6), so what they agreed to is a permanent record,
   never a reconstruction.
2. **Shows them their own Deal first.** Before anything is created, the invitee sees the
   full personal contract Earned is about to make — shared terms plus *their own* local
   defaults for restrictions, verification, and Override rules, all editable within the
   normal creation rules — and binds only by committing that Deal. Accepting the idea and
   accepting the contract are one screen, but nothing is created until the commit.
3. **Creates their personal commitment** through the completely ordinary local creation
   path: `eligibleFrom` per §5, their correction window, their hardening clock starting at
   *their* acceptance.
4. **Reports the link** — the server records which personal commitment id belongs to this
   participant, so progress lines (§7) can be attributed. The id is an opaque link for the
   owner's own client; it grants nobody else anything.

If the backend is unreachable mid-acceptance, nothing half-happens: acceptance is a
server-side transition, and the personal commitment is created only once the server has
recorded the acceptance. A retried acceptance (double-tap, network retry, crash-and-retry)
is idempotent — the same participant accepting twice is one acceptance, one personal
commitment.

### 4.4 Declining, withdrawing, leaving

- **Before acceptance**: the invitee may decline; the creator may withdraw an invitation
  or cancel the whole thing (§6). Nothing existed on the invitee's side, so nothing is
  erased.
- **After acceptance**: the participant owns a real commitment, and the ordinary rules of
  that commitment apply in full. Leaving the *group* is a social act: it removes them
  from the roster and stops the mutual visibility, but **it does not touch their personal
  commitment**. If that commitment is still inside its correction window, they may cancel
  it there like any unhardened commitment; if it has hardened, the ways out are exactly
  Earned's ways out — complete it, or Override. **There is no social escape hatch cheaper
  than an Override** (invariant 32). Removing someone from the group — by leaving,
  unfriending, or blocking — never erases a hardened personal commitment.

---

## 5. Hardening and the eligible window

Each participant's personal commitment hardens **independently, from their own
acceptance**, under the ordinary rule (min(configured window, time-to-deadline ÷ 8)).
Nobody inherits a correction window that started before they were bound:

> Patrick creates Monday 09:00. His correction window runs from 09:00.
>
> Maya accepts Monday 11:00. Her correction window runs from 11:00.
>
> The shared behavioral target — run 3× by Sunday — is identical for both.

The shared window and the personal `eligibleFrom` compose the same way a plan occurrence's
day does (earnedkit-semantics § Eligibility): a participant's `eligibleFrom` is
**max(shared window start, their own acceptance time)**. You cannot commit to a run you
have already done, and you also cannot count a run from before the group's week began. The
shared deadline is everyone's deadline; accepting close to it simply produces a short-fuse
personal commitment, hardening fast under the existing cap, with the app showing exactly
what is being signed up for. As everywhere, there is no upper eligibility bound: a late
workout still clears the participant's own debt — and shows to the group as completed
late (§7).

An invitation accepted *after* the shared deadline is refused as expired: a commitment
cannot be born overdue.

---

## 6. Editing the shared terms

Before anyone else is bound, the agreement is the creator's to shape; the moment another
person accepts, it is nobody's to reshape.

- **Before any acceptance**: the creator edits or cancels freely. Their *own* personal
  commitment still follows their own hardening clock — the usual correction-window rules
  govern what they can change about their own contract; terms edits propagate to the
  outstanding (unaccepted) invitations, which always present the current terms.
- **After any other participant accepts**: the shared terms **freeze**. There is no
  in-place mutation of a promise other people are bound to — no hidden mutable group
  contract. A material change means one of two honest acts:
  - **cancel the unstarted future** — the agreement is closed to further acceptance and
    outstanding invitations expire; everyone already bound keeps exactly the commitment
    they accepted; or
  - **a new agreement** — create a fresh shared commitment with the new terms and invite
    afresh; everyone re-accepts or doesn't. (v1 ships this as "cancel + create new";
    an in-product "revise" affordance that performs those two steps together may come
    later. There is deliberately no versioned re-acceptance flow in v1 — two live
    versions of one promise is complexity with no honest payoff yet.)

The terms carry a version number from birth (§10) so acceptance can record *which* terms
were accepted; in v1 the version only ever advances while nobody else is bound. A
participant who accepts after the creator edited (pre-acceptance) simply binds to the
current version — the version on their row says so.

The creator cancelling before anyone accepts leaves nothing: invitations expire, their own
personal commitment follows their own normal cancellation rules (inside the correction
window it can be withdrawn; hardened, it stands — creating a group you then abandon does
not un-make your own promise).

---

## 7. Shared progress and visibility

Participants of a shared commitment see each other's lines **for that commitment**,
automatically — accepting *is* the sharing choice for this one commitment, made
explicitly, in the open, on the Deal screen ("The people on this list will see whether you
did it"). Everything else about the participant stays governed by their ordinary privacy
settings.

Participants see, per person:

- name / avatar (the identity they already see as friends);
- invitation state (on the roster: accepted, or still invited — declines just drop off);
- progress toward the **shared** target (`2 / 3`);
- completed / incomplete, and completed on time vs late;
- verification tier *label* only where useful and honest (§8).

Never exposed through the shared surface:

- raw HealthKit samples, workout details, times, routes;
- restricted-app selections (unknowable anyway — tokens are opaque even to Earned);
- Override reason text (never leaves the device today; stays that way);
- personal accountability-partner identities, thresholds, or votes;
- any private Gate settings, restriction profiles, warning config;
- other commitments, streaks, or check-ins beyond what existing sharing settings already
  share.

Progress lines are **representation, not enforcement evidence** (invariant 28 unchanged):
the client reports its own count against the shared target, the server repeats it to the
roster, and nothing on any enforcement path may consume it. A patched client can lie to
its friends inside a commitment app; the liar's prize is their friends' misplaced respect.

An Override used on the personal commitment behaves exactly as the owner's Override
sharing dictates (social-architecture §7.1): shared usage shows as an Override; unshared
usage shows the commitment quietly `ended`. The roster never gets a privileged feed of
someone's escape mechanics just because they run together.

Presentation is a printed roster in the receipt language — first names or handles,
figures, a check for done. **No ranking, no ordering by progress, no first place** —
roster order is join order. No progress bars racing each other.

> YOU + MAYA + DAVE
>
> RUN 3× THIS WEEK
>
> MAYA'S DONE. YOURS IS STILL OPEN.

### Reactions

Meaningful moments may carry a small fixed reaction set (👏 🫡 👀), consistent with
social-architecture §9's design: reactions attach to the event, show to the roster/friends
who can already see the event, and are **never counted into any score, streak, or status
currency**. No comments in this milestone. If reactions are not already trivial on the
existing event surface, they ship after SC1, not inside it.

---

## 8. Verification honesty

Participants may run different verification tiers — Patrick Apple-Health-verified, Maya
self-reported. The shared surface must not flatten that difference into false equality:
where tiers differ, the roster may label lines factually (`verified` / `self-reported`),
in muted type, never as a badge of honor or shame. Social representation stays distinct
from enforcement authority: a "verified" label on the roster is still the client's own
report and still confers nothing (§7, invariant 28).

---

## 9. Friendship, blocking, absence

- **Friendship removed after acceptance**: the personal commitments stand untouched.
  Mutual visibility *within the shared commitment* continues for its duration — the
  participant relationship was separately and explicitly accepted, scoped to this one
  commitment — but every friend-gated surface beyond it ends as normal. (Ending shared
  visibility too would let unfriending silently take back an accepted promise's
  witnesses; the roster was part of the deal.) New invitations require friendship, so
  the pair cannot start another one.
- **Block, before acceptance**: pending invitations between the two accounts are
  cancelled (state `withdrawn`, by rule); new ones are prevented — and, as with friend
  requests, a blocked invite fails indistinguishably from success to avoid announcing
  the block.
- **Block, after acceptance**: block supersedes (invariant 29's logic extended): all
  shared-commitment visibility between the two accounts stops immediately, in both
  directions — each sees the other's line vanish from the roster. Personal commitments
  stand untouched; **blocking never erases a hardened obligation**, in either direction.
  If the creator and a participant block each other, each keeps their own commitment and
  loses sight of the other; other participants' visibility is unaffected.
- **Account deletion / sign-out / app deletion**: existing rules apply (NORTHSTAR §45,
  social-architecture §10). A deleted participant simply ceases to appear on the roster —
  no tombstone, no "left owing 2/3". A signed-out or silent participant's line goes
  stale honestly: their last reported progress with no fabricated freshness; absence is
  observable, motive is not (invariant 27).
- **The creator's deletion orphans the agreement, never dissolves it** (settled by
  Patrick; 0021). The roster belongs to everyone bound to it: the agreement survives
  with a null author, the departed creator's line ceases to appear like any deleted
  participant's, and every personal commitment stands untouched. An orphaned agreement
  is closed in practice — no author remains to edit, cancel, or invite into it, and its
  outstanding invitations can no longer be accepted — but the shared context stays
  visible to the bound until normal retention purges it: the deadline horizon, or the
  moment no participant rows remain at all.

---

## 10. Backend model

Same posture as everything in `backend/` (social-architecture §11): **default deny**, RLS
on, no client table writes, every mutation a SECURITY DEFINER function that re-derives
the caller from the JWT, cross-account reads shaped by functions, `anon` gets nothing.
Migration `0020_shared_commitments.sql`, appended after 0001–0019, never rewriting
history; tests in `backend/tests/170_shared_commitments.sql` run by the same `run.sh`.

The server is authoritative for: invitation existence and state, the roster, the
canonical shared terms and their version, acceptance timestamps, and which personal
commitment id belongs to which participant. The server is **not** authoritative for any
participant's Gate resolution — sharedness never promotes Social into an enforcement
source of truth (§3 of social-architecture stands unchanged).

### 10.1 Tables (0020)

`shared_commitment` (0016) was already taken — it is the *witnessing* projection, one
account showing one of its own commitments to friends. Doing-it-together therefore lives
in two tables:

**`shared_commitment_agreement`** — the promise: `id`, `creator`, `title` (neutralised,
≤80), `activity` (`any|running|walking|cycling|strength|swimming|other`), `metric`
(`show_up|sessions|total_duration|total_distance|active_calories` — `sessions` maps to
EarnedKit's `CompletionMetric.sessionCount`, first-class since ledger schema v6: one
qualifying workout record is one session, accumulated under the ordinary activity
filter, harder-only after hardening),
`target` (null exactly for show_up), `window_start`, `deadline`, `terms_version`,
`state` (`open|closed|cancelled`). `closed` = the creator cancelled the unstarted future
after someone was bound; `cancelled` = nobody else ever was.

**`shared_commitment_participant`** — the roster row that is *also* the invitation, one
per (agreement, account), so a duplicate ask is structurally impossible: `state`
(`invited|accepted|declined|withdrawn|expired|left`), `invited_at`, `responded_at`,
`accepted_terms_version` and `commitment_id` (non-null exactly when bound — the
client-minted uuid of the participant's own commitment, same id space as the Contract
Envelope and witnessing tables, deliberately no FK across systems), `verification`
(`self_reported|app_verified`, stated factually per §8), and the self-reported line:
`progress` (against the shared target), `progress_state`
(`open|kept|kept_late|overridden|ended` — the same vocabulary and Override-quieting rule
as 0016), `resolved_at`. A unique partial index on `(account_id, commitment_id)` is what
makes creation idempotent: retrying with the same commitment id finds the agreement the
first call made.

### 10.2 Functions

All SECURITY DEFINER, caller re-derived via `private.social_caller()`, granted to
`authenticated` only: `create_shared_commitment` (agreement + creator's bound row +
invitations, one call, idempotent by commitment id), `invite_to_shared_commitment`,
`withdraw_shared_invitation`, `respond_to_shared_invitation` (the only thing that can
bind a participant — their own session is the consent credential; duplicate acceptance
converges on the first recorded commitment id; past the deadline it refuses, because a
commitment cannot be born overdue), `edit_shared_commitment` (refused after anyone else
accepts), `cancel_shared_commitment`, `leave_shared_commitment`,
`publish_shared_progress` (client may never claim `ended`; the server applies the
owner's Override-sharing switch), `my_shared_commitments` and `my_shared_invitations`
(field exposure decided in `private.shared_roster`, blocked pairs filtered from every
roster a viewer sees, 30-day horizon from the deadline), and `purge_shared_commitments`
(scheduler only, same horizon). `block_user` is recreated additively: a block withdraws
unanswered invitations between the pair, both directions, and nothing else — accepted
rows stand, because a block severs sight, never an obligation.

An invitation to a non-friend, a stranger, or across a block fails with one
indistinguishable refusal — the same shape 0019 uses for partner nomination, so a block
never announces itself.

### 10.3 RLS and limits

Default deny; direct SELECT is own-perspective only (`shared_participant_select_own`,
`shared_agreement_select_participant`); no client write path exists on either table;
`anon` gets nothing. Dials as functions: 8 participants per agreement, 10 creations and
30 invitations per creator per day. Tests: `backend/tests/170_shared_commitments.sql`
(both CI layouts).

### 10.4 Client shape

The participant's personal commitment is created by the ordinary local path with
`createdAt` = acceptance and `eligibleFrom` = max(shared window start, acceptance) —
EarnedKit needed no changes, and deliberately got none: membership is social metadata,
held in `SharedCommitmentRegistry` (a sibling of `SharingRegistry`, not domain state),
and the server heals that cache from `my_shared_commitments()` after a reinstall. The
foreground pass publishes each shared commitment's own progress line exactly like the
witnessing pipeline: changes only, idempotent on both ends, never a notification per
tick.

---

## 11. Notifications

Useful, sparse, and separate from Gate notifications (which remain local, authoritative,
and exactly as they are):

Worth a notification:
- you were invited;
- someone accepted / the roster settled;
- a participant completed (once, at completion — never per workout);
- the shared commitment starts today;
- your own deadline approaching (this is the existing local warning, unchanged).

Never a notification: progress ticks, partial workouts, app opens, reactions received,
declines (quiet, §4.2). The push stance was revisited on purpose with the follow-ups and
the rule is now (social-architecture §9): **no social-engagement push; commitment-relevant
push allowed** — a shared-commitment invitation, an accountability-partner request, an
override approval request. Migration 0021 builds the groundwork: a `push_device` token
registry (session-bound registration; a re-registered token follows the new account) and
a `push_outbox` the server enqueues into at exactly those three transitions, via
triggers, with the kind check constraint as the allow-list. Delivery — the APNs sender
draining the outbox, app-side registration, the aps entitlement — is the deployment
half, exactly as `message_outbox` awaits its SMS/email sender. In-app surfaces (the
invitation card, the roster, the shelf) remain primary either way, and the user's own
deadline warnings are the existing local notifications, unchanged and authoritative.

## 12. Edge cases, settled

| Case | Behavior |
|---|---|
| Creator invites same friend twice | One invitation row; second call is a silent no-op (§4.2) |
| Crossed invitations (A and B each create a similar group) | Two distinct agreements; nothing merges. Each invitation answered on its own |
| Invitee declines | Quiet; roster never shows them (§4.2) |
| Invitee accepts after creator edited terms (pre-any-acceptance) | Binds to current version; their row records it (§6) |
| Creator edits after another acceptance | Refused; cancel-future or new agreement only (§6) |
| Creator cancels before any acceptance | Invitations expire; own commitment follows own rules (§6) |
| Friendship removed before acceptance | Invitation dies with the friendship (roster is drawn from friends); accept refused |
| Friendship removed after acceptance | Commitments stand; in-commitment visibility persists; nothing new can start (§9) |
| Block before acceptance | Pending invites cancelled silently; new ones fail like strangers (§9) |
| Block after acceptance | Visibility severed both ways; obligations untouched (§9) |
| Participant deletes app / signs out | Obligation is theirs (ledger is local; reinstall rules unchanged); roster line goes honestly stale (§9) |
| One finishes, others don't | The point. Lines differ; nothing else happens |
| One uses an Override | Their line follows their Override-sharing setting (§7) |
| One completes late | `done late`, factually (§7) |
| Differing verification tiers | Shown factually if shown at all (§8) |
| Different restriction profiles | Invisible to each other, by design (§7) |
| Accepts very close to deadline | Short-fuse personal commitment; fast hardening; refused only past the deadline (§5) |
| Creator hardened before friend accepts | Irrelevant to the friend: their clock is their own (§5) |
| Backend unavailable during acceptance | Nothing half-happens; retry accepts once, idempotently (§4.3) |
| Duplicate acceptance requests | One acceptance, one personal commitment (§4.3) |

## 13. Social activity events

*Settled by Patrick with the follow-ups: the roster's meaningful moments belong on the
Recent shelf.* Migration 0021 grows the `social_event` vocabulary by five kinds, all
riding the existing shelf machinery — 30-day horizon, cap of 50, the same purge:

- `shared_accepted` — emitted once, at the acceptor's real acceptance (the idempotent
  retry paths emit nothing);
- `shared_started` — the shared window opening, announced once per agreement to each
  *bound* participant by the scheduler (`announce_shared_starts`); a window already open
  at creation is never re-announced — the invitation cards were the announcement;
- `shared_completed` / `shared_completed_late` — the owner's real open→done transition,
  late stated as late. Suppressed when the same commitment is also friend-shared through
  the witnessing pipeline (0016), which already tells the story: one fact, one line;
- `shared_all_completed` — every accepted line done (two or more of them), told once, by
  the participant whose finish closed the roster.

For the shared kinds, `social_event.commitment_id` carries the *agreement* id, so the
witnessing pipeline's per-commitment withdrawal can never collide with them. Explicitly
never events, in any milestone: per-progress-tick, per-app-open, declines, roster
bookkeeping, hydration anything, reaction-received. The kind check constraint is the
allow-list — an event outside the vocabulary cannot be spelled.

## 14. Design tone

Same receipt language as everything (design-language.md). Factual lines, no exclamation
marks, no squad-goals vocabulary, no confetti, no mascots, no coins:

> SHARED COMMITMENT
>
> MAYA'S DONE.
> YOURS IS STILL OPEN.

The loud voice stays reserved for the moments it is earned; someone else finishing their
run is Maya's moment, printed in calm type on Patrick's roster.
