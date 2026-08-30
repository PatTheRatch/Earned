#!/usr/bin/env bash
# The §19 concurrency test, run with real concurrency: five voters, five
# sessions, one starting gun.
#
# "Concurrent approvals: N simultaneous votes on a threshold-2 request →
# exactly one `granted` transition, exactly one grant, all remaining
# recipients `superseded`." A single-session SQL file cannot test that — five
# statements in one transaction never contend — so this script opens five real
# connections, parks them all behind an advisory lock, releases the lock, and
# lets them stampede into cast_override_vote at the same instant. The FOR
# UPDATE on the request row is the only thing standing between that stampede
# and a double grant, which is exactly why it must be the thing under test.
#
# Written before the vote endpoint was implemented, per §22 step 7, and
# watched fail against the stub. If it passes, the §8 transaction holds.
#
# Requires DATABASE_URL pointing at a THROWAWAY database with the migrations
# and test bootstrap applied (run.sh arranges exactly that). It deletes and
# recreates its own account, so it must never point anywhere real.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL to a throwaway Postgres with migrations applied}"

workdir="$(mktemp -d -t vote-drill-XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtA "$@"; }

pass() { echo "  ok  $1"; }
fail() { echo "FAILED: $1" >&2; exit 1; }

BARRIER=424242
VOTERS=5

# MARK: - A 2-of-5 request, built the same way the app would build it

# One session for the whole setup, because auth.uid() lives in a session
# setting: sign in once, act as the account throughout.
sql <<'SQL' > /dev/null
-- Requests first, then the account. recipient.partner_id deliberately does
-- not cascade — a vote receipt outlives the partner who cast it — so a bare
-- account delete would race its own two cascade paths and lose. (What account
-- deletion should actually do is D10, deliberately open; this is test
-- cleanup, not an answer to it.)
delete from public.override_request r
 using public.account a
 where a.id = r.account_id and a.apple_user_id = 'apple-sub-vote-drill';
delete from public.account where apple_user_id = 'apple-sub-vote-drill';
select test_sign_in('99999999-0000-0000-0000-000000000001');
select public.ensure_account('apple-sub-vote-drill', 'Drill');

select public.nominate_partner('V1', 'sms', '+14155550301');
select public.nominate_partner('V2', 'sms', '+14155550302');
select public.nominate_partner('V3', 'sms', '+14155550303');
select public.nominate_partner('V4', 'sms', '+14155550304');
select public.nominate_partner('V5', 'sms', '+14155550305');
select public.respond_to_invitation(test_token_for('V1'), true);
select public.respond_to_invitation(test_token_for('V2'), true);
select public.respond_to_invitation(test_token_for('V3'), true);
select public.respond_to_invitation(test_token_for('V4'), true);
select public.respond_to_invitation(test_token_for('V5'), true);

select public.register_contract_envelope(
  p_commitment_id => '99999999-aaaa-0000-0000-000000000001', p_title => 'Contested run',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select p.id from public.partner p
                          join public.account a on a.id = p.account_id
                         where a.apple_user_id = 'apple-sub-vote-drill'));

-- Advance the clock the honest way: move the commitment's creation into the
-- past and let the trigger recompute hardens_at from it.
update public.contract_envelope e
   set created_at    = e.created_at    - interval '4 hours',
       eligible_from = e.eligible_from - interval '4 hours',
       first_seen_at = e.first_seen_at - interval '4 hours'
  from public.account a
 where a.id = e.account_id and a.apple_user_id = 'apple-sub-vote-drill';

select public.create_override_request(
  '99999999-bbbb-0000-0000-000000000001', '99999999-aaaa-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1, 'Drill, not a drill');
SQL

for i in $(seq 1 $VOTERS); do
  tok="$(sql -c "select test_approval_token_for('V$i')")"
  [ -n "$tok" ] || fail "no approval token found for V$i"
  echo "$tok" > "$workdir/tok$i"
done
pass "a 2-of-5 request exists and five approval links went out"

# MARK: - The stampede

# The starting gun: one session takes the barrier exclusively and holds it
# while the voters line up behind it in shared mode, then lets go. All five
# then hit the vote endpoint in the same instant, which is the point.
psql "$DATABASE_URL" --no-psqlrc -qtA \
  -c "select pg_advisory_lock($BARRIER);" \
  -c "select pg_sleep(2);" \
  -c "select pg_advisory_unlock($BARRIER);" > /dev/null &
gun=$!
sleep 0.5

pids=()
for i in $(seq 1 $VOTERS); do
  psql "$DATABASE_URL" --no-psqlrc -qtA \
    -v tok="$(cat "$workdir/tok$i")" <<'SQL' > "$workdir/out$i" 2>&1 &
begin;
select pg_advisory_xact_lock_shared(424242);
select public.cast_override_vote(:'tok', 'approve');
commit;
SQL
  pids+=($!)
done

for pid in "${pids[@]}"; do wait "$pid" || true; done
wait "$gun" || true

for i in $(seq 1 $VOTERS); do
  if grep -qi "error" "$workdir/out$i"; then
    echo "--- voter $i output ---" >&2; cat "$workdir/out$i" >&2
    fail "voter $i got an error instead of a page"
  fi
done
pass "all five simultaneous voters got an answer, none an error"

# MARK: - Exactly one resolution

read -r state resolved voted superseded approvals resolved_events <<EOF
$(sql -c "
  select r.state,
         (r.resolved_at is not null)::int,
         (select count(*) from public.override_request_recipient rc
           where rc.request_id = r.id and rc.status = 'voted'),
         (select count(*) from public.override_request_recipient rc
           where rc.request_id = r.id and rc.status = 'superseded'),
         (select count(*) from public.override_request_recipient rc
           where rc.request_id = r.id and rc.vote = 'approve'),
         (select count(*) from public.override_request_event e
           where e.request_id = r.id and e.kind = 'resolved')
    from public.override_request r
   where r.commitment_id = '99999999-aaaa-0000-0000-000000000001'" | tr '|' ' ')
EOF

[ "$state" = "granted" ]    || fail "request state is '$state', wanted granted"
[ "$resolved" = "1" ]       || fail "request has no resolved_at"
[ "$voted" = "2" ]          || fail "$voted recipients voted, wanted exactly 2 — the threshold"
[ "$superseded" = "3" ]     || fail "$superseded recipients superseded, wanted exactly 3"
[ "$approvals" = "2" ]      || fail "$approvals approvals recorded, wanted exactly 2 — late votes must not be recorded"
[ "$resolved_events" = "1" ] || fail "$resolved_events 'resolved' events, wanted exactly one transition"
pass "five simultaneous approvals: one granted transition, two votes, three superseded"

# The three losers were told the truth, not given an error: their pages must
# say the request was already resolved, and their rows must hold no vote.
losers_with_votes="$(sql -c "
  select count(*) from public.override_request_recipient rc
    join public.override_request r on r.id = rc.request_id
   where r.commitment_id = '99999999-aaaa-0000-0000-000000000001'
     and rc.status = 'superseded' and rc.vote is not null")"
[ "$losers_with_votes" = "0" ] || fail "a superseded recipient has a recorded vote"
pass "no vote was recorded for anyone past the threshold (§6.2: not accepted, not recorded)"

echo "==> vote concurrency drill complete: two taps at once cannot double-grant (§8, §19)"
