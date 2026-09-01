# Accountability Overrides — Architecture and Threat Model

v0.4 · August 2026 · **Milestones A and B are built. Later milestones are not.**

This is the design to red-team before any of it is written. It covers the Accountability
Override (NORTHSTAR §23–24) as a networked feature: what the backend owns, how approval
links are secured, what a partner can see, and what happens when things go wrong or
concurrent.

It is written to a deliberately higher bar than the rest of the repo, because this is the
first feature where **strangers' commitments, contact details and device restrictions pass
through our architecture**. Every design choice below is measured against two questions:

1. **Product integrity** — is this still Earned?
2. **Launch integrity** — would I be comfortable putting other people's data through this?

Decisions that are genuinely product calls are collected in [§21](#21-decisions) — settled
ones and open ones kept apart, so nothing quietly becomes a default by being written down.

## What changed in v0.4

Written while building Milestones A and B. Two corrections and one new invariant.

| | |
|---|---|
| **Correction: §4.4's harder-only edits were wrong before hardening** | v0.2–v0.3 said the server accepts an envelope update only if every field is at least as hard, at all times. But EarnedKit permits *any* edit inside the correction window — that is what the window is for. A user fixing "10 miles" to "10 km" two minutes after committing would have had the edit accepted by the ledger and refused by the server, stranding the commitment unregistered. The restriction also defended nothing: an unhardened commitment can simply be cancelled and remade. Monotonicity now lives exactly where EarnedKit puts it — at the hardening instant, where the envelope freezes absolutely |
| **New: invariant 22, a contract may not be born impossible** | A roster is drawn only from partners who have already consented, and a threshold may never exceed it. See §4.5 |
| **New: `envelope_status`** | Registration returned a contract's standing at the moment of registration, and nothing re-read it. A roster member revoking afterwards would silently take the accountability route away while the app kept showing the answer it was given. There is now a read path, and the app uses it on every sync |
| Partner model completed | Normalisation, encryption, keyed blind index, consent tokens, global suppression, nomination and resend limits — §14, now built rather than described |

## What changed in v0.3

Patrick made the calls on every open decision from v0.2 except one. All are now recorded as
settled (§21.1) rather than proposed:

| # | Decision | Settled as |
|---|---|---|
| **S11** (was D7) | Request expiry | **24 hours**, not the proposed 48 — a tighter window was chosen deliberately over giving a slow partner more time |
| **S12** (was D9) | Default approvals threshold | **Default 2; a user may choose 1 before hardening, behind an explicit warning. Never silently mandatory** |
| **S13** (was D11) | Late envelope (hardened before the server saw it) | **Accountability route closed for that commitment; Solo remains** |
| **S14** (was D12) | Verified-partner tier | **The `kind` column is built now; not required at MVP** |
| **S15** (was D13) | Receipt window | **30 days**, then the link goes generic and the snapshot purges |
| **S16** (new) | A partner suppressed or revoked after a token was minted but before they voted | **Their vote still counts.** They were legitimately asked before withdrawing; suppression governs future contact, not a vote already in their hand |

**D10 (account deletion) stays open, deliberately.** Patrick chose not to have a placeholder
manufactured for it — it is a privacy/legal question, not a product preference, and nothing
in this document should be built against a guessed answer to it.

## What changed in v0.2

External review found one blocking flaw and several hardening gaps. All are addressed here:

| | |
|---|---|
| **Blocking: the server trusted the client for the *rules*** | v0.1 made the server authoritative for votes but let the request body carry `approvals_required` and the partner roster. A modified client could ask for a threshold of 1 against a contract that hardened at 2. Fixed by the **Contract Envelope** (§4) — the server now holds the accountability terms, frozen at hardening, and reads them from its own records at request time |
| Self-approval was overstated as solved | Server-side link delivery stops automatic self-receipt. It does not prove partners are distinct humans. Stated plainly in §2.2 and §23 |
| Token lifecycle contradicted itself | v0.1 both nulled `token_hash` on resolution *and* promised to show a prior outcome; and both refused votes on resolved requests *and* recorded them. Replaced with one coherent model in §6 |
| Encrypted contact could not be unique-indexed | Randomised encryption is not deterministic. Split into ciphertext plus a keyed blind index (§5, §14) |
| Raw signature bytes in permanent domain events | Moved to a boundary layer; the ledger records the semantic fact and a `serverGrantID` (§9) |
| One immortal compiled public key | Replaced with a signed, rotatable key set under an offline root (§10) |
| Threshold and deletion decisions over-settled | D9 revised to a default rather than a mandate; D10 returned to legal review (§21) |
| Consent had no suppression model | Global opt-out, nomination and resend limits, abuse reporting (§14) |
| No launch gate | New **Launch readiness gates** (§20) |

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
On Patrick's own phone that was fine — scaffolding for a state machine. Shipped to strangers
it is not a security weakness so much as **the feature not existing**: the escape route the
whole override ladder is built around would be a text field.

### The trust boundary, stated precisely

v0.1 said the server was authoritative for *outcomes*. That was not enough, because an
outcome is only meaningful relative to a rule, and the rule was still being supplied by the
adversary. The boundary is now:

> **The server independently holds the accountability terms of a hardened commitment, and
> independently decides whether an override request has met them. The device may propose a
> contract before it hardens, may report progress, and may record a decision. It may never
> state the threshold, name the voters, or conclude the outcome.**

Three separate things follow, and all three are now server-side: *what the rule is*
(§4), *who is allowed to vote* (§4), *whether the rule was met* (§8).

The ledger stays authoritative for gates, progress, hardening, debt and Solo Overrides, and
the app stays fully functional offline for all of it. This is a narrow, deliberate transfer
of exactly one decision and the inputs that decision depends on.

---

## 2. The adversary is the user

This is the unusual thing about Earned's threat model and it should be stated before any
table definitions, because it invalidates several designs that would otherwise look fine.

In a normal product, the user is who you protect. In a commitment device, **the user at
10pm is trying to defeat the user at 9am.** They are motivated, they have physical control
of the client, they own the account, and they are not doing anything wrong by trying.
Designing as if the account holder were trusted produces a feature that is decorative.

| Adversary | Capability | What stops them |
|---|---|---|
| **The account holder** | Owns the device and account; can read app storage, install a proxy CA, replay traffic, edit any file the app writes, and recompile the client | Server holds the terms (§4) and decides (§8); tokens never reach their device (§2.1); grants are signed (§9–10) |
| **The account holder, as their own partner** | Can nominate contacts they also control | Partially mitigated, **not solved** (§2.2) |
| A partner acting in bad faith | Holds one valid token; may share it | One token = one vote, single-use, scope-bound (§6) |
| Someone with a leaked link | Whatever that token can still do | Single-use, expiring, one vote on one request (§6, §17) |
| A stranger on the internet | Can hit public endpoints | 256-bit tokens, default-deny RLS, no enumerable IDs, rate limits (§16, §18) |
| A network attacker | TLS-protected path | TLS plus a pinned, rotatable key set on the grant path (§9–10) |

What we explicitly do **not** defend against: a jailbroken device running a patched binary.
A user who recompiles Earned to ignore its own ledger has left the product, not broken it.
NORTHSTAR §33 already says Earned never claims to be inescapable; this is that, restated at
the client boundary. Note what the Contract Envelope changes here, though: a patched client
can ignore its *own* ledger, but it cannot talk the *server* into granting an override the
contract did not allow. The blast radius of a patched client shrinks to the device.

### 2.1 The finding that decides delivery

**If the user's device sends the approval links, the user has the approval links.**

The obvious MVP — the app opens a share sheet with five links, one per partner — hands the
account holder every token needed to approve their own request. Five taps in Safari, and the
Accountability Override becomes a Free Override with extra steps. No amount of token
hardening fixes this, because the token would be doing exactly what it was designed to do,
for someone holding it legitimately.

So delivery bypasses the requester's device:

> **The server sends the links. The device that made the request never receives a token.**

The app posts a request. The server mints one token per partner from its own roster, sends
each directly by SMS or email, and returns to the app only a request id and a recipient
count. This is settled (**S1**), and its consequences — partner contact details become
stored PII, SMS costs money, partners must consent first — are carried through §14 rather
than wished away.

### 2.2 What server delivery does *not* prove

v0.1 implied this closed the self-approval hole. It does not, and the document should not
have read that way.

Server delivery guarantees only that **the requester does not automatically receive the
tokens**. It says nothing about who is on the other end of a phone number. A requester can
nominate:

- a second email address they own, or a `+tag` alias of their own address
- a spare SIM, a work number, a VoIP number
- a family member's device they have access to

and then simply go and read the message. There is no mechanism here — and, given NORTHSTAR
§33's refusal of invasive identity verification, no mechanism we are willing to build — that
distinguishes "my mother" from "my other phone."

**Honest framing:** anonymous SMS/email partners are an **accountability layer, not a proof
of unique-human identity.** The friction they create is social and physical (the message
goes somewhere; someone might see it; you have to go and fetch it), and that friction is
real and probably sufficient for the ordinary case. It is not a security boundary and must
never be described as one.

Mitigations worth building, none of which is a fix:

- **Reject contacts the account itself has verified.** Once Sign in with Apple exists we
  know the account's own email; if we ever verify a phone number for the account, that too.
  Nominating your own verified contact is refused outright.
- **Two partner tiers, distinguished in the data model from day one**: `unverified_contact`
  (an SMS/email address that consented) and, later, `earned_user` (a partner with their own
  authenticated Earned account). A future policy could require at least one verified partner
  in a roster, or weight them differently. Building the distinction now costs one column;
  retrofitting it costs a migration and a product conversation. Settled as **S14**: build it now, require nothing at MVP.
- **Normalisation deliberately does not merge aliases.** `me+1@x` and `me+2@x` stay distinct
  addresses (§14), because merging them would wrongly suppress legitimate contacts. This is
  a conscious trade that leaves the alias vector open.

This limitation is repeated in §23 so that it survives skim-reading.

---

## 3. What is authoritative, and what is a copy

| Thing | Authority | Notes |
|---|---|---|
| Commitments, gates, progress, hardening, debt | **Device ledger** | Unchanged. Offline-first, replay-verified |
| Solo Override friction and its clock | **Device ledger** | Unchanged. Deliberately needs no network — the last escape route must never depend on our uptime |
| **Accountability terms of a hardened commitment** | **Server** (Contract Envelope, §4) | Threshold, roster, window, deadline, hardening instant. New in v0.2 |
| Accountability partners: identity, contact, consent, suppression | **Server** | Cannot live on the device: it is who we are allowed to contact |
| Override requests as a networked artifact | **Server** | The request row, its recipients, its tokens, its expiry |
| Votes | **Server** | Only ever written by the vote endpoint |
| Whether the threshold was met | **Server** | Decided atomically inside the vote transaction (§8) |
| Progress and reliability figures shown to partners | **Device** | The server has no HealthKit and no ledger. Self-reported, and labelled as such (§7, D6) |
| The *effect* of a grant on the commitment | **Device ledger** | The server decides the override happened; the ledger decides what that means for the Gate |

We are still not moving the domain model to the server. The server answers two questions —
*what did this contract require?* and *did enough of the right people say yes?* — and the
ledger keeps owning what an override does to a commitment.

---

## 4. The Contract Envelope

The fix for the blocking flaw. A small, server-held record of the parts of a commitment the
server must enforce independently, because the client is adversarial about exactly those
parts.

### 4.1 What is in it

```jsonc
{
  "account_id":          "…",
  "commitment_id":       "…",      // opaque uuid; the server never learns the Gate's contents
  "plan_id":             "…|null", // set for a plan-generated occurrence
  "title":               "Run 30 minutes",
  "created_at":          "2026-08-24T08:00:00Z",
  "eligible_from":       "2026-08-24T08:00:00Z",
  "deadline":            "2026-08-24T10:00:00Z",
  "correction_window":   7200,     // seconds, as configured
  "approvals_required":  2,
  "accountability_window": 1800,   // seconds before Solo unlocks
  "partner_ids":         ["…", "…", "…"],
  "version":             1,        // monotonic per commitment
  "policy_digest":       "sha256:…"
}
```

`title` is included deliberately. It is destined for partners regardless, so storing it at
hardening costs no additional disclosure — and it removes a lying vector, since a client
that supplied the title at request time could re-narrate the commitment to make the ask more
sympathetic.

**Explicitly excluded**, and the exclusions are the point:

- HealthKit workouts, workout history, any health metric
- Screen Time / FamilyControls tokens, restricted app identities, any restriction profile
- hydration state, streaks, Free Override balances, debt
- reward eligibility — the server has no use for it; Free Overrides are spent locally and
  never create a request
- anything about other commitments beyond what a `plan_id` implies

The server learns *that* an obligation exists, when it hardened, when it is due, and who may
vote on letting the user out of it. It does not learn what the user actually does.

`policy_digest` is `sha256` over the canonical JSON of the enforceable fields
(`created_at`, `eligible_from`, `deadline`, `correction_window`, `approvals_required`,
`accountability_window`, sorted `partner_ids`). It gives client and server a cheap way to
agree they hold the same contract, and gives the grant receipt a way to name which version
was overridden.

### 4.2 When it is created

**At commitment creation, not at hardening.** This is a change from the obvious design and
it matters.

If the envelope were only sent when the contract hardened, the client would be asserting
"this is now hardened, on these terms" — one adversarial assertion replacing another.
Sending at creation lets the server **compute hardening itself**, using the same rule the
engine uses:

```
hardens_at = created_at + min(correction_window, (deadline - created_at) × 0.125)
```

`Commitment.hardeningFraction` is a constant in both places. The server therefore never asks
the client whether a commitment is hardened; it knows.

For plan occurrences, `created_at` is the *plan's* creation instant (that is already how the
engine works — a plan hardens as a whole), so all of a plan's envelopes carry the same
`created_at` and the same `hardens_at`, and each carries its own `eligible_from`, `deadline`
and `plan_id`.

### 4.3 Can it change after hardening?

**No.** At `hardens_at` the envelope freezes. Every subsequent mutation attempt is rejected,
which is the Monotonic Commitment Principle enforced on a machine the user does not control.

Two exceptions, neither user-driven:

- **A partner revokes consent, or is globally suppressed.** They drop out of live rosters.
  This **never lowers `approvals_required`.** If the reachable roster falls below the
  threshold, the accountability route becomes unavailable for that commitment and the app is
  told plainly; Solo remains. Making the escape harder because a partner withdrew is the
  correct direction.
- **The user removes a partner from their account entirely** (a privacy right — "stop
  texting my ex"). Same handling: the roster shrinks, the threshold does not move. Partners
  may never be *added* to a frozen envelope, because adding a contact you control is the
  Sybil move of §2.2 in slow motion.

### 4.4 Edits before hardening

**Corrected in v0.4.** Earlier revisions of this document said the server accepts an update
only if every field is at least as hard. That was wrong, and building it proved it wrong.

EarnedKit permits *any* edit while `now < hardensAt` — the correction window exists precisely
so a commitment made in haste can be fixed. A server that refused an easing edit the ledger
had already accepted would strand the commitment: accepted locally, refused remotely, stuck
as unregistered forever. And it defended nothing, because before hardening the user can
cancel the commitment and make a new one.

So before hardening the envelope accepts any valid terms, subject only to:

- `version` must increase (ordering and idempotency, not monotonicity)
- `plan_id` may not change — that is structural, not a term
- the roster rules of §4.5, which apply at every version

**At `hardens_at` the envelope freezes absolutely.** No field changes, in either direction,
ever again. That is where monotonicity lives, and it is where EarnedKit puts it too. The
server remains a second independent enforcer of the Monotonic Commitment Principle — it is
simply enforcing the same boundary the ledger does rather than a stricter one nobody asked
for.

### 4.5 How the server verifies a request against it

`POST /requests` carries only `{client_request_id, commitment_id, progress, reason?}`.
It does **not** carry a threshold, a roster, a window, or a deadline. The server:

1. Loads the envelope for `(account_id, commitment_id)`. **No envelope → refuse.**
2. Requires `now >= hardens_at` (server-computed). Not yet hardened → refuse; the user can
   still edit or cancel the commitment freely, which is the cheaper and more honest path.
3. Requires the envelope was **registered before it hardened** (§4.7).
4. Requires no other open request for this commitment.
5. Takes `approvals_required`, `accountability_window` and the roster **from the envelope**.
6. Filters the roster to partners who are consented, unsuppressed and not revoked. If fewer
   than `approvals_required` remain → refuse with a specific reason the app can explain.

**Invariant 22, enforced at registration rather than at request time.** A roster may contain
only partners whose status is `active` — consented, unsuppressed, unrevoked — and
`approvals_required` may not exceed the roster's size. Hardening "2 of Mom, Dave and Chris"
while Dave has never answered would create a contract whose accountability route was dead
from birth, and the user would discover it at the exact moment they needed a way out.

An **empty roster is exempt from the threshold half of the rule**, and is not the same
failure. It is every commitment made before anyone has been nominated — a commitment with no
accountability route, which the receipt reports plainly rather than pretending otherwise.
The deception invariant 22 exists to prevent is a roster that *looks* sufficient and isn't.

A partner who withdraws **after** the contract is registered is untouched by this: the
threshold stands, the roster stays as agreed, and `accountability_available` goes false. That
asymmetry is deliberate — Earned refuses to author a way out that never worked, and refuses
to rewrite one that reality made harder.
7. Freezes the snapshot (§7), mints one token per surviving partner, and sends.

The client's influence over the outcome is now limited to the progress figures and the
optional reason — both of which are *shown to humans who decide*, not inputs to an automatic
rule. That is the difference between advisory data and load-bearing data, and it is the
whole point of the envelope.

### 4.6 Plan occurrences

Each occurrence gets its own envelope, sharing the plan's `created_at` and `hardens_at`,
carrying its own `eligible_from`, `deadline` and `plan_id`. A four-week, three-day plan
registers twelve envelopes at plan creation.

**Plan cancellation** is the one legitimate easing operation, and the server can verify it
without trusting the client, because the rule is expressible in envelope fields alone. The
engine withdraws an occurrence when

```
!isHardened(at: now) || eligible_from > now
```

Both terms are server-computable. So `DELETE /plans/:id` withdraws exactly the envelopes
that satisfy that predicate and leaves the rest standing — the same answer the ledger
reaches, reached independently.

### 4.7 Offline at creation: the late envelope

If the device is offline when a commitment is created, the envelope is queued and sent on
reconnect. If it arrives **after** the commitment's computed `hardens_at`, the server cannot
distinguish an honest offline creation from a contract fabricated with hindsight — a user
could sit offline through the correction window and then register terms chosen to be easy.

Settled as **S13**, though it has a real UX cost:

> A late envelope is **accepted and stored, but permanently marked `late`, and the
> accountability route is unavailable for that commitment.** Solo remains available on the
> local clock, as always.

This fails safe: being offline can never *open* an escape route, only close one. The cost is
that a commitment created on a plane cannot use partners. The app says so at creation time
("this one isn't registered yet — if it hardens before you're back online, you'll only have
the Solo route"), which is honest and gives the user a chance to wait.

The rejected middle path — accept late envelopes if they are at least as hard as the
account's last-synced default policy — is weaker than it sounds, because the default is
itself client-proposed and can be pre-hardened in advance of the trick.

### 4.8 Can an override be requested before the envelope exists?

**No.** There is no fallback, no grace mode, and no "assume the default." The absence of an
envelope is never permission. The app must present this as a stated limitation, not an
error: *"Earned hasn't registered this commitment yet. You can still use the Solo
route."*

### 4.9 What this buys later, on reinstall

The envelope is the first server-authoritative fragment of the contract, and it is the piece
NORTHSTAR §33's reinstall hole needs first. After a delete-reinstall-and-sign-in, the server
can already say: *you have three hardened obligations, with these titles and deadlines.*

What it **cannot** yet say is whether they were completed, because completion is HealthKit
and the ledger, both client-side. So the envelope makes reinstall **detectable, not yet
ineffective** — the app can restore the obligations and let the user assert what they
finished, which is better than silence and short of enforcement. Closing it properly needs
resolution events server-side, which is a later increment and a bigger privacy conversation
(it means the server learns what you completed and when). Not proposed here.

---

## 5. Data model

Sketch, not final DDL. Postgres / Supabase. All timestamps `timestamptz`.

```sql
create table account (
  id                uuid primary key default gen_random_uuid(),
  apple_user_id     text unique not null,     -- Sign in with Apple subject
  display_name      text not null,            -- shown to partners; first name is enough
  verified_email_lookup bytea,                -- blind index of the account's own address (§2.2)
  created_at        timestamptz not null default now(),
  deleted_at        timestamptz
);

-- An accountability partner. Contact details are the most sensitive thing we hold.
create table partner (
  id                  uuid primary key default gen_random_uuid(),
  account_id          uuid not null references account(id) on delete cascade,
  display_name        text not null,          -- as the requester labelled them
  channel             text not null check (channel in ('sms','email')),
  kind                text not null default 'unverified_contact'
                        check (kind in ('unverified_contact','earned_user')),  -- §2.2
  contact_ciphertext  bytea not null,         -- AES-256-GCM, random IV; never returned to a client
  contact_lookup      bytea not null,         -- HMAC-SHA256(pepper, normalized contact) — §14.1
  lookup_key_version  int  not null default 1,
  consented_at        timestamptz,
  consent_asked_at    timestamptz,
  consent_resent_at   timestamptz,
  revoked_at          timestamptz,
  created_at          timestamptz not null default now(),
  unique (account_id, channel, contact_lookup)   -- deterministic, so this actually works
);

-- Global, cross-account opt-out. The minimum artifact needed to honour a refusal.
create table contact_suppression (
  contact_lookup     bytea not null,
  channel            text  not null check (channel in ('sms','email')),
  lookup_key_version int   not null default 1,
  reason             text  not null check (reason in ('optout','complaint','bounce','abuse')),
  suppressed_at      timestamptz not null default now(),
  primary key (contact_lookup, channel)
);

-- The accountability terms the server enforces independently (§4).
create table contract_envelope (
  account_id            uuid not null references account(id) on delete cascade,
  commitment_id         uuid not null,
  plan_id               uuid,
  title                 text not null,
  created_at            timestamptz not null,   -- the commitment's, not the row's
  eligible_from         timestamptz not null,
  deadline              timestamptz not null,
  correction_window     int  not null,          -- seconds
  approvals_required    int  not null check (approvals_required between 1 and 5),
  accountability_window int  not null,
  version               int  not null default 1,
  policy_digest         bytea not null,
  hardens_at            timestamptz not null generated always as (          -- server-computed
    created_at + least(
      make_interval(secs => correction_window),
      (deadline - created_at) * 0.125
    )) stored,
  first_seen_at         timestamptz not null default now(),
  is_late               boolean not null default false,   -- first_seen_at > hardens_at (§4.7)
  withdrawn_at          timestamptz,                      -- plan cancellation (§4.6)
  primary key (account_id, commitment_id)
);

create table contract_envelope_partner (
  account_id    uuid not null,
  commitment_id uuid not null,
  partner_id    uuid not null references partner(id),
  primary key (account_id, commitment_id, partner_id),
  foreign key (account_id, commitment_id)
    references contract_envelope(account_id, commitment_id) on delete cascade
);

-- The request as a networked artifact. Carries no policy — policy lives in the envelope.
create table override_request (
  id                  uuid primary key default gen_random_uuid(),
  account_id          uuid not null references account(id) on delete cascade,
  commitment_id       uuid not null,
  client_request_id   uuid not null,          -- the ledger's OverrideRequest.id
  envelope_version    int  not null,          -- which contract version this ran against
  approvals_required  int  not null,          -- COPIED FROM THE ENVELOPE, never from the client
  state               text not null default 'open'
                        check (state in ('open','granted','cancelled','moot','expired')),
  requested_at        timestamptz not null default now(),
  expires_at          timestamptz not null,
  receipt_expires_at  timestamptz not null,   -- §6
  resolved_at         timestamptz,
  unique (account_id, client_request_id),     -- idempotent creation
  foreign key (account_id, commitment_id)
    references contract_envelope(account_id, commitment_id)
);

-- Frozen at request time. Never updated (§7).
create table override_request_snapshot (
  request_id  uuid primary key references override_request(id) on delete cascade,
  payload     jsonb not null,
  created_at  timestamptz not null default now()
);

-- One row per partner per request. This row *is* the vote, and later the receipt.
create table override_request_recipient (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references override_request(id) on delete cascade,
  partner_id    uuid not null references partner(id),
  token_hash    bytea not null,               -- sha256(raw token); raw is never stored, never nulled
  status        text not null default 'pending'
                  check (status in ('pending','voted','superseded','expired','withdrawn')),
  vote          text check (vote in ('approve','deny')),
  voted_at      timestamptz,
  delivered_at  timestamptz,
  delivery_error text,
  expires_at    timestamptz not null,
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

-- What the server signed, so a grant can be re-served idempotently (§9).
create table server_grant (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null unique references override_request(id) on delete cascade,
  decided_at     timestamptz not null,
  roster         jsonb not null,
  policy_digest  bytea not null,
  signing_kid    text not null,               -- §10
  signature      bytea not null,
  created_at     timestamptz not null default now()
);
```

Things worth noticing:

- **`approvals_required` appears twice on purpose.** The envelope holds the contract; the
  request copies it at creation so a later envelope change (there should be none after
  hardening, but belt and braces) cannot retroactively move the bar on an in-flight request.
  Neither copy is ever written from a client request body.
- **`hardens_at` is a generated column.** The server computes hardening from the contract; it
  is not storable by a client and not falsifiable by one.
- **`unique (request_id, partner_id)`** makes "one partner, one vote" a property of the
  schema rather than of a code path that could be forgotten.
- **`token_hash` is never nulled** — v0.1's contradiction. Inertness comes from `status`
  (§6), not from destroying the lookup key.

---

## 6. Token and receipt lifecycle

v0.1 contained two contradictions. Both are resolved here in favour of a single model.

### 6.1 The token

- **32 bytes from a CSPRNG**, base64url-encoded (43 characters). 256 bits — guessing is not
  a threat model, it is arithmetic.
- **The database stores `sha256(token)`.** A database leak yields hashes, not working links.
  This — not deleting the hash later — is what makes a leaked database useless.
- **The URL contains only the token**: `https://<host>/a/<token>`. No request id, no partner
  id, no account id, nothing incrementable.
- **One token → one recipient row → one request → one vote.** A token cannot be pointed at a
  different request because it *is* the recipient row.

### 6.2 States, and what a link does in each

The recipient row has a `status`, and the token keeps resolving for the row's whole life so
that a stable page can always be rendered.

| Recipient status | How it got there | Opening the link shows |
|---|---|---|
| `pending` | minted and delivered, request still open | The request. Approve / Deny |
| `voted` | this partner voted | **Their receipt.** "You approved this on 24 Aug at 21:31. The request was granted." |
| `superseded` | threshold reached before they voted | "This request has already been resolved. No action needed." |
| `withdrawn` | requester cancelled, or the commitment was completed | "Patrick finished the run — no action needed." |
| `expired` | request expiry passed with no resolution | "This request expired without an answer." |

**Once the threshold is reached the request becomes `granted` and every remaining `pending`
recipient becomes `superseded` in the same transaction.** No further vote is accepted and
**no late vote is recorded** — v0.1 said both and could not mean both. The roster in the
grant is exactly the votes cast before resolution, which is also the roster the partners were
told about, which is the version a human can actually reason about.

A `voted` row keeps its `vote` and `voted_at` forever (within retention), which is what makes
the receipt stable and re-openable. This is deliberate: a partner who approved something
significant should be able to go back and see what they approved, and telling them "invalid
link" would be both rude and suspicious-looking.

### 6.3 Receipt window, then hard expiry

Keeping the hash resolvable means a leaked resolved link keeps rendering the snapshot. That
is bounded:

- `override_request.receipt_expires_at` — 30 days after resolution (**S15**).
- After it passes, the token resolves to a generic *"This link is no longer available"* with
  no snapshot, and the snapshot row is purged on the same schedule (§15).
- Cancellation, mooting and account deletion all collapse the receipt window immediately.

So the exposure of a leaked used link is: the snapshot, for at most the receipt window, with
no ability to act.

---

## 7. The snapshot is a contract artifact

When a partner opens the link, they must see **what they were asked to approve**, not what
the commitment looks like now. If Patrick logs 12 more minutes after asking, the page must
still say 18/30 — otherwise the human is answering a question nobody asked.

Written once, at creation, never updated. In v0.2 it is assembled from **two sources**, and
the distinction is now explicit because it determines what a partner should trust:

```jsonc
{
  // --- from the Contract Envelope. The client cannot alter these. ---
  "requester_display_name": "Patrick",
  "commitment_title":       "Run 30 minutes",
  "deadline":               "2026-08-24T22:00:00Z",
  "approvals_required":     2,
  "hardened_at":            "2026-08-24T08:15:00Z",

  // --- reported by the requester's device. Advisory. ---
  "progress":        { "achieved": 18, "required": 30, "unit": "minutes" },
  "reliability_30d": { "completed": 8, "of": 10, "override_requests": 2, "missed": 1 },
  "reason":          "Knee started bothering me.",

  "requested_at": "2026-08-24T21:12:04Z"
}
```

The partner page renders the two groups distinguishably, and labels the second *"as reported
by Patrick's phone"* (**D6**, settled). This is the same instinct as the event ledger — a
request is a historical fact, and facts do not get retconned — and it is also a privacy
control, because the snapshot is an explicit, reviewable list of everything a partner can
ever see rather than a live query that might one day return more.

**Known gap:** the reliability numbers are computed by the requester's device, because the
server has no ledger. A user who tampered with their local ledger could present flattering
numbers. There is no fix short of server-side resolution state (§4.9). Labelling it is the
honest interim answer, and it is now a settled decision rather than an open one.

---

## 8. Voting, and what happens when two people tap at once

One endpoint: `POST /a/:token/vote` with `{"vote": "approve" | "deny"}`. It is an edge
function using the service role. No anonymous client touches these tables directly (§18).

The entire vote — record it, recount, decide, supersede — happens in **one transaction**:

```sql
begin;
  select r.id, r.state, r.approvals_required, r.expires_at,
         rc.id as recipient_id, rc.status
    from override_request_recipient rc
    join override_request r on r.id = rc.request_id
   where rc.token_hash = $1
     for update;                     -- serialises concurrent voters on this request

  -- guards, each returning its own page rather than a generic error (§6.2):
  --   no row                 → invalid link
  --   rc.status <> 'pending' → receipt / already-resolved / expired / withdrawn
  --   r.state  <> 'open'     → already resolved
  --   now() > least(rc.expires_at, r.expires_at) → expired

  update override_request_recipient
     set status = 'voted', vote = $2, voted_at = now()
   where id = ... and status = 'pending';

  update override_request
     set state = 'granted', resolved_at = now()
   where id = ...
     and state = 'open'
     and (select count(*) from override_request_recipient
           where request_id = ... and vote = 'approve') >= approvals_required;

  -- if and only if the row above was updated, in the same transaction:
  update override_request_recipient
     set status = 'superseded'
   where request_id = ... and status = 'pending';
commit;
```

`for update` on the request row serialises concurrent approvals. Two partners tapping
approve at the same instant on a 2-of-5 request produce exactly one transition to `granted`,
one grant, and three `superseded` rows. The `and state = 'open'` guard means a request can
never double-resolve. The count is taken *after* the update, inside the lock, so there is no
read-modify-write window.

**Denials** record a vote, do not consume an approval slot, and do not resolve the request
(**S5**, settled: a denial is not a veto unless explicitly configured). A request where every
partner has denied stays `open` until it expires — which is correct, because the user's
remaining route is Solo and it is already ticking.

---

## 9. Grants: verification, layering, and the ledger event

### 9.1 Delivery to the app

The app learns the outcome by polling on foreground and on a silent push, authenticated as
the account. It does not receive votes; it receives a decision:

```jsonc
{
  "server_grant_id":   "…",
  "client_request_id": "…",
  "decision":          "granted",
  "decided_at":        "2026-08-24T21:31:08Z",
  "policy_digest":     "sha256:…",
  "roster": [
    { "partner_display_name": "Mom",  "vote": "approve", "at": "…" },
    { "partner_display_name": "Dave", "vote": "approve", "at": "…" }
  ],
  "kid":       "g2",
  "signature": "…"                    // Ed25519 over the canonical payload above
}
```

### 9.2 Layering: the signature does not enter the ledger

v0.1 put the raw attestation bytes into a permanent EarnedKit event. That was wrong, and the
review is right to push back. The layering is now:

1. **Network layer** receives the signed grant.
2. **Security layer** verifies `signature` against the trusted key set for `kid` (§10) and
   checks `client_request_id` matches a live local request.
3. A verified grant becomes **trusted domain input**.
4. **EarnedKit records the semantic fact only:**

```swift
case accountabilityOverrideGranted(
        requestID: UUID, decidedAt: Date, roster: [PartnerVote], serverGrantID: UUID)
```

**Why the signature must not live in the ledger.** The ledger is permanent, replayed on every
launch, and must be a pure deterministic function of history — that property is what the
whole engine is built on, and we have already been bitten once by breaking it. Signatures
have a lifecycle that permanence cannot accommodate:

- Keys rotate and are eventually retired (§10). A 2029 client replaying a 2026 ledger would
  either have to ignore the signature — making it dead weight in permanent history — or fail
  verification and refuse to replay legitimate history. The second is a data-loss bug waiting
  to happen; the first is dishonest storage.
- Replay must work offline and deterministically. Re-verification is neither if it depends on
  a key set that changes.
- Ed25519 is today's mechanism. Committing permanent domain history to it means a future
  algorithm change is a ledger migration rather than a networking change.

The semantic fact — *"an accountability override was granted at this time, by these people,
under server grant X"* — is stable forever. That is what belongs in history.

### 9.3 Where auditability lives instead

A separate, app-local **grant receipt store**, alongside the ledger but explicitly not part
of it:

```
serverGrantID → { payload, signature, kid, policyDigest, verifiedAt, verifierVersion }
```

It is durable, inspectable, exportable for a support conversation, and **disposable**:
losing it costs an audit trail, not correctness, because replay never consults it. The
server keeps the authoritative copy in `server_grant` regardless. This gives the
auditability without coupling permanent domain history to today's cryptography.

### 9.4 Idempotency

A grant is idempotent in both directions. The server re-serves the same `server_grant` row
for repeated polls. The client checks `serverGrantID` against the ledger before appending,
and the reducer rejects a grant for an already-resolved request via the existing
`activeRequest` guard. Both paths want tests (§19).

---

## 10. Key management and rotation

A single compiled public key is not an operational design, and v0.1 left one. Replaced with a
two-level scheme.

### 10.1 Two levels

| Key | Where it lives | Used for | Rotation |
|---|---|---|---|
| **Root** | Offline. Private half never touches a server; public half compiled into the app | Signing the *key set* only. Never signs a grant | Requires an app release. Expected lifetime: years |
| **Grant keys** (`kid`: `g1`, `g2`, …) | Server KMS / platform secret store | Signing grants | Routine, no app release needed |

The only immortal compiled value is the root public key, and it is used for exactly one
narrow purpose. That is a far smaller surface than an immortal grant key.

### 10.2 The key set

```jsonc
{
  "version": 7,
  "issued_at": "2026-08-30T00:00:00Z",
  "keys": [
    { "kid": "g2", "alg": "ed25519", "public": "…", "not_before": "…", "not_after": "…", "state": "current" },
    { "kid": "g3", "alg": "ed25519", "public": "…", "not_before": "…", "not_after": "…", "state": "next" },
    { "kid": "g1", "alg": "ed25519", "public": "…", "not_after": "…", "state": "retired" }
  ],
  "revoked": [ { "kid": "g0", "revoked_at": "…" } ],
  "root_signature": "…"
}
```

- The app ships a **baked-in key set** as a floor, and fetches updates from
  `GET /keys` on launch and daily.
- A fetched key set is accepted only if `root_signature` verifies **and**
  `version` is strictly greater than the stored one — monotonic, so a network attacker
  cannot roll clients back to a revoked key.
- Clients cache the newest valid set. An offline client keeps using its cache; grants it
  cannot verify are held, not discarded, and retried after the next successful key fetch.

### 10.3 Rollout

`next` is published in the key set well before it signs anything, so every client has seen it
before it is used. Promotion to `current` is a server-side switch. `not_before` gives clients
with skewed clocks a grace band.

### 10.4 Compromise

- **A grant key is compromised** → issue a key set with that `kid` in `revoked`, promote
  `next`, push. Clients reject grants signed with the revoked `kid` from the moment they see
  the new set, and re-poll for re-signed grants. **Grants already appended to a ledger are
  unaffected** — precisely because the ledger holds no signature (§9.2). This is the payoff of
  that layering decision, and it is why the two sections belong together.
- **The root key is compromised** → forced app update; there is no in-band recovery, which is
  the accepted cost of having a trust anchor at all. Kept offline specifically so this is
  improbable. Worth splitting under M-of-N custody if Earned reaches a scale where that is
  proportionate.
- Server-side revocation of a compromised `kid` also invalidates any grant that has not yet
  been acknowledged by a client, so the window is bounded by polling interval, not by app
  adoption.

### 10.5 What must be exercised before launch

Rotation is only real if it has been run. A drill — publish `next`, promote it, revoke the
old `kid`, confirm old and new clients behave — is a launch gate (§20), not a runbook to
write later.

---

## 11. Offline

The device must never be *more* locked because our server is unreachable, and never *less*
locked because it is.

| Situation | Behaviour |
|---|---|
| Offline at commitment creation | Commitment is created locally. Envelope queues. If it lands after hardening, the accountability route is closed for that commitment (§4.7, **S13**) |
| Offline when requesting | Request cannot be created. Say so plainly; the Solo route is unaffected |
| Offline while a request is open | Request stays visibly pending. Nothing changes locally |
| Grant happens while offline | Applied on next successful sync. The user stays restricted until then |
| Grant arrives but the key set is stale | Grant is **held, not discarded**; retried after the next key fetch (§10.2) |
| Offline forever | The accountability window elapses on the local clock and **Solo unlocks normally** |

That last row is the important one. The Solo Override's clock is local, its friction is
local, and its availability depends on `requestedAt` — not on us. A user is never trapped by
our downtime, which is the correct behaviour for a product that takes away access to
someone's phone.

The cost is honest and worth stating: a grant can sit undelivered while the user is
restricted, and they will experience that as Earned being slow to let them out. Showing
"waiting to confirm — 2 approvals received" is misleading, since we do not know that offline;
"waiting to hear back" is accurate.

---

## 12. When the request stops mattering

The engine already does the right thing locally: completing the workout moots an open
request (`testWorkoutMootsOpenRequest`). Networked, that has to propagate:

- App completes or cancels → `POST /requests/:id/close` → state `moot` or `cancelled`, every
  `pending` recipient becomes `withdrawn`, and a courtesy message goes to partners who were
  asked: *"Patrick finished the run. No action needed."* Partners who were interrupted
  deserve to know it resolved.
- If the app is offline and cannot close it, a partner may still approve. The grant then
  arrives for an already-resolved commitment and is **rejected by the reducer** — correct,
  but the partner saw a stale page. The outcome page they land on afterwards says the request
  had already been resolved by the time we processed it, rather than pretending their vote
  counted.

---

## 13. What a partner can see

Everything, and only, in the snapshot.

**Yes:** requester's display name · commitment title and requirement · deadline · when it
hardened · how many approvals are needed · progress at request time · the 30-day reliability
triple · the optional reason. The last three are labelled as self-reported (§7).

**No:** restricted app selections (Earned itself cannot read them — they are opaque tokens) ·
any HealthKit data beyond the progress figure for *this* commitment · other commitments ·
other partners' identities or votes · the requester's contact details, location, device, or
account identifiers · anything about past requests.

Two deliberate omissions, both settled:

- **Partners do not see the running tally** (**S6**). "1 of 2 approvals so far" leaks that
  another partner voted and invites coordination or diffusion of responsibility.
- **Partners do not see each other** (**S6**). They may all be family and know perfectly well
  who else is on the list, but that is the requester's information to share, not ours.

**User-authored text reaching strangers** is limited to two fields — the requester's
`display_name` and the optional `reason` — and both are treated as hostile input: rendered as
text and never as markup, length-capped, and **URL-like strings neutralised**, so a request
cannot be turned into a phishing delivery vehicle. The reason field is optional by design
(§24: *a user is never required to explain why they need an Override*).

---

## 14. Consent, contact handling, and suppression

We are about to message people who never installed anything. That deserves care, and v0.1's
one-paragraph consent model was not enough.

### 14.1 Normalisation and blind indexing

Encryption at rest and duplicate detection are different jobs and need different columns.

- **`contact_ciphertext`** — AES-256-GCM with a random IV, key in the platform secret store.
  Randomised, therefore useless for lookup, which is the point.
- **`contact_lookup`** — `HMAC-SHA256(pepper, normalized_contact)`. Deterministic, so it can
  carry the unique constraint and the suppression list. **Keyed, not a bare hash**: the space
  of phone numbers is around 10¹⁰, so an unkeyed digest of a phone number is a trivial
  offline brute force. The pepper lives with the encryption key, never in the database.
- `lookup_key_version` allows pepper rotation, which requires re-deriving every lookup value
  from the ciphertext — a batch job, not a schema change.

**Normalisation rules:**

| Channel | Rule |
|---|---|
| Phone | Parse to **E.164** using the account's region as a hint. Strip all formatting. Reject numbers that cannot be resolved unambiguously rather than guessing a country code |
| Email | Trim whitespace; lowercase the entire address. RFC 5321 makes the local part technically case-sensitive; universal practice is otherwise, and treating `Bob@x` and `bob@x` as different would break suppression. This is a deliberate, documented deviation |

**Explicitly not normalised away:** `+tag` suffixes and provider-specific dot rules. Merging
`me+1@x` into `me@x` would wrongly suppress legitimate distinct addresses and is
provider-specific guesswork. The cost is that alias addresses remain a Sybil vector (§2.2) —
a trade made knowingly in favour of not silently blocking real people.

### 14.2 Consent

- Nominating a partner sends **one** message: *"Patrick added you as an accountability
  partner on Earned. If he asks to be let out of a commitment, you'll get a text.
  [I'm in] [No thanks]."*
- Until `consented_at` is set, that partner receives nothing else and cannot be counted
  toward `approvals_required` (§4.5 step 6).
- **"No thanks"** sets `revoked_at` **and** writes a `contact_suppression` row with
  `reason = 'optout'`. It is global, not per-account.
- Every message carries an opt-out and an abuse-report path.

### 14.3 Suppression and re-contact limits

The specific harm to prevent: someone declines, and then a different Earned user nominates
the same number next week, and the product becomes a nuisance one refusal cannot stop.

- **Global suppression is checked before every send**, keyed on `contact_lookup`. A
  suppressed contact receives nothing, from anyone, ever, regardless of who nominates them.
- The nominating user is told *"Earned can't send messages to this contact"* — deliberately
  not *"they opted out"*, which would disclose a stranger's action to someone who may know
  who they are.
- **One consent request per contact per account, ever.** At most **one resend**, no sooner
  than 72 hours, and only if the first was never answered. Then never again from that
  account.
- **Nomination rate limits**: a small number of new nominations per account per day, on top
  of NORTHSTAR §23's ceiling of five partners.
- **Bounces and provider complaints** feed the same table with `reason = 'bounce' |
  'complaint'`.
- **Abuse reporting**: every message carries a report link that suppresses immediately with
  `reason = 'abuse'` and flags the account. Repeat flags remove the account's ability to
  nominate at all.

### 14.4 Suppression versus account deletion

These pull in opposite directions and the tension is real: deleting an account removes its
partner rows, but if suppression rows went with them, a previously refused contact could be
re-nominated by the same person after a delete-and-recreate.

**Suppression rows survive account deletion.** They contain no plaintext, no ciphertext, and
no link to the account that triggered them — only `(contact_lookup, channel, reason,
suppressed_at)`. That is the minimum artifact capable of honouring a refusal, and retaining
it exists to protect the person who refused, not the account that asked. This retention is
part of what needs legal sign-off (**D10**).

---

## 15. Retention and deletion

- **Snapshots** purge with the receipt window (§6.3), 30 days after resolution (**S15**).
- **Recipient rows** keep `status`, `vote` and `voted_at` for the same period, then reduce to
  a status-only row; `token_hash` goes when the row does.
- **Audit rows** keep hashed addresses under a rotating salt, no message bodies, and are the
  longest-lived artifact.
- **Partner contact ciphertext** is deleted when the partner is removed or the account is
  deleted.
- **`contact_suppression`** persists (§14.4).
- **Envelopes** for resolved or withdrawn commitments are retained while the account exists,
  because §4.9's reinstall story depends on them; deleted with the account.

**Account deletion is not settled here** — see **D10**. What this document does assert is the
separation the decision has to respect:

| | |
|---|---|
| **Deletion of personal data and the account** | A privacy matter. Anti-circumvention is not a lawful basis to refuse or defer it, and the design must not assume it is |
| **Product semantics of abandoning a live commitment** | A product matter. What the app says, what partners are told, what the ledger records |

v0.1 proposed a seven-day cooling-off as though it were an engineering choice. It is not; for
a product that may launch in the UK/EU it is a UK GDPR / GDPR Article 17 question with
consequences for lawful basis and retention justification. It is withdrawn as a proposal and
returned to review.

---

## 16. Abuse and rate limits

| Vector | Control |
|---|---|
| Token guessing | 256-bit tokens; constant-time hash lookup; per-IP limits on `/a/*` |
| Vote replay | Single-use recipient row; idempotent response (§6.2) |
| **Threshold forgery** | Impossible from a client: the threshold comes from the envelope (§4.5) |
| **Sybil partners** | Reject the account's own verified contact; partner tiers; **otherwise unsolved** (§2.2) |
| **Partner fatigue as a bypass** | Cap open requests (already 1 per commitment) *and* requests per rolling 24h per account. A user who spams five partners hourly until someone taps approve to make it stop has found a real escape route |
| Nuisance nomination | Global suppression, one-ask-plus-one-resend, per-day nomination caps (§14.3) |
| Using Earned as a messaging relay | Consented recipients only; fixed copy; the two free-text fields are capped and URL-neutralised (§13) |
| Enumeration | No sequential public identifiers; no endpoint accepts a request id from an unauthenticated caller |
| Cost abuse | Hard daily ceiling on outbound messages per account, alarmed |

Partner fatigue is the vector I would still flag as under-thought. It is not a security bug;
it is a way to convert "two humans must agree" into "one human gets annoyed," and rate limits
are a blunt answer to it.

---

## 17. What a leaked link actually gets you

An attacker with one leaked, unused, unexpired token can cast **one vote** on **one
request**, and see that request's snapshot: a first name, a commitment title, a progress
figure, a deadline, three reliability numbers, and an optional reason.

An attacker with a leaked **used or superseded** token can see the same snapshot, for at most
the receipt window (§6.3), and can do nothing.

Neither can: discover the account, find other requests, vote twice, vote after resolution,
vote after expiry, learn any contact detail, learn who else was asked, alter the contract, or
affect anything outside that one request.

If the threshold is 1, one leaked link is one override. That is inherent to the mechanism —
the same is true of the SMS itself — and it is why the default is 2 and why choosing 1
carries an explicit warning (**S12**).

---

## 18. Supabase posture

- **RLS on every table, default deny, no exceptions.** `anon` and `authenticated` get no
  policy at all on `override_request*`, `partner`, `contact_suppression`, `server_grant` or
  `contract_envelope*`. The only reader/writer is the edge function's service role.
- The partner page is **server-rendered by the edge function**, not a client app holding a
  Supabase key. No Supabase credential ships to a browser on this path.
- The app authenticates as its account. It may read its own envelopes and requests via
  policies keyed on `auth.uid()`; it may **never** write `override_request.approvals_required`,
  `contract_envelope.hardens_at`, any recipient row, or any grant.
- **Migrations checked into `backend/migrations/`** and run in CI. A schema that only exists
  in the dashboard is a schema nobody can review.
- Secrets — grant signing keys, root public key, SMS credentials, contact encryption key,
  lookup pepper — in the platform secret store, never in the repo.

---

## 19. Tests I would require before this ships

**Contract Envelope**
- A request whose body carries `approvals_required: 1` against a 2-approval envelope is
  granted only at 2. The body field is ignored — ideally rejected outright.
- No envelope → request refused. Envelope not yet hardened → refused. `is_late` → refused.
- Easing edits after `hardens_at` rejected; harder-only edits before it accepted; version
  must increment.
- Server-computed `hardens_at` matches `Commitment.hardensAt` across a table of cases,
  including the short-fuse `× 0.125` clamp. **Shared fixtures with EarnedKit**, so the two
  implementations cannot drift.
- Plan cancellation withdraws exactly the occurrences the engine withdraws — same predicate,
  same fixtures.
- Roster shrinking below threshold makes accountability unavailable and never lowers the bar.

**Voting and tokens**
- Concurrent approvals: N simultaneous votes on a threshold-2 request → exactly one `granted`
  transition, exactly one grant, all remaining recipients `superseded`.
- A vote arriving after resolution: refused, **not recorded**, receipt page shown.
- Second vote from the same recipient: refused, prior receipt shown.
- Each terminal status renders its own page: `voted`, `superseded`, `withdrawn`, `expired`,
  past-receipt-window.
- Forged, truncated, and foreign tokens: indistinguishable failure.
- Denials do not consume approval slots and do not resolve.
- Idempotent request creation on repeated `client_request_id`.

**Contacts**
- Blind index: same number in three formats normalises to one `contact_lookup`; `me+1@x` and
  `me+2@x` do not collide.
- Suppression blocks a send from a *different* account.
- One-ask-plus-one-resend enforced; the resend floor is respected.
- Deleting an account leaves the suppression row intact.

**Keys and grants**
- Bad signature → grant refused, never appended.
- Unknown `kid` → refused. Revoked `kid` → refused. `not_before` in the future → refused.
- A key set with a lower `version` than cached is rejected (rollback resistance).
- Full rotation drill: publish `next`, promote, revoke old, confirm both old and new clients.
- A grant received while the key set is stale is held and succeeds after refresh.

**Client / EarnedKit**
- A valid grant for an already-resolved commitment is rejected by the reducer.
- v2 ledgers containing `overrideApprovalRecorded` still replay identically (golden fixture).
- Grants replay deterministically — same state twice, identity included. We have been bitten
  by exactly this in `EnforcementBypass`.
- Replay never consults the grant receipt store; deleting that store changes no state.
- Offline: the Solo window still opens on schedule with no network.

**RLS**
- An `anon` client can read nothing from any of these tables, asserted per table.

---

## 20. Launch readiness gates

Accountability Overrides are not exposed to any external beta user until every line is true.
This list is the gate, not a wish list.

| | Gate |
|---|---|
| ☐ | **Sign in with Apple** and a real account model — no feature ships on `UserDefaults` identity |
| ☐ | **Server-authoritative accountability policy**: no code path reads a threshold, roster, window or deadline from a client request body |
| ☐ | **No client path capable of synthesising a grant** — verified by review *and* by test, including with a proxy CA installed |
| ☐ | **Contract Envelope** enforced, with hardening computed server-side and shared fixtures proving parity with EarnedKit |
| ☐ | **RLS default-deny tested per table**, including the `anon` case |
| ☐ | **Migrations in the repo and running in CI** |
| ☐ | **Contact encryption plus keyed blind index**, with normalisation tests |
| ☐ | **Contact keys held in the platform secret store, not database configuration.** The build reads Supabase Vault when present and falls back to a database setting so the suite runs on a plain Postgres. That fallback must never be production: a pepper stored in the database's own configuration is dumped alongside the rows it exists to protect, which defeats the only thing it is for |
| ☐ | **Consent and global suppression** live, including cross-account suppression |
| ☐ | **Abuse reporting and rate limits** on nomination, requests and messaging, with cost ceilings alarmed |
| ☐ | **Concurrent vote tests** green |
| ☐ | **Token misuse tests** green: reuse, forgery, expiry, post-resolution, foreign token |
| ☐ | **Key rotation drill executed**, not merely designed |
| ☐ | **Retention and deletion policy reviewed by counsel** (**D10**), and implemented as reviewed |
| ☐ | **Partner page privacy review**: exactly the snapshot, nothing more, self-reported fields labelled |
| ☐ | **Sybil limitation documented in-product**, not only in this file — a user choosing partners should understand what the mechanism does and does not prove |

---

## 21. Decisions

### 21.1 Settled

Decided by review, and recorded so they are not silently re-opened.

| # | Decision |
|---|---|
| **S1** | The **server** sends approval links. The requesting device never receives a token |
| **S2** | One token per partner per request; 256-bit random bearer tokens; the raw token is never stored |
| **S3** | The request snapshot is frozen at creation and never updated |
| **S4** | Partners need no Earned account for MVP |
| **S5** | First vote is final; a denial is not a veto by default; the requester may cancel before a grant |
| **S6** | Partners see neither each other nor the running tally |
| **S7** | Partner consent is required before any request can reach them |
| **S8** | The local Solo Override remains fully available through any backend outage |
| **S9** | Reliability figures are labelled self-reported until server-authoritative resolution exists |
| **S10** | Threshold resolution is atomic; RLS is default-deny; the partner page sees the minimum necessary |
| **S11** | An open request expires after **24 hours**. Solo remains available throughout. (Chosen over the proposed 48 — a tighter window against leaked-link exposure, accepted at the cost of a partner who is asleep or offline overnight) |
| **S12** | Default approvals threshold is **2**. A user may deliberately choose **1**, but only before the commitment hardens and only behind an explicit warning that one valid approval link becomes sufficient. Never silently mandatory; frozen at hardening and can only rise |
| **S13** | A Contract Envelope that reaches the server **after** its commitment has already hardened is accepted and stored but marked `late`; the **accountability route is unavailable** for that commitment. Solo remains available on the local clock. Fails safe — offline can close an escape route, never open one |
| **S14** | The `unverified_contact` / `earned_user` partner-tier distinction (§2.2) is **built into the schema now**; no verified partner is required at MVP |
| **S15** | The receipt window is **30 days** after resolution: a resolved request's link keeps rendering the snapshot for that long, then goes permanently generic and the snapshot purges |
| **S16** | A partner **suppressed or revoked after their token was minted but before they voted** still has a valid vote if they use it. They were legitimately asked before withdrawing; suppression governs future contact, not a decision already placed in their hands. (This is why §8's vote transaction checks recipient `status`, never live partner consent state, at the moment of voting) |
| **S17** | Sign in with Apple requests the **`.email` scope** alongside `.fullName`. The verified address is used for private identity/security purposes only — deriving `verified_email_lookup` so §2.2's self-nomination refusal has something to check against. Never shown on a profile, never a search key, never required of existing accounts, never read as proof the user controls no other addresses. Private-relay addresses count normally as the verified address Apple supplied. (Settled August 2026; ships with the accountability flow, not Social S1) |
| **S18** | **Earned-user partners are account-linked** (migration 0019, giving S14's `earned_user` tier its behaviour). The identity is `partner.earned_account_id` — the target's own authenticated account, surviving phone, email and name changes; the stored display name is a refreshable label, never the authority. Nomination travels only through an **accepted friendship**, by handle — so a blocked pair fails exactly like strangers and the block never leaks — but friendship is the channel, never the consent (NORTHSTAR invariant 24): the target answers in-app with their own session, the precise analogue of the external flow's bearer token. One row per requester/target pair, ever; repeated asks are idempotent. Their approval requests are delivered in-app (`my_pending_approvals`) through the same frozen snapshot and the same vote transaction as the web page — a recipient row is minted with its token hashed and discarded, so no raw token ever exists for them. **One deliberate divergence:** a declined or revoked earned partner *can* be asked again (rate-limited, friendship required). The external never-re-ask rule protects strangers' phones from messages; an Earned user is asked in-app behind a friendship they accepted, block is their stop lever — and without re-nomination, "unblock does not resurrect authority" would mean "block is forever" |
| **S19** | **Block supersedes both relationship systems** (NORTHSTAR invariant 29). A block revokes every invited/active earned-user partnership between the two accounts, both directions, as an explicit rule in `block_user` — never a cascade. Frozen envelopes keep their thresholds; the live re-filter in `create_override_request` is what makes a depleted route honestly unavailable, Solo remaining throughout. Votes already cast and grants already issued stay on the record (S16's logic extended: a block, like suppression or revocation, governs the future, not decisions already made). Unblocking restores nothing — authority returns only by fresh nomination and fresh consent. **External partners are untouched by any of this**: their consent, delivery and suppression semantics are exactly §14's |

**Documented for later, deliberately not built — linking an external partner who joins
Earned.** When a consented external partner later creates an Earned account, nothing
merges. Matching display names prove nothing, and a client-side claim of "that's me"
proves less. The trustworthy path, if it is ever wanted: the S17 verified-email blind
index and the partner row's contact blind index use the same keyed HMAC, so an
email-channel partner whose verified Apple address matches is a *candidate* — to be
confirmed by an explicit, two-sided flow (the requester re-affirms, the partner accepts
in-app), never applied automatically. SMS partners have no verified counterpart and no
safe candidate signal today. Until such a flow exists, the same human may hold one
external partnership and one earned partnership with the same requester; that is
redundancy, not a bug, and each was separately consented to.

### 21.2 D10 — half settled, half open

D10 was always two questions wearing one number, and they are now formally separated.

**Settled — the product semantics** (Patrick, August 2026):

- **Deletion is never blocked because commitments are outstanding.** A live obligation is
  not a lien on the delete button.
- **Deletion removes the user's social identity and visibility.** No public or social
  tombstone survives it: nothing that describes outstanding commitments, deletion timing,
  streaks, or apparent motive. "Patrick deleted his account owing a run" is a sentence
  the product will never render, for the same reason NORTHSTAR §45 refuses motive claims
  about silence.
- **Anti-circumvention is not solved by holding profile or social data hostage.** The
  answer to delete-and-recreate lives in account-authoritative state and the invariants
  of §33 — never in making deletion costly, slow, or embarrassing.

**Still open — retention and lawful basis.** This is the privacy/legal half (UK/EU GDPR
Article 17 weighed against legitimate interests), and it still needs real review before
launch, not a guessed answer:

| What | Why it may outlive deletion |
|---|---|
| Suppression records (§14.4) | They protect the person who refused, not the account that asked |
| Abuse/security records | Rate limits and block-evasion defence |
| Any future server-authoritative commitment state | The §33 anti-circumvention intent |
| Retention periods and lawful basis for each | The actual legal question |

Until that review lands, **retention decisions are not silently encoded into cascade
constraints** — which is why `account.auth_user_id` remains deliberately un-FK'd to
`auth.users` (migration 0001 says so in place) and why nothing new should add a cascade
that quietly decides what deletion does.

Worth confirming rather than assuming: **partner approvals stay valid after the Solo window
opens.** The window unlocks Solo as an *additional* route; it does not close the
accountability one. That is the current engine's behaviour and I would keep it.

---

## 22. Build order, if this is approved

1. **Migrations and RLS**, in the repo, in CI. Nothing else until a schema exists that can be
   reviewed.
2. **Sign in with Apple** and the `account` row. Every other table hangs off it, and it is the
   first real step toward the reinstall hole in NORTHSTAR §33.
3. **Contract Envelope**: registration, harder-only versioning, server-computed hardening,
   shared fixtures with EarnedKit. This is the trust boundary and it comes before anything
   that depends on it.
4. **Partners, consent and suppression** — nominate, confirm, revoke, opt out. No requests
   until this works.
5. **Key set, rotation, and the signing path**, drilled before any grant is issued.
6. **Request creation, snapshot and delivery**, vote endpoint stubbed.
7. **The vote endpoint and the partner page**, concurrency tests written first.
8. **Grants, verification layering, `accountabilityOverrideGranted`, ledger v3.**
9. **Close/moot propagation and the courtesy message.**

Steps 1–3 are worth doing even if the approval flow slips, because they are the same
foundation the reinstall problem needs.

---

## 23. What this does not fix

Stated so it is not discovered later.

- **Partners are not proven to be distinct humans.** A requester with a spare SIM or an email
  alias can be their own accountability partner. Server-side delivery stops automatic
  self-receipt; it proves nothing about who reads the message. Anonymous contacts are an
  accountability layer, not an identity boundary (§2.2). Mitigations are partial by design,
  because the alternative is invasive verification NORTHSTAR §33 declines.
- **Reinstalling still erases what is owed.** The envelope makes reinstall *detectable*, not
  *ineffective*: the server knows the obligations existed but not whether they were completed
  (§4.9). Delete-and-reinstall remains the cheapest escape in Earned until resolution state is
  server-side.
- **Reliability and progress figures are self-reported** (§7).
- **A patched client still bypasses everything on its own device.** What the envelope changes
  is that it can no longer recruit the server into the bypass (§2).
- **The root signing key is a single point of trust.** Kept offline and used only to sign key
  sets, but its compromise means a forced app update (§10.4).
- **Partner fatigue is only rate-limited, not solved** (§16).

---

## 24. Shared commitments are not an authority surface

*Added with Shared Commitments (NORTHSTAR §46, [shared-commitments.md](shared-commitments.md));
a boundary clarification, not a design change.*

Doing the same challenge grants no override authority. A shared-commitment participant is
a third relationship concept beside friend and accountability partner (invariant 24,
extended): nothing in migration 0020 is consulted by `register_contract_envelope`,
`create_override_request`, `cast_override_vote`, or anything else on the enforcement
path, and a roster of people running together is never an accountability roster. If a
participant should also be able to approve Overrides, that is a separate nomination
through 0005/0006/0019, with its own explicit consent. In the other direction, nothing
here changes: an override-request snapshot exposes nothing about shared commitments, and
a shared roster never learns who someone's partners are. Each participant's contract —
threshold, hardening (from *their own* acceptance), grants — is individually enveloped
exactly as if they had made the commitment alone; there is no group envelope, and the
server's shared-commitment tables carry representation only (invariant 28).
