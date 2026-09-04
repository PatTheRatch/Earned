// Calling the database from the sender.
//
// Extracted so the empty-body case has a test. `claim_push_batch` returns
// jsonb; `complete_push` and `forget_push_token` return void, and PostgREST
// answers a void function with **204 No Content**. Parsing that as JSON throws
// a SyntaxError — which, on the first live run with real APNs credentials,
// killed the drain after it had already marked one ask delivered and claimed
// two more. The rows were left claimed and uncompleted, which the claim
// timeout recovers, but the sender never got past its first row.
//
// `response.ok` is true for a 204, so the guard has to be about the body, not
// the status.

export async function callRpc(
  url: string, serviceKey: string, name: string, args: unknown = {},
  fetchImpl: typeof fetch = fetch,
): Promise<unknown> {
  const response = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: serviceKey,
      authorization: `Bearer ${serviceKey}`,
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    // The body often names the constraint or the missing grant, which is the
    // difference between a five-minute fix and an afternoon.
    const detail = await response.text().catch(() => "");
    throw new Error(`${name}: ${response.status} ${detail}`.trim());
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text.length === 0 ? null : JSON.parse(text);
}
