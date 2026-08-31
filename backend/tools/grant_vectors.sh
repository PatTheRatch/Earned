#!/usr/bin/env bash
# Produce real Ed25519 test vectors for EarnedKit, from the real schema.
#
# EarnedKit's tests can prove a great deal about verification with a fake
# signature primitive — that the right bytes reach it, that a revoked key is
# refused, that nothing is parsed before it is checked. What a fake cannot
# prove is the thing most likely to break silently: that Swift agrees with
# Postgres and OpenSSL about what the bytes *are*. Timestamp rendering, base64
# padding, key ordering inside a jsonb document — each is invisible until it
# isn't, and none of it is caught by testing Swift against Swift.
#
# So the vectors are made here, by the same code paths production uses, and
# frozen into GrantVectors.swift. On macOS, EarnedKit verifies them with real
# CryptoKit; that test is the only place the three implementations are ever
# checked against each other.
#
# Regenerate deliberately, never to make a red test go green — a vector that
# stopped verifying means the wire format moved, and that is a decision, not a
# chore. Requires DATABASE_URL pointing at a THROWAWAY database with the
# migrations applied; it truncates the key and grant tables.
#
#   backend/tools/grant_vectors.sh > \
#     packages/EarnedKit/Tests/EarnedKitTests/GrantVectors.swift
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL to a throwaway Postgres with migrations applied}"

workdir="$(mktemp -d -t grant-vectors-XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtA "$@"; }

APPLE_SUB='apple-sub-grant-vectors'
AUTH_UID='cafe0000-0000-4000-8000-000000000011'
COMMITMENT='cafe0000-0000-4000-8000-0000000000d1'

sql <<SQL > /dev/null
delete from public.override_request r using public.account a
 where a.id = r.account_id and a.apple_user_id = '$APPLE_SUB';
delete from public.account where apple_user_id = '$APPLE_SUB';
truncate public.server_grant, public.grant_signing_key, public.key_set cascade;
SQL

cd "$workdir"
openssl genpkey -algorithm ed25519 -out root.pem 2>/dev/null
openssl genpkey -algorithm ed25519 -out g1.pem 2>/dev/null
openssl genpkey -algorithm ed25519 -out g2.pem 2>/dev/null
raw_pub() { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A; }
root_pub="$(raw_pub root.pem)"
g1_pub="$(raw_pub g1.pem)"
g2_pub="$(raw_pub g2.pem)"
cd - > /dev/null

publish() { # publish -> prints "<document>\t<signature>"
  sql -c "select public.build_key_set_document()" | tr -d '\n' > "$workdir/ks.json"
  local sig
  sig="$(openssl pkeyutl -sign -inkey "$workdir/root.pem" -rawin \
           -in "$workdir/ks.json" | openssl base64 -A)"
  echo "select public.publish_key_set(:'doc', :'sig')" \
    | sql -v doc="$(cat "$workdir/ks.json")" -v sig="$sig" > /dev/null
  printf '%s\t%s\n' "$(cat "$workdir/ks.json")" "$sig"
}

# The lifecycle, published at every step, because each step is a different
# thing for a client to believe (§10.3). A key must appear in a published set
# *before* it may be promoted, so the set that first carries it necessarily
# shows it as `next` — and a client is right to refuse a signature from that.
echo "select public.introduce_grant_key('g1', :'pub')" | sql -v pub="$g1_pub" > /dev/null
IFS=$'\t' read -r keyset_v1 keyset_v1_sig <<< "$(publish)"
sql -c "select public.promote_grant_key('g1')" > /dev/null
IFS=$'\t' read -r keyset_v2 keyset_v2_sig <<< "$(publish)"

# MARK: - A request, resolved by two real votes, signed by g1

sql <<SQL > /dev/null
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select public.ensure_account('$APPLE_SUB', 'Vectors');
select public.nominate_partner('Mom',  'sms', '+15550199011');
select public.nominate_partner('Dave', 'sms', '+15550199012');
SQL

for who in Mom Dave; do
  token="$(sql -c "
    select substring(o.body from '/c/([0-9a-f]{64})')
      from public.message_outbox o
      join public.partner p on p.contact_ciphertext = o.to_ciphertext
     where p.display_name = '$who' and o.body ~ '/c/'
     order by o.created_at desc limit 1")"
  sql -c "select public.respond_to_invitation('$token', true)" > /dev/null
done

sql <<SQL > /dev/null
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select public.register_contract_envelope(
  p_commitment_id => '$COMMITMENT', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select p.id from public.partner p
                          join public.account a on a.id = p.account_id
                         where a.apple_user_id = '$APPLE_SUB'));
update public.contract_envelope e
   set created_at = e.created_at - interval '4 hours',
       eligible_from = e.eligible_from - interval '4 hours',
       first_seen_at = e.first_seen_at - interval '4 hours'
  from public.account a
 where a.id = e.account_id and a.apple_user_id = '$APPLE_SUB';
select public.create_override_request(
  gen_random_uuid(), '$COMMITMENT', 18, 30, 'minutes', 8, 10, 2, 1, 'Knee.');
SQL

for who in Mom Dave; do
  token="$(sql -c "
    select substring(o.body from '/a/([A-Za-z0-9_-]{43})')
      from public.message_outbox o
      join public.partner p on p.contact_ciphertext = o.to_ciphertext
     where p.display_name = '$who' and o.body ~ '/a/'
     order by o.created_at desc limit 1")"
  sql -c "select public.cast_override_vote('$token','approve')" > /dev/null
done

sql <<SQL > /dev/null
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select public.my_grants();
SQL

grant_id="$(sql -c "select (public.unsigned_grants() -> 0 ->> 'id')")"
sql -c "select (public.unsigned_grants() -> 0 ->> 'document')" | tr -d '\n' > "$workdir/grant.json"
grant_sig="$(openssl pkeyutl -sign -inkey "$workdir/g1.pem" -rawin \
               -in "$workdir/grant.json" | openssl base64 -A)"
echo "select public.store_override_grant(:'id'::uuid, :'sig')" \
  | sql -v id="$grant_id" -v sig="$grant_sig" > /dev/null
grant_doc="$(cat "$workdir/grant.json")"

# A signature by the wrong key, over the right bytes. The negative control: if
# a test using this ever passes, verification is not happening at all.
wrong_sig="$(openssl pkeyutl -sign -inkey "$workdir/g2.pem" -rawin \
               -in "$workdir/grant.json" | openssl base64 -A)"

# MARK: - Rotation, then revocation, each root-signed for real

echo "select public.introduce_grant_key('g2', :'pub')" | sql -v pub="$g2_pub" > /dev/null
IFS=$'\t' read -r keyset_v3 keyset_v3_sig <<< "$(publish)"
sql -c "select public.promote_grant_key('g2')" > /dev/null
IFS=$'\t' read -r keyset_v4 keyset_v4_sig <<< "$(publish)"
sql -c "select public.revoke_grant_key('g1')" > /dev/null
IFS=$'\t' read -r keyset_v5 keyset_v5_sig <<< "$(publish)"

swift_string() { printf '#"""\n%s\n"""#' "$1"; }

cat <<SWIFT
// Generated by backend/tools/grant_vectors.sh — real keys, real signatures.
//
// DO NOT REGENERATE TO FIX A FAILING TEST. These bytes were produced by
// Postgres composing a document, OpenSSL signing it, and the schema serving it
// back, which is exactly the path production takes. A test that stops passing
// against them is reporting that Swift and the server have come to disagree
// about the wire format — the most silent failure this system has, and the
// only place all three implementations are checked against one another.
//
// The private keys were generated in a temporary directory and thrown away;
// only the public halves are here, and public keys are public.

import Foundation

enum GrantVectors {
    /// The offline root key's public half. Signs key sets, never grants.
    static let rootPublicKey = Data(base64Encoded: "$root_pub")!

    /// Version 1: g1 introduced, not yet promoted. A key set can never show a
    /// brand-new key as anything but \`next\` — publication is what earns
    /// promotion — so this is what "told about, not yet trusted to sign"
    /// looks like on the wire.
    static let keySetV1 = $(swift_string "$keyset_v1")
    static let keySetV1Signature = Data(base64Encoded: "$keyset_v1_sig")!

    /// Version 2: g1 promoted and republished. This is the set in force when
    /// the grant below was signed, and the one the happy path uses.
    static let keySetV2 = $(swift_string "$keyset_v2")
    static let keySetV2Signature = Data(base64Encoded: "$keyset_v2_sig")!

    /// Version 3: g2 introduced alongside g1. Rotation begins.
    static let keySetV3 = $(swift_string "$keyset_v3")
    static let keySetV3Signature = Data(base64Encoded: "$keyset_v3_sig")!

    /// Version 4: g2 promoted, g1 retired. A retired key must still verify
    /// what it signed while it was current — that is the whole difference
    /// between retiring a key and revoking one.
    static let keySetV4 = $(swift_string "$keyset_v4")
    static let keySetV4Signature = Data(base64Encoded: "$keyset_v4_sig")!

    /// Version 5: g1 revoked. The kill list, and it reaches backwards.
    static let keySetV5 = $(swift_string "$keyset_v5")
    static let keySetV5Signature = Data(base64Encoded: "$keyset_v5_sig")!

    /// A grant for a real 2-of-2 request, signed by g1.
    static let grant = $(swift_string "$grant_doc")
    static let grantSignature = Data(base64Encoded: "$grant_sig")!
    static let grantKid = "g1"

    /// The same bytes signed by g2 — a valid signature by the wrong key. Any
    /// test that accepts this is not verifying anything.
    static let grantSignatureByWrongKey = Data(base64Encoded: "$wrong_sig")!

    static let policyDigest = "$(printf '%s' "$grant_doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["policy_digest"])')"
}
SWIFT
