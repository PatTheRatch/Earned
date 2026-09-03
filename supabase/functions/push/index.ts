// POST /push — drain the queue of actionable asks to APNs.
//
// The other half of `push_outbox`, which has existed since migration 0022 and
// until now was written to and never read. Two people testing on two phones
// found the consequence immediately: an invitation only existed if you thought
// to go and look for it, which is not a thing two people can coordinate.
//
// **Push is delivery, never authority.** Nothing here decides anything, and
// nothing here is the source of truth for anything. Every ask exists as a row
// the recipient can already see in the app; this makes their phone mention it.
// A failed send costs a buzz, never a fact — which is why the app must keep
// working with notifications refused, and does.
//
// What is deliberately not sendable: the queue's `kind` column is a check
// constraint with three values, all of them asks that a named person made of
// this specific user. There is no row shape for "your friend went for a run",
// so no amount of code here can send one (docs/social-architecture.md §9).
//
// Run it from cron. It claims a batch, delivers, and records the outcome; a
// crash between claiming and recording leaves the row claimable again after
// the claim ages out, so the failure mode is a late notification rather than
// a lost or duplicated one.

import { Ask, providerToken } from "./apns.ts";
import { sendAsk, summarise } from "./drain.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const APNS_KEY = Deno.env.get("APNS_KEY") ?? "";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_TOPIC = Deno.env.get("APNS_TOPIC") ?? "com.pattheratch.earned";
// Sandbox for development builds, production for TestFlight and the App Store.
// A token minted on one is rejected by the other, which presents as silent
// non-delivery, so it is configuration rather than a guess.
const APNS_HOST = Deno.env.get("APNS_HOST") ?? "https://api.sandbox.push.apple.com";

async function rpc(name: string, args: unknown = {}): Promise<unknown> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_KEY,
      authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) throw new Error(`${name}: ${response.status}`);
  return await response.json();
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }
  if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
    // Said plainly in the response, because the alternative is a sender that
    // reports success while nobody's phone ever rings.
    return new Response(
      JSON.stringify({ error: "APNs credentials are not configured" }),
      { status: 503, headers: { "content-type": "application/json" } },
    );
  }

  let jwt: string;
  try {
    jwt = await providerToken(APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID);
  } catch (error) {
    return new Response(
      JSON.stringify({ error: `APNs key unusable: ${error}` }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const asks = (await rpc("claim_push_batch", { p_limit: 50 })) as Ask[];
  let sent = 0;
  let failed = 0;
  const forgotten = new Set<string>();

  for (const ask of asks) {
    const { delivered, outcomes } = await sendAsk(ask, jwt, APNS_HOST, APNS_TOPIC);
    for (const outcome of outcomes) {
      if (outcome.unregistered && !forgotten.has(outcome.token)) {
        forgotten.add(outcome.token);
        await rpc("forget_push_token", { p_token: outcome.token });
      }
    }
    // Nobody to tell is done, not failed.
    const error = ask.tokens.length === 0 || delivered
      ? null : summarise(outcomes);
    await rpc("complete_push", { p_id: ask.id, p_error: error });
    if (error === null) sent += 1; else failed += 1;
  }

  return new Response(
    JSON.stringify({ claimed: asks.length, sent, failed,
                     forgotten: forgotten.size }),
    { headers: { "content-type": "application/json" } },
  );
});
