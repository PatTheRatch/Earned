-- Milestone S1: friendships (docs/social-architecture.md §5).
--
-- One row per pair of accounts, ever. The pair is stored ordered and unique,
-- so "two independent friend records" is structurally impossible, and the
-- direction of the ask lives in an explicit `requester` column instead of in
-- row duplication.
--
-- This table is not the `partner` table and never feeds it. A friendship
-- grants no authority over anyone's contract (NORTHSTAR invariant 24); nothing
-- on the enforcement path reads what is created here.

create table if not exists public.friendship (
  id              uuid primary key default gen_random_uuid(),
  account_low     uuid not null references public.account(id) on delete cascade,
  account_high    uuid not null references public.account(id) on delete cascade,
  -- Who asked. One of the pair, always meaningful for pending/declined, and
  -- merely historical once accepted or blocked.
  requester       uuid not null,
  status          text not null default 'pending'
                    check (status in ('pending', 'accepted', 'declined', 'blocked')),
  -- Blocks are per-member flags, not a single blocked_by: if both members
  -- block and one later unblocks, the other's block must still stand. The
  -- status is 'blocked' exactly while either flag is set.
  blocked_by_low  boolean not null default false,
  blocked_by_high boolean not null default false,
  created_at      timestamptz not null default now(),
  responded_at    timestamptz,
  check (account_low < account_high),
  check (requester in (account_low, account_high)),
  check ((status = 'blocked') = (blocked_by_low or blocked_by_high)),
  unique (account_low, account_high)
);

create index if not exists friendship_low_idx  on public.friendship (account_low);
create index if not exists friendship_high_idx on public.friendship (account_high);

-- MARK: - Internals

-- The caller's account id, with a profile required: social actions are taken
-- by an identity, and an account that skipped setup has none yet.
create or replace function private.social_caller() returns uuid
language plpgsql stable
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
begin
  select a.id into v_account
    from public.account a
    join public.profile p on p.account_id = a.id
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no profile for caller — set one up first' using errcode = '28000';
  end if;
  return v_account;
end;
$$;

create or replace function private.friendship_between(p_a uuid, p_b uuid)
returns public.friendship
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select f.* from public.friendship f
   where f.account_low = least(p_a, p_b) and f.account_high = greatest(p_a, p_b)
$$;

create or replace function private.blocked_between(p_a uuid, p_b uuid) returns boolean
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select coalesce((select f.status = 'blocked'
                     from public.friendship f
                    where f.account_low = least(p_a, p_b)
                      and f.account_high = greatest(p_a, p_b)), false)
$$;

create or replace function private.account_for_handle(p_handle text) returns uuid
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select p.account_id from public.profile p
    join public.account a on a.id = p.account_id and a.deleted_at is null
   where p.handle = public.normalize_handle(p_handle)
$$;

create or replace function private.max_friend_requests_per_day() returns int
language sql immutable as $$ select 20 $$;

-- MARK: - Asking, answering, leaving

-- Ask by handle — never by account id, so the id namespace stays unenumerable.
--
-- Deliberately quiet in three cases, all returning the same shapeless
-- success: the target has blocked the caller, the target is undiscoverable to
-- strangers, or the target does not exist at all. A distinguishable refusal
-- in any of them would announce the very state it exists to hide.
create or replace function public.send_friend_request(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
  v_recent int;
begin
  if v_target is null then
    return;  -- no such profile; indistinguishable from the quiet cases below
  end if;
  if v_target = v_caller then
    raise exception 'you cannot befriend yourself' using errcode = '22023';
  end if;

  v_row := private.friendship_between(v_caller, v_target);

  if v_row.id is not null and v_row.status = 'blocked' then
    if (v_caller = v_row.account_low and v_row.blocked_by_low)
       or (v_caller = v_row.account_high and v_row.blocked_by_high) then
      -- The caller is a blocker and knows it; being plain costs nothing.
      raise exception 'you have blocked this user' using errcode = '22023';
    end if;
    return;  -- they blocked the caller: silently dropped
  end if;

  if v_row.id is null
     and not exists (select 1 from public.profile p
                      where p.account_id = v_target and p.discoverable) then
    return;  -- undiscoverable to strangers: silently dropped
  end if;

  if v_row.id is null or v_row.status = 'declined' then
    select count(*) into v_recent from public.friendship f
     where f.requester = v_caller and f.created_at > now() - interval '1 day';
    if v_recent >= private.max_friend_requests_per_day() then
      raise exception 'too many friend requests today — try again tomorrow'
        using errcode = '54000';
    end if;
  end if;

  if v_row.id is null then
    insert into public.friendship (account_low, account_high, requester)
         values (least(v_caller, v_target), greatest(v_caller, v_target), v_caller);
    return;
  end if;

  case v_row.status
    when 'accepted' then
      return;  -- already friends; idempotent
    when 'pending' then
      if v_row.requester = v_caller then
        return;  -- asked already; idempotent, no duplicate, no re-notification
      end if;
      -- Crossed requests: they asked first, and asking back is an answer.
      update public.friendship
         set status = 'accepted', responded_at = now()
       where id = v_row.id and status = 'pending';
    when 'declined' then
      -- A fresh ask reopens the same row; created_at moves so the rate limit
      -- sees it, and the requester may have changed sides.
      update public.friendship
         set status = 'pending', requester = v_caller,
             created_at = now(), responded_at = null
       where id = v_row.id and status = 'declined';
  end case;
end;
$$;

-- Accept or decline an incoming request. Only the member who was asked can
-- answer; the requester answering their own ask is refused, not ignored,
-- because it is a client bug worth hearing about.
create or replace function public.respond_to_friend_request(p_handle text, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_other  uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
begin
  if v_other is null then
    raise exception 'no such request' using errcode = '22023';
  end if;
  v_row := private.friendship_between(v_caller, v_other);
  if v_row.id is null or v_row.status <> 'pending' or v_row.requester = v_caller then
    raise exception 'no such request' using errcode = '22023';
  end if;

  update public.friendship
     set status = case when p_accept then 'accepted' else 'declined' end,
         responded_at = now()
   where id = v_row.id and status = 'pending';
end;
$$;

-- Withdraw an unanswered ask. Leaves nothing behind.
create or replace function public.cancel_friend_request(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_other  uuid := private.account_for_handle(p_handle);
begin
  delete from public.friendship f
   where f.account_low = least(v_caller, v_other)
     and f.account_high = greatest(v_caller, v_other)
     and f.status = 'pending' and f.requester = v_caller;
end;
$$;

-- Either member may end a friendship. All friend-gated visibility ends with
-- the row.
create or replace function public.remove_friend(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_other  uuid := private.account_for_handle(p_handle);
begin
  delete from public.friendship f
   where f.account_low = least(v_caller, v_other)
     and f.account_high = greatest(v_caller, v_other)
     and f.status = 'accepted';
end;
$$;

-- MARK: - Blocking

-- Overwrites whatever stood, including an accepted friendship. From this
-- moment the pair are invisible to each other: search, profile lookup,
-- avatars, and future requests (silently dropped) all go through checks that
-- consult this row.
create or replace function public.block_user(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
begin
  if v_target is null then
    return;  -- nothing to block; quiet for the same reason requests are
  end if;
  if v_target = v_caller then
    raise exception 'you cannot block yourself' using errcode = '22023';
  end if;

  v_row := private.friendship_between(v_caller, v_target);
  if v_row.id is null then
    insert into public.friendship (account_low, account_high, requester, status,
                                   blocked_by_low, blocked_by_high, responded_at)
         values (least(v_caller, v_target), greatest(v_caller, v_target), v_caller,
                 'blocked',
                 v_caller < v_target, v_caller > v_target, now());
  else
    update public.friendship
       set status = 'blocked',
           blocked_by_low  = blocked_by_low  or (v_caller = account_low),
           blocked_by_high = blocked_by_high or (v_caller = account_high),
           responded_at = now()
     where id = v_row.id;
  end if;
end;
$$;

-- Clears the caller's own flag only. If the other member also blocked, the
-- row stays blocked on their say-so; if nobody is left blocking, the pair
-- return to strangers.
create or replace function public.unblock_user(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
begin
  v_row := private.friendship_between(v_caller, v_target);
  if v_row.id is null or v_row.status <> 'blocked' then
    return;
  end if;
  if not ((v_caller = v_row.account_low and v_row.blocked_by_low)
          or (v_caller = v_row.account_high and v_row.blocked_by_high)) then
    return;  -- not the caller's block to lift
  end if;

  if (v_caller = v_row.account_low and v_row.blocked_by_high)
     or (v_caller = v_row.account_high and v_row.blocked_by_low) then
    -- The other member blocks too; only the caller's flag lifts, and the
    -- status stays blocked on their say-so.
    update public.friendship
       set blocked_by_low  = blocked_by_low  and (v_caller <> account_low),
           blocked_by_high = blocked_by_high and (v_caller <> account_high)
     where id = v_row.id;
  else
    -- The caller was the only one blocking: back to strangers.
    delete from public.friendship where id = v_row.id;
  end if;
end;
$$;

-- MARK: - Reading

-- Accepted friends, with what a friend may see: handle, name, avatar, city.
create or replace function public.my_friends() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'handle',       p.handle,
             'display_name', a.display_name,
             'avatar_path',  p.avatar_path,
             'city',         p.city)
           order by p.handle)
      from public.friendship f
      join public.profile p
        on p.account_id = case when f.account_low = v_caller
                               then f.account_high else f.account_low end
      join public.account a on a.id = p.account_id and a.deleted_at is null
     where v_caller in (f.account_low, f.account_high)
       and f.status = 'accepted'), '[]'::jsonb);
end;
$$;

-- Pending requests, both directions. Incoming carries who is asking; outgoing
-- carries who was asked. Declined requests appear in neither: the requester
-- is never told "declined", their ask simply stops being listed.
create or replace function public.my_friend_requests() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  return jsonb_build_object(
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object(
               'handle',       p.handle,
               'display_name', a.display_name,
               'avatar_path',  p.avatar_path)
             order by f.created_at desc)
        from public.friendship f
        join public.profile p on p.account_id = f.requester
        join public.account a on a.id = p.account_id and a.deleted_at is null
       where v_caller in (f.account_low, f.account_high)
         and f.status = 'pending' and f.requester <> v_caller), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object(
               'handle',       p.handle,
               'display_name', a.display_name,
               'avatar_path',  p.avatar_path)
             order by f.created_at desc)
        from public.friendship f
        join public.profile p
          on p.account_id = case when f.account_low = v_caller
                                 then f.account_high else f.account_low end
        join public.account a on a.id = p.account_id and a.deleted_at is null
       where v_caller in (f.account_low, f.account_high)
         and f.status = 'pending' and f.requester = v_caller), '[]'::jsonb));
end;
$$;

-- The caller's own block list, so unblocking is possible. Only handles the
-- caller blocked; someone who blocked the caller appears nowhere.
create or replace function public.my_blocked() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'handle',       p.handle,
             'display_name', a.display_name)
           order by p.handle)
      from public.friendship f
      join public.profile p
        on p.account_id = case when f.account_low = v_caller
                               then f.account_high else f.account_low end
      join public.account a on a.id = p.account_id and a.deleted_at is null
     where f.status = 'blocked'
       and ((f.account_low = v_caller and f.blocked_by_low)
         or (f.account_high = v_caller and f.blocked_by_high))), '[]'::jsonb);
end;
$$;

-- MARK: - Discovery

-- Exact/prefix handle search. The minimum a human needs to confirm they found
-- the right person: handle, name, avatar. No city, no ids, no counts.
create or replace function public.search_profiles(p_query text) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_query  text := public.normalize_handle(p_query);
begin
  if v_query !~ '^[a-z0-9_]{2,20}$' then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(entry order by entry->>'handle')
      from (
        select jsonb_build_object(
                 'handle',       p.handle,
                 'display_name', a.display_name,
                 'avatar_path',  p.avatar_path) as entry
          from public.profile p
          join public.account a on a.id = p.account_id and a.deleted_at is null
         where p.handle like v_query || '%'
           and p.discoverable
           and p.account_id <> v_caller
           and not private.blocked_between(v_caller, p.account_id)
         order by p.handle
         limit 20) matches), '[]'::jsonb);
end;
$$;

-- One profile, as the caller is allowed to see it, with the relationship from
-- the caller's side. Null — not an error — when the profile does not exist,
-- the owner blocked the caller, or a stranger is undiscoverable: all three
-- must be one indistinguishable answer.
create or replace function public.get_profile(p_handle text) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
  v_state  text;
begin
  if v_target is null then return null; end if;
  if v_target = v_caller then return public.my_profile(); end if;

  v_row := private.friendship_between(v_caller, v_target);

  if v_row.id is not null and v_row.status = 'blocked' then
    if (v_caller = v_row.account_low and v_row.blocked_by_low)
       or (v_caller = v_row.account_high and v_row.blocked_by_high) then
      -- The caller's own block list entry: enough to recognise and unblock,
      -- nothing current — not even the avatar.
      return (select jsonb_build_object(
                       'handle',       p.handle,
                       'display_name', a.display_name,
                       'relationship', 'blocked')
                from public.profile p
                join public.account a on a.id = p.account_id
               where p.account_id = v_target);
    end if;
    return null;  -- they blocked the caller
  end if;

  v_state := case
    when v_row.id is null then 'none'
    when v_row.status = 'accepted' then 'friend'
    when v_row.status = 'pending' and v_row.requester = v_caller then 'pending_outgoing'
    when v_row.status = 'pending' then 'pending_incoming'
    else 'none'  -- declined reads as no relationship, on purpose
  end;

  if v_state = 'none'
     and not exists (select 1 from public.profile p
                      where p.account_id = v_target and p.discoverable) then
    return null;
  end if;

  return (select jsonb_build_object(
                   'handle',       p.handle,
                   'display_name', a.display_name,
                   'avatar_path',  p.avatar_path,
                   'city',         case when v_state = 'friend' then p.city end,
                   'relationship', v_state)
            from public.profile p
            join public.account a on a.id = p.account_id
           where p.account_id = v_target);
end;
$$;

-- MARK: - RLS

-- Default deny; no client writes anywhere. SELECT carries the visibility
-- rules: a member sees the pair's row, except that a blocked row is visible
-- only to whoever set a block flag, and a declined row only to the decliner —
-- the requester is not told they were declined, here or anywhere.
alter table public.friendship enable row level security;
revoke all on public.friendship from anon, authenticated;
grant select on public.friendship to authenticated;

drop policy if exists friendship_select_member on public.friendship;
create policy friendship_select_member on public.friendship
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.auth_user_id = auth.uid()
                    and a.deleted_at is null
                    and a.id in (friendship.account_low, friendship.account_high)
                    and case friendship.status
                          when 'blocked' then
                            (a.id = friendship.account_low and friendship.blocked_by_low)
                            or (a.id = friendship.account_high and friendship.blocked_by_high)
                          when 'declined' then a.id <> friendship.requester
                          else true
                        end));

revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_to_friend_request(text, boolean) from public, anon;
revoke all on function public.cancel_friend_request(text) from public, anon;
revoke all on function public.remove_friend(text) from public, anon;
revoke all on function public.block_user(text) from public, anon;
revoke all on function public.unblock_user(text) from public, anon;
revoke all on function public.my_friends() from public, anon;
revoke all on function public.my_friend_requests() from public, anon;
revoke all on function public.my_blocked() from public, anon;
revoke all on function public.search_profiles(text) from public, anon;
revoke all on function public.get_profile(text) from public, anon;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_to_friend_request(text, boolean) to authenticated;
grant execute on function public.cancel_friend_request(text) to authenticated;
grant execute on function public.remove_friend(text) to authenticated;
grant execute on function public.block_user(text) to authenticated;
grant execute on function public.unblock_user(text) to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.my_friend_requests() to authenticated;
grant execute on function public.my_blocked() to authenticated;
grant execute on function public.search_profiles(text) to authenticated;
grant execute on function public.get_profile(text) to authenticated;
