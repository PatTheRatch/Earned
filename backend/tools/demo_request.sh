#!/usr/bin/env bash
# Build a real override request against a real project, and print the link a
# partner would open.
#
#   backend/tools/demo_request.sh            # set it up, print the link
#   backend/tools/demo_request.sh --clean    # remove everything it made
#
# Two steps of the flow have no interface yet — consent has no page until
# build order step 9, and override requests are not wired into the app — so
# without this the only way to see a partner page with real content in it is
# a dozen hand-typed SQL statements. This is those statements, in order, with
# the fiddly parts (reading a consent token out of the outbox, faking the JWT
# claim the RPCs read, advancing the clock past hardening) done properly.
#
# SAFETY. Everything it writes belongs to one demo account, identified by a
# fixed Apple subject that no real sign-in can produce. It never touches your
# own account, your partners, or your commitments, and --clean deletes only
# rows reachable from that demo account. The contact details are +1-555
# numbers, reserved for fiction and dialable by nobody — which matters less
# than it sounds, because nothing drains message_outbox yet, but the day
# something does this script must not have queued a message to a real person.
#
# Requires DATABASE_URL or $DB.
set -euo pipefail

cd "$(dirname "$0")/../.."
DB="${DATABASE_URL:-${DB:-}}"
if [ -z "$DB" ]; then
  echo "usage: DB=<connection string> backend/tools/demo_request.sh [--clean]" >&2
  exit 2
fi

sql() { psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtA "$@"; }

# The demo identity. Fixed so re-runs are idempotent and teardown is exact.
DEMO_APPLE_SUB='demo.earntherest.invalid'
DEMO_AUTH_UID='dede0000-0000-4000-8000-000000000001'
DEMO_COMMITMENT='dede0000-0000-4000-8000-0000000000c1'

# Deletes requests before the account: recipient rows reference partner without
# a cascade — a vote receipt outlives the partner who cast it — so a bare
# account delete races its own two cascade paths and loses.
clean() {
  sql <<SQL > /dev/null
delete from public.override_request r
 using public.account a
 where a.id = r.account_id and a.apple_user_id = '$DEMO_APPLE_SUB';
delete from public.message_outbox o
 using public.partner p, public.account a
 where p.contact_ciphertext = o.to_ciphertext
   and a.id = p.account_id and a.apple_user_id = '$DEMO_APPLE_SUB';
delete from public.account where apple_user_id = '$DEMO_APPLE_SUB';
SQL
}

if [ "${1:-}" = "--clean" ]; then
  clean
  echo "==> demo account and everything it owned are gone"
  echo "    (your own account and commitments were never touched)"
  exit 0
fi

# MARK: - Preconditions, named rather than discovered as a stack trace

missing="$(sql -c "
  select string_agg(want, ', ')
    from (values ('approval_page'), ('create_override_request'), ('nominate_partner')) v(want)
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = v.want)")"
if [ -n "$missing" ]; then
  echo "missing SQL functions: $missing" >&2
  echo "run backend/apply.sh \"\$DB\" first — see docs/deployment.md §1" >&2
  exit 1
fi

if ! sql -c "select private.contact_lookup('+15550100000')" > /dev/null 2>&1; then
  echo "the contact keys are not configured — see docs/deployment.md §2" >&2
  exit 1
fi

# Links are built server-side from this, so a stale value produces links that
# point somewhere real and wrong rather than failing. Say where it came from.
base_url="$(sql -c "select private.secret('consent_base_url')")"

echo "==> starting from a clean demo account"
clean

# MARK: - The flow, as the app and the server would do it

# `set_config` stands in for a signed-in session: the RPCs read auth.uid() out
# of the JWT claims, exactly as they do behind PostgREST. Everything after this
# runs under the demo account's own authority and RLS, not around it.
echo "==> account, two partners, and consent for both"
sql <<SQL > /dev/null
select set_config('request.jwt.claims',
                  json_build_object('sub', '$DEMO_AUTH_UID')::text, false);
select public.ensure_account('$DEMO_APPLE_SUB', 'Demo');
select public.nominate_partner('Demo Mom',  'sms', '+15550100001');
select public.nominate_partner('Demo Dave', 'sms', '+15550100002');
SQL

# The consent token exists only inside the queued message — that is the point
# of it (S1). Read it the way the consent page's edge function will when step 9
# builds it: by being the server.
for who in 'Demo Mom' 'Demo Dave'; do
  token="$(sql -c "
    select substring(o.body from '/c/([0-9a-f]{64})')
      from public.message_outbox o
      join public.partner p on p.contact_ciphertext = o.to_ciphertext
     where p.display_name = '$who' and o.body ~ '/c/'
     order by o.created_at desc limit 1")"
  [ -n "$token" ] || { echo "no consent token queued for $who" >&2; exit 1; }
  sql -c "select public.respond_to_invitation('$token', true)" > /dev/null
done

echo "==> a commitment, hardened, with both partners on the roster"
sql <<SQL > /dev/null
select set_config('request.jwt.claims',
                  json_build_object('sub', '$DEMO_AUTH_UID')::text, false);
select public.register_contract_envelope(
  p_commitment_id => '$DEMO_COMMITMENT',
  p_title         => 'Run 30 minutes',
  p_created_at    => now(),
  p_eligible_from => now(),
  p_deadline      => now() + interval '8 hours',
  p_correction_window    => 7200,
  p_approvals_required   => 2,
  p_accountability_window => 1800,
  p_partner_ids => array(select p.id from public.partner p
                          join public.account a on a.id = p.account_id
                         where a.apple_user_id = '$DEMO_APPLE_SUB'));
SQL

# A contract has to have hardened before it can be appealed, and hardening is
# thirty minutes away on a fresh commitment. Move its *creation* into the past
# and let the server recompute: hardens_at cannot be written directly — a
# trigger recomputes it on every write, which is exactly what keeps it beyond
# a client's reach — so this advances the clock the rule reads, never the rule.
sql <<SQL > /dev/null
update public.contract_envelope e
   set created_at    = e.created_at    - interval '4 hours',
       eligible_from = e.eligible_from - interval '4 hours',
       first_seen_at = e.first_seen_at - interval '4 hours'
  from public.account a
 where a.id = e.account_id and a.apple_user_id = '$DEMO_APPLE_SUB';
SQL

echo "==> the request"
sql <<SQL > /dev/null
select set_config('request.jwt.claims',
                  json_build_object('sub', '$DEMO_AUTH_UID')::text, false);
select public.create_override_request(
  gen_random_uuid(), '$DEMO_COMMITMENT',
  18, 30, 'minutes',
  8, 10, 2, 1,
  'Knee started bothering me on the way out.');
SQL

# MARK: - What a partner was sent

echo
echo "Two links were queued, one per partner. The threshold is 2, so both have"
echo "to approve before anything is granted. Open one:"
echo
for who in 'Demo Mom' 'Demo Dave'; do
  token="$(sql -c "
    select substring(o.body from '/a/([A-Za-z0-9_-]{43})')
      from public.message_outbox o
      join public.partner p on p.contact_ciphertext = o.to_ciphertext
     where p.display_name = '$who' and o.body ~ '/a/'
     order by o.created_at desc limit 1")"
  printf '  %-10s %s/a/%s\n' "$who" "$base_url" "$token"
done
echo
echo "  built from consent_base_url in Vault: $base_url"
echo "  if that is not your live domain, these links are dead — docs/deployment.md §2"
echo
echo "Approving as one shows that partner's receipt and leaves the request open."
echo "Approving as both resolves it: the second sees 'granted', and had there"
echo "been a third they would find it superseded. Nothing reaches the phone yet"
echo "— grants are build order step 8."
echo
echo "Clean up with: backend/tools/demo_request.sh --clean"
