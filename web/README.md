# web/

`earntherest.com`: the marketing site, the privacy notice, and the two paths that carry
tokens to Supabase edge functions.

Full setup — DNS, deployment, rate limiting — is
[`docs/deployment.md`](../docs/deployment.md) §5. This file is what the code does and why.

## What it is

A Cloudflare Worker with a static site bound to it. Three routes:

| Path | Goes to |
|---|---|
| `/a/<43 base64url chars>` | the `approval` edge function — the partner page (migration 0010) |
| `/c/<64 hex chars>` | the `consent` edge function — not built yet, step 9 |
| everything else | the static site in `public/` |

## Why a proxy and not a redirect

A redirect is one line of configuration and would be wrong. The link arrives in an
unsolicited message, and a 302 flips the address bar to `<ref>.functions.supabase.co` at
the exact moment a stranger is deciding whether to trust the page in front of them. That
throws away the reason for owning a domain at all.

The Worker fetches the function's response and returns it under `earntherest.com`, so the
partner sees one origin from message to decision.

## Why the token shapes are pinned here

`src/router.ts` matches exactly what the database mints — 43 base64url characters for an
approval token (0009), 64 hex for a consent token (0006). Anything else falls through to
the site and never reaches Postgres.

That is the cheapest slice of §16's token-guessing surface, taken off the table for free.
It is not the whole gate: **per-IP rate limiting on `/a/*` is still required** and lives in
the Cloudflare dashboard, because Supabase does not provide it. A malformed token costs an
attacker nothing here; a well-formed guess still reaches the database, and 256 bits is what
makes that arithmetic rather than a threat model.

`src/router_test.ts` holds the patterns down — one short, one long, base64 that is not
base64url, a smuggled slash, path traversal past the token, uppercase hex. A regex nobody
tested is a regex that quietly matches nothing.

## Running the tests

```sh
deno test web/src/
deno check web/src/index.ts
```

CI runs both on every push.

## Deploying

```sh
cd web
npx wrangler deploy
```

`wrangler.toml` needs your project ref in `SUPABASE_FUNCTIONS_URL` first. The value is
public — it is an origin, and the token in the URL is the credential (S1, S2). No secret
belongs in this directory.
