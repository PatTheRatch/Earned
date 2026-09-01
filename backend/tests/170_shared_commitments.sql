\set ON_ERROR_STOP on
\echo 'shared commitments: the promise is shared, the punishment is not'
set time zone 'UTC';

begin;

delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

-- The cast: three users with profiles, one without, two friendships.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patrick', 'Patrick', 'London');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select public.upsert_my_profile('maya', 'Maya', 'Chicago');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.ensure_account('apple-sub-dave', 'Dave');
select public.upsert_my_profile('dave', 'Dave');
select test_sign_in('44444444-4444-4444-4444-444444444444');
select public.ensure_account('apple-sub-lurker', 'Lurker');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select public.send_friend_request('dave');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_friend_request('patrick', true);

-- MARK: - An identity is required

select test_sign_in('44444444-4444-4444-4444-444444444444');
select test_raises($$select public.my_shared_commitments()$$,
                   'no profile, no shared commitments');
select test_raises($$select public.create_shared_commitment(
                     gen_random_uuid(), 'Run', 'running', 'total_distance', 10000,
                     now(), now() + interval '7 days', array['patrick'])$$,
                   'creating included');

-- MARK: - Creating shares the promise

select test_sign_in('11111111-1111-1111-1111-111111111111');

select test_raises($$select public.create_shared_commitment(
                     'aaaaaaaa-0000-0000-0000-00000000000a', 'Run 10 km this week',
                     'running', 'total_distance', 10000,
                     now(), now() + interval '7 days', array[]::text[])$$,
                   'a shared commitment needs somebody to share it with');
select test_raises($$select public.create_shared_commitment(
                     'aaaaaaaa-0000-0000-0000-00000000000a', 'Run 10 km this week',
                     'running', 'total_distance', 10000,
                     now(), now() - interval '1 hour', array['maya'])$$,
                   'the shared deadline must be in the future');
select test_raises($$select public.create_shared_commitment(
                     'aaaaaaaa-0000-0000-0000-00000000000a', '  ',
                     'running', 'total_distance', 10000,
                     now(), now() + interval '7 days', array['maya'])$$,
                   'a blank title is refused');

select public.create_shared_commitment(
         'aaaaaaaa-0000-0000-0000-00000000000a', 'Run 10 km this week',
         'running', 'total_distance', 10000,
         now(), now() + interval '7 days', array['maya', 'dave']);
select test_assert((select count(*) = 1 from public.shared_commitment_agreement),
                   'one agreement');
select test_assert((select count(*) = 1 from public.shared_commitment_participant
                     where state = 'accepted'),
                   'the creator is bound from birth — nobody else is');
select test_assert((select count(*) = 2 from public.shared_commitment_participant
                     where state = 'invited'),
                   'the invited are invited, not obliged');

-- Retrying creation (a network failure, a crash) converges on the same
-- agreement instead of minting a second one.
select test_assert(
  (select (public.create_shared_commitment(
             'aaaaaaaa-0000-0000-0000-00000000000a', 'Run 10 km this week',
             'running', 'total_distance', 10000,
             now(), now() + interval '7 days', array['maya', 'dave']) ->> 'id')::uuid
        = (select id from public.shared_commitment_agreement)),
  'retrying creation with the same commitment id returns the same agreement');
select test_assert((select count(*) = 1 from public.shared_commitment_agreement),
                   'and creates nothing new');

-- MARK: - Inviting: friends only, one ask per person

select test_raises($$select public.invite_to_shared_commitment(
                     (select id from public.shared_commitment_agreement), 'lurker')$$,
                   'only accepted friends can be invited');
select test_raises($$select public.invite_to_shared_commitment(
                     (select id from public.shared_commitment_agreement), 'patrick')$$,
                   'inviting yourself adds nothing');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement), 'maya');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement), 'maya');
select test_assert((select count(*) = 3 from public.shared_commitment_participant),
                   'inviting the same friend twice is one ask — no duplicate rows');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_raises($$select public.invite_to_shared_commitment(
                     (select id from public.shared_commitment_agreement), 'dave')$$,
                   'only the creator invites');

-- MARK: - The invitation card

select test_assert(jsonb_array_length(public.my_shared_invitations()) = 1,
                   'Maya sees the ask');
select test_assert(public.my_shared_invitations() -> 0 ->> 'inviter_handle' = 'patrick',
                   'and who is asking');
select test_assert((public.my_shared_invitations() -> 0 ->> 'accepted_count')::int = 1,
                   'and that one person is already in');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_invitations()) entry,
          jsonb_object_keys(entry) k
    where k not in ('id', 'title', 'activity', 'metric', 'target', 'window_start',
                    'deadline', 'invited_at', 'inviter_handle',
                    'inviter_display_name', 'inviter_avatar_path', 'accepted_count')),
  'an invitation card carries the terms and the asker — no ids of other people, nothing else');
select test_assert(jsonb_array_length(public.my_shared_commitments()) = 0,
                   'an unanswered invitation is not a commitment of Maya''s');

-- MARK: - Acceptance is the only thing that binds (invariant 31)

select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement), true)$$,
                   'accepting must name the personal commitment the client creates');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), true,
         'bbbbbbbb-0000-0000-0000-00000000000b', 'app_verified');
select test_assert((select state = 'accepted' and accepted_terms_version = 1
                      from public.shared_commitment_participant sp
                      join public.profile pr on pr.account_id = sp.account_id
                     where pr.handle = 'maya'),
                   'accepting binds Maya to the terms as they stand');

-- Duplicate acceptance — a double-tap, a retry after a timeout — is one
-- acceptance; the first recorded commitment wins and is repeated back.
select test_assert(
  public.respond_to_shared_invitation(
    (select id from public.shared_commitment_agreement), true,
    'cccccccc-0000-0000-0000-00000000000c') ->> 'commitment_id'
  = 'bbbbbbbb-0000-0000-0000-00000000000b',
  'a duplicate acceptance converges on the first — one acceptance, one commitment');

-- MARK: - Declining is quiet

select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), false);
select test_assert((select state = 'declined' from public.shared_commitment_participant sp
                      join public.profile pr on pr.account_id = sp.account_id
                     where pr.handle = 'dave'),
                   'declining records declined');
select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement), true,
                     'dddddddd-0000-0000-0000-00000000000d')$$,
                   'a declined invitation cannot be accepted later — it takes a fresh ask');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments() -> 0 -> 'participants') p
    where p ->> 'handle' = 'dave'),
  'the roster never shows who said no');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement), 'dave');
select test_assert((select state = 'invited' from public.shared_commitment_participant sp
                      join public.profile pr on pr.account_id = sp.account_id
                     where pr.handle = 'dave'),
                   're-asking after a decline reopens the same row');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement), true,
         'dddddddd-0000-0000-0000-00000000000d');

-- MARK: - The roster, and what each line carries

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(jsonb_array_length(public.my_shared_commitments()) = 1,
                   'Patrick stands on one shared commitment');
select test_assert(
  jsonb_array_length(public.my_shared_commitments() -> 0 -> 'participants') = 3,
  'all three stand on the roster');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments() -> 0 -> 'participants') p,
          jsonb_object_keys(p) k
    where k not in ('handle', 'display_name', 'avatar_path', 'state', 'verification',
                    'progress', 'progress_state', 'resolved_at')),
  'a roster line is identity, state, verification and progress — no account ids, no settings');
select test_assert(
  (select p ->> 'verification' = 'app_verified'
     from jsonb_array_elements(public.my_shared_commitments() -> 0 -> 'participants') p
    where p ->> 'handle' = 'maya'),
  'differing verification tiers are stated factually, never flattened');

-- MARK: - Progress is representation, one line each (invariant 30)

select public.publish_shared_progress('aaaaaaaa-0000-0000-0000-00000000000a',
                                      4200, 'open');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.publish_shared_progress('bbbbbbbb-0000-0000-0000-00000000000b',
                                      10000, 'kept', now());
select test_assert(
  (select (p ->> 'progress')::numeric = 4200 and p ->> 'progress_state' = 'open'
     from jsonb_array_elements(public.my_shared_commitments() -> 0 -> 'participants') p
    where p ->> 'handle' = 'patrick'),
  'Maya finishing does not move Patrick''s line — each owns their own state');
select test_raises($$select public.publish_shared_progress(
                     'aaaaaaaa-0000-0000-0000-00000000000a', 100, 'open')$$,
                   'nobody publishes progress on someone else''s commitment');
select test_raises($$select public.publish_shared_progress(
                     'bbbbbbbb-0000-0000-0000-00000000000b', 100, 'ended')$$,
                   '"ended" is the server''s word, not a state a client may claim');

-- An Override is told only as the owner shares it: off means a quiet 'ended'.
select public.publish_shared_progress('bbbbbbbb-0000-0000-0000-00000000000b',
                                      10000, 'overridden', now());
select test_assert((select progress_state = 'ended'
                      from public.shared_commitment_participant
                     where commitment_id = 'bbbbbbbb-0000-0000-0000-00000000000b'),
                   'an Override with sharing off is stored as a quiet ended');
select public.set_social_sharing(null, true, null);
select public.publish_shared_progress('bbbbbbbb-0000-0000-0000-00000000000b',
                                      10000, 'overridden', now());
select test_assert((select progress_state = 'overridden'
                      from public.shared_commitment_participant
                     where commitment_id = 'bbbbbbbb-0000-0000-0000-00000000000b'),
                   'with sharing on, an Override is stated as one');

-- MARK: - The promise freezes at acceptance (invariant 32)

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select public.edit_shared_commitment(
                     (select id from public.shared_commitment_agreement),
                     'Run 12 km this week', 'running', 'total_distance', 12000,
                     now(), now() + interval '7 days')$$,
                   'after someone accepted, the promise is nobody''s to rewrite');

-- Before anyone else accepts, the terms are still the creator's to shape.
select public.create_shared_commitment(
         'eeeeeeee-0000-0000-0000-00000000000e', 'Lift twice',
         'strength', 'total_duration', 3600,
         now(), now() + interval '3 days', array['maya']);
select public.edit_shared_commitment(
         (select id from public.shared_commitment_agreement where title = 'Lift twice'),
         'Lift for 90 minutes', 'strength', 'total_duration', 5400,
         now(), now() + interval '3 days');
select test_assert((select terms_version = 2 from public.shared_commitment_agreement
                     where title = 'Lift for 90 minutes'),
                   'editing before any acceptance advances the version');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_shared_invitation(
         (select id from public.shared_commitment_agreement where title = 'Lift for 90 minutes'),
         true, 'ffffffff-0000-0000-0000-00000000000f');
select test_assert((select accepted_terms_version = 2
                      from public.shared_commitment_participant
                     where commitment_id = 'ffffffff-0000-0000-0000-00000000000f'),
                   'an acceptance records which terms were accepted');

-- MARK: - Cancelling takes back only what never started

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.cancel_shared_commitment(
         (select id from public.shared_commitment_agreement where title = 'Lift for 90 minutes'))
         ->> 'state' = 'closed',
       'cancelling after an acceptance closes the future — it does not erase the past');
select test_assert((select state = 'accepted' from public.shared_commitment_participant
                     where commitment_id = 'ffffffff-0000-0000-0000-00000000000f'),
                   'Maya keeps exactly the commitment she accepted');

select public.create_shared_commitment(
         '99999999-0000-0000-0000-000000000099', 'Walk 5 km',
         'walking', 'total_distance', 5000,
         now(), now() + interval '2 days', array['maya']);
select test_assert(public.cancel_shared_commitment(
         (select id from public.shared_commitment_agreement where title = 'Walk 5 km'))
         ->> 'state' = 'cancelled',
       'cancelling before anyone accepts cancels outright');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(
  (select count(*) = 0 from jsonb_array_elements(public.my_shared_invitations()) e
    where e ->> 'title' = 'Walk 5 km'),
  'a cancelled ask disappears from the card');
select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement where title = 'Walk 5 km'),
                     true, '88888888-0000-0000-0000-000000000088')$$,
                   'and cannot be accepted afterwards');

-- MARK: - Past the deadline, a commitment cannot be born

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         '77777777-0000-0000-0000-000000000077', 'Evening run',
         'running', 'show_up', null,
         now(), now() + interval '1 hour', array['maya']);
update public.shared_commitment_agreement
   set window_start = now() - interval '2 hours',
       deadline = now() - interval '1 minute'
 where title = 'Evening run';
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement where title = 'Evening run'),
                     true, '66666666-0000-0000-0000-000000000066')$$,
                   'an invitation past its deadline binds nobody');
select test_assert(
  (select count(*) = 0 from jsonb_array_elements(public.my_shared_invitations()) e
    where e ->> 'title' = 'Evening run'),
  'and is no longer offered');

-- MARK: - Leaving is a social act (invariant 32)

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.leave_shared_commitment(
         (select id from public.shared_commitment_agreement
           where title = 'Run 10 km this week'));
select test_assert((select state = 'left' and commitment_id is not null
                      from public.shared_commitment_participant
                     where commitment_id = 'bbbbbbbb-0000-0000-0000-00000000000b'),
                   'leaving takes Maya off the roster and touches nothing she owes');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments()) sc,
          jsonb_array_elements(sc -> 'participants') p
    where sc ->> 'title' = 'Run 10 km this week' and p ->> 'handle' = 'maya'),
  'the roster no longer shows her');
select test_raises($$select public.leave_shared_commitment(
                     (select id from public.shared_commitment_agreement
                       where title = 'Run 10 km this week'))$$,
                   'the creator cancels the future rather than leaving');

-- MARK: - Unfriending kills the ask, not the obligations

select public.create_shared_commitment(
         '55555555-0000-0000-0000-000000000055', 'Cycle an hour',
         'cycling', 'total_duration', 3600,
         now(), now() + interval '4 days', array['dave']);
select public.remove_friend('dave');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(
  (select count(*) = 0 from jsonb_array_elements(public.my_shared_invitations()) e
    where e ->> 'title' = 'Cycle an hour'),
  'the friendship carried the ask; without it the ask is gone');
select test_raises($$select public.respond_to_shared_invitation(
                     (select id from public.shared_commitment_agreement where title = 'Cycle an hour'),
                     true, '44444444-0000-0000-0000-000000000044')$$,
                   'and cannot be accepted');
select test_assert((select state = 'accepted' from public.shared_commitment_participant
                     where commitment_id = 'dddddddd-0000-0000-0000-00000000000d'),
                   'while the commitment Dave already accepted stands untouched');

-- MARK: - Block supersedes: sight severed, obligations standing (invariant 29 extended)

select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.block_user('patrick');
select test_assert((select state = 'accepted' from public.shared_commitment_participant
                     where commitment_id = 'dddddddd-0000-0000-0000-00000000000d'),
                   'blocking never erases a hardened obligation — Dave''s row stands');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments()) sc,
          jsonb_array_elements(sc -> 'participants') p
    where p ->> 'handle' = 'patrick'),
  'Dave no longer sees Patrick''s line');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_shared_commitments()) sc,
          jsonb_array_elements(sc -> 'participants') p
    where p ->> 'handle' = 'dave'),
  'and Patrick no longer sees Dave''s — a block cuts both ways');

-- A block lands on any unanswered ask between the pair, in both directions.
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.unblock_user('patrick');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('dave');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.invite_to_shared_commitment(
         (select id from public.shared_commitment_agreement where title = 'Cycle an hour'),
         'dave');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.block_user('patrick');
select test_assert((select sp.state = 'withdrawn' from public.shared_commitment_participant sp
                      join public.shared_commitment_agreement sa on sa.id = sp.agreement_id
                      join public.profile pr on pr.account_id = sp.account_id
                     where sa.title = 'Cycle an hour' and pr.handle = 'dave'),
                   'a block withdraws the unanswered ask between the pair');

-- MARK: - RLS: direct reads are own-perspective only

select test_sign_in('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select test_assert((select count(*) = 0 from public.shared_commitment_participant sp
                      join public.profile pr on pr.account_id = sp.account_id
                     where pr.handle <> 'patrick'),
                   'RLS: nobody reads another participant''s row directly');
select test_assert((select count(*) > 0 from public.shared_commitment_agreement),
                   'RLS: a participant can read the agreements they stand on');
reset role;

-- MARK: - Anon gets nothing

set local role anon;
select test_sign_out();
select test_raises($$select count(*) from public.shared_commitment_agreement$$,
                   'anon cannot read agreements');
select test_raises($$select count(*) from public.shared_commitment_participant$$,
                   'anon cannot read rosters');
select test_raises($$select public.my_shared_commitments()$$,
                   'anon cannot ask for shared commitments');
select test_raises($$select public.create_shared_commitment(
                     gen_random_uuid(), 'X', 'any', 'show_up', null,
                     now(), now() + interval '1 day', array['patrick'])$$,
                   'anon cannot create one');
reset role;

rollback;
