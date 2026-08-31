\set ON_ERROR_STOP on
\echo 'avatars: one current image, visibility decided at read time'
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

-- Shorthand for each account's folder.
create temp view t_ids as
  select (select account_id::text from public.profile where handle = 'patrick') as patrick,
         (select account_id::text from public.profile where handle = 'maya')    as maya,
         (select account_id::text from public.profile where handle = 'dave')    as dave;

-- MARK: - The write-side rule

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.avatar_path_is_mine(
                     (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'an account may write inside its own folder');
select test_assert(not public.avatar_path_is_mine(
                     (select maya from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'and nowhere else');
select test_assert(not public.avatar_path_is_mine(
                     (select patrick from t_ids) || '/evil.exe'),
                   'only avatar-shaped names are writable');
select test_assert(not public.avatar_path_is_mine(
                     (select patrick from t_ids) || '/../' || (select maya from t_ids) || '.jpg'),
                   'path tricks do not parse as an avatar name');

select test_raises(
  $$select public.set_my_avatar((select maya from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg')$$,
  'the profile pointer cannot be aimed at someone else''s folder');
select test_raises($$select public.set_my_avatar('not-a-path')$$,
                   'or at a malformed name');

-- MARK: - Current vs replaced

select public.set_my_avatar(
  (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg');

-- Patrick and Maya become friends; Dave stays a stranger.
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);

select test_assert(public.avatar_is_visible(
                     (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'a friend sees the current avatar');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(public.avatar_is_visible(
                     (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'a stranger sees it exactly where they would see the profile');

-- Replace it. The old object must stop being readable by anyone but the owner
-- at the instant of the repoint — deletion is cleanup, not the boundary.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(public.set_my_avatar(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg')
                     ->> 'previous'
                   = (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg',
                   'replacing returns the orphaned path for deletion');
select test_assert(public.avatar_is_visible(
                     (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'the owner can still read their own replaced object');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(not public.avatar_is_visible(
                     (select patrick from t_ids) || '/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa.jpg'),
                   'a friend cannot — a replaced avatar is nobody''s current avatar');
select test_assert(public.avatar_is_visible(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg'),
                   'the new one is what the friend sees');

-- MARK: - Undiscoverable and blocked

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.set_my_discoverability(false);
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(not public.avatar_is_visible(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg'),
                   'an undiscoverable profile''s avatar is invisible to strangers');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.avatar_is_visible(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg'),
                   'but friends still see it');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.set_my_discoverability(true);

select public.block_user('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(not public.avatar_is_visible(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg'),
                   'a block ends avatar access, whatever the friendship was');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(not public.avatar_is_visible(
                     (select maya from t_ids) || '/cccccccc-3333-3333-3333-cccccccccccc.jpg')
                   and not exists (select 1 from public.profile
                                    where handle = 'maya' and avatar_path is not null),
                   'blocking is symmetric — and Maya has no avatar to see anyway');
select public.unblock_user('maya');

-- MARK: - Clearing

select test_assert(public.clear_my_avatar() ->> 'previous'
                   = (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg',
                   'clearing returns the orphaned path too');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_assert(not public.avatar_is_visible(
                     (select patrick from t_ids) || '/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb.jpg'),
                   'a cleared avatar is readable by nobody else');

-- MARK: - Anon

set local role anon;
select test_sign_out();
select test_raises($$select public.avatar_is_visible('whatever.jpg')$$,
                   'anon cannot even ask the visibility question');
reset role;

-- The bucket's own caps — 1 MB, image/jpeg only, private — live in
-- storage.buckets and are applied by migration 0015 where the storage schema
-- exists. A plain Postgres has no storage schema, so what is held here is the
-- rule the policies delegate to; the caps themselves are asserted by the
-- deployment runbook (docs/deployment.md).
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice '  ok  no storage schema here — bucket caps are asserted by the deployment runbook';
    return;
  end if;
  -- Referenced dynamically: on a plain Postgres this block must not even parse
  -- a query that names storage.buckets.
  execute $q$select test_assert(
    exists (select 1 from storage.buckets
             where id = 'avatars' and not public
               and file_size_limit = 1048576
               and allowed_mime_types = array['image/jpeg']),
    'where Storage exists, the bucket is private, 1 MB, JPEG-only')$q$;
end
$$;

rollback;
