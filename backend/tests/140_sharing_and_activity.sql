\set ON_ERROR_STOP on
\echo 'commitment sharing, the activity shelf, and streak figures'
set time zone 'UTC';

begin;

delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select public.upsert_my_profile('maya', 'Maya');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.ensure_account('apple-sub-dave', 'Dave');
select public.upsert_my_profile('dave', 'Dave');
select test_sign_in('44444444-4444-4444-4444-444444444444');
select public.ensure_account('apple-sub-lurker', 'Lurker');

-- Patrick and Maya are friends; Dave is a stranger.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);

-- MARK: - Publishing needs an identity, and honest inputs

select test_sign_in('44444444-4444-4444-4444-444444444444');
select test_raises(
  $$select public.publish_shared_commitment(gen_random_uuid(), 'Run', now() + interval '1 day', 'open')$$,
  'no profile, no sharing');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises(
  $$select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                            'Run 30 minutes', now() + interval '1 day', 'ended')$$,
  '"ended" is the server''s word, not a state a client may claim');
select test_raises(
  $$select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                            '   ', now() + interval '1 day', 'open')$$,
  'a shared commitment needs a title');

-- MARK: - Share, and the shelf hears exactly once

select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                        'Run 30 minutes', now() + interval '1 day', 'open');
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                        'Run 30 minutes', now() + interval '1 day', 'open');
select test_assert((select count(*) = 1 from public.shared_commitment),
                   'one shared commitment, however often it is republished');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'commitment_shared'),
                   'and one commitment_shared event, not one per foreground');

select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                        'Run 30 minutes', now() + interval '1 day', 'kept',
                                        now());
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                        'Run 30 minutes', now() + interval '1 day', 'kept',
                                        now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'commitment_kept'),
                   'open → kept emits exactly one event');

-- Shared after the fact: the terminal event is the story, "shared" is not.
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000002',
                                        'Cycle 45 minutes', now(), 'kept_late', now());
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'commitment_kept_late'),
                   'a commitment shared already-resolved emits its outcome');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'commitment_shared'),
                   'and no retroactive commitment_shared');

-- Links do not ride into friends'' feeds on a commitment title.
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000003',
                                        'Run — see https://evil.example/pay', now(), 'open');
select test_assert((select title not like '%evil%' from public.shared_commitment
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
                   'titles are neutralised like every other user text');

-- MARK: - Overrides are told only when the owner says so

select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000004',
                                        'Swim', now(), 'overridden', now());
select test_assert((select state = 'ended' from public.shared_commitment
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000004'),
                   'with sharing off, an Override is stored as a quiet "ended"');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'override_used'),
                   'and no event says otherwise');

select public.set_social_sharing(p_share_override_usage => true);
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000005',
                                        'Lift', now() + interval '1 day', 'open');
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000005',
                                        'Lift', now() + interval '1 day', 'overridden', now());
select test_assert((select state = 'overridden' from public.shared_commitment
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000005'),
                   'with sharing on, an Override is stored as what it is');
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'override_used'),
                   'and told once');

-- Turning it back off withdraws what was being shared, now.
select public.set_social_sharing(p_share_override_usage => false);
select test_assert((select count(*) = 0 from public.shared_commitment
                     where state = 'overridden'),
                   'every shared "overridden" becomes "ended" when sharing stops');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'override_used'),
                   'and the events that said more are withdrawn');

-- MARK: - What a friend sees, and what a stranger does not

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(jsonb_array_length(public.friend_activity()) >= 3,
                   'a friend sees the shelf');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.friend_activity()) entry,
          jsonb_object_keys(entry) k
    where k not in ('handle', 'display_name', 'avatar_path', 'kind', 'title',
                    'milestone', 'occurred_at')),
  'an event is who, what, which title, when — no ids, no reasons, nothing else');

select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(jsonb_array_length(public.friend_activity()) = 0,
                   'a stranger sees nothing');

-- MARK: - Unsharing withdraws everything the commitment generated

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.unshare_commitment('aaaaaaaa-0000-0000-0000-000000000001');
select test_assert((select count(*) = 0 from public.social_event
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
                   'no event survives because a friend once saw it');
select test_assert((select count(*) = 0 from public.shared_commitment
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
                   'and the shared commitment itself is gone');

-- MARK: - Streak figures follow their switch

select public.set_social_streaks(4);
select test_assert((select count(*) = 0 from public.social_streaks),
                   'with sharing off, figures are quietly not stored at all');

select public.set_social_sharing(p_share_streaks => true);
select public.set_social_streaks(4);
select test_assert((select commitments_kept = 4 and since_last_override is null
                     from public.social_streaks),
                   'with sharing on they are, and "never overridden" stays null, not zero');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'streak_milestone'),
                   'four is not a milestone');

select public.set_social_streaks(5, 2);
select public.set_social_streaks(5, 2);
select test_assert((select count(*) = 1 from public.social_event
                     where kind = 'streak_milestone' and milestone = 5),
                   'rising onto a milestone is told once, however often republished');

select test_raises($$select public.set_social_streaks(-1)$$,
                   'a negative streak is refused');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert((public.get_profile('patrick') ->> 'commitments_kept')::int = 5
                   and public.get_profile('patrick') ->> 'since_last_override' = '2',
                   'a friend sees the shared figures on the profile');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(public.get_profile('patrick') ->> 'commitments_kept' is null,
                   'a stranger does not');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.set_social_sharing(p_share_streaks => false);
select test_assert((select count(*) = 0 from public.social_streaks),
                   'turning streak sharing off deletes the figures');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'streak_milestone'),
                   'and their milestone events');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.get_profile('patrick') ->> 'commitments_kept' is null,
                   'the friend''s view honestly loses them too');

-- MARK: - The shelf has a horizon

-- Backdate one event past it, as only the suite (superuser) can.
update public.social_event
   set created_at = now() - interval '31 days'
 where kind = 'commitment_kept_late';
select test_assert((select count(*) = 0
                     from jsonb_array_elements(public.friend_activity()) entry
                    where entry ->> 'kind' = 'commitment_kept_late'),
                   'friend_activity refuses to read past 30 days');
select test_assert(public.purge_social_events() >= 1,
                   'and the purge deletes behind the same horizon');
select test_assert((select count(*) = 0 from public.social_event
                     where kind = 'commitment_kept_late'),
                   'gone from storage, not just from view');

-- MARK: - Blocking ends the feed as it ends everything else

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(jsonb_array_length(public.friend_activity()) >= 1,
                   'Maya still sees Patrick''s remaining events');
select public.block_user('patrick');
select test_assert(jsonb_array_length(public.friend_activity()) = 0,
                   'blocking empties the shelf both ways');
select public.unblock_user('patrick');

-- MARK: - RLS and anon

set local role authenticated;
select test_assert((select count(*) = 0 from public.shared_commitment),
                   'RLS: Maya reads no shared_commitment rows but her own (she has none)');
select test_assert((select count(*) = 0 from public.social_event),
                   'same for events');
select test_raises($$insert into public.social_event (account_id, kind, occurred_at)
                     values (gen_random_uuid(), 'commitment_kept', now())$$,
                   'no client role writes events directly');
reset role;

set local role anon;
select test_sign_out();
select test_raises($$select public.friend_activity()$$, 'anon has no shelf');
select test_raises(
  $$select public.publish_shared_commitment(gen_random_uuid(), 'x', now(), 'open')$$,
  'anon shares nothing');
reset role;

rollback;
