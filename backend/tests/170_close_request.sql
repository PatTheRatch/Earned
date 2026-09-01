\set ON_ERROR_STOP on
\echo 'close_override_request: the requester resolves their own ask, the links stop mattering'
set time zone 'UTC';

begin;

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

-- A courtesy message is the only outbox row that says so, and the only way to
-- tell it apart from the /a/ and /c/ link messages.
create or replace function test_courtesy_count() returns int
language sql stable as $$
  select count(*) from public.message_outbox where body like '%No action needed%'
$$;

-- MARK: - A mixed roster: Patrick asks an earned partner and two external ones

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patrick', 'Patrick');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select public.upsert_my_profile('maya', 'Maya');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_earned_partner('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_partner_request(
  (select id from public.partner where kind = 'earned_user'), true);

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_partner('Mom',  'sms', '+14155550100');
select public.nominate_partner('Dave', 'sms', '+14155550101');
select public.respond_to_invitation(test_token_for('Mom'),  true);
select public.respond_to_invitation(test_token_for('Dave'), true);

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where status = 'active'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000001');

select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1);

-- MARK: - Refusals that never touch a request

select test_raises($$
  select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000001', 'huh')$$,
  'an outcome is moot or cancelled, nothing else');

select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-00000000ffff', 'moot')
          ->> 'open')::boolean is false,
  'a commitment with no request is a no-op, not an error');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000001', 'moot')
          ->> 'open')::boolean is false,
  'a different account cannot close Patrick''s request — it reads as not-theirs');
select test_sign_in('11111111-1111-1111-1111-111111111111');

-- MARK: - The moot close

select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000001', 'moot')
          ->> 'state') = 'moot',
  'the completed commitment moots the open request');

select test_assert(
  (select state = 'moot' and resolved_at is not null from public.override_request
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'the request is resolved as moot');
select test_assert(
  (select receipt_expires_at = resolved_at from public.override_request
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'the receipt window collapses immediately — the frozen snapshot cannot outlive the close');

select test_assert(
  (select count(*) = 3 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      and rc.status = 'withdrawn'),
  'every still-pending recipient is withdrawn');

select test_assert(
  (select count(*) = 0 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      and rc.status = 'pending'),
  'no recipient is left pending — a stale link cannot still read as a live ask');

select test_assert(
  (select test_courtesy_count() = 2),
  'exactly one courtesy message per external partner');

select test_assert(
  (select count(*) = 2 from public.message_outbox mo
     join public.partner p on p.contact_ciphertext = mo.to_ciphertext
    where mo.body like '%No action needed%' and p.kind = 'unverified_contact'),
  'both courtesy messages go to external partners');

select test_assert(
  (select count(*) = 0 from public.message_outbox mo
     join public.partner p on p.contact_ciphertext = mo.to_ciphertext
    where mo.body like '%No action needed%'
      and p.kind = 'earned_user'),
  'and none to the earned partner — their surface is in-app, not an outbox');

select test_assert(
  (select count(*) = 2 from public.message_outbox
    where body = 'Patrick finished the commitment. No action needed.'),
  'the courtesy copy names the requester and says no action is needed');

select test_assert(
  (select count(*) = 1 from public.override_request_event
    where request_id = (select id from public.override_request
                         where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001')
      and kind = 'resolved' and detail ->> 'outcome' = 'moot'),
  'the resolution is on the audit record');

-- MARK: - Idempotent: the second close changes nothing

select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000001', 'moot')
          ->> 'state') = 'moot',
  'closing an already-closed request returns its state');
select test_assert(
  (select test_courtesy_count() = 2),
  'and sends no second round of messages');

-- MARK: - A withdrawn link no longer mints an approval

-- The collapsed window makes the link resolve to `gone` in production; the
-- frozen now() of the test transaction keeps it on the `withdrawn` page here.
-- Either way it is inert — never a fresh ask, never a new approval.
set local role service_role;
select test_assert(
  public.cast_override_vote(test_approval_token_for('Mom'), 'approve') ->> 'page' in ('withdrawn', 'gone'),
  'voting with a withdrawn link yields a terminal page, never a new approval');
reset role;
select test_assert(
  (select count(*) = 0 from public.override_request_recipient where vote = 'approve'),
  'and records no late vote');

-- MARK: - The cancelled close

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Run 45 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where status = 'active'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000002');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002',
  18, 30, 'minutes', 8, 10, 2, 1);

-- Dave texts STOP after the request went out but before it closes. Global
-- suppression is checked on every send (§14.3): a suppressed contact receives
-- nothing, ever — including the courtesy that would otherwise reach them.
insert into public.contact_suppression (contact_lookup, channel, reason)
  select contact_lookup, channel, 'optout' from public.partner where display_name = 'Dave';

select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000002', 'cancelled')
          ->> 'state') = 'cancelled',
  'a withdrawn ask cancels the request');
select test_assert(
  (select count(*) = 3 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000002'
      and rc.status = 'withdrawn'),
  'and withdraws every pending recipient the same way');
select test_assert(
  (select count(*) = 1 from public.message_outbox
    where body = 'Patrick cancelled the request. No action needed.'),
  'the suppressed partner gets no courtesy — only the still-reachable one is told');

-- MARK: - A vote already cast stands (a fresh partner, so the token is unambiguous)

select public.nominate_partner('Sam', 'sms', '+14155550102');
select public.respond_to_invitation(test_token_for('Sam'), true);

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Swim 1 km',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where display_name in ('Sam', 'Mom')));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000003');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000003',
  1, 1, 'km', 8, 10, 2, 1);

-- Sam approves, but the threshold of two is not met — the request stays open.
set local role service_role;
select public.cast_override_vote(test_approval_token_for('Sam'), 'approve');
reset role;

select test_assert(
  (select public.close_override_request('aaaaaaaa-0000-0000-0000-000000000003', 'moot')
          ->> 'state') = 'moot',
  'the request still closes even with a vote already cast');
select test_assert(
  (select rc.status = 'voted' and rc.vote = 'approve'
     from public.override_request_recipient rc
     join public.partner p on p.id = rc.partner_id
     join public.override_request r on r.id = rc.request_id
    where p.display_name = 'Sam'
      and r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'a vote already cast is preserved — only pending recipients are withdrawn');
select test_assert(
  (select rc.status = 'withdrawn'
     from public.override_request_recipient rc
     join public.partner p on p.id = rc.partner_id
     join public.override_request r on r.id = rc.request_id
    where p.display_name = 'Mom'
      and r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'and the still-pending partner is withdrawn');

-- MARK: - A granted request is never re-written (a second account, to stay in the daily budget)

select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.ensure_account('apple-sub-nina', 'Nina');
select public.nominate_partner('Rita', 'sms', '+14155550104');
select public.respond_to_invitation(test_token_for('Rita'), true);

select public.register_contract_envelope(
  p_commitment_id => 'cccccccc-0000-0000-0000-000000000001', p_title => 'Yoga',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Rita'));
select test_advance_past_hardening('cccccccc-0000-0000-0000-000000000001');
select public.create_override_request(
  'dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001',
  1, 1, 'session', 8, 10, 2, 1);
set local role service_role;
select public.cast_override_vote(test_approval_token_for('Rita'), 'approve');
reset role;

select test_assert(
  (select state = 'granted' from public.override_request
    where commitment_id = 'cccccccc-0000-0000-0000-000000000001'),
  'a single approval on a threshold-one contract grants it');
select test_assert(
  (select public.close_override_request('cccccccc-0000-0000-0000-000000000001', 'moot')
          ->> 'state') = 'granted',
  'a granted request is never re-written to moot — votes already cast stand');

-- MARK: - Anonymous callers have no route in

set local role anon;
select test_sign_out();
select test_raises($$select public.close_override_request(gen_random_uuid(), 'moot')$$,
                   'anon cannot close anyone''s request');
reset role;

rollback;
