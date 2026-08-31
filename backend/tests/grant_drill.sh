#!/usr/bin/env bash
# A real grant, signed with a real key, verified the way the app will verify it.
#
# 100_grants.sql proves the schema refuses what it must, with well-formed junk
# where a signature goes. This proves the other half: that the bytes the
# database composes, signed by the key the key set advertises, verify against
# the public half a client extracts from that published key set — and that
# they stop verifying the moment anything about them changes.
#
# It stands in for the `grants` edge function with openssl, because what is
# under test is the round trip rather than the function's plumbing: SQL builds
# a document, something outside Postgres signs it (pgcrypto has no Ed25519),
# the signature comes back, and the app verifies. Deploying a function to
# prove that would test Supabase rather than Earned.
#
# Requires DATABASE_URL pointing at a THROWAWAY database with the migrations
# applied (run.sh arranges exactly that): it truncates the key and grant tables
# to get a clean stage.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL to a throwaway Postgres with migrations applied}"

workdir="$(mktemp -d -t grant-drill-XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtA "$@"; }
pass() { echo "  ok  $1"; }
fail() { echo "FAILED: $1" >&2; exit 1; }

APPLE_SUB='apple-sub-grant-drill'
AUTH_UID='cafe0000-0000-4000-8000-000000000001'
COMMITMENT='cafe0000-0000-4000-8000-0000000000c1'

sql <<SQL > /dev/null
delete from public.override_request r using public.account a
 where a.id = r.account_id and a.apple_user_id = '$APPLE_SUB';
delete from public.account where apple_user_id = '$APPLE_SUB';
truncate public.server_grant, public.grant_signing_key, public.key_set cascade;
SQL

# MARK: - A key, published and promoted

cd "$workdir"
openssl genpkey -algorithm ed25519 -out root.pem 2>/dev/null
openssl pkey -in root.pem -pubout -out root.pub.pem 2>/dev/null
openssl genpkey -algorithm ed25519 -out g1.pem 2>/dev/null
g1_pub="$(openssl pkey -in g1.pem -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
cd - > /dev/null

echo "select public.introduce_grant_key('g1', :'pub')" | sql -v pub="$g1_pub" > /dev/null
sql -c "select public.build_key_set_document()" | tr -d '\n' > "$workdir/keyset.json"
keyset_sig="$(openssl pkeyutl -sign -inkey "$workdir/root.pem" -rawin \
                -in "$workdir/keyset.json" | openssl base64 -A)"
echo "select public.publish_key_set(:'doc', :'sig')" \
  | sql -v doc="$(cat "$workdir/keyset.json")" -v sig="$keyset_sig" > /dev/null
sql -c "select public.promote_grant_key('g1')" > /dev/null
# Published a second time: the first document was taken before promotion and
# still calls g1 `next`, and signing against that is what 0012 refuses.
sql -c "select public.build_key_set_document()" | tr -d '\n' > "$workdir/keyset.json"
keyset_sig="$(openssl pkeyutl -sign -inkey "$workdir/root.pem" -rawin \
                -in "$workdir/keyset.json" | openssl base64 -A)"
echo "select public.publish_key_set(:'doc', :'sig')" \
  | sql -v doc="$(cat "$workdir/keyset.json")" -v sig="$keyset_sig" > /dev/null

# MARK: - A request, resolved by two real votes

sql <<SQL > /dev/null
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select public.ensure_account('$APPLE_SUB', 'Drill');
select public.nominate_partner('Drill Mom',  'sms', '+15550199001');
select public.nominate_partner('Drill Dave', 'sms', '+15550199002');
SQL

for who in 'Drill Mom' 'Drill Dave'; do
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

for who in 'Drill Mom' 'Drill Dave'; do
  token="$(sql -c "
    select substring(o.body from '/a/([A-Za-z0-9_-]{43})')
      from public.message_outbox o
      join public.partner p on p.contact_ciphertext = o.to_ciphertext
     where p.display_name = '$who' and o.body ~ '/a/'
     order by o.created_at desc limit 1")"
  sql -c "select public.cast_override_vote('$token','approve')" > /dev/null
done

state="$(sql -c "select r.state from public.override_request r
                   join public.account a on a.id = r.account_id
                  where a.apple_user_id = '$APPLE_SUB'")"
[ "$state" = "granted" ] || fail "the request is '$state', not granted"
pass "two real votes resolved a real request"

# MARK: - Sign it the way the edge function does

sql <<SQL > /dev/null
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select public.my_grants();
SQL

grant_id="$(sql -c "select (public.unsigned_grants() -> 0 ->> 'id')")"
kid="$(sql -c "select (public.unsigned_grants() -> 0 ->> 'kid')")"
[ -n "$grant_id" ] && [ "$kid" = "g1" ] || fail "no unsigned grant waiting for g1"

# printf, so the signed bytes and the stored bytes match to the byte.
sql -c "select (public.unsigned_grants() -> 0 ->> 'document')" | tr -d '\n' > "$workdir/grant.json"
grant_sig="$(openssl pkeyutl -sign -inkey "$workdir/g1.pem" -rawin \
               -in "$workdir/grant.json" | openssl base64 -A)"
echo "select public.store_override_grant(:'id'::uuid, :'sig')" \
  | sql -v id="$grant_id" -v sig="$grant_sig" > /dev/null
pass "the document was signed outside Postgres and the signature stored"

# MARK: - Verify it the way the app will

# my_grants() reads auth.uid() out of the session's JWT claims, so the claim
# and the call have to travel in one psql invocation.
as_account() { # as_account <expression> -> its value
  sql <<SQL | tail -1
select set_config('request.jwt.claims', json_build_object('sub','$AUTH_UID')::text, false);
select $1;
SQL
}

printf '%s' "$(as_account "(public.my_grants() -> 0 ->> 'document')")" > "$workdir/served.json"
printf '%s' "$(as_account "(public.my_grants() -> 0 ->> 'signature')")" \
  | openssl base64 -d -A > "$workdir/served.sig"

cmp -s "$workdir/grant.json" "$workdir/served.json" \
  || fail "the served document differs from the one that was signed"
pass "the grant is served byte-for-byte as it was signed"

# The public key comes out of the *published key set*, not out of the local
# PEM: that is the round trip the app actually performs, and the only one that
# proves the key set is telling clients the truth.
python3 - "$workdir/keyset.json" "$kid" "$workdir/g1.served.der" <<'PY'
import base64, json, sys
doc = json.load(open(sys.argv[1]))
key = next(k for k in doc["keys"] if k["kid"] == sys.argv[2])
raw = base64.b64decode(key["public"])
assert len(raw) == 32, "an Ed25519 public key is 32 bytes"
open(sys.argv[3], "wb").write(bytes.fromhex("302a300506032b6570032100") + raw)
PY

openssl pkeyutl -verify -pubin -keyform DER -inkey "$workdir/g1.served.der" -rawin \
  -in "$workdir/served.json" -sigfile "$workdir/served.sig" > /dev/null 2>&1 \
  || fail "the served grant does not verify against the key set's public key for $kid"
pass "it verifies against the public key taken from the published key set"

# Negative control, or none of the above proves anything.
sed 's/"granted"/"granteD"/' "$workdir/served.json" | tr -d '\n' > "$workdir/tampered.json"
if openssl pkeyutl -verify -pubin -keyform DER -inkey "$workdir/g1.served.der" -rawin \
     -in "$workdir/tampered.json" -sigfile "$workdir/served.sig" > /dev/null 2>&1; then
  fail "a tampered grant still verified — the check proves nothing"
fi
pass "one changed character and it stops verifying"

# MARK: - The document says what the app needs

python3 - "$workdir/served.json" "$COMMITMENT" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["decision"] == "granted", "decision"
assert doc["kid"] == "g1", "kid names the signing key"
assert doc["policy_digest"].startswith("sha256:"), "policy digest"
assert len(doc["roster"]) == 2, "both votes in the roster"
assert all(v["vote"] == "approve" for v in doc["roster"]), "both approved"
assert "signature" not in doc, "the document never contains its own signature"
PY
pass "the grant carries the decision, the contract digest, and who approved"

sql <<SQL > /dev/null
delete from public.override_request r using public.account a
 where a.id = r.account_id and a.apple_user_id = '$APPLE_SUB';
delete from public.account where apple_user_id = '$APPLE_SUB';
SQL

echo "==> grant drill complete: signed outside Postgres, verified against the published key set (§9)"
