import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { Ask, deliver, payloadFor } from "./apns.ts";
import { sendAsk, summarise } from "./drain.ts";
import { callRpc } from "./rpc.ts";

const ask: Ask = {
  id: "11111111-1111-1111-1111-111111111111",
  kind: "shared_invitation",
  title: "Patrick invited you.",
  body: "Run 3 times this week",
  route_id: "22222222-2222-2222-2222-222222222222",
  tokens: ["token-a", "token-b"],
};

Deno.test("the payload carries the ask and nothing about the person", () => {
  const payload = payloadFor(ask) as Record<string, unknown>;
  const encoded = JSON.stringify(payload);

  const aps = payload.aps as Record<string, unknown>;
  assertEquals((aps.alert as Record<string, string>).title, "Patrick invited you.");
  assertEquals(payload.kind, "shared_invitation");
  assertEquals(payload.route, ask.route_id);

  // The recipient is a party to the agreement, so its id is theirs to know.
  // Nothing else about anybody may ride along.
  assert(!encoded.includes("account"), "no account identifiers in the payload");
  assert(!encoded.includes("health"), "no health data in the payload");
  assert(!encoded.includes("reason"), "no override reason text in the payload");
});

Deno.test("a re-send of one ask collapses into a single banner", () => {
  const aps = (payloadFor(ask) as { aps: Record<string, string> }).aps;
  // Same ask, same collapse id: APNs replaces rather than stacks, so a retry
  // that reached Apple twice still buzzes once.
  assertEquals(aps["collapse-id"], ask.id);
});

Deno.test("a 410 marks the token gone rather than merely failed", async () => {
  const outcome = await deliver(
    "https://apns.test", "com.example", "jwt", ask, "dead-token",
    () => Promise.resolve(new Response(JSON.stringify({ reason: "Unregistered" }),
                                       { status: 410 })),
  );
  assert(outcome.unregistered, "410 Unregistered is permanent");
});

Deno.test("a 429 is a failure to retry, not a token to delete", async () => {
  const outcome = await deliver(
    "https://apns.test", "com.example", "jwt", ask, "live-token",
    () => Promise.resolve(new Response(JSON.stringify({ reason: "TooManyRequests" }),
                                       { status: 429 })),
  );
  assert(!outcome.unregistered, "throttling says nothing about the device");
  assertEquals(outcome.status, 429);
});

Deno.test("one device taking the ask is enough", async () => {
  let call = 0;
  const result = await sendAsk(ask, "jwt", "https://apns.test", "com.example",
    () => {
      call += 1;
      return Promise.resolve(call === 1
        ? new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 })
        : new Response("", { status: 200 }));
    });
  assert(result.delivered, "the person has been told, on the device that worked");
  assertEquals(result.outcomes.length, 2);
  assert(result.outcomes[0].unregistered, "and the dead token is reported for removal");
});

Deno.test("failures are summarised without leaking the payload", () => {
  const summary = summarise([
    { token: "a", status: 429, reason: "TooManyRequests", unregistered: false },
    { token: "b", status: 200, unregistered: false },
  ]);
  assertEquals(summary, "429 TooManyRequests");
  assertEquals(summarise([{ token: "a", status: 200, unregistered: false }]), null,
               "a clean send has nothing to record");
  assertEquals(summarise([]), null, "and nobody to send to is not a failure");
});

Deno.test("a void RPC answers 204, and that is not a parse error", async () => {
  // complete_push and forget_push_token return void, so PostgREST answers
  // 204 No Content. Parsing that as JSON threw on the first live run: the
  // database had already marked one ask delivered, the sender died on the way
  // back, and the rest of the batch sat claimed and untouched.
  const result = await callRpc(
    "https://db.test", "key", "complete_push", { p_id: "x" },
    () => Promise.resolve(new Response(null, { status: 204 })),
  );
  assertEquals(result, null);
});

Deno.test("an empty 200 body is also not a parse error", async () => {
  const result = await callRpc(
    "https://db.test", "key", "complete_push", {},
    () => Promise.resolve(new Response("", { status: 200 })),
  );
  assertEquals(result, null);
});

Deno.test("a jsonb RPC still parses", async () => {
  const result = await callRpc(
    "https://db.test", "key", "claim_push_batch", { p_limit: 1 },
    () => Promise.resolve(new Response(JSON.stringify([{ id: "a" }]),
                                       { status: 200 })),
  );
  assertEquals(result, [{ id: "a" }]);
});

Deno.test("a refusal carries what the database said", async () => {
  let message = "";
  try {
    await callRpc("https://db.test", "key", "claim_push_batch", {},
      () => Promise.resolve(new Response("permission denied for function",
                                         { status: 403 })));
  } catch (error) {
    message = String(error);
  }
  assert(message.includes("403"), "the status survives");
  assert(message.includes("permission denied"),
         "and the reason, which is the difference between a fix and an afternoon");
});
