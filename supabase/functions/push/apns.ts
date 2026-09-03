// APNs token authentication, and one delivery.
//
// The provider token is a JWT signed with an ES256 key from the Apple
// Developer portal. Apple rate-limits token *creation* rather than use, and
// rejects tokens older than an hour, so one is minted per process and reused —
// a fresh token per notification is the documented way to get 429ed.

const TOKEN_LIFETIME_MS = 45 * 60 * 1000;

interface CachedToken {
  jwt: string;
  mintedAt: number;
}

let cached: CachedToken | null = null;

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/// The provider token. `now` is injectable so the expiry rule can be tested
/// without waiting three quarters of an hour.
export async function providerToken(
  keyPem: string, keyId: string, teamId: string, now: number = Date.now(),
): Promise<string> {
  if (cached && now - cached.mintedAt < TOKEN_LIFETIME_MS) return cached.jwt;

  const key = await crypto.subtle.importKey(
    "pkcs8", pemToPkcs8(keyPem),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const header = base64url(new TextEncoder()
    .encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64url(new TextEncoder()
    .encode(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) })));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const jwt = `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
  cached = { jwt, mintedAt: now };
  return jwt;
}

/// Reset between tests; also the escape hatch if a key is rotated under a
/// warm process.
export function forgetProviderToken(): void {
  cached = null;
}

export interface Ask {
  id: string;
  kind: string;
  title: string;
  body: string;
  route_id: string | null;
  tokens: string[];
}

/// What actually crosses to Apple.
///
/// Deliberately not in here: anything the recipient has not already been told
/// by the ask itself. No Health data, no restriction profiles, no Override
/// reason text, no account identifiers. `route` is the row the recipient is
/// already a party to, which is what makes the tap land somewhere.
export function payloadFor(ask: Ask): unknown {
  return {
    aps: {
      alert: { title: ask.title, body: ask.body },
      sound: "default",
      // Coalesces a re-send of the same ask into one banner, so a retry that
      // reached Apple twice cannot buzz twice.
      "collapse-id": ask.id,
      "interruption-level": "active",
    },
    kind: ask.kind,
    route: ask.route_id,
  };
}

export interface DeliveryOutcome {
  token: string;
  status: number;
  reason?: string;
  /// APNs says this token is gone and should never be used again.
  unregistered: boolean;
}

export async function deliver(
  host: string, topic: string, jwt: string, ask: Ask, token: string,
  fetchImpl: typeof fetch = fetch,
): Promise<DeliveryOutcome> {
  const response = await fetchImpl(`${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": "alert",
      "apns-collapse-id": ask.id,
      "content-type": "application/json",
    },
    body: JSON.stringify(payloadFor(ask)),
  });
  if (response.status === 200) {
    return { token, status: 200, unregistered: false };
  }
  let reason = "";
  try {
    reason = ((await response.json()) as { reason?: string }).reason ?? "";
  } catch {
    reason = `http ${response.status}`;
  }
  // 410 is Apple saying the app is gone from that device; BadDeviceToken means
  // it was never right. Both are permanent, and believing them is the only
  // thing that keeps the device table the size of the fleet.
  const unregistered = response.status === 410 || reason === "Unregistered"
    || reason === "BadDeviceToken";
  return { token, status: response.status, reason, unregistered };
}
