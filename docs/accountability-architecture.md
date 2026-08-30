# Accountability Overrides — Architecture and Threat Model

v0.1 · August 2026 · **Design for review. Nothing here is built.**

This is the design to red-team before any of it is written. It covers the Accountability
Override (NORTHSTAR §23–24) as a networked feature: what the backend owns, how approval
links are secured, what a partner can see, and what happens when things go wrong or
concurrent.

It is written to a deliberately higher bar than the rest of the repo, because this is the
first feature where **strangers' commitments, contact details and device restrictions pass
through our architecture**. Every design choice below is measured against two questions,
not one:

1. **Product integrity** — is this still Earned?
2. **Launch integrity** — would I be comfortable putting other people's data through this?

Decisions that are genuinely product calls are collected in [§17](#17-open-decisions-that-need-a-human)
rather than settled quietly here.

---

## 1. What actually changes

Everything Earned does today can live on one phone. Approval cannot.

An Accountability Override is a **claim about what other people did**. A device has no
standing to make that claim about itself. Today it does anyway:

```swift
case .overrideApprovalRecorded(let requestID, let partnerID):
    var request = try activeRequest(requestID)
    try validateFreshVote(request, partnerID: partnerID)
    request.approvals[partnerID] = date
    …if request.approvals.count >= policy.approvalsRequired { grant }
```

`partnerID` is a `String` the app supplies. Nothing anywhere verifies that a human sent it.
On Patrick's own phone that was fine — it was scaffolding for a state machine. Shipped to
strangers it is not a security weakness so much as **the feature not existing**: the escape
route the whole override ladder is built around would be a text field.

So the trust boundary moves. From here:

> **The server is authoritative for accountability outcomes. The device may record an
> outcome; it may never decide one.**

Everything else in this document follows from that sentence.

The ledger stays authoritative for gates, progress, hardening, debt and Solo Overrides, and
the app stays fully functional offline for all of it. This is a narrow, deliberate transfer
of exactly one decision.

---

## 2. The adversary is the user

This is the unusual thing about Earned's threat model and it should be stated before any
table definitions, because it invalidates several designs that would otherwise look fine.

In a normal product, the user is who you protect. In a commitment device, **the user at
10pm is trying to defeat the user at 9am.** They are motivated, they have physical control
of the client, they own the account, and they are not doing anything wrong by trying.
Designing as if the account holder were trusted produces a feature that is decorative.

Ranked by how much they can do:

| Adversary | Capability | What stops them |
|---|---|---|
| **The account holder** | Owns the device and account; can read app storage, install a proxy CA, replay traffic, and edit any file the app writes | Server decides; signed attestation; tokens never reach their device (§4) |
| A partner acting in bad faith | Holds one valid token; may share it | One token = one vote, single-use, non-transferable in effect (§5) |
| Someone with a leaked link | Whatever that token can still do | Single-use, expiring, scope-limited to one vote on one request (§5, §14) |
| A stranger on the internet | Can hit public endpoints | 256-bit tokens, default-deny RLS, no enumerable IDs, rate limits (§13, §15) |
| A network attacker | TLS-protected path | TLS + pinned signing key on the grant path (§8) |

What we explicitly do **not** defend against: a jailbroken device running a patched binary.
A user who recompiles Earned to ignore its own ledger has left the product, not broken it.
NORTHSTAR §33 already says Earned never claims to be inescapable; this is that, restated at
the client boundary.

### 2.1 The finding that decides the whole design

**If the user's device sends the approval links, the user has the approval links.**

The obvious MVP — the app opens a share sheet with five links, one per partner — hands the
account holder every token needed to approve their own request. Five taps in Safari, and the
Accountability Override becomes a Free Override with extra steps. No amount of token
hardening fixes this, because the token would be doing exactly what it was designed to do,
for someone holding it legitimately.

So delivery has to bypass the requester's device:

> **The server sends the links. The device that made the request never receives a token.**

The app posts a request. The server holds the partner contact details, mints one token per
partner, sends each one directly (SMS or email), and returns to the app only a request id
and a count of recipients. This is not a hardening measure — it is the difference between
the feature working and not working, and it has consequences (partner phone numbers become
stored PII, SMS costs money, partners need to consent first) that are carried through the
rest of this document rather than wished away.

The alternative — accept that a determined user can self-approve, and treat accountability
as an honour-system nudge — is a legitimate product position, but it is a *different
product*, and it should be chosen deliberately if it is chosen. See decision **D1**.

---

## 3. What is authoritative, and what is a copy

| Thing | Authority | Notes |
|---|---|---|
| Commitments, gates, progress, hardening, debt | **Device ledger** | Unchanged. Offline-first, replay-verified |
| Solo Override friction and its clock | **Device ledger** | Unchanged. Deliberately needs no network — the last escape route must never depend on our uptime |
| Accountability partners (who they are, contact details, consent) | **Server** | Cannot live on the device: it is who we are allowed to text |
| Override requests as a *networked artifact* | **Server** | The request row, its recipients, its tokens, its expiry |
| Votes | **Server** | Only ever written by the vote endpoint |
| Whether the threshold was met | **Server** | Decided atomically inside the vote transaction (§7) |
| The *effect* of a grant on the commitment | **Device ledger** | The server decides the override happened; the ledger decides what that means for the Gate |

That last row matters. We are not moving the domain model to the server. The server answers
exactly one question — *did enough of the right people say yes?* — and the ledger keeps
owning what an override does to a commitment. That keeps the engine testable, offline, and
in one place.

---

## 4. Data model

Sketch, not final DDL. Postgres/Supabase. All timestamps `timestamptz`.

```sql
-- Who the requester is. Thin on purpose (§34 minimum knowledge).
create table account (
  id                uuid primary key default gen_random_uuid(),
  apple_user_id     text unique not null,     -- Sign in with Apple subject
  display_name      text not null,            -- shown to partners; first name is enough
  created_at        timestamptz not null default now(),
  deleted_at        timestamptz
);

-- An accountability partner. Contact details are the most sensitive thing we hold.
create table partner (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references account(id) on delete cascade,
  display_name      text not null,            -- as the requester labelled them
  channel           text not null check (channel in ('sms','email')),
  contact           text not null,            -- encrypted at rest; never returned to any client
  consented_at      timestamptz,              -- null until they opt in (§12)
  revoked_at        timestamptz,
  created_at        timestamptz not null default now(),
  unique (account_id, channel, contact)
);

-- The request as a networked artifact.
create table override_request (
  id                  uuid primary key default gen_random_uuid(),
  account_id          uuid not null references account(id) on delete cascade,
  client_request_id   uuid not null,          -- the ledger's OverrideRequest.id
  commitment_id       uuid not null,          -- opaque to the server
  approvals_required  int  not null check (approvals_required between 1 and 5),
  state               text not null default 'open'
                        check (state in ('open','granted','cancelled','moot','expired')),
  requested_at        timestamptz not null,
  expires_at          timestamptz not null,
  resolved_at         timestamptz,
  created_at          timestamptz not null default now(),
  unique (account_id, client_request_id)      -- idempotent creation
);

-- Frozen at request time. Never updated (§6).
create table override_request_snapshot (
  request_id  uuid primary key references override_request(id) on delete cascade,
  payload     jsonb not null,
  created_at  timestamptz not null default now()
);

-- One row per partner per request. This row *is* the vote.
create table override_request_recipient (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references override_request(id) on delete cascade,
  partner_id    uuid not null references partner(id),
  token_hash    bytea not null,               -- sha256(raw token); raw is never stored
  delivered_at  timestamptz,
  delivery_error text,
  expires_at    timestamptz not null,
  vote          text check (vote in ('approve','deny')),
  voted_at      timestamptz,
  unique (request_id, partner_id),            -- one partner, one vote, structurally
  unique (token_hash)
);

-- Append-only audit. Carries no PII: addresses are hashed with a rotating salt.
create table override_request_event (
  id           bigserial primary key,
  request_id   uuid not null references override_request(id) on delete cascade,
  kind         text not null,                 -- created | delivered | viewed | voted | resolved | …
  at           timestamptz not null default now(),
  recipient_id uuid,
  detail       jsonb,
  ip_hash      bytea,
  ua_hash      bytea
);
```

Two things worth noticing:

- **`unique (request_id, partner_id)`** makes "one partner, one vote" a property of the
  schema rather than of a code path that could be forgotten. `validateFreshVote` in
  EarnedKit is the same rule; here it is enforced by Postgres.
- **The commitment id is opaque to the server.** It stores a uuid so the app can correlate;
  it never learns what the commitment is except through the snapshot the requester chose to
  send.

---

## 5. Token design

- **32 bytes from a CSPRNG**, base64url-encoded (43 characters). 256 bits — guessing is not
  a threat model, it is arithmetic.
- **The database stores `sha256(token)`.** A database leak yields hashes, not working links.
  Lookup is by hash, so it is an index probe, not a scan.
- **The URL contains only the token**: `https://<host>/a/<token>`. No request id, no partner
  id, no account id, nothing incrementable. There is no `?request=123` to change to `124`,
  because there is no request id in the URL at all.
- **One token → one recipient row → one request → one vote.** Scope is structural: a token
  cannot be pointed at a different request because it *is* the recipient row.
- **Single-use.** Once `vote` is non-null the token stops accepting votes. Re-opening the
  link shows the outcome (§7) rather than erroring — idempotent, not fragile.
- **Expiring.** `expires_at` on both the recipient and the request; the shorter wins.
- **Revocable.** Cancelling or mooting a request invalidates every token on it immediately.
- **Hash nulled on resolution**, so a resolved request's leaked link is inert even against a
  future bug.

The token is a bearer credential for exactly one action on exactly one artifact, and it dies
after that action. That is the whole design.

---

## 6. The snapshot is a contract artifact

When a partner opens the link, they must see **what they were asked to approve**, not what
the commitment looks like now. If Patrick logs 12 more minutes after asking, the page must
still say 18/30 — otherwise the human is answering a question nobody asked.

`override_request_snapshot.payload` is written once, at creation, and never updated:

```json
{
  "requester_display_name": "Patrick",
  "commitment_title": "Run 30 minutes",
  "requirement": "30 minutes of any workout",
  "progress": { "achieved": 18, "required": 30, "unit": "minutes" },
  "deadline": "2026-08-24T22:00:00Z",
  "requested_at": "2026-08-24T21:12:04Z",
  "approvals_required": 2,
  "reliability_30d": { "completed": 8, "of": 10, "override_requests": 2, "missed": 1 },
  "reason": "Knee started bothering me."
}
```

This is the same instinct as the event ledger: a request is a historical fact, and facts do
not get retconned. It is also a privacy control — the snapshot is an explicit, reviewable
list of everything a partner can ever see, rather than a live query that might one day
return more than intended.

**Known gap, stated plainly:** the reliability numbers are computed by the requester's
device, because the server has no ledger. A user who tampered with their local ledger could
present flattering numbers. There is no fix short of server-side ledger state; the honest
interim options are to label the figures as self-reported on the partner page, or to accept
it silently. See **D6**.

---

## 7. Voting, and what happens when two people tap at once

One endpoint: `POST /a/:token/vote` with `{"vote": "approve" | "deny"}`. It is an edge
function using the service role. There is no path by which an anonymous client touches these
tables directly (§15).

The entire vote — record it, recount, decide — happens in **one transaction**:

```sql
begin;
  select r.id, r.state, r.approvals_required, r.expires_at, rc.id as recipient_id, rc.vote
    from override_request_recipient rc
    join override_request r on r.id = rc.request_id
   where rc.token_hash = $1
     for update;                     -- serialises concurrent voters on this request

  -- guards, each returning its own outcome page rather than a generic error:
  --   no row                        → invalid link
  --   rc.vote is not null           → already voted (show prior outcome)
  --   r.state <> 'open'             → resolved / cancelled / moot
  --   now() > least(rc.expires_at, r.expires_at) → expired

  update override_request_recipient set vote = $2, voted_at = now() where id = ...;

  -- decide, inside the same transaction
  update override_request
     set state = 'granted', resolved_at = now()
   where id = ...
     and state = 'open'
     and (select count(*) from override_request_recipient
           where request_id = ... and vote = 'approve') >= approvals_required;
commit;
```

`for update` on the request row means concurrent approvals serialise. Two partners tapping
approve at the same instant on a 2-of-5 request produce exactly one transition to `granted`,
and the `and state = 'open'` guard means a request can never double-resolve even if a later
vote arrives. The count is taken *after* the insert, inside the lock, so there is no
read-modify-write window.

Late votes on an already-granted request are recorded (`vote` is set) but change nothing.
That is deliberate: the roster should show who actually responded, not just who responded
before the threshold happened to be crossed.

---

## 8. How the outcome reaches the app, and becomes a ledger event

The app learns the outcome by **polling on foreground and on a silent push**, authenticated
as the account. It does not receive votes; it receives a decision:

```json
{
  "client_request_id": "…",
  "decision": "granted",
  "decided_at": "2026-08-24T21:31:08Z",
  "roster": [
    { "partner_display_name": "Mom",  "vote": "approve", "at": "…" },
    { "partner_display_name": "Dave", "vote": "approve", "at": "…" }
  ],
  "attestation": "ed25519:…"
}
```

The `attestation` is an Ed25519 signature over `(client_request_id, decision, decided_at,
roster)` by a key whose public half is **compiled into the app**. This is not paranoia about
the network; it is §2 again. The account holder can install a CA profile on their own phone
and MITM their own traffic. Without a pinned signature, forging a grant is a proxy rule.
With one, it requires the private key.

The app verifies the signature and appends **one new event**:

```swift
case accountabilityOverrideGranted(
        requestID: UUID, decidedAt: Date, roster: [PartnerVote], attestation: Data)
```

Design notes on that event:

- **It is a new case, not a reuse of `overrideApprovalRecorded`.** The app stops emitting
  approval events entirely. Threshold arithmetic is no longer something a client performs;
  it consumes a decision.
- **The roster travels with the event** so the ledger can still answer *why* — "Mom and Dave
  approved at 9:31pm" — without re-deriving anything. Same principle that made
  `freeOverrideEarned` carry its own identity: state must be a pure function of history, and
  history has to contain enough to be that function.
- **`overrideApprovalRecorded` stays in the reducer** so existing histories replay literally.
  We have done this once already with v1's `restrictedAppsChanged`; the rule is that we
  never rewrite what was written, we stop writing it.
- **Ledger schema goes to v3**, with a golden fixture for a v2 file containing the old
  approval events, exactly as v1→v2 was pinned.

An attested grant is idempotent: replaying it against an already-resolved request is
rejected by `activeRequest`, which is the existing behaviour and wants a test.

---

## 9. Offline

The device must never be *more* locked because our server is unreachable, and never *less*
locked because it is.

| Situation | Behaviour |
|---|---|
| Offline when requesting | Request cannot be created. Say so plainly; the Solo route is unaffected |
| Offline while a request is open | Request stays visibly pending. Nothing changes locally |
| Grant happens while offline | Applied on next successful sync. The user stays restricted until then |
| Offline forever | The accountability window elapses on the local clock and **Solo unlocks normally** |

That last row is the important one. The Solo Override's clock is local, its friction is
local, and its availability depends on `requestedAt` — not on us. A user is never trapped by
our downtime, which is the correct behaviour for a product that takes away access to
someone's phone.

The cost is honest and worth stating: a grant can sit undelivered while the user is
restricted, and they will experience that as Earned being slow to let them out. Showing
"waiting to confirm — 2 approvals received" is misleading (we do not know that offline);
"waiting to hear back" is accurate.

---

## 10. When the request stops mattering

The engine already does the right thing locally: completing the workout moots an open
request (`testWorkoutMootsOpenRequest`). Networked, that has to propagate:

- App completes or cancels → `POST /requests/:id/close` → state `moot` or `cancelled`,
  every token invalidated, and — worth doing — a courtesy text to partners who were asked:
  *"Patrick finished the run. No action needed."* Partners who were interrupted deserve to
  know it resolved.
- If the app is offline and cannot close it, a partner may still approve. The grant then
  arrives for an already-resolved commitment and is **rejected by the reducer**, which is
  correct but means the partner saw a stale page. Acceptable; it should not be silent — the
  outcome page should say the request had already been resolved by the time we processed it.

---

## 11. What a partner can see

Everything, and only, in the snapshot:

**Yes:** requester's display name · commitment title and requirement · progress at request
time · deadline · the 30-day reliability triple · the optional reason · how many approvals
are needed.

**No:** restricted app selections (Earned itself cannot read them — they are opaque tokens)
· any HealthKit data beyond the progress figure for *this* commitment · other commitments ·
other partners' identities or votes · the requester's contact details, location, device, or
account identifiers · anything about past requests.

Two deliberate omissions:

- **Partners do not see the running tally.** "1 of 2 approvals so far" leaks that another
  partner voted and invites coordination or diffusion of responsibility. Each partner
  answers on the merits. See **D5**.
- **Partners do not see each other.** They may all be family and know perfectly well who
  else is on the list, but that is the requester's information to share, not ours.

The reason field is optional by design (§24: *a user is never required to explain why they
need an Override*) and is free text written by the requester — it is rendered as text, never
as markup, and it is the one field where a user could put something they later regret. It
inherits the snapshot's retention (§12).

---

## 12. Consent, contact details, and retention

We are about to text people who never installed anything. That deserves care.

- **Partner consent is a precondition.** Nominating someone sends one message: *"Patrick
  added you as an accountability partner on Earned. If he asks to be let out of a
  commitment, you'll get a text. [I'm in] [No thanks]."* Until `consented_at` is set, that
  partner receives no request. "No thanks" sets `revoked_at` permanently, and every message
  carries an opt-out. This is both the decent thing and the compliant thing.
- **Contact details are encrypted at rest** and never returned to any client — not to the
  partner's page, and not to the requester's app, which only ever sees the display name it
  supplied.
- **Retention.** Snapshots purge 90 days after resolution. `token_hash` is nulled on
  resolution. Audit rows keep hashed addresses with a rotating salt and no message bodies.
  Deleting an account cascades to partners, requests, snapshots and recipients.
- **Deletion is not an escape hatch.** Worth a moment: once obligations are server-side,
  "delete my account" and "delete my debt" become the same button, and NORTHSTAR §33 says
  they must not be. The honest resolution is that account deletion is real and complete, but
  is not instant — a stated cooling-off (say 7 days, with the obligations visible and the
  Solo route open the whole time) makes deletion a right rather than a shortcut. Flagged
  here because it is a product decision, not an engineering one; it is **D10** and it does
  not block the approval feature.

---

## 13. Abuse and rate limits

| Vector | Control |
|---|---|
| Token guessing | 256-bit tokens; constant-time hash lookup; per-IP limits on `/a/*` |
| Vote replay | Single-use recipient row; idempotent response |
| **Partner fatigue as a bypass** | Cap open requests (already 1 per commitment) *and* requests per rolling 24h per account. A user who spams five partners hourly until someone taps approve to make it stop has found a real escape route |
| Using Earned as an SMS relay | Send only to consented partners; cap messages per account per day; the reason field is the only user-controlled text and it goes only to consented recipients |
| Enumeration | No sequential public identifiers anywhere; no endpoint accepts a request id from an unauthenticated caller |
| Cost abuse | Hard daily ceiling on outbound messages per account, alarmed |

Partner fatigue is the one I would flag to a reviewer as under-thought. It is not a security
bug; it is a way to convert "two humans must agree" into "one human must get annoyed," and
rate limits are a blunt answer to it.

---

## 14. What a leaked link actually gets you

Concretely, because this is the question a reviewer should ask:

An attacker with one leaked, unused, unexpired token can cast **one vote** on **one
request** — and see that request's snapshot: a first name, a commitment title, a progress
figure, a deadline, three reliability numbers, and an optional reason.

They cannot: discover the account, find other requests, vote twice, vote after resolution,
vote after expiry, learn any contact detail, learn who else was asked, or affect anything
outside that one request.

If the threshold is 1, one leaked link is one override. That is inherent to the mechanism —
the same is true of the SMS itself — and is a reason the default threshold should be ≥ 2.

---

## 15. Supabase posture

- **RLS on every table, default deny, no exceptions.** `anon` and `authenticated` roles get
  no policy at all on `override_request*` or `partner`. The only reader/writer is the edge
  function's service role.
- The partner page is **server-rendered by the edge function**, not a client app holding a
  Supabase key. No Supabase credential is ever shipped to a browser on this path.
- The app authenticates as its account and may read only its own requests, via a policy
  keyed on `auth.uid()`.
- **Migrations are checked into `backend/migrations/`** and run in CI. A schema that only
  exists in the dashboard is a schema nobody can review.
- Secrets (signing key, SMS provider credentials, encryption key) live in the platform's
  secret store, never in the repo. The signing key's public half is in the app; its private
  half exists only server-side.

---

## 16. Tests I would require before this ships

Not a wish list — these are the ones whose absence would make me object.

**Backend**
- Concurrent approvals: N simultaneous votes on a threshold-2 request → exactly one
  `granted` transition, exactly one grant delivered.
- A vote arriving after resolution: recorded, changes nothing, no second grant.
- Second vote from the same recipient: rejected, prior outcome shown.
- Expired token; expired request; cancelled request; moot request — each its own outcome.
- Forged token, truncated token, token from a different request: indistinguishable failure.
- Voting when the request was created by a different account: impossible by construction, tested anyway.
- Denials do not consume approval slots and do not resolve (subject to **D2**).
- Idempotent request creation: the same `client_request_id` twice creates one request.
- RLS: an `anon` client can read nothing from any of these tables.

**Client / EarnedKit**
- An `accountabilityOverrideGranted` with a bad signature is refused and never appended.
- A valid grant for an already-resolved commitment is rejected by the reducer.
- v2 ledgers containing `overrideApprovalRecorded` still replay identically (golden fixture).
- Grant replays deterministically — the same state twice, identity included. We have already
  been bitten by exactly this in `EnforcementBypass`.
- Offline: the Solo window still opens on schedule with no network.

---

## 17. Open decisions that need a human

These are product calls. Proposed answers are recommendations, not choices already made.

| # | Decision | Proposed | Why it matters |
|---|---|---|---|
| **D1** | Who sends the approval links — the server, or the user's device via a share sheet? | **Server** | §2.1. Device delivery hands the account holder every token. This is the decision the feature stands on, and it costs money and PII |
| **D2** | Does a denial veto? Alice approves, Bob denies, Claire approves, threshold 2 — granted? | **Granted.** Denial is not a veto unless explicitly configured | Otherwise "2 approvals required" silently means something else. A `vetoAllowed` flag can come later |
| **D3** | Can a partner change their vote? | **No. First vote is final** | The same contract logic the product applies to the user. Also removes a whole class of race |
| **D4** | Can the requester cancel an open request? | **Yes, before resolution**, recorded in the ledger and the audit log | "Screw it, I'll do the last 12 minutes" is the outcome we want to make easy |
| **D5** | Do partners see the running tally? | **No** | Leaks other partners' participation; invites diffusion of responsibility |
| **D6** | Is the reliability snapshot labelled as self-reported? | **Yes**, until the ledger is server-side | It is computed on the requester's device. Saying so costs one line and is true |
| **D7** | How long does a request stay open? | **48 hours**, then `expired`. Solo remains available throughout | Long enough for a sleeping partner, short enough that a stale link is not a standing key |
| **D8** | Is partner consent required before the first request? | **Yes** | We are texting people who never installed anything |
| **D9** | Minimum approvals threshold | **Floor of 2 where more than one partner exists** | A threshold of 1 makes one leaked link one override (§14) |
| **D10** | Does account deletion delete outstanding obligations? | Deletion is real but **not instant** — a cooling-off period | Otherwise "delete account" becomes the cheapest override in the product (§12) |

Also worth confirming rather than assuming: **partner approvals stay valid after the Solo
window opens** — the window only unlocks Solo as an *additional* route, it does not close the
accountability one. That is the current engine's behaviour and I would keep it.

---

## 18. Build order, if this is approved

1. **Migrations and RLS**, in the repo, in CI. Nothing else until a schema exists that can be reviewed.
2. **Sign in with Apple** and the `account` row. Every other table hangs off it, and it is the
   first real step toward the reinstall hole in NORTHSTAR §33.
3. **Partners and consent** — nominate, confirm, revoke. No requests until this works.
4. **Request creation + snapshot + delivery**, with the vote endpoint stubbed.
5. **The vote endpoint and the partner page**, with the concurrency tests written first.
6. **Attested grants + `accountabilityOverrideGranted` + ledger v3.**
7. **Close/moot propagation and the courtesy message.**

Steps 1–3 are worth doing even if the approval flow slips, because they are the same
foundation the deletion problem needs.

---

## 19. What this does not fix

Stated so it is not discovered later:

- **Reinstalling still erases what is owed.** This design puts *accountability* on the
  server, not the ledger. Delete-and-reinstall remains the cheapest escape in Earned until
  commitment state is account-authoritative. Steps 1–2 above are the beginning of that, not
  the end of it.
- **Reliability figures are self-reported** (§6).
- **A patched client bypasses everything** (§2).
- **Partner identity is a phone number**, not a verified human. Nothing here proves the
  person who tapped approve is the person the requester meant. Making that stronger means
  invasive verification, which NORTHSTAR §33 explicitly declines.
