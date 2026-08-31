// The partner page: GET shows a token's page, POST casts its vote.
//
// Server-rendered on purpose (§18). No Supabase credential reaches the
// browser, no JavaScript runs there, and the token in the URL is the entire
// credential — which is also why POST needs no CSRF artifice: there is no
// cookie or session for a cross-site request to ride on.
//
// This file is a thin transport around two SQL functions. Everything with
// rules in it — what each token state answers, who may vote, what a second
// tap does — lives in migration 0010 where the test suite holds it down;
// everything with words in it lives in render.ts where its own tests do.

import { renderPage, type Page } from "./render.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function rpc(name: string, args: Record<string, unknown>): Promise<Page> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_KEY,
      authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    throw new Error(`${name} refused: ${response.status} ${await response.text()}`);
  }
  return await response.json() as Page;
}

// The audit log keeps hashed addresses only (§15). The salt rotates daily, so
// rows correlate within a day (enough to spot token guessing) and not across
// days. Honest limitation: without a key the hash of a known IP is checkable
// for that day; the log carries no other identity to join it to.
async function dailyHash(value: string | null): Promise<string | null> {
  if (!value) return null;
  const day = new Date().toISOString().slice(0, 10);
  const bytes = new TextEncoder().encode(`${day}:${value}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return "\\x" + Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Note that Supabase overrides two of these on *.functions.supabase.co: it
// forces content-type to text/plain and replaces the CSP with `sandbox`, so
// the page arrives as source text if it is fetched from that domain directly.
// That is an anti-abuse rule for a shared function domain, not a bug, and the
// Cloudflare worker in web/ restores both on the way to earntherest.com. These
// stay correct here because they are what the response means, and because the
// day this moves behind a Supabase custom domain they stop being overridden.
function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex, nofollow",
      "referrer-policy": "no-referrer",
      "content-security-policy":
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
    },
  });
}

Deno.serve(async (request: Request): Promise<Response> => {
  const token = new URL(request.url).pathname.split("/").filter(Boolean).pop() ?? "";
  const ipHash = await dailyHash(request.headers.get("x-forwarded-for"));
  const uaHash = await dailyHash(request.headers.get("user-agent"));

  try {
    if (request.method === "GET") {
      const page = await rpc("approval_page", {
        p_token: token, p_ip_hash: ipHash, p_ua_hash: uaHash,
      });
      return html(renderPage(page));
    }

    if (request.method === "POST") {
      const form = await request.formData();
      const vote = form.get("vote");
      if (vote !== "approve" && vote !== "deny") {
        return html(renderPage({ page: "invalid" }), 400);
      }
      const page = await rpc("cast_override_vote", {
        p_token: token, p_vote: vote, p_ip_hash: ipHash, p_ua_hash: uaHash,
      });
      return html(renderPage(page));
    }

    return new Response("method not allowed", { status: 405 });
  } catch (error) {
    // A partner mid-decision gets an apology, not a stack trace; the trace
    // goes where the operator reads.
    console.error(error);
    return html(renderPage({ page: "invalid" }), 500);
  }
});
