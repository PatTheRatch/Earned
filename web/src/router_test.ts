// The router, held to the token shapes the database actually mints.
//
// These are not decorative: the whole value of matching at the edge is that a
// malformed token never reaches Postgres, and a regex nobody tested is a regex
// that quietly matches nothing (or everything).

import { route, upstream } from "./router.ts";

function assert(condition: boolean, what: string): void {
  if (!condition) throw new Error(`FAILED: ${what}`);
}

// Exactly what migration 0009 mints: 32 random bytes, base64url, unpadded.
const APPROVAL_TOKEN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
// Exactly what 0006 mints: 32 random bytes as hex.
const CONSENT_TOKEN = "0123456789abcdef".repeat(4);

Deno.test("token shapes are the ones the database mints", () => {
  assert(APPROVAL_TOKEN.length === 43, "approval tokens are 43 base64url chars");
  assert(CONSENT_TOKEN.length === 64, "consent tokens are 64 hex chars");
});

Deno.test("a well-formed approval link routes to the approval function", () => {
  const r = route(`/a/${APPROVAL_TOKEN}`);
  assert(r.kind === "approval", "recognised as an approval link");
  assert(
    upstream(r, "https://ref.functions.supabase.co") ===
      `https://ref.functions.supabase.co/approval/${APPROVAL_TOKEN}`,
    "and points at the approval function with the token intact",
  );
});

Deno.test("a well-formed consent link routes to the consent function", () => {
  const r = route(`/c/${CONSENT_TOKEN}`);
  assert(r.kind === "consent", "recognised as a consent link");
  assert(
    upstream(r, "https://ref.functions.supabase.co") ===
      `https://ref.functions.supabase.co/consent/${CONSENT_TOKEN}`,
    "and points at the consent function",
  );
});

Deno.test("malformed tokens never reach the database", () => {
  const cases: [string, string][] = [
    [`/a/${APPROVAL_TOKEN.slice(0, 42)}`, "one character short"],
    [`/a/${APPROVAL_TOKEN}x`, "one character long"],
    [`/a/${APPROVAL_TOKEN.slice(0, 42)}+`, "base64 that is not base64url"],
    [`/a/${APPROVAL_TOKEN.slice(0, 42)}/`, "a slash smuggled into the token"],
    ["/a/", "no token at all"],
    ["/a", "no trailing path"],
    [`/c/${CONSENT_TOKEN.toUpperCase()}`, "uppercase hex, which is not what is minted"],
    [`/c/${CONSENT_TOKEN.slice(0, 63)}`, "short hex"],
    [`/a/${APPROVAL_TOKEN}/../../etc/passwd`, "path traversal past the token"],
    ["/approval/anything", "the upstream path is not exposed here"],
  ];
  for (const [path, what] of cases) {
    assert(route(path).kind === "site", `${what} falls through to the site`);
  }
});

Deno.test("ordinary site paths are served by the site", () => {
  for (const path of ["/", "/privacy", "/privacy.html", "/index.html", "/anything"]) {
    const r = route(path);
    assert(r.kind === "site", `${path} is site content`);
    assert(upstream(r, "https://ref.functions.supabase.co") === null,
      `${path} has no upstream`);
  }
});

Deno.test("a token cannot be redirected to a different origin", () => {
  // The origin is supplied by configuration, never by the request, so there is
  // no input that makes this point somewhere else.
  const r = route(`/a/${APPROVAL_TOKEN}`);
  const target = upstream(r, "https://ref.functions.supabase.co")!;
  assert(new URL(target).origin === "https://ref.functions.supabase.co",
    "the upstream origin is fixed by config");
});
