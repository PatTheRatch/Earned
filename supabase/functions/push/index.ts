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
import { callRpc } from "./rpc.ts";

const rpc = (name: string, args: unknown = {}) =>
  callRpc(SUPABASE_URL, SERVICE_KEY, name, args);

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

  let asks: Ask[];
  try {
    asks = ((await rpc("claim_push_batch", { p_limit: 50 })) ?? []) as Ask[];
  } catch (error) {
    return new Response(JSON.stringify({ error: `claim failed: ${error}` }),
                        { status: 500, headers: { "content-type": "application/json" } });
  }
  // Counted apart on purpose. An ask with no registered device is *finished*
  // — the recipient refused notifications, or has not opened the app on a
  // phone yet — but nothing rang, and a sender that reports it as "sent" is
  // the operator's version of the app claiming a restriction it never applied.
  let delivered = 0;
  let nobody = 0;
  let failed = 0;
  let errored = 0;
  const forgotten = new Set<string>();

  for (const ask of asks) {
    // One ask that goes wrong leaves the rest of the batch alone. Anything
    // thrown here leaves its row claimed and uncompleted, which the claim
    // timeout hands back — late, rather than lost.
    try {
      const { delivered: took, outcomes } =
        await sendAsk(ask, jwt, APNS_HOST, APNS_TOPIC);
      for (const outcome of outcomes) {
        if (outcome.unregistered && !forgotten.has(outcome.token)) {
          forgotten.add(outcome.token);
          await rpc("forget_push_token", { p_token: outcome.token });
        }
      }
      // Nobody to tell is done, not failed.
      const reachable = ask.tokens.length > 0;
      const error = !reachable || took ? null : summarise(outcomes);
      await rpc("complete_push", { p_id: ask.id, p_error: error });
      if (error !== null) failed += 1;
      else if (reachable) delivered += 1;
      else nobody += 1;
    } catch {
      errored += 1;
    }
  }

  return new Response(
    JSON.stringify({ claimed: asks.length, delivered, nobody, failed, errored,
                     forgotten: forgotten.size }),
    { headers: { "content-type": "application/json" } },
  );
});
