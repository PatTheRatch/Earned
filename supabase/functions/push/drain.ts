// The part of the sender worth testing: what happens to one ask, and what a
// failure is worth recording. Kept out of `index.ts` so importing it does not
// start a server.

import { Ask, DeliveryOutcome, deliver } from "./apns.ts";

/// One ask to every device its recipient has.
///
/// The ask is finished when *any* device took it: a person with a phone and an
/// iPad has been told once they have been told anywhere. Dead tokens are
/// discovered here rather than in a sweep, because APNs only ever reports them
/// one delivery at a time.
export async function sendAsk(
  ask: Ask, jwt: string, host: string, topic: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ delivered: boolean; outcomes: DeliveryOutcome[] }> {
  const outcomes: DeliveryOutcome[] = [];
  let delivered = false;
  for (const token of ask.tokens) {
    const outcome = await deliver(host, topic, jwt, ask, token, fetchImpl);
    outcomes.push(outcome);
    if (outcome.status === 200) delivered = true;
  }
  return { delivered, outcomes };
}

/// What to record against a row that did not go cleanly.
///
/// Never the payload: a send error is operational, and the ask's contents are
/// the two people's business. An ask with nobody to send it to summarises to
/// null — the recipient has no device registered or refused notifications,
/// both ordinary, and neither worth retrying forever.
export function summarise(outcomes: DeliveryOutcome[]): string | null {
  if (outcomes.length === 0) return null;
  const failures = outcomes.filter((o) => o.status !== 200);
  if (failures.length === 0) return null;
  return failures.map((o) => `${o.status}${o.reason ? ` ${o.reason}` : ""}`)
    .join("; ").slice(0, 300);
}
