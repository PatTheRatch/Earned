\set ON_ERROR_STOP on
\echo 'check-in sharing: one fact, whole days, only interesting silence'
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

-- Patrick and Maya are friends; Dave is a stranger.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);

-- MARK: - Off means not stored, not stored-and-hidden

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.record_checkin();
select test_assert((select last_checkin_at is null from public.profile
                     where handle = 'patrick'),
                   'with the switch off, a check-in records nothing at all');

-- MARK: - On starts the clock now, and fresh silence is not news

select public.set_social_sharing(p_share_last_checkin => true);
select test_assert((select last_checkin_at is not null from public.profile
                     where handle = 'patrick'),
                   'turning it on starts the clock at now');
select public.record_checkin();

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_friends() -> 0 ->> 'quiet_days' is null,
                   'a friend heard from recently shows no quiet block — no live presence');
select test_assert(public.get_profile('patrick') ->> 'quiet_days' is null,
                   'on the profile too');

-- MARK: - Silence past the threshold surfaces, coarsely, to friends only

-- Share one still-open commitment first, so the quiet block has its fact.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.publish_shared_commitment('aaaaaaaa-0000-0000-0000-000000000001',
                                        'Run 30 minutes', now() + interval '1 day', 'open');
-- Backdate the check-in, as only the suite (superuser) can.
update public.profile set last_checkin_at = now() - interval '4 days 1 hour'
 where handle = 'patrick';

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert((public.my_friends() -> 0 ->> 'quiet_days')::int = 4,
                   'a friend sees whole days of silence, not a timestamp');
select test_assert((public.my_friends() -> 0 ->> 'open_shared_commitments')::int = 1,
                   'and how many shared commitments were open at the last check-in');
select test_assert((public.get_profile('patrick') ->> 'quiet_days')::int = 4,
                   'the friend profile carries the same block');
select test_assert(public.my_friends() -> 0 ->> 'last_checkin_at' is null,
                   'the raw timestamp is never a field anywhere');

select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(public.get_profile('patrick') ->> 'quiet_days' is null,
                   'a stranger learns nothing from the silence');

-- Just under the threshold: nothing, even for a friend.
update public.profile set last_checkin_at = now() - interval '71 hours'
 where handle = 'patrick';
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_friends() -> 0 ->> 'quiet_days' is null,
                   'under 72 hours a silence is not yet interesting');

-- MARK: - A silence never shared is never surfaced retroactively

update public.profile set last_checkin_at = now() - interval '10 days'
 where handle = 'patrick';
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.set_social_sharing(p_share_last_checkin => false);
select test_assert((select last_checkin_at is null from public.profile
                     where handle = 'patrick'),
                   'off deletes the fact');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_friends() -> 0 ->> 'quiet_days' is null,
                   'and the friend view honestly loses it');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.set_social_sharing(p_share_last_checkin => true);
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_friends() -> 0 ->> 'quiet_days' is null,
                   'turning it back on starts from now — the old silence is not resurrected');

-- MARK: - Anon

set local role anon;
select test_sign_out();
select test_raises($$select public.record_checkin()$$, 'anon checks in nowhere');
select test_raises($$select public.set_social_sharing(p_share_last_checkin => true)$$,
                   'anon has no switches');
reset role;

rollback;
