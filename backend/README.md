# backend/

Supabase project: schema, migrations, and the tests that hold them to the design.

The design and threat model is
[`docs/accountability-architecture.md`](../docs/accountability-architecture.md) (v0.3).
Every product decision in it is settled except account deletion (§21.2), which waits on
privacy/legal review — nothing here should be built against a guessed answer to that one.

## What exists (Milestones A–E)

Accounts, the Contract Envelope, partners with real consent, the grant-signing key
infrastructure, override requests with their frozen snapshot and delivery, and voting with
the partner page. No grants — that is step 8, and none of its code is here.

| | |
|---|---|
| `migrations/0001` | `account`, and the `partner` skeleton |
| `migrations/0002` | `contract_envelope`, `contract_envelope_partner`, and `earned_hardens_at` |
| `migrations/0003` | `register_contract_envelope` and `withdraw_plan_envelopes` |
| `migrations/0004` | RLS: default deny, SELECT-your-own, and no write policy anywhere |
| `migrations/0005` | Contact normalisation, encryption and keyed blind indexing; partner `status`; global suppression; invitations; the outbox |
| `migrations/0006` | `nominate_partner`, `resend_partner_invitation`, `respond_to_invitation`, `revoke_partner` |
| `migrations/0007` | Roster eligibility (invariant 22), the corrected pre-hardening edit rule, and `envelope_status` |
| `migrations/0008` | Grant signing keys, the rotation state machine, and root-signed key set documents (§10) |
| `migrations/0009` | `override_request` and its snapshot, recipients and audit log; `create_override_request`, `override_request_status`, expiry, and a vote endpoint that refuses (§§4.5, 6, 7, 13, 16) |
| `migrations/0010` | `cast_override_vote` for real, `approval_page`, and the receipt purge (§§6.2, 8, 15, 17) |
| `functions/approval/` | The partner page: a server-rendered edge function over those two functions (§18) |

Migrations are appended, never rewritten — 0005–0007 alter what 0001–0004 created rather
than editing it, because an applied migration and its file have to keep matching.

### Consent, and why the server sends the message

A contact address reaches the server exactly once, at nomination. It is normalised there
(E.164, or a lowercased address), encrypted there, and blind-indexed there with a keyed
HMAC — and it is never returned. The app works in display names and ids from then on.

The invitation is composed and queued by the server, and **the consent token never touches
the requester's device**. An app that could see the token could accept on its partner's
behalf, which would make the entire mechanism theatre. Same property, and the same reason,
as the approval links in a later milestone.

A refusal is **global**. "No thanks" writes a suppression row keyed on the blind index, and
every future nomination of that contact is refused before a message is composed — including
one from a different Earned account. The person refusing is not our user and did not agree
to be asked again next week by someone else.

### Roster eligibility (invariant 22)

`register_contract_envelope` refuses a roster containing anyone who has not consented, and
refuses a threshold larger than the roster. Hardening "2 of Mom, Dave and Chris" while Dave
has never answered would build a contract whose way out was dead from birth. An empty roster
is exempt from the threshold check and simply means no accountability route — which is every
commitment until someone is nominated, and the receipt says so.

### The part that matters

`approvals_required`, the partner roster, the accountability window and the deadline are
read from the envelope the server holds. They are never read from a request body. That is
the whole point of this milestone: the threat model treats the account holder as the
adversary, so a modified client that asks for a threshold of 1 against a contract that
hardened at 2 has to be refused by something it does not control.

Hardening is computed here, not accepted here:

```
hardens_at = created_at + min(correction_window, max(0, deadline - created_at) * 0.125)
```

That is the same rule as `Commitment.hardensAt` in EarnedKit, and the two are pinned
together by [`fixtures/hardening-cases.json`](../fixtures/hardening-cases.json), which both
sides read. Change one without the other and CI fails on both.

### Grant keys and the key set (build order step 5)

When a grant is eventually issued (steps 6–8), the app will trust it because it verifies
against a key set, not because our server said so. `0008` builds that trust chain before
any grant exists, because §10.5 is blunt about it: rotation that has never been run is not
a design, and drilling it with real grants in flight would be drilling on users.

Two levels of key, and the database holds only public halves:

- **Root** — offline. The private half never touches the server, Vault, or this repo; its
  public half will be compiled into the app. It signs key set *documents*, never grants.
- **Grant keys** (`g1`, `g2`, …) — Ed25519 pairs whose private halves live in Supabase
  Vault as `grant_key_<kid>`. The schema stores their public halves and lifecycle:
  `next → current → retired`, or `revoked` from anywhere, terminally.

The lifecycle rules the tests hold it to: one `current` and one `next` at most; a key
cannot be promoted until a *published* key set carries it (a key nobody was told about must
never sign) nor before its `not_before` (clock-skew grace band); the outgoing key retires
with a verification tail rather than dying, so in-flight grants survive rotation; revoking
the current key deliberately leaves nothing to sign with until the next key is promoted.

A key set document is assembled by `build_key_set_document()`, signed **offline** by the
root, and stored by `publish_key_set()` byte-for-byte — versions are strictly monotonic
and gap-free, which is the server's half of the rollback resistance clients enforce.
`current_key_set()` serves the newest document verbatim (this is `GET /keys` in substance,
and the one function `anon` may call — everything in it is public keys). The signing path
for later milestones starts at `current_signing_kid()`, which names the Vault secret to
sign with and raises rather than guessing when there is no safe answer.

The state machine is tested in `tests/70_key_rotation.sql`; the crypto path is
[`tests/keyset_drill.sh`](tests/keyset_drill.sh), which runs the full §10.5 drill in CI
with real Ed25519 keys — introduce, publish, verify the served bytes against the root key,
sign a stand-in grant and verify it with the public key *from the served document*, rotate,
revoke, and confirm a stale document cannot be republished. The launch-gate drill against
the production project (root key on an offline machine, clients on real devices) still has
to be run by a person; the script is its rehearsal and its script.

### Override requests (build order step 6)

`create_override_request` is the trust boundary made concrete. It takes what the device
observed — progress, the 30-day reliability triple, an optional reason — and **nothing that
decides the outcome**. The threshold, the roster, the accountability window and the deadline
are read from the envelope. There is no parameter to put them in, and a test asserts that
against the catalogue rather than against a reading of the source.

The §4.5 chain, each refusal with its own message because the app has to explain which wall
it hit: no envelope (absence is never permission, §4.8) · not yet hardened (edit or cancel
it instead, which is cheaper and more honest than asking three people) · registered late, so
the accountability route never existed (S13) · already an open request · over the daily cap ·
fewer eligible partners than the contract needs. That last one re-filters the roster at
request time, because invariant 22 guaranteed consent at *registration* and a partner can
withdraw afterwards — and when that happens the threshold does not quietly drop to match who
is left.

**The token never reaches the requester.** One 256-bit token per partner, base64url, minted
server-side, stored only as `sha256`, and placed in the outbound message and nowhere else —
the same discipline as the consent tokens in 0006, for the same reason (S1, S2). The
response to the requesting device carries the request id and a count of who was asked.

**The snapshot is frozen at creation** (§7) and split structurally into `contract` (the
server's own, from the envelope) and `self_reported` (the device's, advisory). §7 requires
the partner page to render the two halves distinguishably and label the second; a flat
object with a comment marking the split would leave the page hardcoding which keys it may
trust, and a future field would join the wrong half by accident. The known gap is unchanged
and stated there: reliability is computed by the requester's own device, so a tampered
ledger can flatter it — labelling it is the honest interim answer.

The two free-text fields that reach a stranger — the requester's display name and the
optional reason — are length-capped and URL-neutralised before they are stored (§13). The
page rendering text and never auto-linking is the real defence; this is the layer that stops
Earned lending its own credibility to a link it did not author.

`override_request_status` deliberately withholds the running tally. §11 settles the wording
for the offline case — "waiting to hear back", never "2 approvals received" — and the same
restraint applies online: the decision arrives once, as a signed grant, in step 8.

Requests expire after 24 hours (S11). `expire_override_requests()` is a sweeper for a
scheduled job, but nothing depends on its having run: expiry is recomputed wherever it is
read, and creation retires anything elapsed on its way past, so a user is never held behind
a row nobody got round to.

`cast_override_vote` exists and refuses. It is step 7, and §19 wants its concurrency tests
written first — N simultaneous votes on a threshold-2 request producing exactly one
transition to `granted`. A vote endpoint that silently did nothing would be the worse
failure, so the stub is loud.

### Voting and the partner page (build order step 7)

The concurrency test was written before the endpoint, as §22 orders, and it earned its
keep on day one: the first implementation locked recipient-and-request in one `FOR UPDATE`
join, straight from §8's sketch, and five simultaneous voters deadlocked it — the winner
holds the request row and reaches for the losers' recipient rows to supersede them, while
each loser holds its own recipient row and waits for the request. The lock order is now a
stated rule: **the request row first, recipient rows only under it**, everywhere — voters,
creation's lazy expiry, and the sweeper alike. [`tests/vote_concurrency.sh`](tests/vote_concurrency.sh)
runs five real sessions behind an advisory-lock starting gun in CI on every push and
demands exactly one `granted` transition, exactly two recorded votes, and three
`superseded` rows.

The semantics ([`tests/90_voting.sql`](tests/90_voting.sql)): first vote is final and a
second tap changes nothing, not even the audit log · a denial is recorded, consumes no
approval slot, and resolves nothing — all-denials stays open until expiry, because Solo is
already ticking (S5) · a vote after resolution is refused and **not recorded**, and its
page says the tap did not change the outcome (§12) · a partner revoked after their token
was minted still has a valid vote (S16) · forged, truncated and foreign tokens are
indistinguishable · past the receipt window every link goes permanently generic, the purge
removes the snapshot, and receipts reduce to status-only (S15, §15).

Every token state answers with a page, not an error (§6.2): `request`, `receipt`,
`resolved`, `withdrawn`, `expired`, and the deliberately identical faces of `invalid` and
`gone`. The page itself is [`functions/approval/`](functions/approval/) — server-rendered,
no Supabase credential in any browser, no JavaScript on the page at all, votes cast by
form post. All the rules live in SQL under the test suite; all the words live in
`render.ts` under its own tests (escaping hostile text, the §7 two-halves labelling, no
tally anywhere).

Deploying it:

```sh
supabase functions deploy approval
```

[`supabase/config.toml`](../supabase/config.toml) sets `verify_jwt = false` for this
function and points the CLI at `backend/functions/approval/`, since the code lives here
rather than in the CLI's default location. Turning JWT verification off is required and
correct: partners are strangers without accounts
(S4), and the 256-bit token in the URL is the entire credential. The function reads
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from the environment Supabase injects.
Point `consent_base_url`'s `/a/<token>` links at it (a redirect or rewrite from your
domain to `https://<ref>.functions.supabase.co/approval/<token>`). Per-IP rate limiting on
`/a/*` (§16) belongs to whatever fronts the function — Supabase does not provide it —
and is tracked as a launch-gate concern, not solved here.

Two functions now want a schedule: `expire_override_requests()` and
`purge_override_receipts()`. Neither is load-bearing — expiry and the receipt window are
recomputed wherever they are read — so a daily `pg_cron` call keeps stored state tidy
rather than keeping the system correct.

## Running the tests

Any throwaway Postgres 16 will do; CI uses a service container.

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres backend/tests/run.sh
```

CI runs the suite twice: once against a bare Postgres and once with
`EARNED_LAYOUT=supabase`, which lays pgcrypto out in an `extensions` schema the way the
real project does. A pinned `search_path` that misses `extensions` passes on the first and
fails on the second — every function here had exactly that bug once, so both layouts gate.

`00_bootstrap.sql` stands in for what Supabase provides in production — the `anon`,
`authenticated` and `service_role` roles, `auth.uid()`, and the contact-crypto secrets. It reproduces Supabase's own
definition of `auth.uid()` rather than a simpler one, because a shim that read the account
some easier way would let these tests pass while production failed. Nothing in it ships.

The suite asserts the rules by trying to break them: lowering a threshold, moving a deadline
later, removing a partner, editing a frozen contract, writing a table directly as
`authenticated`, reading anything as `anon`. Two meta-tests fail if a table ever ships
without RLS or if anyone adds an INSERT/UPDATE/DELETE policy.

## Applying to a real project

**The full walk-through is [`docs/deployment.md`](../docs/deployment.md)** — an empty
Supabase project to a partner opening a real approval link, in order, with something to run
after each step. What follows is the schema-specific detail that runbook links back to.


Migrations run in filename order and are written to **converge on re-run**, so a set that
failed halfway can simply be applied again.

```sh
backend/apply.sh "postgresql://postgres.<ref>:<password>@<host>:5432/postgres"
```

The connection string is in Project Settings → Database → Connection string (URI). It carries
your database password: pass it as an argument, never commit it.

`pgcrypto` lives in the `extensions` schema on Supabase and in `public` on a plain Postgres,
so every function pins `search_path` to see both. Getting that wrong is silent until the
first partner is invited and `hmac` cannot be found, so the test suite is run against a
database laid out the Supabase way as well as the default one.

### Then: three settings that are not in the migrations

**1. Vault secrets.** Project Settings → Vault. Nothing that touches a real contact works
without these, and `private.secret()` raises rather than falling back quietly in production.

| Name | What it is |
|---|---|
| `contact_pepper` | HMAC key for the blind index. A long random string. **Changing it later invalidates every stored lookup**, so generate it once and keep it |
| `contact_key` | Symmetric key for contact ciphertext |
| `consent_base_url` | Origin of the consent and approval pages, e.g. `https://earntherest.com` — both the invitation link (`/c/<token>`) and the approval link (`/a/<token>`) are built from it |

A fourth kind arrives with key rotation rather than setup: `grant_key_<kid>`, the private
half of each grant signing key, created when that key is introduced (see the runbook in
`tests/keyset_drill.sh` — the real rotation follows the same steps, with the root key kept
offline). The root private key is never a Vault secret; it never touches the server at all.

**2. Sign in with Apple.** Authentication → Providers → Apple. Needs the Services ID, Team
ID, Key ID and the `.p8` key from the Apple Developer portal. The same capability also has
to be enabled on the App ID in Xcode's Signing & Capabilities, or device builds fail to sign.

**3. The app's own config.** `app/Earned/Backend.plist` — gitignored, so create it by hand on
the machine that builds:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SupabaseURL</key>
	<string>https://YOUR-PROJECT.supabase.co</string>
	<key>SupabasePublishableKey</key>
	<string>sb_publishable_…</string>
</dict>
</plist>
```

Use the **publishable** key (`sb_publishable_…`), which is meant to ship inside the app. The
secret key (`sb_secret_…`) bypasses RLS entirely and must never go near the client or the
repository. Without this file the app reports "no backend configured" and behaves exactly as
it did before any of this existed — gates, hardening, debt and the Solo Override are all
local and never depend on our uptime (S8).

## Key custody — a launch gate, not a detail

`private.secret()` reads Supabase Vault when it is present and falls back to a database
setting otherwise, so the suite can run on a plain Postgres. **The fallback must never be
production.** A pepper stored in the database's own configuration is dumped alongside the
rows it exists to protect, which defeats the only thing it is for: making a leaked table of
phone numbers resistant to offline brute force. Set the three secrets above in Vault before
any real contact is stored.

## Not here yet

The vote endpoint and the partner page (step 7), and the grants the keys of `0008` will
eventually sign (step 8). Close/moot propagation and the courtesy message are step 9, which
is why a requester cannot yet cancel an open request — completing the workout moots it
locally, and telling the partners so is that step's job.

Also not here: an actual SMS or email sender. `message_outbox` is where invitations and
approval links queue, and nothing drains it yet. See §22 of the architecture doc for the
order, and §20 for what must be true before any of it reaches a beta user.
