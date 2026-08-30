-- Partners, consent, and suppression (docs/accountability-architecture.md §14).
--
-- Milestone A left `partner` as a shape with no behaviour. This gives it one:
-- a contact is normalised, encrypted and blind-indexed by the server; an
-- invitation is sent by the server; and a refusal is honoured globally rather
-- than per-account, because the person refusing is not our user and did not
-- agree to be asked again by someone else next week.
--
-- Appended rather than folded into 0001-0004. Those may already have been
-- applied to a real project, and quietly rewriting an applied migration is how
-- a schema and its history stop matching.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- MARK: - Key custody

-- Supabase Vault in production; a database setting otherwise.
--
-- The GUC fallback exists so this is testable on a plain Postgres. It is NOT
-- adequate for production and is a launch gate: a pepper that lives in the
-- database's own configuration is dumped alongside the rows it is supposed to
-- protect, which defeats the only thing it is for — making a leaked table of
-- phone numbers resistant to offline brute force.
create or replace function private.secret(p_name text) returns text
language plpgsql stable
set search_path = private, public, pg_temp
as $$
declare
  v_value text;
begin
  if to_regclass('vault.decrypted_secrets') is not null then
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
      into v_value using p_name;
    if v_value is not null and v_value <> '' then return v_value; end if;
  end if;

  v_value := current_setting('app.' || p_name, true);
  if v_value is null or v_value = '' then
    raise exception 'secret % is not configured', p_name using errcode = '42501';
  end if;
  return v_value;
end;
$$;

-- MARK: - Normalisation

-- One contact point, one canonical string. Deliberately strict rather than
-- clever: a number that cannot be resolved unambiguously is refused, not
-- guessed at with a country code we inferred (§14.1).
--
-- Deliberately does NOT strip `+tag` suffixes or provider-specific dots.
-- Merging me+1@x into me@x would suppress addresses that belong to different
-- people. The cost is that aliases remain a self-nomination route (§2.2), which
-- is a trade made knowingly in favour of not silently blocking real people.
create or replace function public.normalize_contact(p_channel text, p_raw text)
returns text
language plpgsql immutable
as $$
declare
  v text := btrim(coalesce(p_raw, ''));
begin
  if p_channel = 'email' then
    -- RFC 5321 makes the local part technically case-sensitive; universal
    -- practice is otherwise, and treating Bob@x and bob@x as different people
    -- would let one of them opt out and still be contacted as the other.
    v := lower(v);
    if v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      raise exception 'that does not look like an email address' using errcode = '22023';
    end if;
    return v;

  elsif p_channel = 'sms' then
    if left(v, 1) <> '+' then
      raise exception 'phone numbers must be in international format, starting with +'
        using errcode = '22023';
    end if;
    v := '+' || regexp_replace(v, '[^0-9]', '', 'g');
    if length(v) < 9 or length(v) > 16 then
      raise exception 'that does not look like a phone number in international format'
        using errcode = '22023';
    end if;
    return v;
  end if;

  raise exception 'unknown contact channel %', p_channel using errcode = '22023';
end;
$$;

-- Deterministic, keyed. The unique constraint and the suppression list both
-- turn on this, so it can never be supplied by a caller: a client that could
-- choose its own blind index could choose one that misses a suppression row.
create or replace function private.contact_lookup(p_normalized text) returns bytea
language sql stable
set search_path = private, public, pg_temp
as $$ select hmac(p_normalized, private.secret('contact_pepper'), 'sha256') $$;

create or replace function private.contact_encrypt(p_normalized text) returns bytea
language sql volatile
set search_path = private, public, pg_temp
as $$ select pgp_sym_encrypt(p_normalized, private.secret('contact_key')) $$;

-- MARK: - Partner state

alter table public.partner
  add column if not exists status text not null default 'invited'
    check (status in ('invited', 'active', 'declined', 'revoked'));

comment on column public.partner.status is
  'invited: asked, no answer yet. active: consented, eligible for a roster. '
  'declined: said no (and is globally suppressed). revoked: removed by the account holder.';

-- MARK: - Global suppression

-- Cross-account by design. Someone who declines has refused Earned, not one
-- user of it, and must not be reachable by the next person who types their
-- number in. Holds no plaintext, no ciphertext and no link to the account that
-- triggered it — only enough to recognise the contact and refuse (§14.4).
create table if not exists public.contact_suppression (
  contact_lookup     bytea       not null,
  channel            text        not null check (channel in ('sms', 'email')),
  lookup_key_version int         not null default 1,
  reason             text        not null check (reason in ('optout', 'complaint', 'bounce', 'abuse')),
  suppressed_at      timestamptz not null default now(),
  primary key (contact_lookup, channel)
);

-- MARK: - Invitations

create table if not exists public.partner_invitation (
  id            uuid        primary key default gen_random_uuid(),
  partner_id    uuid        not null references public.partner(id) on delete cascade,
  -- sha256 of a 256-bit token. The token itself is never stored anywhere;
  -- it exists only inside the outbound message.
  token_hash    bytea       not null unique,
  sent_at       timestamptz not null default now(),
  expires_at    timestamptz not null,
  responded_at  timestamptz,
  response      text check (response in ('accepted', 'declined')),
  is_resend     boolean     not null default false
);

create index if not exists partner_invitation_partner_idx
  on public.partner_invitation (partner_id);

-- MARK: - Outbox

-- What the server will send. The requester's device never sees a row of this
-- table, which is the whole point: an approval or consent link that passes
-- through the account holder's phone is a link the account holder has (§2.1).
create table if not exists public.message_outbox (
  id            uuid        primary key default gen_random_uuid(),
  channel       text        not null check (channel in ('sms', 'email')),
  -- Encrypted at rest, exactly like the partner row it was derived from.
  to_ciphertext bytea       not null,
  body          text        not null,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz,
  failed_at     timestamptz,
  failure       text
);

create index if not exists message_outbox_pending_idx
  on public.message_outbox (created_at) where sent_at is null and failed_at is null;
