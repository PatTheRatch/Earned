// GET /grants — the app asks what it has been granted.
//
// Build order step 8 (docs/accountability-architecture.md §9). The app polls
// this on foreground; it receives a decision, never votes (§9.1).
//
// Three roles meet here, and keeping them apart is the point:
//
//   the caller   authenticated as their own account. Their JWT is forwarded,
//                so `my_grants()` sees their `auth.uid()` and RLS applies to
//                them exactly as it would anywhere else.
//   service_role signs and stores. The account holder has no path to this.
//   the key      neither of the above. It lives in this function's own
//                environment, so a database compromise cannot sign a grant.
//
// This function never decides anything. Whether a request resolved, who voted
// and what the contract said are all settled in SQL before a document exists;
// all that happens here is a signature over bytes the database composed.

import { envNameFor, signDocument } from "./sign.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function rpc(name: string, authorization: string, args: unknown = {}) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_KEY,
      authorization,
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    throw new Error(`${name}: ${response.status} ${await response.text()}`);
  }
  return await response.json();
}

const asService = (name: string, args: unknown = {}) =>
  rpc(name, `Bearer ${SERVICE_KEY}`, args);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

Deno.serve(async (request: Request): Promise<Response> => {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    return json({ error: "sign in first" }, 401);
  }

  try {
    // As the caller. Creates unsigned documents for any of *their* resolved
    // requests that lack one, and returns whatever is already signed.
    await rpc("my_grants", authorization);

    // As the server. Deliberately not scoped to the caller: whoever polls
    // drains the queue, so a grant is signed by the first app to come asking
    // rather than waiting for its own owner to open theirs.
    const unsigned = await asService("unsigned_grants") as
      Array<{ id: string; kid: string; document: string }>;

    for (const grant of unsigned) {
      const pkcs8 = Deno.env.get(envNameFor(grant.kid));
      if (!pkcs8) {
        // A key the schema believes in but this environment does not hold.
        // Leaving the grant unsigned is correct: it stays invisible to the
        // app, and the operator gets told which secret is missing.
        console.error(`no signing key configured for ${grant.kid}`);
        continue;
      }
      const signature = await signDocument(pkcs8, grant.document);
      await asService("store_override_grant", {
        p_grant_id: grant.id,
        p_signature: signature,
      });
    }

    // As the caller again, now that signatures exist.
    return json({ grants: await rpc("my_grants", authorization) });
  } catch (error) {
    console.error(error);
    return json({ error: "could not load grants" }, 500);
  }
});
