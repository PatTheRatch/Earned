// Signing a grant, as narrowly as possible.
//
// Pure apart from WebCrypto, so its tests run anywhere Deno does and none of
// them need a database, a network, or a deployed function.

// Where a kid's private key lives.
//
// **Not Supabase Vault**, and that is a deliberate departure from what §10.1
// sketched. The grant signing key is the one secret whose loss lets someone
// mint permission the account holder never earned, which is the single thing
// this entire design exists to prevent. Keeping it in the platform's function
// secrets rather than in the database means a total database compromise —
// every table, every Vault row, the service role itself — still does not
// yield the ability to sign a grant. Contact keys stay in Vault because they
// protect data that is in the database anyway; this one protects against the
// database.
//
// The kid pattern is pinned by the schema (`^g[0-9]+$`), so this can only ever
// produce a boring name, but it is checked again rather than trusted: an
// environment lookup built from unvalidated input is how a config read turns
// into a way of asking for the wrong secret.
export function envNameFor(kid: string): string {
  if (!/^g[0-9]+$/.test(kid)) throw new Error(`refusing to look up a key named ${kid}`);
  return `GRANT_KEY_${kid.toUpperCase()}`;
}

// Allocated, and typed over ArrayBuffer explicitly. Both matter: a bare
// `Uint8Array` annotation widens to ArrayBufferLike, and WebCrypto's
// BufferSource will not accept a view that might be over shared memory.
export function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value.replace(/\s+/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function encodeBase64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

/**
 * Sign the exact bytes of a grant document.
 *
 * `pkcs8Base64` is the body of an Ed25519 private key PEM with its header,
 * footer and newlines removed — what `openssl genpkey -algorithm ed25519`
 * produces, minus the decoration.
 *
 * The document is signed as UTF-8 bytes and returned base64. Nothing here
 * parses the document: what is signed is what was handed over, which is the
 * same discipline the key sets use, and the reason the app can verify before
 * it parses.
 */
export async function signDocument(
  pkcs8Base64: string,
  document: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    decodeBase64(pkcs8Base64),
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "Ed25519" },
    key,
    new TextEncoder().encode(document),
  );
  return encodeBase64(new Uint8Array(signature));
}
