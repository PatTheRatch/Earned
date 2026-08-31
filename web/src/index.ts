// earntherest.com — the marketing site, and the two paths that carry tokens.
//
// The Worker is deliberately thin. It decides where a request goes (router.ts,
// which is tested) and then either proxies to a Supabase edge function or hands
// the request to the static site. It holds no secrets: `SUPABASE_FUNCTIONS_URL`
// is a public origin, and the token in the URL is the entire credential the
// partner page needs (S1, S2).

import { route, upstream } from "./router.ts";

interface Env {
  SUPABASE_FUNCTIONS_URL: string;
  ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const target = upstream(route(url.pathname), env.SUPABASE_FUNCTIONS_URL);

    if (target === null) return env.ASSETS.fetch(request);

    // An allowlist, not a copy of the incoming headers. Forwarding everything
    // sends `host: earntherest.com` and a pile of cf-* headers to Supabase,
    // which is at best noise and at worst a request that routes nowhere. Only
    // three headers mean anything to the function at the other end:
    // content-type for the page's form post, and the two the function hashes
    // for its audit log (§15). The Worker never sees the hashes and never
    // stores the address.
    const headers = new Headers();
    const contentType = request.headers.get("content-type");
    if (contentType) headers.set("content-type", contentType);
    headers.set("x-forwarded-for", request.headers.get("cf-connecting-ip") ?? "");
    headers.set("user-agent", request.headers.get("user-agent") ?? "");

    let response: Response;
    try {
      response = await fetch(target, {
        method: request.method,
        headers,
        body: request.method === "GET" || request.method === "HEAD"
          ? undefined
          : await request.arrayBuffer(),
        redirect: "manual",
      });
    } catch (error) {
      // A partner mid-decision must never see a bare platform error page.
      // Throwing here would hand them Cloudflare's, which tells them nothing
      // and looks like the scam this link already has to work to avoid.
      console.error("upstream fetch failed", target, error);
      return new Response(UNAVAILABLE, {
        status: 502,
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    // A partner page is per-person and time-sensitive; nothing about it should
    // be cached by an intermediary or indexed by anyone.
    const out = new Headers(response.headers);
    out.set("cache-control", "no-store");
    out.set("x-robots-tag", "noindex, nofollow");
    return new Response(response.body, { status: response.status, headers: out });
  },
};

// Deliberately plain, and deliberately not an explanation. Someone holding
// this link is a stranger doing a favour; "try again shortly" is the whole of
// what is useful to them, and anything about our infrastructure is both
// useless and a small gift to anyone probing.
const UNAVAILABLE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Earned</title>
<style>body{margin:0;background:#F2EFE9;color:#141210;
font:16px/1.55 -apple-system,"Segoe UI",system-ui,sans-serif}
main{max-width:34rem;margin:0 auto;padding:3rem 1.25rem}
h1{font-size:1.35rem;margin:0 0 1rem}p{color:#6F6A61}</style>
</head><body><main>
<h1>This page is temporarily unavailable.</h1>
<p>Nothing is wrong with the link. Please try again shortly.</p>
</main></body></html>`;
