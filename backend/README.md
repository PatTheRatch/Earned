# backend/

Supabase project: schema, migrations, and the tests that hold them to the design.

The design and threat model is
[`docs/accountability-architecture.md`](../docs/accountability-architecture.md) (v0.3).
Every product decision in it is settled except account deletion (§21.2), which waits on
privacy/legal review — nothing here should be built against a guessed answer to that one.

## What exists (Milestone A)

Accounts and the Contract Envelope. No approval flow, no partner consent, no messaging, no
tokens, no votes — those are later milestones and none of their code is here.

| | |
|---|---|
| `migrations/0001` | `account`, and the `partner` skeleton (contact ciphertext + keyed blind index, consent columns, the `unverified_contact` / `earned_user` tier from S14) |
| `migrations/0002` | `contract_envelope`, `contract_envelope_partner`, and `earned_hardens_at` |
| `migrations/0003` | `register_contract_envelope` and `withdraw_plan_envelopes` — the only write paths |
| `migrations/0004` | RLS: default deny, SELECT-your-own, and no write policy anywhere |

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
`authenticated` and `service_role` roles, and `auth.uid()`. It reproduces Supabase's own
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

## Not here yet

Partner consent and global suppression, override requests, approval tokens and the partner
page, grant signing and key rotation. See §22 of the architecture doc for the order, and
§20 for what must be true before any of it reaches a beta user.
