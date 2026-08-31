// Where a link goes, decided before anything is fetched.
//
// Two paths carry tokens, and both were minted by the database with a shape
// this file knows exactly (migrations 0006 and 0009). Everything that does not
// match those shapes is refused here, at the edge, without touching Postgres —
// which takes the cheapest slice of §16's token-guessing surface off the table
// for nothing. Rate limiting on `/a/*` is the rest of that gate and belongs to
// the platform's own rules, not to this code.
//
// A pure function, so it can be tested without a network, a Worker runtime, or
// a Cloudflare account.

export type Route =
  | { kind: "approval"; token: string }
  | { kind: "consent"; token: string }
  | { kind: "site" };

// 32 bytes of CSPRNG, base64url, unpadded: 43 characters (§6.1).
const APPROVAL = /^\/a\/([A-Za-z0-9_-]{43})$/;

// 32 bytes of CSPRNG, hex: 64 characters (0006's `encode(..., 'hex')`).
const CONSENT = /^\/c\/([0-9a-f]{64})$/;

export function route(pathname: string): Route {
  const approval = APPROVAL.exec(pathname);
  if (approval) return { kind: "approval", token: approval[1] };

  const consent = CONSENT.exec(pathname);
  if (consent) return { kind: "consent", token: consent[1] };

  // Anything else is the marketing site, including a malformed token. A
  // stranger who mistypes a character gets the site rather than a diagnosis
  // of what they got wrong.
  return { kind: "site" };
}

// The edge function a route proxies to. Proxy, never redirect: a 302 flips the
// address bar to a Supabase subdomain at the exact moment a partner is deciding
// whether to trust the page, which throws away the entire reason for owning a
// domain (§17 — a leaked or forwarded link should look like what it is).
export function upstream(route: Route, functionsOrigin: string): string | null {
  switch (route.kind) {
    case "approval":
      return `${functionsOrigin}/approval/${route.token}`;
    case "consent":
      // Build order step 9. Until that function is deployed this 404s from
      // Supabase, which is the honest answer: the link is real, the page is
      // not built yet.
      return `${functionsOrigin}/consent/${route.token}`;
    case "site":
      return null;
  }
}
