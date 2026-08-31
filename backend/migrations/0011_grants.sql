-- Grants: what the server signs, and what the app is allowed to believe
-- (docs/accountability-architecture.md §§9, 10).
--
-- Build order step 8, server half. The app half — verifying the signature
-- against the key set and recording the semantic fact in the ledger — is
-- separate, and deliberately so: §9.2 is emphatic that the signature must
-- never enter the ledger, and that boundary is easier to hold when the two
-- sides are written apart.
--
-- **Postgres cannot sign this.** pgcrypto has no Ed25519, so the signature is
-- produced by the `grants` edge function, and that is why a grant exists in
-- two phases: this schema builds and freezes the exact bytes to be signed, and
-- the function attaches a signature to them. A half-made grant is a row with
-- no signature, which is served to nobody.
--
-- **Where that key lives supersedes 0008.** Its comments say Vault, written
-- when no signer existed yet; the function reads the key from its own
-- environment instead. 0008 is left exactly as applied — migrations are
-- appended, never rewritten — so the decision is recorded here. The reason:
-- contact keys are in Vault because they protect data that is in the database
-- anyway, whereas the grant signing key protects *against* the database. It is
-- the one secret whose loss lets someone mint permission a user never earned,
-- so a total database compromise — every table, every Vault row, the service
-- role itself — must still not be able to sign a grant.
--
-- The document is signed and stored **verbatim**, exactly as key sets are in
-- 0008, and for exactly the same reason: the app verifies over the bytes it
-- was served and only then parses, so no canonicalisation scheme has to be
-- agreed between Postgres, Deno and Swift and kept agreed forever. §9.1 draws
-- the grant as a payload with a `signature` field beside it; a field inside
-- the object it signs cannot be part of what was signed, so the signature
-- travels alongside the document instead.

-- Every statement converges on re-run, like everything before it.

create table if not exists public.server_grant (
  id           uuid        primary key default gen_random_uuid(),
  -- One grant per request, forever. §9.4's idempotency is this constraint:
  -- repeated polls re-serve this row rather than minting a second decision.
  request_id   uuid        not null unique
                 references public.override_request(id) on delete cascade,
  -- The exact bytes that were signed, and the exact bytes that are served.
  document     text        not null,
  -- Null until the edge function has signed. A grant is not a grant yet.
  signature    bytea       check (signature is null or octet_length(signature) = 64),
  -- Which key signed it, fixed when the document was built so that the bytes
  -- and the key can never disagree about each other.
  signing_kid  text        not null references public.grant_signing_key(kid),
  decided_at   timestamptz not null,
  created_at   timestamptz not null default now(),
  signed_at    timestamptz,
  check ((signature is null) = (signed_at is null))
);

create index if not exists server_grant_unsigned_idx
  on public.server_grant (created_at) where signature is null;

alter table public.server_grant enable row level security;
revoke all on public.server_grant from anon, authenticated;
-- No policy (§18). The app reads grants through my_grants() below, which
-- serves only signed ones and only the caller's own.

-- MARK: - The document

-- Assembled from what the server knows, never from anything a client sent.
-- The roster is the votes actually cast before resolution, which is the roster
-- the partners were told about and the one a human can reason about (§6.2).
--
-- jsonb sorts its keys, so ::text is deterministic for the same content —
-- convenient, but not load-bearing: whatever bytes this returns are the bytes
-- that get signed and stored, so determinism is a nicety rather than a
-- protocol both ends must reproduce.
create or replace function private.grant_document(
  p_grant_id   uuid,
  p_request_id uuid,
  p_kid        text
) returns text
language plpgsql stable
set search_path = private, public, extensions, pg_temp
set timezone = 'UTC'
as $$
declare
  v_req public.override_request;
  v_env public.contract_envelope;
begin
  select * into v_req from public.override_request where id = p_request_id;
  select * into v_env from public.contract_envelope
   where account_id = v_req.account_id and commitment_id = v_req.commitment_id;

  return (jsonb_build_object(
    'server_grant_id',   p_grant_id,
    'client_request_id', v_req.client_request_id,
    'decision',          'granted',
    'decided_at',        v_req.resolved_at,
    -- Ties the grant to the contract it was granted against. An app holding
    -- an envelope whose digest differs is looking at a different contract
    -- than the one the partners approved.
    'policy_digest',     'sha256:' || encode(v_env.policy_digest, 'hex'),
    'kid',               p_kid,
    'roster',            coalesce((
      select jsonb_agg(jsonb_build_object(
               'partner_display_name', p.display_name,
               'vote',                 rc.vote,
               'at',                   rc.voted_at)
             order by rc.voted_at, p.display_name)
        from public.override_request_recipient rc
        join public.partner p on p.id = rc.partner_id
       where rc.request_id = p_request_id and rc.vote is not null), '[]'::jsonb)
  ))::text;
end;
$$;

-- MARK: - What the app asks for

-- The app's `GET /grants`, in substance, reached through the edge function
-- that signs. Volatile because it does more than read: a resolved request
-- with no grant row gets one here, unsigned.
--
-- Minting that row is not a privilege the caller gains — every field in it is
-- derived from state the server already holds, and the one thing that makes
-- it usable, the signature, is added by a role the caller does not have. The
-- alternative was signing inside the vote transaction, which Postgres cannot
-- do, or a sweeper, which would put a grant behind a schedule when a user is
-- sitting there locked out.
create or replace function public.my_grants() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_req     record;
  v_kid     text;
  v_grant   public.server_grant;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  for v_req in
    select r.id, r.commitment_id
      from public.override_request r
     where r.account_id = v_account
       and r.state = 'granted'
       and not exists (select 1 from public.server_grant g where g.request_id = r.id)
  loop
    -- No current key means no grant, and saying so is better than inventing
    -- one: current_signing_kid() raises rather than guessing (0008).
    v_kid := public.current_signing_kid();
    insert into public.server_grant (request_id, document, signing_kid, decided_at)
         values (v_req.id, '', v_kid,
                 (select resolved_at from public.override_request where id = v_req.id))
      returning * into v_grant;
    -- Written second because the document names its own grant id.
    update public.server_grant
       set document = private.grant_document(v_grant.id, v_req.id, v_kid)
     where id = v_grant.id;
  end loop;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'commitment_id', r.commitment_id,
             'document',      g.document,
             'signature',     replace(encode(g.signature, 'base64'), chr(10), ''),
             'kid',           g.signing_kid)
           order by g.created_at)
      from public.server_grant g
      join public.override_request r on r.id = g.request_id
     where r.account_id = v_account and g.signature is not null), '[]'::jsonb);
end;
$$;

-- MARK: - Signing, which happens elsewhere

-- Named for the edge function that calls it: hand me the unsigned documents,
-- and I will take the signatures back.
create or replace function public.unsigned_grants() returns jsonb
language plpgsql stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'kid', g.signing_kid,
                                        'document', g.document)
           order by g.created_at)
      from public.server_grant g
     where g.signature is null and g.document <> ''), '[]'::jsonb);
end;
$$;

-- Attaching a signature is the one irreversible step, so it refuses to happen
-- twice: a grant that is already signed keeps the signature it has. Re-signing
-- would let a later key silently replace what an app may already have
-- verified and recorded.
create or replace function public.store_override_grant(
  p_grant_id  uuid,
  p_signature text
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_grant public.server_grant;
begin
  select * into v_grant from public.server_grant where id = p_grant_id for update;
  if v_grant.id is null then
    raise exception 'no such grant %', p_grant_id using errcode = '42704';
  end if;
  if v_grant.signature is not null then
    return jsonb_build_object('id', v_grant.id, 'signed', false,
                              'reason', 'already signed');
  end if;

  update public.server_grant
     set signature = decode(replace(replace(p_signature, chr(10), ''), chr(13), ''), 'base64'),
         signed_at = now()
   where id = p_grant_id;

  insert into public.override_request_event (request_id, kind, detail)
       values (v_grant.request_id, 'granted',
               jsonb_build_object('server_grant_id', v_grant.id,
                                  'kid', v_grant.signing_kid));

  return jsonb_build_object('id', v_grant.id, 'signed', true);
end;
$$;

-- MARK: - Who may call what

revoke all on function private.grant_document(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.my_grants() from public, anon;
revoke all on function public.unsigned_grants() from public, anon, authenticated;
revoke all on function public.store_override_grant(uuid, text)
  from public, anon, authenticated;

-- The account holder may ask for its own grants, and gets only signed ones.
grant execute on function public.my_grants() to authenticated;

-- Signing is the server acting on itself, with a key the account holder has
-- no path to. This is the line the whole design exists to draw: a client that
-- could reach these could mint its own permission.
grant execute on function public.unsigned_grants() to service_role;
grant execute on function public.store_override_grant(uuid, text) to service_role;
