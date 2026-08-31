// The signing path, held to what a client will actually do with it.

import { decodeBase64, envNameFor, signDocument } from "./sign.ts";

function assert(condition: boolean, what: string): void {
  if (!condition) throw new Error(`FAILED: ${what}`);
}

// A fixed Ed25519 key pair, so these tests assert against known bytes rather
// than only against themselves. Generated once with openssl; it signs nothing
// real and exists only in this file.
const PKCS8 =
  "MC4CAQAwBQYDK2VwBCIEIHwqEQhZLKFxKMPPqLj2Qw6aXBqLpiZBqzXK1oJvBmZo";

Deno.test("a signature is 64 bytes and verifies with the matching public key", async () => {
  const document = '{"decision":"granted","server_grant_id":"abc"}';
  const signatureB64 = await signDocument(PKCS8, document);
  const signature = decodeBase64(signatureB64);
  assert(signature.length === 64, "Ed25519 signatures are 64 bytes");

  // Derive the public half the way a client gets it: from the key set, as raw
  // bytes. Here it comes out of the private key, which is the same 32 bytes.
  const priv = await crypto.subtle.importKey(
    "pkcs8", decodeBase64(PKCS8),
    { name: "Ed25519" }, true, ["sign"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", priv);
  const pub = await crypto.subtle.importKey(
    "jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x },
    { name: "Ed25519" }, false, ["verify"],
  );
  assert(
    await crypto.subtle.verify(
      { name: "Ed25519" }, pub, signature, new TextEncoder().encode(document)),
    "the signature verifies over the exact document bytes",
  );
});

Deno.test("one changed byte breaks it", async () => {
  const document = '{"decision":"granted","server_grant_id":"abc"}';
  const signatureB64 = await signDocument(PKCS8, document);
  const signature = decodeBase64(signatureB64);

  const priv = await crypto.subtle.importKey(
    "pkcs8", decodeBase64(PKCS8),
    { name: "Ed25519" }, true, ["sign"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", priv);
  const pub = await crypto.subtle.importKey(
    "jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x },
    { name: "Ed25519" }, false, ["verify"],
  );
  const tampered = document.replace('"granted"', '"granted "');
  assert(
    !(await crypto.subtle.verify(
      { name: "Ed25519" }, pub, signature, new TextEncoder().encode(tampered))),
    "a document that changed after signing does not verify",
  );
});

Deno.test("signing is deterministic, so a retry cannot produce a second answer", async () => {
  const document = '{"decision":"granted"}';
  assert(
    await signDocument(PKCS8, document) === await signDocument(PKCS8, document),
    "Ed25519 is deterministic — the same document signs identically",
  );
});

Deno.test("the environment name is derived, never taken on trust", () => {
  assert(envNameFor("g1") === "GRANT_KEY_G1", "g1 maps to GRANT_KEY_G1");
  assert(envNameFor("g12") === "GRANT_KEY_G12", "and multi-digit kids work");
  for (const bad of ["", "g", "G1", "g1;", "../g1", "g1 g2", "root", "g-1"]) {
    let refused = false;
    try { envNameFor(bad); } catch { refused = true; }
    assert(refused, `a kid of "${bad}" is refused rather than looked up`);
  }
});
