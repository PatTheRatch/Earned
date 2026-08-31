-- Milestone S3: check-in sharing and the hasn't-checked-in surface
-- (docs/social-architecture.md §10).
--
-- A friend going silent is exactly the social friction this layer exists
-- for — and exactly where honest language matters most, because the server
-- cannot distinguish a deleted app from a lost phone, a dead battery, or a
-- quiet week. So what is stored is one fact (when Earned last heard from
-- this account), what is shared is coarser still (whole days, and only once
-- the silence is long enough to mean anything), and what is *said* is
-- decided by the clients — which render facts, never motive (invariant 27).
--
-- Opt-in, like every sharing switch (invariant 26): with the switch off the
-- fact is not even stored, and turning it off deletes what was.

alter table public.profile
  add column if not exists share_last_checkin boolean not null default false,
  -- The one fact. Recorded only while the switch is on; nulled when it turns
  -- off. Never exposed raw — friends get whole days, past the threshold.
  add column if not exists last_checkin_at timestamptz;

-- How long a silence must last before it is interesting enough to surface.
-- Below this, nothing is shown at all — which is also what makes the surface
-- coarse: absence of the figure means "recently active OR not sharing", and
-- that ambiguity is the point. No live presence exists here.
create or replace function private.checkin_silence_threshold() returns interval
language sql immutable as $$ select interval '72 hours' $$;

-- MARK: - Recording

-- The app checks in on every foreground pass. A quiet no-op while sharing is
-- off — the fact is not stored at all, not stored-and-hidden.
create or replace function public.record_checkin() returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  update public.profile
     set last_checkin_at = now()
   where account_id = v_caller and share_last_checkin;
end;
$$;

-- MARK: - The switches, now three

-- The two-argument version must go, not linger: PostgREST resolves RPCs by
-- named arguments, and a surviving overload would make every existing
-- two-argument call ambiguous.
drop function if exists public.set_social_sharing(boolean, boolean);

create or replace function public.set_social_sharing(
  p_share_streaks        boolean default null,
  p_share_override_usage boolean default null,
  p_share_last_checkin   boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  if p_share_streaks is not null then
    update public.profile set share_streaks = p_share_streaks, updated_at = now()
     where account_id = v_caller;
    if not p_share_streaks then
      delete from public.social_streaks where account_id = v_caller;
      delete from public.social_event
       where account_id = v_caller and kind = 'streak_milestone';
    end if;
  end if;

  if p_share_override_usage is not null then
    update public.profile set share_override_usage = p_share_override_usage, updated_at = now()
     where account_id = v_caller;
    if not p_share_override_usage then
      update public.shared_commitment set state = 'ended', updated_at = now()
       where account_id = v_caller and state = 'overridden';
      delete from public.social_event
       where account_id = v_caller and kind = 'override_used';
    end if;
  end if;

  if p_share_last_checkin is not null then
    update public.profile
       set share_last_checkin = p_share_last_checkin,
           -- Off deletes the fact; on starts the clock now rather than
           -- retroactively surfacing a silence nobody agreed to show.
           last_checkin_at = case when p_share_last_checkin then now() end,
           updated_at = now()
     where account_id = v_caller;
  end if;

  return (select jsonb_build_object(
            'share_streaks', p.share_streaks,
            'share_override_usage', p.share_override_usage,
            'share_last_checkin', p.share_last_checkin)
            from public.profile p where p.account_id = v_caller);
end;
$$;

-- MARK: - What a friend may learn

-- The quiet block for one profile, or empty. Whole days only, only past the
-- threshold, only while shared — plus how many *shared* commitments were
-- still open when Earned last heard from them, which is a fact about the
-- last sync by construction: an unheard-from client cannot have updated
-- them since.
create or replace function private.quiet_block(p_account uuid) returns jsonb
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select coalesce((
    select jsonb_build_object(
             'quiet_days',
             floor(extract(epoch from now() - p.last_checkin_at) / 86400)::int,
             'open_shared_commitments',
             (select count(*)::int from public.shared_commitment sc
               where sc.account_id = p.account_id and sc.state = 'open'))
      from public.profile p
     where p.account_id = p_account
       and p.share_last_checkin
       and p.last_checkin_at is not null
       and p.last_checkin_at <= now() - private.checkin_silence_threshold()),
    '{}'::jsonb)
$$;

-- Recreated from 0014 with the quiet block appended per friend.
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
           || private.quiet_block(p.account_id)
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

-- Recreated from 0017: friends additionally get the quiet block. Strangers,
-- pending requests and blocked pairs see exactly what they saw before.
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
      return (select jsonb_build_object(
                       'handle',       p.handle,
                       'display_name', a.display_name,
                       'relationship', 'blocked')
                from public.profile p
                join public.account a on a.id = p.account_id
               where p.account_id = v_target);
    end if;
    return null;
  end if;

  v_state := case
    when v_row.id is null then 'none'
    when v_row.status = 'accepted' then 'friend'
    when v_row.status = 'pending' and v_row.requester = v_caller then 'pending_outgoing'
    when v_row.status = 'pending' then 'pending_incoming'
    else 'none'
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
                 || coalesce((select jsonb_build_object(
                                'commitments_kept', s.commitments_kept,
                                'since_last_override', s.since_last_override)
                               from public.social_streaks s
                              where s.account_id = v_target
                                and v_state = 'friend'
                                and p.share_streaks), '{}'::jsonb)
                 || case when v_state = 'friend'
                         then private.quiet_block(v_target) else '{}'::jsonb end
            from public.profile p
            join public.account a on a.id = p.account_id
           where p.account_id = v_target);
end;
$$;

-- Recreated from 0017 with the third switch visible to its owner.
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
           'discoverable', p.discoverable,
           'share_streaks', p.share_streaks,
           'share_override_usage', p.share_override_usage,
           'share_last_checkin', p.share_last_checkin)
    into v_result
    from public.profile p
    join public.account a on a.id = p.account_id
   where p.account_id = v_account;

  return v_result;  -- null when there is no profile yet, which is the answer
end;
$$;

-- MARK: - Grants

revoke all on function public.record_checkin() from public, anon;
revoke all on function public.set_social_sharing(boolean, boolean, boolean) from public, anon;
grant execute on function public.record_checkin() to authenticated;
grant execute on function public.set_social_sharing(boolean, boolean, boolean) to authenticated;
