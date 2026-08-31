\set ON_ERROR_STOP on
\echo 'grant keys: lifecycle, monotonic key sets, and who may touch them'
set time zone 'UTC';

begin;

-- A previous run of keyset_drill.sh leaves its keys behind (it exercises
-- persistence on purpose), and server_grant references them (0011). This
-- transaction rolls back, so clearing the stage here is invisible outside it.
truncate public.server_grant, public.grant_signing_key, public.key_set;

-- The server treats signatures as opaque bytes — verification belongs to
-- clients holding the root public key — so these tests exercise the state
-- machine and the refusals with well-formed junk where a signature goes.
-- The *real* crypto path (openssl-signed documents verified over the exact
-- bytes the database serves back) is keyset_drill.sh.

create or replace function test_b64(p_n int) returns text
language sql volatile
set search_path = public, extensions, pg_temp
as $$
  select replace(encode(gen_random_bytes(p_n), 'base64'), chr(10), '')
$$;

set local role service_role;

-- MARK: introduction

select test_raises(
  $$select public.introduce_grant_key('g1', test_b64(16))$$,
  'a public key that is not 32 bytes is refused');
select test_raises(
  $$select public.introduce_grant_key('key-one', test_b64(32))$$,
  'a kid that does not match g<n> is refused');

select public.introduce_grant_key('g1', test_b64(32));

select test_raises(
  $$select public.promote_grant_key('g1')$$,
  'a key that has never appeared in a published key set cannot be promoted');
select test_raises(
  $$select public.current_signing_kid()$$,
  'before any promotion there is no key it is safe to sign with');

-- MARK: publication is monotonic and truthful

select test_raises(
  $$select public.current_key_set()$$,
  'before any publication there is no key set to serve');

select public.publish_key_set(public.build_key_set_document(), test_b64(64));

select test_assert(
  (public.current_key_set() ->> 'version')::int = 1,
  'the first published key set is version 1');
select test_assert(
  ((public.current_key_set() ->> 'document')::jsonb -> 'keys' -> 0 ->> 'kid') = 'g1',
  'the published document lists the introduced key');

select test_raises(
  $$select public.publish_key_set(
      (select document from public.key_set where version = 1), test_b64(64))$$,
  'republishing an already-published version is refused (monotonic, gap-free)');
select test_raises(
  $$select public.publish_key_set(
      replace(public.build_key_set_document(), '"keys": [', '"keys": [{"kid": "g9"}, '),
      test_b64(64))$$,
  'a document that lies about the key state is refused');
select test_raises(
  $$select public.publish_key_set(
      (public.build_key_set_document()::jsonb
         || jsonb_build_object('root_signature', test_b64(64)))::text,
      test_b64(64))$$,
  'a document that embeds its own signature is refused');

-- MARK: promotion

select public.promote_grant_key('g1');
-- Promotion alone is not enough, and this is the check that says so. The
-- published set still calls g1 `next`, which is all any app has been told, so
-- signing with it would produce grants every correct client refuses (0012).
select test_raises(
  $$select public.current_signing_kid()$$,
  'a promoted key whose promotion was never published still cannot sign');

select public.publish_key_set(public.build_key_set_document(), test_b64(64));
select test_assert(public.current_signing_kid() = 'g1',
                   'after publication, promotion and publication again, g1 signs');

-- MARK: rotation

select public.introduce_grant_key('g2', test_b64(32));
select test_raises(
  $$select public.introduce_grant_key('g3', test_b64(32))$$,
  'only one key waits as next at a time');
select test_raises(
  $$select public.promote_grant_key('g2')$$,
  'a next key cannot be promoted until a key set carrying it has been published');

select public.publish_key_set(public.build_key_set_document(), test_b64(64));
select public.promote_grant_key('g2');
select public.publish_key_set(public.build_key_set_document(), test_b64(64));

select test_assert(public.current_signing_kid() = 'g2', 'g2 signs after promotion');
select test_assert(
  (select state = 'retired' and not_after is not null
     from public.grant_signing_key where kid = 'g1'),
  'the outgoing key is retired with a verification cutoff, not deleted');

-- MARK: compromise

select public.revoke_grant_key('g2');
select test_raises(
  $$select public.current_signing_kid()$$,
  'revoking the current key stops signing rather than signing with a leaked key');

select public.publish_key_set(public.build_key_set_document(), test_b64(64));
select test_assert(
  exists (select 1
            from jsonb_array_elements(
                   (public.current_key_set() ->> 'document')::jsonb -> 'revoked') r
           where r ->> 'kid' = 'g2'),
  'the next published set names the revoked kid in its kill list');
select test_assert(
  not exists (select 1
                from jsonb_array_elements(
                       (public.current_key_set() ->> 'document')::jsonb -> 'keys') k
               where k ->> 'kid' = 'g2'),
  'and no longer lists it among the trusted keys');
select test_raises(
  $$select public.promote_grant_key('g2')$$,
  'a revoked key can never come back');

-- MARK: clock skew grace band

select public.introduce_grant_key('g4', test_b64(32), now() + interval '1 day');
select public.publish_key_set(public.build_key_set_document(), test_b64(64));
select test_raises(
  $$select public.promote_grant_key('g4')$$,
  'a key cannot be promoted before its not_before');

reset role;

-- MARK: who may touch what

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select public.introduce_grant_key('g5', test_b64(32))$$,
                   'a signed-in account cannot introduce a key');
select test_raises($$select public.promote_grant_key('g4')$$,
                   'a signed-in account cannot promote a key');
select test_raises($$select public.revoke_grant_key('g4')$$,
                   'a signed-in account cannot revoke a key');
select test_raises($$select public.publish_key_set('{}', 'x')$$,
                   'a signed-in account cannot publish a key set');
select test_raises($$select public.build_key_set_document()$$,
                   'a signed-in account cannot even assemble one');
select test_raises($$select public.current_signing_kid()$$,
                   'a signed-in account cannot ask which key signs');
select test_raises($$select count(*) from public.grant_signing_key$$,
                   'a signed-in account cannot read key lifecycle state');
select test_raises($$select count(*) from public.key_set$$,
                   'a signed-in account cannot read the key set table directly');
select test_assert((public.current_key_set() ->> 'version')::int = 6,
                   'but the published key set itself is served to it');
reset role;

set local role anon;
select test_sign_out();
select test_raises($$select count(*) from public.grant_signing_key$$,
                   'anon cannot read key lifecycle state');
select test_raises($$select count(*) from public.key_set$$,
                   'anon cannot read the key set table directly');
select test_assert((public.current_key_set() ->> 'version')::int = 6,
                   'the published key set is public — anon may fetch it');
reset role;

rollback;
