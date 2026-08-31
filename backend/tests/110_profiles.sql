\set ON_ERROR_STOP on
\echo 'profiles: identity, handles, and one canonical name'
set time zone 'UTC';

begin;

-- Leftovers from prior drills would skew unqualified counts; the transaction
-- rolls back, so deleting here is invisible outside it.
delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select test_sign_in('11111111-1111-1111-1111-111111111111');

-- MARK: - Completion state

select test_assert(public.my_profile() is null,
                   'before setup, my_profile is null — that IS the completion check');

-- MARK: - Creation, normalisation, and the canonical name

select public.upsert_my_profile('@Patrick ', 'Patrick', ' London ', 'Europe/London');

select test_assert(public.my_profile() ->> 'handle' = 'patrick',
                   'a handle is trimmed, de-@ed and lowercased on the way in');
select test_assert(public.my_profile() ->> 'city' = 'London',
                   'city is trimmed and kept');
select test_assert(public.my_profile() ->> 'timezone' = 'Europe/London',
                   'timezone is stored (privately)');
select test_assert((select display_name = 'Patrick' from public.account
                     where apple_user_id = 'apple-sub-patrick'),
                   'display name lives on account — the same row the partner page reads');

select public.upsert_my_profile('patrick', 'Pat', 'London', 'Europe/London');
select test_assert(public.my_profile() ->> 'display_name' = 'Pat'
                   and (select display_name = 'Pat' from public.account
                         where apple_user_id = 'apple-sub-patrick'),
                   'editing the profile name edits THE name — no split-brain identity');

select test_assert(
  (select count(*) = 0 from jsonb_object_keys(public.my_profile()) k
    where k not in ('handle', 'display_name', 'avatar_path', 'city', 'timezone',
                    'discoverable', 'share_streaks', 'share_override_usage',
                    'share_last_checkin')),
  'my_profile carries exactly the designed fields — no account id, no apple subject');
select test_assert(public.my_profile() ->> 'share_streaks' = 'false'
                   and public.my_profile() ->> 'share_override_usage' = 'false'
                   and public.my_profile() ->> 'share_last_checkin' = 'false',
                   'every sharing switch is born off (invariant 26)');

-- MARK: - Handle validation

select test_raises($$select public.upsert_my_profile('ab', 'Patrick')$$,
                   'a two-character handle is refused');
select test_raises($$select public.upsert_my_profile('this_is_way_too_long_for_a_handle', 'Patrick')$$,
                   'an over-long handle is refused');
select test_raises($$select public.upsert_my_profile('pat rick', 'Patrick')$$,
                   'spaces are refused');
select test_raises($$select public.upsert_my_profile('pat.rick', 'Patrick')$$,
                   'punctuation beyond underscore is refused');
select test_raises($$select public.upsert_my_profile('earned', 'Patrick')$$,
                   'a reserved handle is refused');
select test_raises($$select public.upsert_my_profile('admin', 'Patrick')$$,
                   'so is admin');
select test_raises($$select public.upsert_my_profile('patrick', '')$$,
                   'a profile without a display name is refused');

-- MARK: - Uniqueness is case-insensitive

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_raises($$select public.upsert_my_profile('PATRICK', 'Maya')$$,
                   'a taken handle is refused regardless of case');
select public.upsert_my_profile('maya', 'Maya');
select test_assert(public.my_profile() ->> 'handle' = 'maya',
                   'a free handle is granted');

-- MARK: - Isolation

set local role authenticated;
select test_assert((select count(*) = 1 from public.profile),
                   'RLS: an account SELECTs its own profile row and nobody else''s');
select test_assert((select handle = 'maya' from public.profile),
                   'and the row it sees is its own');
select test_raises($$update public.profile set city = 'Mordor'$$,
                   'no client role can write the profile table directly');
select test_raises($$delete from public.profile$$,
                   'or delete from it');
select test_raises($$insert into public.profile (account_id, handle)
                     values (gen_random_uuid(), 'intruder')$$,
                   'or insert into it');
reset role;

-- Maya editing her profile must not touch Patrick's.
select public.upsert_my_profile('maya', 'Maya', 'Chicago');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.my_profile() ->> 'city' = 'London',
                   'one account''s edit cannot reach another''s profile');

-- MARK: - Anon gets nothing

set local role anon;
select test_sign_out();
select test_raises($$select count(*) from public.profile$$,
                   'anon cannot read the profile table');
select test_raises($$select public.my_profile()$$,
                   'anon cannot call my_profile');
select test_raises($$select public.upsert_my_profile('anon', 'Anon')$$,
                   'anon cannot create a profile');
reset role;

rollback;
