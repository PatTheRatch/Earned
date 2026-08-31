# Social Accountability — Architecture

v0.1 · August 2026 · Milestone S1 built; everything past S1 is design, not code.

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
has no business touching. The existing `partner.kind = 'earned_user'` value remains the
future hook for letting an authenticated friend *become* a partner — but that promotion
must run through the same nomination-and-consent flow as any other partner. Friendship is
never implicit accountability consent.

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

The `.email` scope is currently **not** requested. Evaluated for S1: adding it would let
the server fill `account.verified_email_lookup`, which is the blind index that refuses
self-nomination as your own accountability partner (accountability-architecture §2.2) —
a real improvement to an existing protection, but one that belongs to the accountability
flow, changes `ensure_account`'s contract, and needs the pepper-keyed HMAC path exercised.
Deferred as its own small change rather than smuggled in with Social; email would in any
case never be public profile data.

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

| Setting | Default | S1 |
|---|---|---|
| Profile discoverability (`discoverable`) | on | **built** (column + enforcement; UI in profile editing) |
| Default commitment visibility | **Private** | designed only — no sharing pipeline exists to apply it to |
| Share streaks | off | designed only |
| Share Override usage | off | designed only |
| Share inactivity / last-check-in | off | designed only |
| Share missed commitments | off | designed only |

Sharing is **chosen, never assumed**: every one of these defaults to the private side. A
future "share my exercise commitments with friends by default" is an explicit choice a
user makes in settings, never a launch default.

### 7.2 Honesty of changes, and retention

- Making a profile undiscoverable removes it from search immediately. Removing a
  friendship or blocking removes friend-gated visibility immediately.
- Privacy changes affect **future visibility honestly**: nothing is manufactured to
  cover a gap, and nothing already withdrawn is kept alive "because a friend once saw
  it". When shared activity events exist (S2), an event whose owner withdraws sharing is
  withdrawn with it, and events expire on a short fixed horizon (design target: 30 days)
  rather than accumulating into a permanent timeline.
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

## 8. Streaks (designed, not built)

Two distinct concepts, deliberately not one gamified score, and no XP behind either:

1. **Commitment streak** — consecutive *eligible* commitments resolved on time.
   "Eligible" reuses the reward-streak notion EarnedKit already has: commitments the user
   marked as streak-participating; hydration acknowledgements never count.
2. **Integrity streak** — commitments (or time) since the last **user-visible escape
   event** *under the sharing policy*: an Override the owner chose to share, or an
   enforcement bypass the owner chose to share. Nothing the owner keeps private can end a
   streak their friends can see — a streak must never leak what it was built to summarise.

An Override is a legitimate contract mechanism, not cheating, and the presentation must
not shame it. Friend-facing shapes that fit the receipt language:

```
12 COMMITMENTS KEPT           10-DAY COMMITMENT STREAK
6 since last Override         No Overrides this week
```

Exact semantics (does a shared Override *reset* or merely *annotate*; how the two streaks
interact with debt-clearing late workouts) get their own decision record before any
implementation. Friends are never ranked by either number.

---

## 9. Meaningful social events (designed, not built — S2)

The Recent area of the Social screen will carry a **bounded, recent** set of events, not a
timeline. Candidate events, all gated on the owner's sharing choices:

- shared commitment created / completed on time / completed late
- streak milestone
- Override used (only if the owner shares Override activity; never the private reason text)
- enforcement-integrity lapse (only under explicit sharing rules)
- a friend has not checked in for a meaningful period (§10)

Explicitly never events: hydration acknowledgements, app opens, or anything at
per-interaction granularity. A shared commitment exposes at most: title/requirement,
deadline, completion state, on-time-ness, optionally progress, and Override usage if
elected — never restricted-app selections, raw HealthKit data, unrelated commitments, or
hydration.

Reactions (👏 🫡 👀 😂 — a small fixed set, no counts-as-status) may come later. **No
comments** in the initial social design; there is nothing to moderate on a screen with no
text entry.

In S1 the Recent area ships as an honest empty state. It fabricates nothing.

### S1 → S2 boundary

S2, the intended next milestone, is: commitment-visibility choice at creation (default
Private), the activity-event backend with its retention window, the Recent area rendering
real events, streak presentation, and opt-in check-in sharing. Not in S2 either:
push notifications for friends, reactions, comments, invite links (unless pulled in),
leaderboards (never), XP (never), contact imports (never), follow model (never), public
web profiles.

---

## 10. Absence, silence, and what Earned may claim

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
- Design target for "interesting": silence becomes surfaceable after **72 hours**, and
  only to friends, and only when the owner opted in. Below that it is noise.
- This feature deliberately does **not** settle account deletion (D10). What deletion
  does to social visibility inherits whatever D10 decides; nothing here forecloses it.

---

## 11. Backend posture

Same as everything else in `backend/`: **default deny.** RLS on, no client write
permission on any table, every mutation a `SECURITY DEFINER` function that re-derives the
caller from the JWT, `anon` gets nothing. Reads that need cross-account shaping
(search, friend profiles) go through functions too, so field exposure is decided in
exactly one reviewed place per query rather than by policy arithmetic.

Migrations: `0013_profiles.sql`, `0014_friendship.sql`, `0015_avatar_storage.sql` —
appended after the existing 0001–0012, which are never rewritten. The storage migration
guards on the `storage` schema existing so the plain-Postgres CI layout still applies
cleanly; the visibility *rule* is a public function tested without Supabase.

Tests: `backend/tests/110_profiles.sql`, `120_friendship.sql`, `130_avatars.sql`, run by
the same `run.sh` in both layouts. What they must cover is listed in the S1 task and
mirrored in the files themselves — profile mutation isolation, case-insensitive handle
uniqueness, malformed/reserved handles, block non-discoverability through every endpoint,
idempotent and crossed requests, search field shape, removal revoking access, anon getting
nothing, and no identifier leaks.
