# Social Accountability — Architecture

v0.3 · August 2026 · Milestones S1 (profiles, friends, Social tab), S2 (commitment
sharing, the activity shelf, streak presentation) and S3 (check-in sharing, the
hasn't-checked-in surface) are built; everything past them is design, not code.

The product intent lives in NORTHSTAR §45. This document is the working design: the
relationship model, the profile/identity model, the privacy rules, the storage design, and
the explicit line between what the server enforces and what it merely repeats. Where this
document and the code disagree, one of them is a bug — fix whichever is wrong, not
whichever is cheaper.

---

## 1. What this is for

**Make promises visible enough that walking away from them has social weight.**

The existing loop is private: commit → do the thing → the phone unlocks. Social
accountability adds one ingredient — *someone knows* — without adding an attention
product:

> Commit → someone knows → do the thing → keep the promise → build trust.

Earned exists partly to reduce compulsive digital consumption. A social layer inside it
must therefore clear a higher bar than social layers usually do. The anti-goals are as
load-bearing as the goals:

- **No XP economy.** Nothing in the social layer mints points.
- **No global leaderboard, no ranking of friends.** Reliability is not a scoreboard.
- **No follower counts, no follow model.** Connections are mutual or they are nothing.
- **No infinite feed.** The Social screen shows a bounded, recent set of meaningful
  events, and then it ends.
- **No engagement metric as a goal.** Success is commitments kept, not minutes in-app.
- **No feature whose main purpose is keeping somebody inside Earned.**

Every proposed social feature faces the Earned Test (NORTHSTAR §42) plus one more
question: *does this make a kept promise weightier, or does it just make the app
stickier?* Sticky-only features are rejected.

---

## 2. Friends are not accountability partners

This is the foundational distinction, and it is structural, not stylistic.

| | Friend / Connection | Accountability Partner |
|---|---|---|
| What it is | Two Earned users mutually agreed to connect | A person the user granted **authority to approve an Accountability Override** |
| Consent | Mutual friend request/accept | Explicit nomination + the partner's own consent (migration 0005/0006) |
| Needs an Earned account | Yes | No (`partner.kind = 'unverified_contact'` is the normal case) |
| What they can see | Whatever the profile owner has chosen to share | The override-request snapshot, and only while a request is live (accountability-architecture §13) |
| What they can do | Nothing to your contract | Cast a vote that can open your phone |
| Table | `friendship` (0014) | `partner` (0001, 0005–0007) |

A person may be both. The relationships still never merge:

- **Being my friend does not give you authority over my contract.** A friendship row is
  never consulted by `register_contract_envelope`, `create_override_request`,
  `cast_override_vote`, or anything else on the enforcement path. Roster eligibility
  (invariant 22) remains: consented partners only.
- **Being my accountability partner does not give you access to my social activity.**
  Partners are frequently not Earned users at all; the ones who are get nothing socially
  unless a friendship is separately formed and sharing separately chosen.

The `partner` table is **not** repurposed as a friendship table, and never will be — it
carries encrypted contact details, consent state and suppression semantics that friendship
has no business touching.

### The bridge, as built (migration 0019)

`partner.kind = 'earned_user'` now has its behaviour: an accepted friend can be nominated
as an accountability partner **by their authenticated identity** — no phone number, no
email, ever. The friendship is the *nomination channel*: the ask travels through it (which
is also why a blocked pair fails exactly like strangers, leaking nothing), and stops there.
Consent is the friend's own explicit in-app act, their session standing where the external
flow's bearer token stands. Both kinds of partner are first-class: the external flow —
no account, no app install, consent and approvals through secure web links — is untouched
and remains the only path for anyone not on Earned.

Two cross-system rules, and only these two:

- **Block supersedes both systems** (NORTHSTAR invariant 29): a block revokes any
  invited/active earned partnership between the two accounts, both directions, as an
  explicit rule — frozen contract thresholds never lower, depleted routes become honestly
  unavailable, Solo remains, and past votes and grants stay on the record. Unblocking
  restores nothing; authority returns only by fresh nomination and fresh consent.
- **Nothing else crosses.** Removing a friendship leaves an accountability partnership
  standing; revoking a partner leaves the friendship standing; becoming one never implies
  the other (invariant 24).

### A third relationship: the shared participant

Shared Commitments (NORTHSTAR §46, [docs/shared-commitments.md](shared-commitments.md))
add a third concept beside friend and accountability partner: a **shared participant** —
someone who explicitly accepted the same shared commitment. It grants exactly one thing:
mutual visibility of that one commitment's roster and progress lines. It grants no
authority over anyone's contract, no access to anything else the person shares, and it is
never inferred: friendship is only the invitation channel, and acceptance is the
participant's own in-app act (invariant 31). The three relationships may overlap; none
ever implies another. Block behaves here as everywhere — unanswered invitations between
a blocked pair are withdrawn, roster visibility between them severs both ways, and
nobody's personal commitment moves an inch (invariant 32).

---

## 3. Enforcement authority vs social representation

The Contract Envelope system exists because the threat model treats the account holder as
the adversary: the server enforces the approval threshold because a modified client cannot
be allowed to state it. That trust boundary is expensive and it is **not extended to
social data**.

| | Enforcement authority | Social representation |
|---|---|---|
| Examples | Approval thresholds, rosters, hardening times, grants | "Dave finished today's workout", streaks, completion claims |
| Source of truth | The envelope and grant tables the client cannot write | The client's own ledger / HealthKit evidence, self-reported |
| A modified client can lie about it | **No** — that is the whole design | **Yes**, and we say so |
| Consequence of a lie | None possible | The liar impresses their friends inside a commitment app, which is its own punishment |

Social data is **not** a security boundary and must never quietly become one. Nothing may
ever consume social claims as an input to enforcement — no "your friends vouched for you"
override discount, no reputation-gated escape route — unless server-authoritative
completion is built first, and that is explicitly a separate future project. The recently
tabled Strava decision is not reopened to make the Social screen look trustworthy; the
Social screen instead stays honest about being a representation.

Corollary invariant: **social visibility never changes Gate truth.** The ledger decides
whether the phone is locked. Sharing, unsharing, being blocked, or the social backend
being down changes what other people see, never what the user owes.

---

## 4. Identity: the profile

### 4.1 One canonical display name

`account.display_name` already exists and is what accountability pages render. It stays
**authoritative**. The new `profile` table deliberately has no display-name column; every
profile read joins it from `account`, and the profile-edit RPC writes it to `account`.
There is exactly one name, so accountability can never show "Patrick" while Social shows
an independently edited "Pat". If a deliberate separation is ever wanted, it gets designed
on purpose — it cannot happen by accident.

**One canonical name is not the same as one canonical *writer*, and that gap cost the
product its identity for two real users** (fixed in migration 0024). Apple hands over a
display name on the **first authorization only**; every sign-in after that — a second
device, a reinstall — returns nil. The app substituted the literal string `"Someone"`, and
`ensure_account` upserted it with `set display_name = excluded.display_name`, so a single
re-sign-in overwrote the name chosen in profile setup. One person signing in on a new
phone made themselves anonymous, at once, on every surface that reads this column:
friends' rosters, shared-commitment participants, the Recent shelf, the partner approval
page, and every push body.

Three rules now hold it:

1. **The client never invents a name.** Nothing to report is sent as empty.
2. **`ensure_account` cannot be talked out of a name it already has.** The upsert is
   `coalesce(nullif(btrim(excluded.display_name), ''), account.display_name)` — silence is
   not new information about what somebody is called.
3. **Empty means unknown, and unknown renders as the handle.** `private.social_name()`
   falls back to `@handle`, which is recognisable and — unlike `"Someone"` — different for
   every person. That difference is the entire point: a placeholder that renders
   identically for everybody removes the one thing a social surface exists to show.

The account's own `display_name` check now permits an empty string for exactly this
reason. `Earned user` remains as a last resort for an account with neither name nor
handle, which in practice cannot appear on a social surface at all, because a profile
requires both.

### 4.2 The profile table (migration 0013)

One row per account, created by the post-sign-in setup flow:

| Column | Required | Visibility |
|---|---|---|
| `account_id` | — | never exposed to other users (see §7.4) |
| `handle` | yes | public to signed-in users (search, friends) |
| display name (via `account`) | yes | same as handle |
| `avatar_path` | no | per §6.3 |
| `city` | no | **friends only.** Coarse, user-typed text ("London", "Grenoble"). Never a coordinate |
| `timezone` | auto | **private system information.** From `TimeZone.current`, for deadline/social presentation later. Never shown to anyone |
| `discoverable` | default true | controls search only |

Deliberately absent, per the product decision: date of birth, gender, GPS location,
contact-list anything, biography, employer, school, demographics. Core Location permission
is never requested for profiles. Implementation found no concrete need for any of them.

**Profile completion** = the profile row exists (a row cannot exist without a valid
handle, and an account cannot exist without a display name). The app checks `my_profile()`
after sign-in and offers the setup flow when it returns nothing. Completion gates only the
social features — never the Gate engine, never Solo Override, never anything local (S8
applies to Social exactly as to accountability: our outage must never touch the contract
machinery on the phone).

### 4.3 Handles

- Case-insensitive, stored lowercased; input is trimmed and a leading `@` dropped.
- `^[a-z0-9_]{3,20}$` after normalisation. Malformed is refused server-side.
- Reserved names (`earned`, `admin`, `support`, `official`, `apple`, …) are refused by
  `handle_is_reserved()` — a function, so the list can grow without a schema change.
- Uniqueness is a real constraint, not an application check.
- Handles are the discovery mechanism. **Account ids are not**: no RPC accepts or returns
  another user's `account_id`, so the id namespace stays unenumerable.

### 4.4 Sign in with Apple → profile setup

Apple sends the full name **only on first authorization** (the code already handles this:
kept when offered, reused from UserDefaults after). Setup prefills from whatever
`ensure_account` stored and lets the user edit. The flow is four short steps and a
full-stop — name, handle, optional photo, optional city — then `WELCOME TO EARNED.` No
questionnaire.

The `.email` scope is **adopted** alongside `.fullName` (settled by Patrick for S2; S1
ships without it). The verified Apple-associated email exists for private
identity/security purposes only — concretely, deriving `account.verified_email_lookup`,
the blind index that refuses self-nomination as your own accountability partner
(accountability-architecture §2.2, S17). The boundaries are explicit:

- never exposed on a profile, and never usable for friend search or any discovery;
- never treated as proof the user controls no *other* addresses — the self-nomination
  refusal catches the honest mistake, not the determined spare-alias (§2.2 already says
  so of the whole mechanism);
- never required of existing accounts — an account without one simply keeps a null
  `verified_email_lookup`, as today;
- an Apple private-relay address is handled normally, as the verified address Apple
  supplied — it is exactly as good a blind-index input as any other.

The implementation rides the accountability flow (it changes `ensure_account`'s contract
and exercises the pepper-keyed HMAC path), not the social one.

---

## 5. Friendship

### 5.1 The model (migration 0014)

**One row per pair of accounts**, ever — not two directional rows. The pair is stored
ordered (`account_low < account_high`) with a unique constraint, so a duplicate
relationship is structurally impossible, and direction lives in an explicit `requester`
column:

```
friendship (
  account_low, account_high   -- the pair, ordered; unique
  requester                   -- who asked; must be one of the pair
  status                      -- pending | accepted | declined | blocked
  blocked_by                  -- who blocked, when status = blocked
  created_at, responded_at
)
```

### 5.2 State machine

| From | Action | To | Notes |
|---|---|---|---|
| — | A requests B | `pending` (requester = A) | by handle, never by id |
| `pending` (A) | A requests B again | `pending`, same row | idempotent; no duplicate, no re-notification |
| `pending` (A) | B requests A | **`accepted`** | crossed requests mean both wanted it; resolves deterministically to one mutual friendship |
| `pending` (A) | B accepts | `accepted` | one mutual friendship, one row |
| `pending` (A) | B declines | `declined` | quiet: A's outgoing request stops being listed; A is never shown "declined" |
| `pending` (A) | A cancels | row deleted | withdrawing an unanswered ask leaves nothing behind |
| `declined` | A requests B again | `pending` | allowed; per-account rate limits are the S2 defence if this is abused |
| `accepted` | either removes | row deleted | either side may end it; all friend-gated visibility ends with it |
| any | either blocks | `blocked`, `blocked_by` set | overwrites whatever stood, including `accepted` |
| `blocked` | blocker unblocks | row deleted | back to strangers; a fresh request is possible after |

### 5.3 What blocking means

Blocking is the strongest word in the model and it must hold everywhere, not just in the
obvious endpoint:

- The blocked user's requests to the blocker are **silently dropped** — the RPC returns
  the same nothing-shaped success as ever, and no row is created or modified. A
  distinguishable refusal would itself announce the block.
- Each stops appearing in the other's search results and profile lookups (`get_profile`
  returns not-found). Indistinguishable from a user who turned discoverability off or
  never existed — that ambiguity is deliberate and is the standard, correct trade.
- Only the **blocker** can see the blocked row (it is their block list). The blocked user
  cannot read the relationship state from `friendship`, from search, from profile lookup,
  from avatar access, or from any future endpoint — the tests exercise each path, because
  a block that leaks through a side door is a privacy incident, not a bug.
- Blocking severs friend-gated visibility immediately (city, avatar, future shared
  activity).

### 5.4 Discovery

S1 discovery is **handle search only**: exact and prefix match on the normalised handle,
minimum two characters, capped result count. Results expose the minimum that lets a human
confirm they found the right person: handle, display name, avatar. City is not in search
results. Not built, by decision: contact-book upload, phone-number search, email search,
any public directory. A future invite link (a signed token that pre-approves one
friendship) is documented as the likely S2 discovery addition and does not ship now.

---

## 6. Avatars

### 6.1 Pipeline

- **PhotosPicker** on iOS; no camera or photo-library blanket permission needed.
- The chosen image is **re-encoded before upload** by `EarnedMedia.AvatarEncoder`
  (ImageIO): decoded, downscaled to at most 512×512, and written as a fresh JPEG with no
  source properties copied. EXIF, GPS, TIFF and every other metadata block are absent
  from the derivative **by construction** — the original file is never uploaded.
- Accepted input is anything ImageIO decodes; anything it cannot is refused
  client-side. The bucket refuses everything but `image/jpeg` server-side, so the client
  cannot be talked into uploading something else.
- Size limits: ≤ 512px derivative, and the bucket enforces a 1 MB object cap.

### 6.2 Storage layout (migration 0015)

Supabase Storage, **private** bucket `avatars`. Object path:

```
avatars/<account_id>/<random-uuid>.jpg
```

- The path contains an opaque account uuid and a random object name — no handle, no name,
  no contact information. (The account id appears only in a path that is itself served
  solely through authenticated, policy-checked storage reads — it is not a discovery
  surface.)
- `profile.avatar_path` points at the **current** object. Replacing an avatar uploads a
  new random-named object, repoints `avatar_path`, then deletes the old object. Because
  visibility (below) is defined as *being some visible profile's current avatar*, a
  replaced object stops being readable by anyone but its owner at the instant of the
  repoint, even before the delete lands. Retention: replaced objects are deleted
  immediately by the client; a server-side sweep of orphans is S2 housekeeping, not a
  correctness dependency.
- The client talks to Storage with the user's own JWT under RLS. No service-role or
  administration credential ships in the app.

### 6.3 Who can see an avatar

The rule lives in one SQL function, `avatar_visible_to(viewer, path)`, which the storage
SELECT policy delegates to and the backend tests exercise directly:

| Viewer | Sees the avatar? |
|---|---|
| The owner | yes |
| An accepted friend | yes |
| A signed-in non-friend | yes, iff they could see the profile at all (discoverable, not blocked) — the avatar shows wherever the search result or profile does |
| Either side of a block | **no** |
| Owner with `discoverable = false` | friends and owner only |
| Anonymous / signed out | **no** |
| Anyone, for a non-current (replaced) object | **no** — owner only |

Write access: owners may insert/update/delete only inside their own
`<account_id>/` prefix, only `.jpg`, and only in `avatars`. Nobody else can write at all.

Default rendering when there is no avatar (or it fails to load) is the owner's initials on
the field colour — the poster identity degrades to typography, not to a broken-image glyph.

---

## 7. Privacy model

### 7.1 Settings, designed now

| Setting | Default | Status |
|---|---|---|
| Profile discoverability (`discoverable`) | on | **built** (S1; UI in profile editing) |
| Commitment visibility | **Private** | **built** (S2): per-commitment Private/Friends, chosen at creation or on the commitment, changeable any time in either direction — visibility is a privacy choice, not a contract term, and monotonicity never governs it |
| Share streaks (`share_streaks`) | off | **built** (S2): off deletes the stored figures and their milestone events |
| Share Override usage (`share_override_usage`) | off | **built** (S2): off stores and tells an Override as a quiet 'ended'; turning it off withdraws existing `override_used` events and quiets existing states |
| Share inactivity / last-check-in (`share_last_checkin`) | off | **built** (S3): off means the fact is not even stored, and turning it off deletes it; turning it on starts the clock at now — an old silence is never retroactively surfaced |
| Share missed commitments | off | designed only — an overdue shared commitment simply stays 'open' in friends' view |

Sharing is **chosen, never assumed**: every one of these defaults to the private side. A
future "share my exercise commitments with friends by default" is an explicit choice a
user makes in settings, never a launch default.

### 7.2 Honesty of changes, and retention

- Making a profile undiscoverable removes it from search immediately. Removing a
  friendship or blocking removes friend-gated visibility immediately.
- Privacy changes affect **future visibility honestly**: nothing is manufactured to
  cover a gap, and nothing already withdrawn is kept alive "because a friend once saw
  it". Built as designed (0016/0017): unsharing a commitment deletes it and every event
  it generated; turning a sharing switch off withdraws server-side what it was sharing;
  and events live behind a **30-day horizon** — `friend_activity` refuses to read past
  it and `purge_social_events` deletes behind the same number, so the shelf cannot
  quietly become a timeline.
- Declined/cancelled requests keep no long-term record; removed friendships and unblocks
  delete their row outright.

### 7.3 Hydration is excluded

Hydration events never enter the social layer in v1. Nobody needs "Patrick drank water
11 minutes ago", and a behavioural interrupt must not become a performance.

### 7.4 What endpoints may not leak

No social RPC or search result exposes: Apple subject (`apple_user_id`), `auth_user_id`,
email or its blind index, partner contact material, internal `account.id`s of *other*
users, timezone, or anything from the accountability tables. The tests assert the shape of
every result, not just its row count.

---

## 8. Streaks (built in S2, to the settled semantics)

*Semantics settled by Patrick, August 2026; implemented the same week.
`EarnedState.socialStreaks(now:)` computes the figures from the ledger,
`SocialStreakTests` holds the semantics below, and `social_streaks` (0017) carries them
to friends only while `share_streaks` is on.*

Two distinct concepts, deliberately not one gamified score, and no XP behind either:

1. **Commitment streak** — consecutive *eligible* commitments completed **on time**.
   "Eligible" reuses the reward-streak notion EarnedKit already has: commitments the user
   marked as streak-participating; hydration acknowledgements never count. Missing a
   deadline and completing late clears the debt but **breaks the on-time streak** — the
   two facts are both true and both recorded.
2. **Since last Override** — the number of commitments completed since the most recent
   Override. A legitimate Override — Free, Accountability, or Solo — **resets or
   annotates this counter and does not automatically erase the commitment streak.** An
   Override is a contract mechanism the user built in on purpose; using one is not a
   moral failure, and the two numbers stay separate so it never reads as one.

Public copy uses the literal wording — **"6 since last Override"** — never a loaded label
like "integrity streak". The name describes the arithmetic, not the person.

An **enforcement bypass is not an Override** and is represented separately, exactly as
NORTHSTAR §33 requires of history. If — and only if — the owner has opted into sharing
bypass information, a detected bypass may reset the relevant escape-free counter; the
default, like every default in §7.1, is that it is nobody's business.

Nothing the owner keeps private can end a counter their friends can see — a shared number
must never leak what it was built to summarise. Friend-facing shapes that fit the receipt
language:

```
12 COMMITMENTS KEPT           10-DAY COMMITMENT STREAK
6 since last Override         No Overrides this week
```

Presentation, as built: the Social tab shows the owner their own two figures straight off
the ledger (with a footer saying who else sees them), and a friend's profile shows theirs
only while they share them. Milestone events fire when the kept count *rises onto* 5, 10,
25, 50, 100 or 250 — once, however often the same figures are republished. Friends are
never ranked by either number.

---

## 9. Meaningful social events (built in S2)

The Recent area carries a **bounded, recent** set of events, not a timeline: 30-day
horizon, capped at 50, then it ends. The events that exist, all gated on the owner's
sharing choices (`social_event`, 0016):

- `commitment_shared` — a commitment shared while still open. One shared *after* it
  resolved emits only its outcome, never a retroactive "committed".
- `commitment_kept` / `commitment_kept_late` — the outcome of a shared commitment. Late
  is stated as late; a kept promise is a kept promise either way.
- `override_used` — only while the owner shares Override usage; never the private reason
  text. With sharing off, the commitment quietly becomes `ended` and no event says more.
- `streak_milestone` — the kept count rising onto a milestone, while streaks are shared.

Every transition emits **at most one event**, and republishing the same state emits
nothing — the app publishes on every foreground and the server is idempotent about it.
The pipeline: the client's `SharingRegistry` records the choice, `publish_shared_commitment`
distributes the story, and the ledger remains the only place the truth lives (§3).

Designed but not built: enforcement-integrity-lapse events (needs its own sharing rule)
and hasn't-checked-in events (§10, needs check-in sharing first).

Explicitly never events: hydration acknowledgements, app opens, or anything at
per-interaction granularity. A shared commitment exposes exactly: title (neutralised like
every user text), deadline, state, and resolution time — never restricted-app selections,
raw HealthKit data, progress (deferred as designed-optional), unrelated commitments, or
hydration.

Reactions (👏 🫡 👀 😂 — a small fixed set, no counts-as-status) may come later. **No
comments** in the initial social design; there is nothing to moderate on a screen with no
text entry.

### Where the milestones stand

S2 shipped: per-commitment visibility (default Private; one-off commitments choose at
creation, any commitment on its detail screen), the event backend with its retention
window, the Recent shelf rendering real events, and streak presentation to the settled
semantics. Plan occurrences are shareable individually from their detail screens; a
whole-plan sharing choice at creation is deliberately deferred — twelve
`commitment_shared` events in one tap is a feed, not a promise.

S3 shipped: opt-in check-in sharing and the hasn't-checked-in surface (§10). A quiet
friend is a state on the roster and the profile, deliberately **not** an event on the
shelf — silence is not content, and an event would let it outlive the silence.

Next, when warranted: invite links, possibly reactions, enforcement-integrity-lapse
sharing. Still never: comments, leaderboards, XP, contact imports, follow model, public
web profiles.

### The push rule (revised by Patrick with the SC1 follow-ups)

The old blanket line — *no push notifications for friends* — is replaced by a sharper
one:

**No social-engagement push notifications. Commitment-relevant notifications are
allowed.**

Allowed: a shared-commitment invitation, an accountability-partner request, an override
approval request waiting on you — asks that are *actionable commitment events*, where a
person's phone buzzing is the promise machinery working. Never pushed: reactions,
generic social activity, streak updates, milestones, "your friend finished their run",
or any engagement nudge — the shelf is where those live, read when the user chooses.
Structurally, the server's `push_outbox` (0022) can only spell the allowed kinds; an
engagement push is not a policy violation waiting to be caught in review, it is a row
that cannot exist.

**Delivery landed in S4** (migration 0024, `supabase/functions/push`). Two people on two
phones found the missing half immediately: an invitation only existed if you thought to go
and look for it, which two people cannot coordinate.

| | |
|---|---|
| Registration | `register_push_token` from the app once notification permission exists. `push_device` is revoked from `authenticated` outright — no client can read any token, including its own. |
| Claiming | `claim_push_batch` hands a row out **once** (`for update skip locked`, a claim timestamp, an attempt count). Two senders running together, or one retried after a timeout, cannot buzz a person twice. |
| Collapsing | The payload carries `collapse-id` = the row id, so even a send that reached Apple twice replaces rather than stacks. |
| Completion | `complete_push` records delivered or failed. A crash between claiming and recording leaves the row claimable when the claim ages out: late, never lost or doubled. |
| Dead tokens | A 410 / `Unregistered` / `BadDeviceToken` calls `forget_push_token`. Anything else is a retry, because throttling says nothing about the device. |
| Retirement | `purge_push_outbox` drops asks older than a week, so a phone that was off does not wake to a decision made without it. |
| Blocking | The enqueue triggers check `private.blocked_between` first. A block stops the phone buzzing, not merely the reads. |

What crosses to Apple: a title, a body, the `kind`, and a `route` — the id of the
agreement or request the recipient is *already a party to*. Never an account id, never
Health data, never a restriction profile, never the Override reason text, which is the
requester's words to a chosen few and not lock-screen material.

**Push is delivery, never authority.** Every ask exists as a row the app fetches on its
own; notifications only mean a person finds out while it still matters. Refusing them
costs timeliness and nothing else, which is why permission is asked once, late, from a
screen that explains it, at the moment somebody first depends on this phone noticing
something — and never at launch, where there is nothing to be reachable for.

---

## 10. Absence, silence, and what Earned may claim (built in S3)

A friend going silent is exactly the useful social friction this feature exists for — and
exactly where honest language matters most, because **Earned cannot distinguish** app
deletion from a lost phone, a dead battery, an off-grid week, or simply not opening the
app. Therefore:

- Earned states **facts it observed**, never motive:

  > PATRICK HASN'T CHECKED IN
  > Last seen by Earned 2 days ago.

  and, when the last reliable sync showed unresolved shared commitments:

  > PATRICK HASN'T CHECKED IN
  > 1 shared commitment was still open at his last check-in.

- Never rendered, in any wording: "Patrick deleted Earned to get out of his run."
  Motive is not observable (NORTHSTAR §33 already refuses intent claims; the same rule,
  same reason).
- Presence sharing is **opt-in** (§7.1), coarse ("last seen by Earned", day-level), and
  never a live online indicator.
- Silence becomes surfaceable after **72 hours**, and only to friends, and only when the
  owner opted in. Below that it is noise.

As built (0018): the app calls `record_checkin` on every foreground pass, and the server
stores one timestamp — only while `share_last_checkin` is on; with it off the fact is not
stored at all, and turning it off deletes it. Friends never see the timestamp: they see a
**whole-day count**, present only past the 72-hour threshold, on the friend list and the
friend profile. Its absence deliberately means "recently active *or* not sharing" — the
ambiguity is what makes this not a presence indicator. "Open at last check-in" is
computed from the `shared_commitment` rows still marked open, which by construction
cannot have been updated since the server last heard from that client. Turning the switch
back on starts the clock at now — a silence the owner never agreed to show is never
retroactively surfaced.
- The product half of account deletion is now settled (accountability-architecture
  §21.2): deletion is never blocked by outstanding commitments, and it removes the
  user's social identity and visibility entirely — no tombstone describing what was
  outstanding, when they left, their streaks, or apparent motive. A deleted friend
  simply ceases to appear; they do not become a cautionary tale. The retention/legal
  half of D10 (suppression, abuse records, lawful basis) stays open under privacy/legal
  review, and nothing social encodes an answer to it.

---

## 11. Backend posture

Same as everything else in `backend/`: **default deny.** RLS on, no client write
permission on any table, every mutation a `SECURITY DEFINER` function that re-derives the
caller from the JWT, `anon` gets nothing. Reads that need cross-account shaping
(search, friend profiles) go through functions too, so field exposure is decided in
exactly one reviewed place per query rather than by policy arithmetic.

Migrations: `0013_profiles.sql`, `0014_friendship.sql`, `0015_avatar_storage.sql` (S1),
`0016_commitment_sharing.sql`, `0017_streaks_and_activity.sql` (S2),
`0018_checkin_sharing.sql` (S3), `0019_earned_partners.sql`, and
`0021_shared_commitments.sql` (SC1 — design in
[shared-commitments.md](shared-commitments.md)) — appended after the existing 0001–0012,
which are never rewritten. The storage migration guards on the
`storage` schema existing so the plain-Postgres CI layout still applies cleanly; the
visibility *rule* is a public function tested without Supabase.

Tests: `backend/tests/110_profiles.sql`, `120_friendship.sql`, `130_avatars.sql`,
`140_sharing_and_activity.sql`, `150_checkins.sql`, `160_earned_partners.sql`,
`180_shared_commitments.sql`, run by the same `run.sh` in both layouts. What they must
cover is listed in the milestone tasks and mirrored in the files themselves — profile
mutation isolation, case-insensitive handle uniqueness, malformed/reserved handles, block
non-discoverability through every endpoint, idempotent and crossed requests, search and
event field shape, removal revoking access, publish idempotency, the Override-sharing
switch quieting states and withdrawing events, unshare withdrawing everything, the 30-day
horizon on both read and purge, anon getting nothing, and no identifier leaks.
