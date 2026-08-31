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

    // Forward method and body so the page's own form post reaches the vote
    // endpoint, and pass the client's address along in the header the edge
    // function hashes (§15) — the Worker never sees the hash and never stores
    // the address.
    const headers = new Headers(request.headers);
    headers.set("x-forwarded-for", request.headers.get("cf-connecting-ip") ?? "");

    const response = await fetch(target, {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD"
        ? undefined
        : await request.arrayBuffer(),
      redirect: "manual",
    });

    // A partner page is per-person and time-sensitive; nothing about it should
    // be cached by an intermediary or indexed by anyone.
    const out = new Headers(response.headers);
    out.set("cache-control", "no-store");
    out.set("x-robots-tag", "noindex, nofollow");
    return new Response(response.body, { status: response.status, headers: out });
  },
};
