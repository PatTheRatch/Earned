\set ON_ERROR_STOP on
\echo 'presence and delivery: the name a person is called, and push that arrives once'
set time zone 'UTC';

begin;

delete from public.override_request;
delete from public.account;
delete from public.push_outbox;
delete from public.push_device;

-- MARK: - A name that survives signing in again

-- Apple sends a display name exactly once, on the first authorization. Every
-- later sign-in — a second device, a reinstall — returns nothing. The account
-- upsert used to write that nothing straight over the name the user had
-- chosen, and two real people watched each other turn into "Someone".
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patravious', 'Patrick McDowell');

select test_assert(
  (select display_name = 'Patrick McDowell' from public.account
    where apple_user_id = 'apple-sub-patrick'),
  'profile setup is what names an account');

select public.ensure_account('apple-sub-patrick', '');
select test_assert(
  (select display_name = 'Patrick McDowell' from public.account
    where apple_user_id = 'apple-sub-patrick'),
  'signing in on a second device, where Apple says nothing, does not erase it');

select public.ensure_account('apple-sub-patrick', '   ');
select test_assert(
  (select display_name = 'Patrick McDowell' from public.account
    where apple_user_id = 'apple-sub-patrick'),
  'and neither does whitespace');

-- A real name may still replace one: this is an update, not a freeze.
select public.ensure_account('apple-sub-patrick', 'Patrick M');
select test_assert(
  (select display_name = 'Patrick M' from public.account
    where apple_user_id = 'apple-sub-patrick'),
  'a name that is actually a name still updates it');
select public.upsert_my_profile('patravious', 'Patrick McDowell');

-- MARK: - What an unnamed account is called

-- Empty means unknown, and unknown falls back to the handle: recognisable,
-- deterministic, and different for every person — which is the entire failure
-- of "Someone", a string that renders identically for everybody.
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', '');
select test_assert(
  (select private.social_name(id) = 'Earned user' from public.account
    where apple_user_id = 'apple-sub-maya'),
  'no name and no handle is the only case with nothing to say');
select public.upsert_my_profile('maya', 'Maya');
select test_assert(
  (select private.social_name(id) = 'Maya' from public.account
    where apple_user_id = 'apple-sub-maya'),
  'a named account is called its name');

-- Forced back to unknown to prove the handle path, which is what a person who
-- never completed a name would actually be shown as.
update public.account set display_name = ''
 where apple_user_id = 'apple-sub-maya';
select test_assert(
  (select private.social_name(id) = '@maya' from public.account
    where apple_user_id = 'apple-sub-maya'),
  'an unnamed account with a handle is called its handle, never "Someone"');
select test_assert(
  (select private.social_name(id) <> 'Someone' from public.account
    where apple_user_id = 'apple-sub-maya'),
  'and never that word in particular');
update public.account set display_name = 'Maya'
 where apple_user_id = 'apple-sub-maya';

-- MARK: - Device tokens are the backend's alone

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.register_push_token('token-patrick-aaaaaaaaaaaaaaaa');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.register_push_token('token-maya-bbbbbbbbbbbbbbbbbb');

set local role authenticated;
select test_sign_in('22222222-2222-2222-2222-222222222222');
-- Refused outright rather than filtered to nothing: the grant is revoked, so
-- there is no policy to get wrong later.
select test_raises($$ select count(*) from public.push_device $$,
                   'a signed-in user cannot read the device token table at all');
select test_raises($$ select count(*) from public.push_outbox $$,
                   'nor the queue of asks');
select test_raises($$ select public.claim_push_batch(10) $$,
                   'nor claim a batch — that would be reading everyone tokens');
select test_raises($$ select public.forget_push_token('token-patrick-aaaaaaaaaaaaaaaa') $$,
                   'nor delete somebody else device');
reset role;

-- Re-registering a token moves it to whoever signed in on that phone, rather
-- than leaving a stranger's notifications pointed at it.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.register_push_token('token-maya-bbbbbbbbbbbbbbbbbb');
select test_assert(
  (select d.account_id = (select id from public.account
                           where apple_user_id = 'apple-sub-patrick')
     from public.push_device d where d.token = 'token-maya-bbbbbbbbbbbbbbbbbb'),
  'a token re-registered after a new sign-in follows the new owner');

-- MARK: - One ask, one buzz

-- The cast needs a friendship before anyone can be invited to anything.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patravious', true);

delete from public.push_outbox;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         'aaaaaaaa-0000-0000-0000-0000000000a1', 'Run 3 times this week',
         'running', 'sessions', 3,
         now() - interval '1 hour', now() + interval '6 days',
         array['maya']);

select test_assert((select count(*) = 1 from public.push_outbox), 'one ask, one row');
select test_assert(
  (select title like 'Patrick McDowell invited you%' from public.push_outbox),
  'the title carries the person, because a lock screen shows the title');
select test_assert((select route_id is not null from public.push_outbox),
                   'and the row it routes to, so the tap lands somewhere');

-- Claiming is what makes a retry safe: handed out once, not once per attempt.
select test_assert(
  (select jsonb_array_length(public.claim_push_batch(10)) = 1),
  'the sender claims the unsent ask');
select test_assert(
  (select jsonb_array_length(public.claim_push_batch(10)) = 0),
  'and a second sender running at the same time claims nothing — no double buzz');

select test_assert(
  (select (public.claim_push_batch(10, interval '0 seconds') -> 0 -> 'tokens')
            @> '["token-maya-bbbbbbbbbbbbbbbbbb"]'::jsonb) is not true,
  'a claim carries only the recipient device tokens');

select public.complete_push((select id from public.push_outbox));
select test_assert((select sent_at is not null from public.push_outbox),
                   'a delivered ask is finished');
select test_assert(
  (select jsonb_array_length(public.claim_push_batch(10, interval '0 seconds')) = 0),
  'and is never claimed again, however long the sender runs');

-- A failure leaves it claimable, so a crashed sender loses nothing.
delete from public.push_outbox;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.create_shared_commitment(
         'aaaaaaaa-0000-0000-0000-0000000000a2', 'Lift twice',
         'strength', 'sessions', 2,
         now() - interval '1 hour', now() + interval '6 days',
         array['maya']);
select public.claim_push_batch(10);
select public.complete_push((select id from public.push_outbox), 'APNs said no');
select test_assert(
  (select jsonb_array_length(public.claim_push_batch(10)) = 1),
  'a failed send is retried');
select test_assert((select attempts = 2 from public.push_outbox),
                   'and the attempt is counted, so it cannot retry forever');

-- MARK: - A block stops the phone buzzing, not just the reads

delete from public.push_outbox;
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.block_user('patravious');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$
  select public.create_shared_commitment(
           'aaaaaaaa-0000-0000-0000-0000000000a3', 'Blocked run',
           'running', 'sessions', 1,
           now() - interval '1 hour', now() + interval '6 days',
           array['maya']) $$,
  'a blocked person cannot even be named as an invitee');
select test_assert((select count(*) = 0 from public.push_outbox),
                   'and nothing was queued to their phone on the way to that refusal');

-- MARK: - Dead tokens, and asks nobody needs any more

select public.forget_push_token('token-patrick-aaaaaaaaaaaaaaaa');
select test_assert(
  (select count(*) = 0 from public.push_device
    where token = 'token-patrick-aaaaaaaaaaaaaaaa'),
  'a token APNs reports as gone is forgotten');

delete from public.push_outbox;
insert into public.push_outbox (account_id, kind, title, body, created_at)
     values ((select id from public.account where apple_user_id = 'apple-sub-maya'),
             'partner_request', 'Old', 'Old', now() - interval '30 days');
select test_assert(public.purge_push_outbox() = 1,
                   'a week-old ask is retired rather than delivered late');

rollback;
