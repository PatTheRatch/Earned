\set ON_ERROR_STOP on
\echo 'shared follow-ups: orphaned agreements, roster events, commitment-relevant push'
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

-- The cast, with friendships Patrick–Maya and Patrick–Dave.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select public.upsert_my_profile('maya', 'Maya');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.ensure_account('apple-sub-dave', 'Dave');
select public.upsert_my_profile('dave', 'Dave');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select public.send_friend_request('dave');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_friend_request('patrick', true);

-- MARK: - Invitations enqueue commitment-relevant push, and only real asks

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         'aaaaaaaa-0000-0000-0000-00000000000a', 'Run 3 times this week',
         'running', 'sessions', 3,
         now() - interval '1 hour', now() + interval '6 days',
         array['maya', 'dave']);
select test_assert((select count(*) = 2 from public.push_outbox
                     where kind = 'shared_invitation'),
                   'each invitation queues one push to its invitee');
-- The person goes in the title and the commitment in the body, because a lock
-- screen shows the title and often nothing else — and "someone invited you" is
-- exactly the notification a person does not act on.
select test_assert((select bool_and(title like 'Patrick invited you%')
                      from public.push_outbox where kind = 'shared_invitation'),
                   'the push titles the asker, factually');
select test_assert((select bool_and(body like 'Run 3 times this week%')
                      from public.push_outbox where kind = 'shared_invitation'),
                   'and the body says what was asked for');
-- Tapping it has somewhere to land.
select test_assert((select bool_and(route_id is not null)
                      from public.push_outbox where kind = 'shared_invitation'),
                   'every actionable push carries the row it routes to');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement), 'maya');
select test_assert((select count(*) = 2 from public.push_outbox
                     where kind = 'shared_invitation'),
                   're-asking someone already asked queues nothing — one ask, one push');
select test_assert((select start_announced_at is not null
                      from public.shared_commitment_agreement),
                   'a window already open at creation counts as announced');

-- MARK: - Acceptance is a shelf moment, told once

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), true,
         'bbbbbbbb-0000-0000-0000-00000000000b');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_accepted'),
                   'accepting emits one shared_accepted event');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), true,
         'cccccccc-0000-0000-0000-00000000000c');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_accepted'),
                   'a duplicate acceptance emits nothing — one acceptance, one event');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(
  (select count(*) = 1 from jsonb_array_elements(public.friend_activity()) e
    where e ->> 'kind' = 'shared_accepted' and e ->> 'handle' = 'maya'),
  'friends see the acceptance on the Recent shelf');

-- A decline is quiet everywhere: no event, no push beyond the original ask.
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), false);
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_accepted'),
                   'declining emits no event of any kind');

-- A fresh ask after a decline is a real ask again, so it queues again.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement), 'dave');
select test_assert((select count(*) = 3 from public.push_outbox
                     where kind = 'shared_invitation'),
                   'a re-ask after a decline is a fresh ask, and queues a fresh push');

-- MARK: - Completion, late stated as late, and the everyone-made-it moment

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.publish_shared_progress('bbbbbbbb-0000-0000-0000-00000000000b',
                                      3, 'kept', now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_completed'),
                   'a real completion transition emits one shared_completed');
select public.publish_shared_progress('bbbbbbbb-0000-0000-0000-00000000000b',
                                      3, 'kept', now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_completed'),
                   'republishing the same story emits nothing');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'shared_all_completed'),
                   'the roster is not closed while a line is still open');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.publish_shared_progress('aaaaaaaa-0000-0000-0000-00000000000a',
                                      3, 'kept_late', now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_completed_late'),
                   'late is stated as late');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_all_completed'),
                   'the last finisher closes the roster: everyone made it, told once');
select test_assert((select count(*) = 1 from public.social_event e
                     join public.profile pr on pr.account_id = e.account_id
                    where e.kind = 'shared_all_completed' and pr.handle = 'patrick'),
                   'and it is told by the person whose finish closed it');

-- MARK: - One fact, one line: witnessing suppresses the shared duplicate

select public.create_shared_commitment(
         'dddddddd-0000-0000-0000-00000000000d', 'Walk 5 km',
         'walking', 'total_distance', 5000,
         now() - interval '1 hour', now() + interval '3 days', array['maya']);
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement where title = 'Walk 5 km'),
         true, 'eeeeeeee-0000-0000-0000-00000000000e');
-- Maya also shares this commitment with her friends through the witnessing
-- pipeline; its story will be told there.
select public.publish_shared_commitment('eeeeeeee-0000-0000-0000-00000000000e',
                                        'Walk 5 km', now() + interval '3 days', 'open');
select public.publish_shared_progress('eeeeeeee-0000-0000-0000-00000000000e',
                                      5000, 'kept', now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'shared_completed'),
                   'a completion already witnessed is not told twice');

-- MARK: - The shared window opening, announced once

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         'ffffffff-0000-0000-0000-00000000000f', 'Cycle an hour',
         'cycling', 'total_duration', 3600,
         now() + interval '2 hours', now() + interval '2 days', array['maya', 'dave']);
select test_assert((select start_announced_at is null
                      from public.shared_commitment_agreement
                     where title = 'Cycle an hour'),
                   'a future window is not announced at creation');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement where title = 'Cycle an hour'),
         true, '99999999-0000-0000-0000-000000000099');

update public.shared_commitment_agreement
   set window_start = now() - interval '1 minute'
 where title = 'Cycle an hour';
select test_assert(public.announce_shared_starts() = 1,
                   'the scheduler announces the window that opened');
select test_assert((select count(*) = 2 from public.social_event
                     where kind = 'shared_started'),
                   'once per bound participant — the still-invited hear nothing');
select test_assert(public.announce_shared_starts() = 0,
                   'and never twice');

-- The vocabulary is closed: a kind that is not on the list cannot be spelled.
select test_raises($$insert into public.social_event (account_id, kind, occurred_at)
                     values ((select account_id from public.profile where handle = 'maya'),
                             'reaction_received', now())$$,
                   'no event kind exists outside the allow-list');

-- MARK: - Partner requests and override approvals ride the same outbox

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_earned_partner('maya');
select test_assert((select count(*) = 1 from public.push_outbox
                     where kind = 'partner_request'),
                   'an accountability ask queues one push');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_partner_request(
  (select id from public.partner where kind = 'earned_user'), true);

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_partner('Mom', 'sms', '+14155550100');
select public.respond_to_invitation(test_token_for('Mom'), true);
select public.register_contract_envelope(
  p_commitment_id => '11110000-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where status = 'active'));
select test_advance_past_hardening('11110000-0000-0000-0000-000000000001');
select public.create_override_request(
  '22220000-0000-0000-0000-000000000001', '11110000-0000-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1);
select test_assert((select count(*) = 2 from public.override_request_recipient),
                   'both kinds of partner are recipients');
select test_assert((select count(*) = 1 from public.push_outbox
                     where kind = 'override_approval_request'),
                   'only the in-app partner gets a push — the external one gets a link');
select test_assert((select count(*) = 1 from public.push_outbox po
                     join public.profile pr on pr.account_id = po.account_id
                    where po.kind = 'override_approval_request' and pr.handle = 'maya'),
                   'and it goes to the partner, naming the asker in the body');

-- MARK: - Push tokens: registered by session, moved by re-registration

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.register_push_token('maya-device-token-0000000000000001');
select test_assert((select count(*) = 1 from public.push_device),
                   'a token registers once');
select public.register_push_token('maya-device-token-0000000000000001');
select test_assert((select count(*) = 1 from public.push_device),
                   'and idempotently');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.register_push_token('maya-device-token-0000000000000001');
select test_assert((select count(*) = 1 from public.push_device pd
                     join public.profile pr on pr.account_id = pd.account_id
                    where pr.handle = 'dave'),
                   'a re-registered token follows the signed-in account — a handed-on '
                   'phone does not keep pushing to its old owner');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.remove_push_token('maya-device-token-0000000000000001');
select test_assert((select count(*) = 1 from public.push_device),
                   'only the token''s current owner can remove it');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.remove_push_token('maya-device-token-0000000000000001');
select test_assert((select count(*) = 0 from public.push_device),
                   'the owner''s removal removes it');
select test_raises($$select public.register_push_token('x')$$,
                   'a token too short to be one is refused');

-- Neither push table is readable by any client role.
select test_sign_in('22222222-2222-2222-2222-222222222222');
set local role authenticated;
select test_raises($$select count(*) from public.push_outbox$$,
                   'clients cannot read the outbox');
select test_raises($$select count(*) from public.push_device$$,
                   'or the device registry');
reset role;

-- MARK: - Creator deletion orphans, never dissolves (decision 2)

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         '33330000-0000-0000-0000-000000000003', 'Swim twice',
         'swimming', 'sessions', 2,
         now() - interval '1 hour', now() + interval '5 days', array['dave']);

-- Recipient rows deliberately pin their partner rows (0009's audit trail), so
-- clearing the override request is part of any hard deletion — as the suite's
-- own setup already does. The orphaning rule under test is about agreements.
delete from public.override_request;
delete from public.account
 where id = (select account_id from public.profile where handle = 'patrick');

select test_assert((select count(*) = 4 from public.shared_commitment_agreement),
                   'the creator''s deletion dissolves nothing');
select test_assert((select bool_and(creator is null)
                      from public.shared_commitment_agreement),
                   'it orphans: the agreements survive with no author');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(
  (select count(*) >= 1 from jsonb_array_elements(public.my_shared_commitments()) sc
    where sc ->> 'title' = 'Run 3 times this week'
      and (sc ->> 'created_by_me')::boolean = false),
  'a bound participant keeps the shared context, authorless');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments()) sc,
          jsonb_array_elements(sc -> 'participants') p
    where p ->> 'handle' = 'patrick'),
  'the departed simply cease to appear — no tombstone line');

select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(
  (select count(*) = 0 from jsonb_array_elements(public.my_shared_invitations()) e
    where e ->> 'title' = 'Swim twice'),
  'an orphaned agreement asks nobody new');
select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement where title = 'Swim twice'),
                     true, '44440000-0000-0000-0000-000000000004')$$,
                   'and cannot be accepted — there is no author left to have asked');

-- MARK: - Retention purges only what nobody stands on

select test_assert(public.purge_shared_commitments() = 0,
                   'agreements people still stand on are not purged');
delete from public.account;
select test_assert(public.purge_shared_commitments() = 4,
                   'with no participants left, retention collects the empty shells');

rollback;
