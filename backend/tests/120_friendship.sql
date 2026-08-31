\set ON_ERROR_STOP on
\echo 'friendship: requests, blocking, and what a stranger can learn'
set time zone 'UTC';

begin;

delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

-- Three users with profiles, one without.
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

-- MARK: - An identity is required

select test_raises($$select public.send_friend_request('patrick')$$,
                   'no profile, no social actions');
select test_raises($$select public.search_profiles('pat')$$,
                   'search included');

-- MARK: - Asking

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select public.send_friend_request('patrick')$$,
                   'you cannot befriend yourself');

select public.send_friend_request('@Maya');  -- normalisation applies here too
select test_assert((select count(*) = 1 from public.friendship),
                   'a request is one pending row');
select public.send_friend_request('maya');
select public.send_friend_request('maya');
select test_assert((select count(*) = 1 from public.friendship),
                   'repeating the ask is idempotent — no duplicates');

select test_assert(public.my_friend_requests() -> 'outgoing' -> 0 ->> 'handle' = 'maya',
                   'the ask shows as outgoing to the asker');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_friend_requests() -> 'incoming' -> 0 ->> 'handle' = 'patrick',
                   'and as incoming to the asked');

-- MARK: - Crossed requests resolve to one friendship

select public.send_friend_request('patrick');
select test_assert((select count(*) = 1 from public.friendship where status = 'accepted'),
                   'asking back IS accepting: one mutual friendship, one row');
select test_assert(public.my_friends() -> 0 ->> 'handle' = 'patrick',
                   'Maya sees Patrick as a friend');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.my_friends() -> 0 ->> 'handle' = 'maya',
                   'Patrick sees Maya — acceptance is mutual, not two records');
select test_assert(public.my_friends() -> 0 ->> 'city' = 'Chicago',
                   'a friend sees city');

-- MARK: - Accept and decline, the ordinary way

select public.send_friend_request('dave');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_raises($$select public.respond_to_friend_request('nobody_here', true)$$,
                   'answering a request that does not exist is refused');
select public.respond_to_friend_request('patrick', false);
select test_assert((select status = 'declined' from public.friendship
                     where requester = (select account_id from public.profile where handle = 'patrick')
                       and status <> 'accepted'),
                   'declining records declined');
select test_assert(jsonb_array_length(public.my_friend_requests() -> 'incoming') = 0,
                   'a declined request stops being listed for the decliner');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(jsonb_array_length(public.my_friend_requests() -> 'outgoing') = 0,
                   'the requester''s ask just disappears — never shown "declined"');
set local role authenticated;
select test_assert((select count(*) = 0 from public.friendship where status = 'declined'),
                   'RLS agrees: the declined row is invisible to the requester');
reset role;

select public.send_friend_request('dave');
select test_assert((select count(*) = 1 from public.friendship where status = 'pending'),
                   're-asking after a decline reopens the same row');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_friend_request('patrick', true);
select test_assert((select count(*) = 2 from public.friendship where status = 'accepted'),
                   'accepting works after an earlier decline');

-- The requester of a pending row cannot answer their own ask.
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.send_friend_request('dave');
select test_raises($$select public.respond_to_friend_request('dave', true)$$,
                   'the asker cannot accept on the asked''s behalf');
select public.cancel_friend_request('dave');
select test_assert((select count(*) = 0 from public.friendship where status = 'pending'),
                   'cancelling an unanswered ask leaves nothing behind');

-- MARK: - Removal revokes access

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.get_profile('maya') ->> 'city' = 'Chicago',
                   'while friends, the profile shows city');
select public.remove_friend('maya');
select test_assert(jsonb_array_length(public.my_friends()) = 0
                   or public.my_friends() -> 0 ->> 'handle' <> 'maya',
                   'either side may remove the friendship');
select test_assert(public.get_profile('maya') ->> 'city' is null,
                   'and city disappears with it');
select test_assert(public.get_profile('maya') ->> 'relationship' = 'none',
                   'the pair are strangers again');

-- MARK: - Search shape

select test_assert(public.search_profiles('ma') -> 0 ->> 'handle' = 'maya',
                   'prefix search finds a handle');
select test_assert(jsonb_array_length(public.search_profiles('m')) = 0,
                   'one character is too little to search on');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.search_profiles('ma')) entry,
          jsonb_object_keys(entry) k
    where k not in ('handle', 'display_name', 'avatar_path')),
  'a search result is handle, name, avatar — no city, no ids, nothing else');
select test_assert(public.search_profiles('ma') -> 0 ->> 'account_id' is null,
                   'account ids are not a discovery mechanism');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.set_my_discoverability(false);
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(jsonb_array_length(public.search_profiles('ma')) = 0,
                   'an undiscoverable profile is findable by nobody new');
select test_assert(public.get_profile('maya') is null,
                   'and reads as not-found to a stranger');
select public.send_friend_request('maya');
select test_assert((select count(*) = 0 from public.friendship where status = 'pending'),
                   'a request to an undiscoverable stranger is quietly dropped');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.set_my_discoverability(true);

-- MARK: - Blocking

-- Maya blocks Patrick, over their (removed) history.
select public.block_user('patrick');
select test_assert((select count(*) = 1 from public.friendship where status = 'blocked'),
                   'blocking writes one blocked row');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.get_profile('maya') is null,
                   'the blocked cannot see the blocker''s profile');
select test_assert(jsonb_array_length(public.search_profiles('ma')) = 0,
                   'or find them in search');
select public.send_friend_request('maya');
select test_assert((select count(*) = 1 from public.friendship
                     where status = 'blocked'
                       and not exists (select 1 from public.friendship f2
                                        where f2.status = 'pending')),
                   'a request to someone who blocked you is dropped without a trace');
set local role authenticated;
select test_assert((select count(*) = 0 from public.friendship where status = 'blocked'),
                   'RLS: the blocked party cannot read the blocked row — the block itself is private');
reset role;
select test_assert(jsonb_array_length(public.my_blocked()) = 0,
                   'the blocked party''s own block list is empty');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_blocked() -> 0 ->> 'handle' = 'patrick',
                   'the blocker sees their block list');
select test_assert(public.get_profile('patrick') ->> 'relationship' = 'blocked',
                   'and the blocked profile reads as blocked to them');
select test_assert(public.get_profile('patrick') ->> 'avatar_path' is null,
                   'with no avatar — a block cuts both ways');

-- Mutual blocks: Patrick blocks Maya too, then Maya unblocks. Patrick's block
-- must still stand.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.block_user('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.unblock_user('patrick');
select test_assert((select status = 'blocked' from public.friendship
                     where blocked_by_low or blocked_by_high),
                   'one side unblocking does not lift the other side''s block');
select test_assert(public.get_profile('patrick') is null,
                   'Maya is now the blocked one and sees nothing');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.unblock_user('maya');
select test_assert((select count(*) = 0 from public.friendship where status = 'blocked'),
                   'when nobody is left blocking, the row is gone');
select public.send_friend_request('maya');
select test_assert((select count(*) = 1 from public.friendship where status = 'pending'),
                   'after a full unblock the pair may start over');

-- MARK: - What leaks, checked by shape

select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_friends()) entry,
          jsonb_object_keys(entry) k
    where k not in ('handle', 'display_name', 'avatar_path', 'city')),
  'a friend row is handle, name, avatar, city — nothing else');
select test_assert(public.get_profile('dave') ->> 'timezone' is null,
                   'timezone is private system information, shown to nobody');

-- MARK: - Anon gets nothing

set local role anon;
select test_sign_out();
select test_raises($$select count(*) from public.friendship$$,
                   'anon cannot read friendships');
select test_raises($$select public.search_profiles('pat')$$,
                   'anon cannot search');
select test_raises($$select public.get_profile('patrick')$$,
                   'anon cannot read profiles');
select test_raises($$select public.send_friend_request('patrick')$$,
                   'anon cannot ask');
reset role;

rollback;
