\set ON_ERROR_STOP on
\echo 'voting: every token state has a page, and only votes before resolution count'
set time zone 'UTC';

begin;

-- The concurrency half of step 7 lives in vote_concurrency.sh, with real
-- sessions. This file is the semantics: what each state answers, what gets
-- recorded, and what pointedly does not.

-- Leftovers from a previous run's drills — vote_concurrency.sh commits an
-- account with partners and a resolved request — would skew every unqualified
-- count below. This transaction rolls back, so deleting here is invisible
-- outside it. Requests go first: recipient rows reference partners without a
-- cascade, so a bare account delete would race its own cascade paths.
delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

create or replace function test_advance_past_hardening(p_commitment_id uuid) returns void
language plpgsql as $$
begin
  update public.contract_envelope
     set created_at    = created_at - interval '4 hours',
         eligible_from = eligible_from - interval '4 hours',
         first_seen_at = first_seen_at - interval '4 hours'
   where commitment_id = p_commitment_id;
end;
$$;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.nominate_partner('Mom',   'sms', '+14155550100');
select public.nominate_partner('Dave',  'sms', '+14155550101');
select public.nominate_partner('Chris', 'sms', '+14155550102');
select public.respond_to_invitation(test_token_for('Mom'),   true);
select public.respond_to_invitation(test_token_for('Dave'),  true);
select public.respond_to_invitation(test_token_for('Chris'), true);

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where display_name in ('Mom', 'Dave', 'Chris')));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000001');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1, 'Knee started bothering me.');

-- MARK: - A token that is not ours answers with nothing, uniformly

select test_assert(
  public.approval_page('forged-token-that-never-was') = '{"page": "invalid"}'::jsonb,
  'a forged token gets the invalid page and nothing else');
select test_assert(
  public.approval_page(left(test_approval_token_for('Mom'), 20))
    = public.approval_page('forged-token-that-never-was'),
  'a truncated real token is indistinguishable from a forged one');
select test_assert(
  public.approval_page('') = public.approval_page('forged-token-that-never-was'),
  'and so is an empty one');

-- MARK: - The request page

select test_assert(
  public.approval_page(test_approval_token_for('Mom')) ->> 'page' = 'request',
  'a pending token on an open request answers with the request page');
select test_assert(
  public.approval_page(test_approval_token_for('Mom'))
    -> 'snapshot' -> 'contract' ->> 'commitment_title' = 'Run 30 minutes',
  'the page carries the frozen snapshot, contract half included');
select test_assert(
  (public.approval_page(test_approval_token_for('Mom'))
    -> 'snapshot' -> 'self_reported' -> 'progress' ->> 'achieved') = '18',
  'and the self-reported half the page must label as such');
select test_assert(
  public.approval_page(test_approval_token_for('Mom'))::text !~ 'Dave|Chris',
  'a partner sees no other partner (S6)');
select test_assert(
  (select count(*) from public.override_request_event e
     join public.override_request r on r.id = e.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      and e.kind = 'viewed') >= 1,
  'opening a live link is an audit event');

-- MARK: - Votes, in order: approve, revote, deny, approve

select test_assert(
  public.cast_override_vote(test_approval_token_for('Mom'), 'approve') ->> 'page' = 'receipt',
  'a first approval answers with that partner''s receipt');
select test_assert(
  public.cast_override_vote(test_approval_token_for('Mom'), 'approve') ->> 'outcome' = 'open',
  'the receipt before resolution says open — never a tally (S6)');
select test_assert(
  (select state = 'open' from public.override_request),
  'one approval of two does not resolve');

select public.cast_override_vote(test_approval_token_for('Mom'), 'deny');
select test_assert(
  (select vote = 'approve' from public.override_request_recipient rc
     join public.partner p on p.id = rc.partner_id where p.display_name = 'Mom'),
  'a second vote from the same partner changes nothing — first vote is final (S5)');
select test_assert(
  (select count(*) = 1 from public.override_request_event where kind = 'voted'),
  'and is not recorded, not even as an event');

select test_assert(
  public.cast_override_vote(test_approval_token_for('Dave'), 'deny') ->> 'vote' = 'deny',
  'a denial is recorded and receipted');
select test_assert(
  (select state = 'open' from public.override_request),
  'a denial resolves nothing and consumes no approval slot (S5)');

select test_assert(
  public.cast_override_vote(test_approval_token_for('Chris'), 'approve') ->> 'outcome' = 'granted',
  'the second approval resolves the request and the receipt says so');
select test_assert(
  (select state = 'granted' and resolved_at is not null from public.override_request),
  'the request is granted exactly then');
select test_assert(
  (select count(*) = 1 from public.override_request_event where kind = 'resolved'),
  'one resolution event, ever');

-- Every partner had voted before resolution here, so nobody was superseded —
-- the superseded path under real contention is the drill's job.
select test_assert(
  (select count(*) = 0 from public.override_request_recipient where status = 'superseded'),
  'nobody was superseded — all three had already answered');

-- Receipts stay stable and reopenable after resolution (§6.2).
select test_assert(
  public.approval_page(test_approval_token_for('Dave')) ->> 'page' = 'receipt'
    and public.approval_page(test_approval_token_for('Dave')) ->> 'vote' = 'deny',
  'a partner who denied can reopen their receipt and see what they decided');

-- MARK: - S16: a vote already placed in someone's hands stays valid

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Second run',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Chris'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000002');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002',
  1, 1, 'session', 8, 10, 2, 1);

select public.revoke_partner((select id from public.partner where display_name = 'Chris'));

select test_assert(
  public.cast_override_vote(test_approval_token_for('Chris'), 'approve') ->> 'outcome' = 'granted',
  'a partner revoked after their token was minted still has a valid vote (S16)');

-- MARK: - Votes after expiry

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-nina', 'Nina');
select public.nominate_partner('Ada', 'sms', '+14155550200');
select public.respond_to_invitation(test_token_for('Ada'), true);
select public.register_contract_envelope(
  p_commitment_id => 'cccccccc-0000-0000-0000-000000000001', p_title => 'Swim',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Ada'));
select test_advance_past_hardening('cccccccc-0000-0000-0000-000000000001');
select public.create_override_request(
  'dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001',
  1, 1, 'session', 3, 4, 0, 1);

update public.override_request set expires_at = now() - interval '1 minute'
 where commitment_id = 'cccccccc-0000-0000-0000-000000000001';

select test_assert(
  public.cast_override_vote(test_approval_token_for('Ada'), 'approve') ->> 'page' = 'expired',
  'a vote on a lapsed request gets the expired page, sweeper or no sweeper');
select test_assert(
  (select vote is null from public.override_request_recipient rc
     join public.partner p on p.id = rc.partner_id where p.display_name = 'Ada'),
  'and nothing was recorded for it');
select test_assert(
  (select state = 'expired' from public.override_request
    where commitment_id = 'cccccccc-0000-0000-0000-000000000001'),
  'the lapsed request was retired on the way past');

-- MARK: - The receipt window closes, and closes honestly

update public.override_request set receipt_expires_at = now() - interval '1 minute'
 where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001';

select test_assert(
  public.approval_page(test_approval_token_for('Mom')) = '{"page": "gone"}'::jsonb,
  'past the receipt window a resolved link goes permanently generic (S15)');
select test_assert(
  public.cast_override_vote(test_approval_token_for('Mom'), 'approve') = '{"page": "gone"}'::jsonb,
  'and cannot vote either');

select test_assert(public.purge_override_receipts() = 1,
  'the purge removes exactly the snapshot whose window has closed');
select test_assert(
  not exists (select 1 from public.override_request_snapshot s
                join public.override_request r on r.id = s.request_id
               where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'what the partners were shown is not kept beyond its purpose (§15)');
select test_assert(
  (select count(*) = 0 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      and rc.vote is not null),
  'and how each person answered is scrubbed to status-only');
select test_assert(
  public.approval_page(test_approval_token_for('Mom')) ->> 'page' = 'gone',
  'the purged link still answers gone, not invalid — an old real link never looks forged');

-- MARK: - A broken caller is an error, not a page

select test_raises(
  $$select public.cast_override_vote('whatever', 'maybe')$$,
  'a vote that is neither approve nor deny is refused outright');

-- MARK: - Who may call what

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select public.approval_page('x')$$,
                   'the account holder cannot resolve approval tokens');
select test_raises($$select public.cast_override_vote('x', 'approve')$$,
                   'the account holder cannot vote — that is the entire design (S1)');
select test_raises($$select public.purge_override_receipts()$$,
                   'the account holder cannot run the purge');
reset role;

set local role anon;
select test_sign_out();
select test_raises($$select public.approval_page('x')$$,
                   'anon cannot resolve approval tokens — the page is server-rendered (§18)');
select test_raises($$select public.cast_override_vote('x', 'approve')$$,
                   'anon cannot vote');
reset role;

rollback;
