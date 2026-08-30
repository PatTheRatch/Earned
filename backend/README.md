# backend/

Supabase project: schema, migrations, and the tests that hold them to the design.

The design and threat model is
[`docs/accountability-architecture.md`](../docs/accountability-architecture.md) (v0.3).
Every product decision in it is settled except account deletion (§21.2), which waits on
privacy/legal review — nothing here should be built against a guessed answer to that one.

## What exists (Milestones A and B)

Accounts, the Contract Envelope, and partners with real consent. No override requests, no
approval tokens, no votes, no grants — those are later milestones and none of their code is
here.

| | |
|---|---|
| `migrations/0001` | `account`, and the `partner` skeleton |
| `migrations/0002` | `contract_envelope`, `contract_envelope_partner`, and `earned_hardens_at` |
| `migrations/0003` | `register_contract_envelope` and `withdraw_plan_envelopes` |
| `migrations/0004` | RLS: default deny, SELECT-your-own, and no write policy anywhere |
| `migrations/0005` | Contact normalisation, encryption and keyed blind indexing; partner `status`; global suppression; invitations; the outbox |
| `migrations/0006` | `nominate_partner`, `resend_partner_invitation`, `respond_to_invitation`, `revoke_partner` |
| `migrations/0007` | Roster eligibility (invariant 22), the corrected pre-hardening edit rule, and `envelope_status` |

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

## Running the tests

Any throwaway Postgres 16 will do; CI uses a service container.

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres backend/tests/run.sh
```

`00_bootstrap.sql` stands in for what Supabase provides in production — the `anon`,
`authenticated` and `service_role` roles, `auth.uid()`, and the contact-crypto secrets. It reproduces Supabase's own
definition of `auth.uid()` rather than a simpler one, because a shim that read the account
some easier way would let these tests pass while production failed. Nothing in it ships.

The suite asserts the rules by trying to break them: lowering a threshold, moving a deadline
later, removing a partner, editing a frozen contract, writing a table directly as
`authenticated`, reading anything as `anon`. Two meta-tests fail if a table ever ships
without RLS or if anyone adds an INSERT/UPDATE/DELETE policy.

## Applying to a real project

Migrations are plain SQL and run in filename order.

```sh
supabase link --project-ref <ref>
supabase db push          # or: psql "$SUPABASE_DB_URL" -f backend/migrations/000N_*.sql
```

Then point the app at it. `app/Earned/Backend.plist` is **not** in the repository — the anon
key is public by design, but the project URL is not, and a fork pointing at someone else's
project is a bad default. Create it by hand:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SupabaseURL</key>
	<string>https://YOUR-PROJECT.supabase.co</string>
	<key>SupabaseAnonKey</key>
	<string>YOUR-ANON-KEY</string>
</dict>
</plist>
```

Without that file the app reports "no backend configured" and behaves exactly as it did
before any of this existed. Gates, hardening, debt, restrictions and the Solo Override are
all local and none of them may ever start depending on our uptime (S8).

Sign in with Apple also needs enabling twice: once as an Xcode capability on the App ID
(same one-time step Family Controls needed), and once as a provider in the Supabase
dashboard under Authentication → Providers → Apple.

## Key custody — a launch gate, not a detail

`private.secret()` reads Supabase Vault when it is present and falls back to a database
setting otherwise, so the suite runs on a plain Postgres. **The fallback must never be
production.** A pepper stored in the database's own configuration is dumped alongside the
rows it exists to protect, which defeats the only thing it is for: making a leaked table of
phone numbers resistant to offline brute force. Set `contact_pepper`, `contact_key` and
`consent_base_url` in Vault before any real contact is stored.

## Not here yet

Override requests, approval tokens and the partner page, grant signing and key rotation.
Also not here: an actual SMS or email sender. `message_outbox` is where invitations queue,
and nothing drains it yet. See §22 of the architecture doc for the order, and
§20 for what must be true before any of it reaches a beta user.
