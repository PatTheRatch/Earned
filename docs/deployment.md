# Deploying Earned

From an empty Supabase project to a working approval link a partner can open, in order.

Every step ends with something you can run to check it worked, because the failures here
are mostly silent: a missing Vault secret does nothing until the first partner is invited,
and a misconfigured auth provider looks exactly like a broken app.

**Nothing here is needed to develop against.** The app works with no backend at all —
gates, hardening, debt and the Solo Override are local and never depend on our uptime
(**S8**). Steps 1–4 get you accounts and Contract Envelopes; steps 5–6 are only needed the
day you want another human to receive a message.

| | Step | Needed for |
|---|---|---|
| 1 | [Migrations](#1-apply-the-migrations) | Anything at all |
| 2 | [Vault secrets](#2-set-the-vault-secrets) | Anything touching a contact |
| 3 | [Sign in with Apple](#3-sign-in-with-apple) | Accounts, and everything hanging off one |
| 4 | [The app's own config](#4-the-apps-config) | The app reaching the backend |
| 5 | [Domain and the partner page](#5-the-domain-and-the-partner-page) | A partner opening a link |
| 6 | [Sending messages](#6-sending-messages) | A partner *receiving* a link |
| 7 | [Scheduled jobs](#7-scheduled-jobs-one-of-them-load-bearing) | Tidiness — and the shared-start event |

---

## 0. Before you start

You need `psql` locally (`brew install libpq`, or `postgresql@16`), and an **Apple Developer
Program** membership — the Family Controls entitlement cannot be provisioned by a free Apple
ID, so the app will not install on a device without it.

Get a connection string from the Supabase dashboard → **Connect** → **Session pooler**, and
keep the password out of it:

```sh
export DB="postgresql://postgres.<ref>@aws-1-<region>.pooler.supabase.com:5432/postgres"
printf 'DB password: '; read -rs PGPASSWORD; echo; export PGPASSWORD
```

**Both of those are per-shell.** Open a new terminal tomorrow and `$DB` is empty, at which
point `psql "$DB"` silently falls back to a local socket and reports
`connection to server on socket "/tmp/.s.PGSQL.5432" failed` — which reads like the
database is down rather than like a missing variable. `history | grep apply.sh` recovers
the string you used last time.

Worth doing once so it stops recurring: put the password in `~/.pgpass` and the prompt
disappears for good.

```sh
echo 'aws-1-<region>.pooler.supabase.com:5432:postgres:postgres.<ref>:YOUR_PASSWORD' >> ~/.pgpass
chmod 600 ~/.pgpass
```

After that only `export DB=...` is needed in a new shell, and it is safe to keep that line
in `~/.zshrc` — a connection string with no password in it is not a secret. In `.pgpass`,
only `:` and `\` in the password need a backslash before them; `%` and `@` are fine.

Two traps, both of which will waste your afternoon:

- **Use the session pooler, not the direct connection.** Direct is IPv6-only on newer
  projects without the IPv4 add-on, and simply hangs. Avoid port 6543 (transaction pooler);
  migrations need session mode.
- **Do not put the password in the URI.** A `%` or `@` in a database password breaks URI
  parsing in ways that look like a network fault (`invalid percent-encoded token`, or a
  hostname with your password inside it). The `read -rs` above sidesteps the whole class,
  and keeps the password out of your shell history. The URI should contain exactly one `@`.

Check it:

```sh
psql "$DB" -c "select current_user, current_database();"
```

---

## 1. Apply the migrations

```sh
backend/apply.sh "$DB"
```

Safe to re-run: every statement is written to converge, so a set that fails halfway can
simply be applied again. On a first run you will see a page of `NOTICE ... does not exist,
skipping` lines — that is the convergence working, not a problem.

**Re-run this after every `git pull` that adds a migration.** It is not a one-time step.
A missing migration does not announce itself: the edge function will deploy happily, then
return 500 because the SQL function it calls does not exist yet. If something that worked
in the repo does not work against your project, check this first:

```sh
psql "$DB" -c "select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public'
                  and p.proname in ('approval_page','create_override_request','current_key_set')
                order by 1;"
```

Three rows means you are current with the migrations in this repo as of step 7.

**Check:**

```sh
psql "$DB" -c "
select (select count(*) from pg_tables where schemaname='public')                     as tables,
       (select count(*) from pg_tables where schemaname='public' and not rowsecurity) as no_rls,
       (select count(*) from pg_policies where schemaname='public' and cmd<>'SELECT') as write_policies;"
```

`no_rls` and `write_policies` must both be **0**. Anything else means a table is exposed or
someone has added a write policy, and both are design violations rather than
misconfigurations — stop and find out why.

Then make PostgREST notice the new functions, or the app's RPC calls will 404:

```sh
psql "$DB" -c "notify pgrst, 'reload schema';"
```

---

## 2. Set the Vault secrets

Three secrets, generated inside the database so they never enter your shell history:

```sh
psql "$DB" -c "
select vault.create_secret(encode(extensions.gen_random_bytes(32),'base64'), 'contact_pepper',
       'HMAC key for the contact blind index. Changing this orphans every stored lookup.');
select vault.create_secret(encode(extensions.gen_random_bytes(32),'base64'), 'contact_key',
       'Symmetric key for contact ciphertext');
select vault.create_secret('https://earntherest.com', 'consent_base_url',
       'Origin for /c/<token> consent and /a/<token> approval links');"
```

> **`contact_pepper` is permanent.** It is the key behind the contact blind index.
> Regenerate it later and every stored lookup becomes unmatchable, which breaks suppression
> and duplicate detection for good — including the record of people who have already
> refused to be contacted. Read it back with
> `select decrypted_secret from vault.decrypted_secrets where name='contact_pepper';` and
> put it in a password manager now, in case you ever migrate projects.

`consent_base_url` is the one that is safe to change — it is a plain config string, not a
key. To repoint it later:

```sh
psql "$DB" -c "
delete from vault.secrets where name = 'consent_base_url';
select vault.create_secret('https://newdomain.example', 'consent_base_url', 'Link origin');"
```

Only links minted afterwards pick up the change; ones already queued keep the old origin.

**Check** — this exercises Vault *and* the `search_path` pinning that lets pgcrypto resolve
in Supabase's schema layout, which is the thing that silently breaks in production:

```sh
psql "$DB" -c "
select length(private.contact_lookup(public.normalize_contact('sms','+1 (415) 555-0100'))) as lookup_bytes,
       length(private.contact_encrypt('+14155550100')) > 0                                 as encrypts;"
```

Expect `32` and `t`. A `secret contact_pepper is not configured` error means the Vault step
did not land.

> **This is a launch gate.** `private.secret()` falls back to a database setting when Vault
> is absent, so the test suite can run on a plain Postgres. That fallback must never be
> production: a pepper stored in the database's own configuration is dumped alongside the
> rows it exists to protect, defeating the only thing it is for.

---

## 3. Sign in with Apple

Two places, and both are required.

**Apple Developer portal** → Identifiers → your App ID (`com.pattheratch.earned`) → enable
the **Sign in with Apple** capability. The entitlement is already in
`app/Earned/Earned.entitlements`; without the matching capability on the App ID, device
builds fail to sign.

**Supabase** → Authentication → Providers → **Apple** → enable, and put the bundle ID
`com.pattheratch.earned` in **Client IDs**.

That is all. Leave the **Secret Key (for OAuth)** section — Services ID, Team ID, Key ID,
`.p8` — empty. That set is only for the web redirect flow, which this app never uses: it
sends Apple's identity token straight to `/auth/v1/token?grant_type=id_token`, and Supabase
validates it against the Client IDs list.

**Check:** sign in on the device, then

```sh
psql "$DB" -c "select display_name, created_at from public.account;"
```

One row with your name means Apple → Supabase auth → `ensure_account` → RLS all held.

If sign-in fails, **Supabase dashboard → Logs → Auth Logs** has the real reason. The two
common ones are `Provider ... is not enabled` (you missed the toggle) and `Unacceptable
audience in id_token` (you missed the Client ID).

---

## 4. The app's config

`app/Earned/Backend.plist` is gitignored — the publishable key is public by design, but the
project it points at is yours. Create it by hand, from the terminal rather than an editor,
because a smart quote pasted from a browser produces
`unable to read input file as a property list` at build time:

```sh
SUPA_URL="https://<ref>.supabase.co"
SUPA_KEY="sb_publishable_..."

cat > app/Earned/Backend.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SupabaseURL</key>
	<string>${SUPA_URL}</string>
	<key>SupabasePublishableKey</key>
	<string>${SUPA_KEY}</string>
</dict>
</plist>
EOF

plutil -lint app/Earned/Backend.plist   # must say OK
```

Both values are in Project Settings → API Keys. Use the **publishable** key
(`sb_publishable_…`), which is meant to ship inside the app. The secret key
(`sb_secret_…`) bypasses RLS entirely and must never go near the client or this repository.

Then build:

```sh
xcodegen generate --spec app/project.yml --project app
open app/Earned.xcodeproj
```

Without the plist the app reports "no backend configured" and behaves exactly as it did
before any of this existed, which is deliberate (**S8**).

**Check:** create a commitment in the app with a deadline a few hours out, then

```sh
psql "$DB" -c "select title, approvals_required, hardens_at, is_late from public.contract_envelope;"
```

A row whose `hardens_at` the server computed itself, with `is_late` false, means the
Contract Envelope is live — the accountability terms now exist somewhere the app cannot
edit, which is the trust boundary the whole design rests on.

---

## 5. The domain and the partner page

Until now everything has been testable by one person. This is the step that makes a link
openable by someone else.

### 5.1 Deploy the approval function

You need the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
(`brew install supabase/tap/supabase`), and the repo linked to your project once:

```sh
supabase login
supabase link --project-ref <ref>
```

Then, from the repo root:

```sh
supabase functions deploy approval
```

No `--no-verify-jwt` flag: [`supabase/config.toml`](../supabase/config.toml) sets
`verify_jwt = false` for this function, and that is deliberate. Partners are strangers with
no Earned account (**S4**) and the 256-bit token in the URL is the entire credential, so
JWT verification must be off — and a setting that must never be wrong belongs in a file
under review rather than in a flag someone types from memory.

Run it **from the repo root**. The CLI resolves `supabase/config.toml` and the function
directory relative to where you invoke it, so running from a subdirectory fails with
`Entrypoint path does not exist`.

The function reads `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from the environment
Supabase injects; there is nothing to configure for either.

> If the deploy complains that Docker is not running, it is trying to bundle locally.
> Recent CLI versions bundle without it; if yours insists, start Docker Desktop and retry.

**Check** it is reachable, using the ugly URL for now — and check the *status*, not just
the page:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://<ref>.functions.supabase.co/approval/not-a-real-token"
```

- **200** — working. The function ran, asked the database, and was told that token is not
  real. Fetching the body shows "This link is no longer available", the same page a forged
  token gets, which is the point (§17).
- **500** — the function is deployed but cannot reach `approval_page`. Almost always this
  means the function and the migrations are on **different projects**: check
  `supabase projects list` against the `$DB` you have been running migrations into.

The body alone cannot tell those apart — the error path deliberately renders the same
page rather than leaking a stack trace to a partner — so read the status code.

### 5.2 Put the domain in front of it

The links say `https://earntherest.com/a/<token>`, so something has to serve that path.
[`web/`](../web/) is a Cloudflare Worker that proxies the two token paths and serves the
site for everything else.

**Proxy, never redirect.** A 302 flips the address bar to a Supabase subdomain at the exact
moment a stranger is deciding whether to trust the page, which throws away the reason for
owning a domain.

**And the domain is load-bearing, not decoration.** Supabase will not serve HTML from
`*.functions.supabase.co`: it rewrites `content-type` to `text/plain`, adds `nosniff`, and
replaces the CSP with `sandbox`, so the partner page arrives as visible source text. That
is a reasonable anti-abuse rule for a function domain shared by every project — nobody
should be able to host a page there — and it means the partner page cannot work at all
without a domain of your own in front of it. The worker restores the content type and CSP,
and drops the upstream's `sb-project-ref`, `sb-request-id` and friends on the way past.

1. Add the domain to Cloudflare (free plan is enough) and point your registrar's
   nameservers at the two Cloudflare gives you. Wait for the zone to go **Active** —
   usually minutes, occasionally hours.
2. Put your project ref into `web/wrangler.toml` (`SUPABASE_FUNCTIONS_URL`).
3. Deploy:

   ```sh
   cd web
   npx wrangler deploy
   ```
4. In the dashboard: **Workers & Pages** → `earned-web` → **Settings** → **Domains &
   Routes** → **Add** → **Custom Domain**, once for `earntherest.com` and once for
   `www.earntherest.com`.

   Custom Domain, not Route. A Custom Domain creates the proxied DNS record for you, which
   is what you want on a zone that has none. A Route is pattern matching over a hostname
   that must already resolve, so on a fresh zone it silently matches nothing. Do not add
   DNS records by hand for this — Cloudflare manages them, and the "Visitors cannot reach
   earntherest.com" warnings on the DNS page clear themselves once the domain is
   attached.

**Check** — three requests, and the *differences* between them are the point:

```sh
# 1. the site
curl -s https://earntherest.com/ | grep -o '<title>.*</title>'

# 2. a well-formed token that does not exist -> reaches Supabase, answers "invalid"
TOK=$(python3 -c "import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='))")
curl -s -o /dev/null -w 'well-formed -> %{http_code}\n' "https://earntherest.com/a/$TOK"

# 3. a malformed token -> filtered at the edge, never reaches the database
curl -s -o /dev/null -w 'malformed   -> %{http_code}\n' "https://earntherest.com/a/not-a-real-token"
```

The title, then **200**, then **404**.

The 404 is not a failure: the worker pins the token shape, so a malformed one is served by
the static site instead of being proxied. Testing with an obviously-fake string like
`not-a-real-token` therefore proves nothing about the proxy — it has to be 43 base64url
characters to get past the edge at all. Against the Supabase URL directly (§5.1) the same
string returns 200, because there is no worker in front to filter it.

### 5.3 Grant signing keys

A resolved request is not permission until the server signs a statement about it. That
needs two keys, and where they live is the point.

**The root key never touches any server.** Generate it on a machine you control and keep
the private half offline — a password manager, a USB stick in a drawer, anywhere that is
not this project. Its public half will be compiled into the app; it signs key set
documents, never grants.

```sh
openssl genpkey -algorithm ed25519 -out root.pem       # keep offline, back up
openssl pkey -in root.pem -pubout -out root.pub.pem    # this goes into the app later
```

**A grant key, whose private half lives in the function's secrets** — not in Vault, and not
in the database. Contact keys are in Vault because they protect data that is in the
database anyway; this one protects *against* the database. It is the single secret whose
loss lets someone mint permission a user never earned, so a total database compromise must
not yield it.

```sh
openssl genpkey -algorithm ed25519 -out g1.pem
supabase secrets set GRANT_KEY_G1="$(grep -v -- '-----' g1.pem | tr -d '\n')"

# The public half goes into the schema, is published in a root-signed key set,
# and only then is allowed to sign anything.
PUB="$(openssl pkey -in g1.pem -pubout -outform DER | tail -c 32 | openssl base64 -A)"
psql "$DB" -c "select public.introduce_grant_key('g1', '$PUB');"

DOC="$(psql "$DB" -qtA -c 'select public.build_key_set_document()' | tr -d '\n')"
printf '%s' "$DOC" > keyset.json
SIG="$(openssl pkeyutl -sign -inkey root.pem -rawin -in keyset.json | openssl base64 -A)"
psql "$DB" -v doc="$DOC" -v sig="$SIG" <<'SQL'
select public.publish_key_set(:'doc', :'sig');
SQL
psql "$DB" -c "select public.promote_grant_key('g1');"

# And publish again. The document above was built before the promotion, so it
# still describes g1 as `next` — and `next` is all any app would ever be told.
# Signing against that produces grants every correct client refuses, so the
# server refuses to do it. This second publication is what puts g1 in service.
DOC="$(psql "$DB" -qtA -c 'select public.build_key_set_document()' | tr -d '\n')"
printf '%s' "$DOC" > keyset.json
SIG="$(openssl pkeyutl -sign -inkey root.pem -rawin -in keyset.json | openssl base64 -A)"
psql "$DB" -v doc="$DOC" -v sig="$SIG" <<'SQL'
select public.publish_key_set(:'doc', :'sig');
SQL
```

The same two-step applies to every future rotation: introduce, publish, promote, **publish
again**. Skipping the last one is the one mistake here that produces no error until a
locked-out user's grant fails to verify on their phone, which is why the server now checks
it instead of trusting the runbook.

Then deploy the signer:

```sh
supabase functions deploy grants
```

**Check** — a key that is promoted and published is one the server will sign with:

```sh
psql "$DB" -c "select public.current_signing_kid();"
```

`g1`. An error here names which step is missing — never published, never promoted, or
promoted without republishing — and the schema is right to refuse every one of them: a key
nobody was told could sign must never sign (§10.3).

Confirm the served key set agrees, since that document is the only thing an app ever sees:

```sh
psql "$DB" -qtA -c "select public.current_key_set() ->> 'document'" | python3 -m json.tool
```

`g1` must appear with `"state": "current"`.

> Back up `root.pem` before you go further. Losing it means no future key set can ever be
> published, which means keys can never be rotated — and rotation is the only answer to a
> compromised grant key. `g1.pem` itself can be discarded once the secret is set; it is
> recoverable only in the sense that you can rotate to a new key.

### 5.4 Rate limiting — do not skip this

§16 requires per-IP limits on `/a/*`, and Supabase does not provide them. In Cloudflare:
**Security** → **WAF** → **Rate limiting rules** → a rule matching `URI Path starts with
/a/`, something like 20 requests per minute per IP.

The Worker's strict token patterns mean a malformed guess never reaches Postgres, but a
well-formed one does. 256-bit tokens make guessing arithmetic rather than a threat model;
the rate limit is what stops someone paying to find out.

### 5.5 End to end, for real

```sh
backend/tools/demo_request.sh
```

It prints two links — one per partner, on a request with a threshold of 2 — and opening
one in a browser is the whole mechanism working, minus delivery: the commitment, the two
labelled halves of the snapshot, and Approve / Deny. Tapping one records a real vote and
shows that partner's receipt. Tapping both resolves the request; a third partner would
find it superseded.

Consent still has no page, and this script predates the app being wired into override
requests (it is now: `LockScreenView` appends the local event and then asks the roster), so
the script does both the way the server would: it reads the consent token out of the outbox rather than being handed it, and it
advances the commitment's *creation* time so the server recomputes hardening, rather than
writing `hardens_at` (which a trigger would overwrite anyway, and that is the point of the
trigger).

Everything it writes belongs to one demo account under a fixed Apple subject no real
sign-in can produce, with `+1-555` contact numbers. It never touches your account, and:

```sh
backend/tools/demo_request.sh --clean
```

removes only what it made. Re-running the setup cleans first, so it is safe to repeat —
which also means the three-requests-per-day cap never gets in the way.

---

## 6. Sending messages

`message_outbox` is where invitations and approval links queue, and **nothing drains it
yet**. Until something does, a partner can only be reached by copying a link out of the
table by hand.

The app knows this and has stopped offering the form: `Partner.contactInvitationsDeliverable`
is `false`, so Partners → Add partner says the invitation cannot be sent instead of taking a
number and queueing a message nobody will receive. Only friends who are already on Earned can
be accountability partners, and that path needs neither this drainer nor the consent page.
Flip the flag when both exist.

That also means consent cannot be completed the normal way. To do it manually today:

```sh
# The consent token lives only inside the queued message.
psql "$DB" -c "select body from public.message_outbox where body like '%/c/%' order by created_at desc limit 1;"

# Then, as the server:
psql "$DB" -c "select public.respond_to_invitation('<the token from that link>', true);"
```

When you build the drainer, the choice worth making deliberately:

| | Cost | Friction |
|---|---|---|
| **Email** (Resend, Postmark, SES) | Free tier covers a beta | Verify a domain, set SPF/DKIM/DMARC. An afternoon. |
| **SMS** (Twilio and friends) | ~2–5¢ per message | US A2P 10DLC brand and campaign registration, often needing a business entity. Weeks. |

**Start with email.** The schema already supports `channel = 'email'`, and neither the
consent flow nor the approval flow cares which channel carried the link. SMS is the better
product eventually — people read texts — but it should not gate the first real test with
another person.

Set the DNS records early either way: SPF, DKIM and DMARC take a day or two to settle, and
you want them warm before the first invitation goes out. Your provider will give you the
exact records; they go in the same Cloudflare DNS panel as step 5.

§16 also asks for a hard daily ceiling on outbound messages per account, alarmed. The
per-account caps in the database (5 partners, 5 nominations/day, 3 override requests/day)
bound it to at most 15 approval messages per account per day, but the spend alarm belongs
with whoever is billing you.

---

## 7. Scheduled jobs (one of them load-bearing)

Five functions: four housekeeping, one not. The housekeeping four are not load-bearing —
expiry and the receipt window are recomputed wherever they are read, and request creation
retires anything elapsed on its way past — so they keep stored state tidy rather than
keeping the system correct.

**`announce-shared-starts` is the exception**, and the reason this section is no longer
titled "optional": nothing else ever emits the `shared_started` event, so leaving that one
unscheduled would not make the database untidy, it would make a feature silently not
happen.

```sh
psql "$DB" -c "
create extension if not exists pg_cron with schema extensions;
select cron.schedule('expire-override-requests', '*/15 * * * *',
                     \$\$select public.expire_override_requests()\$\$);
select cron.schedule('purge-override-receipts', '17 3 * * *',
                     \$\$select public.purge_override_receipts()\$\$);
select cron.schedule('purge-social-events', '23 3 * * *',
                     \$\$select public.purge_social_events()\$\$);
select cron.schedule('announce-shared-starts', '0 * * * *',
                     \$\$select public.announce_shared_starts()\$\$);
select cron.schedule('purge-shared-commitments', '47 3 * * *',
                     \$\$select public.purge_shared_commitments()\$\$);"
```

(`purge_social_events`, from migration 0017, is the same not-load-bearing shape:
`friend_activity` already refuses to read past the 30-day horizon; the purge keeps
storage honest about the retention promise.)

**Done on the hosted project, 31 August 2026** (the three jobs above) **and 1 September
2026** (the two Shared Commitments jobs in §8). All five jobs are scheduled and active
in `cron.job`, and each function was run once by hand to prove it executes cleanly under
the role cron uses. One divergence from the command above worth knowing: Supabase
relocates pg_cron to `pg_catalog` regardless of the `with schema extensions` clause —
the clause is accepted, the extension picks its own home, and `cron.schedule` works the
same either way.

**Check what is actually scheduled.** The failure mode here is a job nobody ever created,
which from the outside looks exactly like a quiet week:

```sh
psql "$DB" -c "select jobname, schedule, active from cron.job order by jobname;"
```

---

## 8. Social (Milestone S1)

Migrations `0013`–`0018` apply through the same `backend/apply.sh` pass as everything
else. `0015` also creates the `avatars` Storage bucket and its policies when it runs
against a real Supabase project (on a plain Postgres it skips them, loudly); `0016`/`0017`
add commitment sharing, the activity shelf and streak figures, and want the
`purge-social-events` cron from §7; `0018` adds check-in sharing (no cron — the only
stored fact is one timestamp the switch itself deletes).

**Applied to the hosted project, 31 August 2026** (0013–0018), and every check below
verified by SQL the same day — except the two-device pass, which still needs real phones.
**`0019` (earned-user partners) is applied to the hosted project (1 September 2026)** —
it went up by the same road as the rest, and needs no bucket, cron, or dashboard step.

Verified independently from outside the database, with only the publishable key — worth
recording because it is a check anyone can repeat without the connection string. PostgREST
distinguishes a function that exists and refuses `anon` (`401`, SQLSTATE `42501`) from one
that is not there at all (`404`, `PGRST202`), so one RPC probe per migration proves it
landed: `my_partner_requests` (0019), `close_override_request` (0020),
`my_shared_commitments` and `my_shared_invitations` (0021), `register_push_token`,
`announce_shared_starts` and `purge_shared_commitments` (0022) all answered `42501`,
against a control of a made-up name answering `PGRST202`. The four new tables —
`shared_commitment_agreement`, `shared_commitment_participant`, `push_device`,
`push_outbox` — each refuse an anonymous read with `42501`, matching `profile` and
`social_event`. That every new function answered at all also confirms the
`notify pgrst, 'reload schema'` step landed.

**`0020`–`0022` are applied to the hosted project (1 September 2026).** `0020` (close an
override request when it stops mattering) needs nothing special. `0021`/`0022` are Shared
Commitments (`docs/shared-commitments.md`) and are the first social migrations since
`0017` that **want cron**, so they were scheduled at the same time rather than left as a
half-deployment:

- **`announce_shared_starts()`** — emits the `shared_started` event when a shared
  window opens. Unscheduled, that moment simply never reaches anyone's shelf. Hourly is
  ample; the function is idempotent (`start_announced_at` is the latch), so a missed run
  costs lateness, never a duplicate.
- **`purge_shared_commitments()`** — the same not-load-bearing shape as
  `purge_social_events`: retention behind the 30-day horizon plus agreements no
  participant stands on any more. Daily, beside the existing purge cron in §7.

Both are `service_role` only and deliberately not granted to `authenticated`, so they
are scheduled exactly like `purge-social-events`: `announce-shared-starts` hourly
(`0 * * * *`) and `purge-shared-commitments` daily (`47 3 * * *`). Nothing else in
`0021`/`0022` needs a
bucket or a dashboard step. The `push_outbox` they create is **queued but never
drained** until an APNs sender exists — rows accumulating there are the expected state,
not a fault, exactly as `message_outbox` awaited its SMS sender.

Notes from the 0013–0018 run:

- `apply.sh` needs the database connection string, which deliberately lives nowhere on
  disk. When it isn't to hand, there is a second sanctioned road: the **Management API's
  query endpoint** (`POST /v1/projects/<ref>/database/query`), authenticated with the
  Supabase CLI's own access token — which the CLI keeps in the macOS keychain as service
  `Supabase CLI`, so a linked, logged-in machine can deploy without the password. Each
  migration file goes up verbatim as one query; they are convergent, so a failed half can
  simply be re-sent.
- The 0015 storage DO block ran with sufficient privileges — bucket and all four
  policies created by the migration itself. The dashboard-policy-editor fallback below
  was **not** needed, and stays documented only for projects where it is.
- Verified after applying: all five social tables present with RLS enabled and their
  select-own policies; the full profile column set through `share_last_checkin`; exactly
  one `set_social_sharing` (three arguments — 0018's drop of the two-argument version
  took, so PostgREST has no ambiguity); `anon` can execute none of the social functions
  and `authenticated` all of them; bucket caps as below.

Verify after applying:

- **The bucket's caps took.** In the dashboard (Storage → avatars) or via SQL: private,
  `file_size_limit = 1048576`, `allowed_mime_types = {image/jpeg}`. The SQL test suite
  asserts this only where the storage schema exists, so the hosted project is where it
  actually gets checked.
- **The policies exist on `storage.objects`**: `avatars_read`, `avatars_insert`,
  `avatars_update`, `avatars_delete`. If the Supabase project restricts DDL on
  `storage.objects` for the migration role, create the same four policies from the
  dashboard's policy editor — their entire logic is delegated to
  `public.avatar_is_visible(name)` / `public.avatar_path_is_mine(name)`, so the dashboard
  version cannot drift from the tested rule.
- A second test account can find the first by handle, connect, and see its avatar; after a
  block, neither can find the other.

---

## What is still missing

Not deployment problems — unbuilt steps, in
[§22's](accountability-architecture.md) order:

- ~~The app half of step 8~~ — *landed.* The app fetches grants, verifies them against the
  published key set under the compiled-in root key, and offers them to the ledger
  (`app/Earned/Grants/`). What remains is the end-to-end pass on a real device.
- ~~**Moot propagation (step 9)**~~ — *landed.* Migration `0020` added
  `close_override_request`, and the app calls it on the foreground pass for any commitment
  that resolved by some route other than the partners themselves, so a friend who was asked
  at 7am is not still holding a live-looking link at lunchtime
  (`AccountStore.closeResolvedRequests`). What remains of step 9 is the *requester-initiated*
  cancel: there is no "never mind" button.
- **The consent page at `/c/<token>`.** The Worker routes it
  (`web/src/router.ts`) but there is no `consent` edge function behind the route — only
  `approval` and `grants` exist under `supabase/functions/`. So the link a queued invitation
  contains would 404 even if it were delivered.
- **The outbox drainer** (§6 above). Together with the missing consent page this means
  external accountability does not work at all, and the app no longer offers it:
  `Partner.contactInvitationsDeliverable` is `false`, and the invite form says why rather
  than taking a phone number and sending nothing. **Flip that flag in the same change that
  lands both halves**, not before.
- ~~**A `DeviceActivityMonitor` extension**~~ — *built* (`app/EarnedMonitor/`), so a Gate
  closing while the app is not running no longer waits for next launch. Never observed
  working on hardware; see `docs/beta-readiness.md` B‑2 for the device test that would
  settle it.

And two gates that are neither code nor configuration:

- **Family Controls (Distribution)** — free, but Apple reviews it by hand, per bundle ID
  and separately for each Screen Time extension. Needed before TestFlight. Start early.
- **D10, the retention half.** The product semantics of deletion are settled
  ([§21.2](accountability-architecture.md): never blocked by outstanding commitments, no
  social tombstone), but what may lawfully outlive deletion — suppression, abuse records,
  retention periods and their basis — is a privacy and legal question that needs counsel
  before Earned is offered to anyone outside development.
