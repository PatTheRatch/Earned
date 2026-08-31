-- Milestone S1: the Earned profile (docs/social-architecture.md §4).
--
-- Identity for the social layer, and nothing else. The enforcement path never
-- reads this table, and this table never reaches into the accountability
-- tables — a friend is not an accountability partner (NORTHSTAR invariant 24),
-- and the schema is where that stops being a slogan.
--
-- One deliberate absence: a display-name column. `account.display_name` is
-- canonical and stays so — accountability pages already render it, and a
-- second independently mutable name would be a split-brain identity waiting
-- to happen. Profile reads join the name in; the profile edit writes it there.

create table if not exists public.profile (
  -- One profile per account, and the account id is the key rather than a new
  -- id: a profile is not a thing that exists apart from its account. Never
  -- exposed to other users — handles are the only discovery mechanism.
  account_id   uuid primary key references public.account(id) on delete cascade,
  -- Stored lowercased; uniqueness is therefore plainly unique, and
  -- case-insensitivity is a property of normalisation, not of a special index.
  handle       text not null unique
                 check (handle ~ '^[a-z0-9_]{3,20}$'),
  -- The current avatar object in the `avatars` bucket, or null. The path, not
  -- the image: visibility is decided at read time (0015), so pointing at a
  -- new object is what revokes the old one.
  avatar_path  text
                 check (avatar_path is null or
                        avatar_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'),
  -- Coarse, user-typed, optional. "London", not a coordinate. Shown to
  -- accepted friends only.
  city         text
                 check (city is null or length(btrim(city)) between 1 and 64),
  -- Private system information for deadline/social presentation. Captured
  -- from the device, never shown to anyone, and validated only loosely — an
  -- IANA identifier is what the client sends, but the server has no business
  -- carrying the tz database to police it.
  timezone     text
                 check (timezone is null or length(timezone) between 1 and 64),
  -- Search only. A profile that opts out is findable by nobody, which is
  -- deliberately indistinguishable from not existing.
  discoverable boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- MARK: - Handles

-- What a user typed, made canonical: trimmed, a leading @ dropped, lowercased.
-- Validation happens against the result, so "@Patrick" and "patrick" are the
-- same handle rather than two.
create or replace function public.normalize_handle(p_raw text) returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select lower(ltrim(btrim(coalesce(p_raw, '')), '@'))
$$;

-- Names Earned keeps for itself. A function rather than a table so the list
-- can grow in a migration without a schema change, and so the check lives in
-- exactly one place.
create or replace function public.handle_is_reserved(p_handle text) returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select p_handle in (
    'earned', 'admin', 'administrator', 'root', 'support', 'help', 'staff',
    'team', 'official', 'moderator', 'mod', 'security', 'api', 'www', 'app',
    'apple', 'system', 'null', 'undefined', 'everyone', 'nobody', 'me', 'you',
    'settings', 'about', 'privacy', 'terms', 'friend', 'friends', 'profile'
  )
$$;

-- MARK: - Reading and writing your own profile

-- Create or update the caller's profile. The one write path.
--
-- Display name is accepted here for the setup flow's convenience, and written
-- to `account.display_name` — the same row `ensure_account` maintains and the
-- partner page reads. There is one name.
create or replace function public.upsert_my_profile(
  p_handle       text,
  p_display_name text,
  p_city         text default null,
  p_timezone     text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_handle  text;
  v_city    text;
  v_row     public.profile;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  v_handle := public.normalize_handle(p_handle);
  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'a handle is 3-20 characters: letters, numbers, underscore'
      using errcode = '22023';
  end if;
  if public.handle_is_reserved(v_handle) then
    raise exception 'that handle is reserved' using errcode = '22023';
  end if;

  if length(btrim(coalesce(p_display_name, ''))) not between 1 and 64 then
    raise exception 'a profile needs a name' using errcode = '22023';
  end if;

  v_city := nullif(btrim(coalesce(p_city, '')), '');

  update public.account
     set display_name = btrim(p_display_name)
   where id = v_account;

  insert into public.profile (account_id, handle, city, timezone)
       values (v_account, v_handle, v_city, p_timezone)
  on conflict (account_id) do update
          set handle     = excluded.handle,
              city       = excluded.city,
              timezone   = excluded.timezone,
              updated_at = now()
    returning * into v_row;

  return public.my_profile();
exception
  when unique_violation then
    -- The handle column is the only other unique constraint reachable here.
    raise exception 'that handle is taken' using errcode = '23505';
end;
$$;

-- The caller's own profile, or null when setup has not happened. This is the
-- profile-completion check: a row cannot exist without a valid handle.
create or replace function public.my_profile() returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_result  jsonb;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  select jsonb_build_object(
           'handle',       p.handle,
           'display_name', a.display_name,
           'avatar_path',  p.avatar_path,
           'city',         p.city,
           'timezone',     p.timezone,
           'discoverable', p.discoverable)
    into v_result
    from public.profile p
    join public.account a on a.id = p.account_id
   where p.account_id = v_account;

  return v_result;  -- null when there is no profile yet, which is the answer
end;
$$;

create or replace function public.set_my_discoverability(p_discoverable boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account uuid;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  update public.profile set discoverable = p_discoverable, updated_at = now()
   where account_id = v_account;
  if not found then
    raise exception 'no profile yet' using errcode = '22023';
  end if;
end;
$$;

-- MARK: - RLS

-- Same posture as everything else: default deny, SELECT your own row, no
-- client write permission anywhere. Cross-account reads (search, a friend's
-- profile) deliberately do NOT get a policy — they go through functions in
-- 0014, so what a stranger sees is decided in one reviewed place per query
-- rather than by policy arithmetic.
alter table public.profile enable row level security;
revoke all on public.profile from anon, authenticated;
grant select on public.profile to authenticated;

drop policy if exists profile_select_own on public.profile;
create policy profile_select_own on public.profile
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = profile.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

revoke all on function public.upsert_my_profile(text, text, text, text) from public, anon;
revoke all on function public.my_profile() from public, anon;
revoke all on function public.set_my_discoverability(boolean) from public, anon;
-- The normaliser and the reserved list are harmless and useful to any caller;
-- they leak nothing.

grant execute on function public.upsert_my_profile(text, text, text, text) to authenticated;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.set_my_discoverability(boolean) to authenticated;
