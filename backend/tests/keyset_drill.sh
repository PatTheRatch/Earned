#!/usr/bin/env bash
# The rotation drill of §10.5, run for real: introduce → publish → promote →
# rotate → revoke, with actual Ed25519 keys and actual signatures over the
# actual bytes the database serves back.
#
# 70_key_rotation.sql proves the state machine refuses what it must; this
# proves the crypto path is not theatre. A root key signs each document
# offline (here: openssl standing in for the offline machine), the database
# stores and serves the bytes verbatim, and verification happens the way a
# client would do it — against the served bytes, with the root public key,
# and with the grant public key extracted from the served document itself.
#
# Requires DATABASE_URL pointing at a THROWAWAY database with the migrations
# applied (run.sh arranges exactly that). It truncates the key tables to get a
# clean stage, which is one of several reasons it must never point anywhere
# real — the production drill is run against the real project by a person,
# with the root key on the offline machine this script pretends to be.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL to a throwaway Postgres with migrations applied}"

workdir="$(mktemp -d -t keyset-drill-XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtA "$@"; }

pass() { echo "  ok  $1"; }
fail() { echo "FAILED: $1" >&2; exit 1; }

# Ed25519 keypair; prints the raw 32-byte public key, base64. The private half
# stays in a PEM file, which in production is the Vault secret grant_key_<kid>
# (or, for the root, a file that never leaves the offline machine).
genkey() {
  openssl genpkey -algorithm ed25519 -out "$1.pem" 2>/dev/null
  openssl pkey -in "$1.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A
}

sign() { # sign <keyfile> <docfile> -> base64 signature
  openssl pkeyutl -sign -inkey "$1.pem" -rawin -in "$2" | openssl base64 -A
}

# Build server-side, sign "offline", publish. The document is written with
# printf '%s' so the signed bytes and the published bytes are identical down
# to the absence of a trailing newline.
publish() { # publish <docfile>
  sql -c "select public.build_key_set_document()" | tr -d '\n' > "$1"
  local sig; sig="$(sign root "$1")"
  # psql only interpolates :'variables' from stdin or a file, never from -c.
  echo "select public.publish_key_set(:'doc', :'sig')" \
    | sql -v doc="$(cat "$1")" -v sig="$sig" > /dev/null
}

# Fetch what a client would fetch, and verify it the way a client would:
# signature first, over the raw served bytes, with the root public key —
# parse only after that holds.
fetch_and_verify() { # fetch_and_verify <outfile>
  sql -c "select public.current_key_set() ->> 'document'" | tr -d '\n' > "$1"
  sql -c "select public.current_key_set() ->> 'root_signature'" \
    | openssl base64 -d -A > "$1.sig"
  openssl pkeyutl -verify -pubin -inkey root.pub.pem -rawin \
    -in "$1" -sigfile "$1.sig" > /dev/null 2>&1
}

# Pull one key's raw public key out of a served document and rebuild the SPKI
# DER that openssl wants. The point of doing it from the served bytes rather
# than from the local PEM is that it proves the round trip: what was
# introduced is what clients are told to trust.
served_pubkey() { # served_pubkey <docfile> <kid> -> writes <kid>.served.der
  python3 - "$1" "$2" <<'PY'
import base64, json, sys
doc = json.load(open(sys.argv[1]))
key = next(k for k in doc["keys"] if k["kid"] == sys.argv[2])
raw = base64.b64decode(key["public"])
assert len(raw) == 32
spki = bytes.fromhex("302a300506032b6570032100") + raw
open(sys.argv[2] + ".served.der", "wb").write(spki)
PY
}

doc_field() { # doc_field <docfile> <python expr over doc>
  python3 -c "import json,sys; doc=json.load(open(sys.argv[1])); print($2)" "$1"
}

# server_grant references grant_signing_key (0011).
sql -c "truncate public.server_grant, public.grant_signing_key, public.key_set" > /dev/null

# MARK: - A root, a first key, a first key set

openssl genpkey -algorithm ed25519 -out root.pem 2>/dev/null
openssl pkey -in root.pem -pubout -out root.pub.pem 2>/dev/null

g1_pub="$(genkey g1)"
echo "select public.introduce_grant_key('g1', :'pub')" \
  | sql -v pub="$g1_pub" > /dev/null

publish v1.json
fetch_and_verify served1.json || fail "version 1 does not verify against the root key"
pass "published key set verifies over the exact served bytes"

cmp -s v1.json served1.json || fail "served bytes differ from the signed bytes"
pass "the database serves back byte-for-byte what the root signed"

# Negative control, or the verification above proves nothing: flip one byte.
sed 's/"version": 1/"version": 2/' served1.json | tr -d '\n' > tampered.json
if openssl pkeyutl -verify -pubin -inkey root.pub.pem -rawin \
     -in tampered.json -sigfile served1.json.sig > /dev/null 2>&1; then
  fail "a tampered document still verified — the check is broken"
fi
pass "a tampered document is rejected by the same check"

# MARK: - The signing path

sql -c "select public.promote_grant_key('g1')" > /dev/null
kid="$(sql -c "select public.current_signing_kid()")"
[ "$kid" = "g1" ] || fail "current_signing_kid returned '$kid', wanted g1"

# Sign a stand-in grant payload with the private half (Vault, in production)
# and verify it with the public half a client got from the served document.
printf '%s' '{"decision":"granted","this":"is a stand-in for a grant"}' > grant.json
sign g1 grant.json | openssl base64 -d -A > grant.sig
served_pubkey served1.json g1
openssl pkeyutl -verify -pubin -keyform DER -inkey g1.served.der -rawin \
  -in grant.json -sigfile grant.sig > /dev/null 2>&1 \
  || fail "a grant signed with g1's private key does not verify with the served public key"
pass "the signing path closes: private key signs, served public key verifies"

# MARK: - Rotation

g2_pub="$(genkey g2)"
echo "select public.introduce_grant_key('g2', :'pub')" \
  | sql -v pub="$g2_pub" > /dev/null
publish v2.json
sql -c "select public.promote_grant_key('g2')" > /dev/null

kid="$(sql -c "select public.current_signing_kid()")"
[ "$kid" = "g2" ] || fail "after rotation current_signing_kid is '$kid', wanted g2"
pass "rotation: g2 published as next, then promoted, now signs"

# MARK: - Compromise

sql -c "select public.revoke_grant_key('g1')" > /dev/null
publish v3.json
fetch_and_verify served3.json || fail "version 3 does not verify against the root key"

[ "$(doc_field served3.json '[r["kid"] for r in doc["revoked"]]')" = "['g1']" ] \
  || fail "g1 is not on the kill list of the served document"
[ "$(doc_field served3.json '[k["kid"] for k in doc["keys"]]')" = "['g2']" ] \
  || fail "the served document should list exactly g2 as trusted"
pass "revocation: the served, root-signed document now kills g1 and trusts g2"

# A replayed older document must be refused: rollback resistance is monotonic
# versions, and the server enforces its half of it.
if echo "select public.publish_key_set(:'doc', :'sig')" \
     | sql -v doc="$(cat v2.json)" -v sig="$(sign root v2.json)" > /dev/null 2>&1; then
  fail "republishing version 2 after version 3 was accepted"
fi
pass "a stale document cannot be republished over a newer one"

echo "==> key rotation drill complete: rotated in anger once already (§10.5)"
