-- Grant signing keys and the published key set
-- (docs/accountability-architecture.md §10).
--
-- Build order step 5: the key set, rotation, and the signing path, drilled
-- before any grant is issued. No grant exists yet — that is the point. When
-- step 8 lands, the code that signs a grant starts from current_signing_kid()
-- and a key that has already been rotated in anger at least once.
--
-- Two levels of key, and the server holds only one of them:
--
--   Root       Offline. The private half never touches this database, this
--              server, or this repo. Its public half is compiled into the app.
--              It signs key set *documents*, never grants.
--   Grant keys Ed25519 pairs named g1, g2, … The private halves live in the
--              platform secret store (Supabase Vault, `grant_key_<kid>`); this
--              schema stores only public halves and lifecycle state.
--
-- Clients trust a key set document because the root signed it, not because we
-- served it. So the server never manufactures trust here: it assembles the
-- document, hands the exact bytes to an operator to sign offline, and stores
-- document and signature verbatim. Verification is the client's job — a server
-- that "verified" its own key set would prove nothing an attacker with the
-- database could not also fake.

-- Every statement converges on re-run, like everything before it: a migration
-- set that jams halfway is worse than one that can simply be applied again.

-- MARK: - Grant keys

create table if not exists public.grant_signing_key (
  -- The kid appears verbatim inside root-signed documents, inside grants, and
  -- as the Vault secret name `grant_key_<kid>`; keep it too boring to escape.
  kid         text primary key check (kid ~ '^g[0-9]+$'),
  alg         text not null default 'ed25519' check (alg = 'ed25519'),
  -- Raw Ed25519 public key, exactly 32 bytes. Never the private half: a dump
  -- of this table must be worth nothing to the person holding it.
  public_key  bytea not null check (octet_length(public_key) = 32),
  state       text not null default 'next'
              check (state in ('next', 'current', 'retired', 'revoked')),
  -- Grace band for clients with skewed clocks (§10.3). A grant signed by a
  -- kid before its not_before is refused by clients, so promotion refuses to
  -- make a key current before it.
  not_before  timestamptz not null,
  -- Verification cutoff, stamped at retirement. Grants already in ledgers are
  -- unaffected — the ledger holds no signature (§9.2).
  not_after   timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now(),
  check ((state = 'revoked') = (revoked_at is not null))
);

-- One key signs at a time, and one waits its turn. More of either would make
-- "which key is this?" a question with a wrong answer available.
create unique index if not exists grant_signing_key_one_current
  on public.grant_signing_key ((true)) where state = 'current';
create unique index if not exists grant_signing_key_one_next
  on public.grant_signing_key ((true)) where state = 'next';

-- MARK: - Published key sets

-- `document` is the exact byte sequence the root key signed, stored verbatim
-- and served verbatim. Clients verify the signature over the raw bytes and
-- only then parse — so no canonicalisation scheme has to be agreed between
-- Postgres, Deno and Swift, forever, byte for byte.
create table if not exists public.key_set (
  version        int primary key check (version > 0),
  document       text not null,
  root_signature bytea not null check (octet_length(root_signature) = 64),
  issued_at      timestamptz not null,
  published_at   timestamptz not null default now()
);

alter table public.grant_signing_key enable row level security;
alter table public.key_set           enable row level security;
revoke all on public.grant_signing_key from anon, authenticated;
revoke all on public.key_set           from anon, authenticated;
-- No policy at all, not even SELECT (§18): the app has no business reading
-- lifecycle state, and the one thing a client needs — the newest published
-- document — is served by current_key_set() below.

-- MARK: - Lifecycle: introduce → publish → promote → (eventually) revoke

-- A new key enters as `next` and cannot sign anything. It becomes able to
-- sign only after (a) it has appeared in a *published* key set, so every
-- polling client has had the chance to learn it (§10.3), and (b) its
-- not_before has passed.
create or replace function public.introduce_grant_key(
  p_kid        text,
  p_public_key text,                       -- base64, 32 bytes decoded
  p_not_before timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key bytea;
begin
  v_key := decode(replace(replace(p_public_key, chr(10), ''), chr(13), ''), 'base64');

  insert into public.grant_signing_key (kid, public_key, not_before)
       values (p_kid, v_key, p_not_before);

  return jsonb_build_object('kid', p_kid, 'state', 'next',
                            'not_before', p_not_before);
end;
$$;

-- The document an operator signs. Assembled deterministically (UTC, jsonb key
-- ordering) so that building twice against the same state yields the same
-- bytes — but determinism is a convenience, not a load-bearing property:
-- whatever exact bytes the operator signs are the bytes publish_key_set
-- stores and current_key_set serves.
--
-- Keys are listed current-first, then next, then retired; revoked kids move
-- to their own list, which clients treat as a kill list (§10.4).
create or replace function public.build_key_set_document() returns text
language plpgsql stable
security definer
set search_path = public, extensions, pg_temp
set timezone = 'UTC'
as $$
declare
  v_doc jsonb;
begin
  v_doc := jsonb_build_object(
    'version', coalesce((select max(version) from public.key_set), 0) + 1,
    'issued_at', now(),
    'keys', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kid', k.kid, 'alg', k.alg,
               'public', replace(encode(k.public_key, 'base64'), chr(10), ''),
               'not_before', k.not_before, 'not_after', k.not_after,
               'state', k.state)
             order by case k.state when 'current' then 0
                                   when 'next' then 1
                                   else 2 end, k.kid)
        from public.grant_signing_key k
       where k.state <> 'revoked'), '[]'::jsonb),
    'revoked', coalesce((
      select jsonb_agg(jsonb_build_object('kid', k.kid, 'revoked_at', k.revoked_at)
             order by k.kid)
        from public.grant_signing_key k
       where k.state = 'revoked'), '[]'::jsonb));

  return v_doc::text;
end;
$$;

-- Store what the root signed. The server cannot vouch for the signature —
-- clients hold the root public key and do that — but it can refuse a document
-- that lies about the table it claims to describe, which catches an operator
-- signing stale bytes long before a client would.
--
-- Version is strictly monotonic and gap-free. Monotonic is what gives clients
-- rollback resistance (§10.2); gap-free means a skipped number is a mistake
-- surfaced at publish time rather than a mystery in an audit later.
create or replace function public.publish_key_set(
  p_document       text,
  p_root_signature text                    -- base64, 64 bytes decoded
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_doc       jsonb;
  v_version   int;
  v_issued_at timestamptz;
  v_expected  jsonb;
  v_row       public.key_set;
begin
  v_doc := p_document::jsonb;
  v_version := (v_doc ->> 'version')::int;
  v_issued_at := (v_doc ->> 'issued_at')::timestamptz;

  -- The signature travels beside the document, never inside it — a document
  -- that embedded its own signature could not have been what was signed.
  if v_doc ? 'root_signature' then
    raise exception 'the document must not embed root_signature; pass it separately'
      using errcode = '22023';
  end if;

  if v_version is distinct from coalesce((select max(version) from public.key_set), 0) + 1 then
    raise exception 'key set version % is not the next version', v_version
      using errcode = '55000';
  end if;
  if v_issued_at is null or v_issued_at > now() + interval '1 hour' then
    raise exception 'key set issued_at is missing or in the future'
      using errcode = '22007';
  end if;

  -- Same content check the builder would produce now, minus the field that
  -- legitimately differs between build time and publish time.
  v_expected := public.build_key_set_document()::jsonb;
  if (v_doc - 'issued_at') is distinct from (v_expected - 'issued_at') then
    raise exception 'key set document does not match the current key state'
      using errcode = '55000';
  end if;

  insert into public.key_set (version, document, root_signature, issued_at)
       values (v_version, p_document,
               decode(replace(replace(p_root_signature, chr(10), ''), chr(13), ''), 'base64'),
               v_issued_at)
    returning * into v_row;

  return jsonb_build_object('version', v_row.version,
                            'published_at', v_row.published_at);
end;
$$;

-- Promotion is the server-side switch of §10.3, and it is where the rules
-- concentrate: a key nobody was told about must never start signing, because
-- every grant it produced would be refused by every honest client.
create or replace function public.promote_grant_key(
  p_kid               text,
  p_verification_tail interval default interval '30 days'
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key      public.grant_signing_key;
  v_latest   jsonb;
begin
  select * into v_key from public.grant_signing_key where kid = p_kid for update;
  if not found or v_key.state <> 'next' then
    raise exception 'key % is not waiting as next', p_kid using errcode = '55000';
  end if;
  if v_key.not_before > now() then
    raise exception 'key % is not valid until %', p_kid, v_key.not_before
      using errcode = '55000';
  end if;

  select document::jsonb into v_latest
    from public.key_set order by version desc limit 1;
  if v_latest is null
     or not exists (select 1 from jsonb_array_elements(v_latest -> 'keys') k
                     where k ->> 'kid' = p_kid) then
    raise exception 'key % has never appeared in a published key set', p_kid
      using errcode = '55000';
  end if;

  -- The outgoing key keeps verifying for a tail, so grants it signed that are
  -- still in flight (held offline, not yet polled) do not die with it.
  update public.grant_signing_key
     set state = 'retired', not_after = now() + p_verification_tail
   where state = 'current';

  update public.grant_signing_key set state = 'current' where kid = p_kid;

  return jsonb_build_object('kid', p_kid, 'state', 'current');
end;
$$;

-- Compromise path (§10.4). Terminal, from any state: a key believed leaked is
-- never trusted again, and if it was current there is deliberately no current
-- key afterwards — better to be unable to sign than to sign with a key an
-- attacker also holds. Publish the new set and promote the next key; clients
-- reject the revoked kid from the moment they see the set.
create or replace function public.revoke_grant_key(p_kid text) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key public.grant_signing_key;
begin
  select * into v_key from public.grant_signing_key where kid = p_kid for update;
  if not found then
    raise exception 'no such key %', p_kid using errcode = '55000';
  end if;
  if v_key.state = 'revoked' then
    return jsonb_build_object('kid', p_kid, 'state', 'revoked',
                              'revoked_at', v_key.revoked_at);
  end if;

  update public.grant_signing_key
     set state = 'revoked', revoked_at = now(), not_after = coalesce(not_after, now())
   where kid = p_kid;

  return jsonb_build_object('kid', p_kid, 'state', 'revoked', 'revoked_at', now());
end;
$$;

-- MARK: - What the world gets to ask

-- GET /keys, in substance: the newest published document, verbatim, plus its
-- signature. Public by design — everything in it is public keys and
-- lifecycle metadata, and the signature is the only thing that makes it
-- worth trusting anyway.
create or replace function public.current_key_set() returns jsonb
language plpgsql stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row public.key_set;
begin
  select * into v_row from public.key_set order by version desc limit 1;
  if not found then
    raise exception 'no key set has been published' using errcode = '55000';
  end if;
  return jsonb_build_object(
    'version', v_row.version,
    'document', v_row.document,
    'root_signature', replace(encode(v_row.root_signature, 'base64'), chr(10), ''));
end;
$$;

-- The signing path starts here: the edge function that will sign grants asks
-- for the kid, then reads `grant_key_<kid>` from Vault. Raising instead of
-- returning null is deliberate — "there is no key it is safe to sign with"
-- must stop a grant, not produce an unsigned one.
create or replace function public.current_signing_kid() returns text
language plpgsql stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_key    public.grant_signing_key;
  v_latest jsonb;
begin
  select * into v_key from public.grant_signing_key where state = 'current';
  if not found then
    raise exception 'no current grant signing key' using errcode = '55000';
  end if;
  if v_key.not_before > now() then
    raise exception 'current key % is not valid until %', v_key.kid, v_key.not_before
      using errcode = '55000';
  end if;

  -- Belt and braces on top of promotion's own check: if the newest published
  -- set no longer lists this kid as trustworthy, refuse to sign with it.
  select document::jsonb into v_latest
    from public.key_set order by version desc limit 1;
  if v_latest is null
     or not exists (select 1 from jsonb_array_elements(v_latest -> 'keys') k
                     where k ->> 'kid' = v_key.kid) then
    raise exception 'current key % is not in the published key set', v_key.kid
      using errcode = '55000';
  end if;

  return v_key.kid;
end;
$$;

-- MARK: - Who may call what

-- Lifecycle operations are the server operating on itself: service_role only,
-- reached through an operator or an ops edge function, never through the app.
-- The account holder is the adversary of this design; handing any of these to
-- `authenticated` would hand them the trust anchor's supply chain.
revoke all on function public.introduce_grant_key(text, text, timestamptz)
  from public, anon, authenticated;
revoke all on function public.build_key_set_document() from public, anon, authenticated;
revoke all on function public.publish_key_set(text, text) from public, anon, authenticated;
revoke all on function public.promote_grant_key(text, interval)
  from public, anon, authenticated;
revoke all on function public.revoke_grant_key(text) from public, anon, authenticated;
revoke all on function public.current_signing_kid() from public, anon, authenticated;
revoke all on function public.current_key_set() from public;

grant execute on function public.introduce_grant_key(text, text, timestamptz) to service_role;
grant execute on function public.build_key_set_document() to service_role;
grant execute on function public.publish_key_set(text, text) to service_role;
grant execute on function public.promote_grant_key(text, interval) to service_role;
grant execute on function public.revoke_grant_key(text) to service_role;
grant execute on function public.current_signing_kid() to service_role;

-- The key set itself is the one public thing here.
grant execute on function public.current_key_set() to anon, authenticated, service_role;
