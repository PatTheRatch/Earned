-- Milestone S2: streak presentation, the sharing switches, the activity feed,
-- and the retention that keeps it a shelf rather than a timeline
-- (docs/social-architecture.md §7.2, §8, §9).

-- The two figures a friend may see, exactly as the client computed them from
-- its own ledger. Self-reported by design and labelled so in the docs — this
-- table exists only while the owner shares streaks, so turning sharing off is
-- a delete, not a flag.
create table if not exists public.social_streaks (
  account_id          uuid primary key references public.account(id) on delete cascade,
  commitments_kept    int not null check (commitments_kept between 0 and 100000),
  -- Null means no Override has ever been used, which renders as "No
  -- Overrides yet" — a different sentence from zero.
  since_last_override int check (since_last_override between 0 and 100000),
  updated_at          timestamptz not null default now()
);

-- MARK: - The switches

-- Flip the sharing choices. Turning something off withdraws what it was
-- sharing, immediately and completely: streaks off deletes the figures and
-- their milestone events; Override sharing off turns every shared
-- 'overridden' into a quiet 'ended' and withdraws the events that said more.
-- Turning something on shares only what happens next — history is not
-- retroactively manufactured (§7.2).
create or replace function public.set_social_sharing(
  p_share_streaks        boolean default null,
  p_share_override_usage boolean default null
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

  return (select jsonb_build_object(
            'share_streaks', p.share_streaks,
            'share_override_usage', p.share_override_usage)
            from public.profile p where p.account_id = v_caller);
end;
$$;

-- MARK: - Streak figures

-- Milestones worth a line on a friend's shelf. A function, not a table, for
-- the same reason as the reserved handles: one place, growable in a
-- migration.
create or replace function private.streak_milestones() returns int[]
language sql immutable as $$ select array[5, 10, 25, 50, 100, 250] $$;

-- Publish the client's current figures. Quietly does nothing when streak
-- sharing is off — the app republishes on every foreground and must not race
-- its own privacy toggle into an error. A milestone event is emitted only
-- when the kept count *rises onto* a milestone, so republishing the same
-- numbers forever emits nothing.
create or replace function public.set_social_streaks(
  p_commitments_kept    int,
  p_since_last_override int default null
) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_shares boolean;
  v_old    int;
begin
  if p_commitments_kept is null or p_commitments_kept < 0 or p_commitments_kept > 100000
     or (p_since_last_override is not null
         and (p_since_last_override < 0 or p_since_last_override > 100000)) then
    raise exception 'not a plausible streak figure' using errcode = '22023';
  end if;

  select share_streaks into v_shares from public.profile where account_id = v_caller;
  if not v_shares then
    return;
  end if;

  select commitments_kept into v_old from public.social_streaks
   where account_id = v_caller;

  insert into public.social_streaks (account_id, commitments_kept, since_last_override)
       values (v_caller, p_commitments_kept, p_since_last_override)
  on conflict (account_id) do update
     set commitments_kept = excluded.commitments_kept,
         since_last_override = excluded.since_last_override,
         updated_at = now();

  if p_commitments_kept > coalesce(v_old, 0)
     and p_commitments_kept = any (private.streak_milestones()) then
    insert into public.social_event (account_id, kind, milestone, occurred_at)
         values (v_caller, 'streak_milestone', p_commitments_kept, now());
  end if;
end;
$$;

-- MARK: - The shelf

-- How old an event may be and still be shown. Read-side and purge-side use
-- the same number, so the shelf cannot quietly become a timeline.
create or replace function private.social_event_horizon() returns interval
language sql immutable as $$ select interval '30 days' $$;

-- Recent, meaningful, bounded: what the Social tab's Recent area shows. Only
-- accepted friends' events (blocked pairs cannot be friends, so exclusion is
-- structural), only inside the horizon, capped — and then it ends. Fields
-- are the minimum that renders a line: who, what, which title, when.
create or replace function public.friend_activity() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  return coalesce((
    select jsonb_agg(entry order by entry->>'occurred_at' desc)
      from (
        select jsonb_build_object(
                 'handle',       p.handle,
                 'display_name', a.display_name,
                 'avatar_path',  p.avatar_path,
                 'kind',         e.kind,
                 'title',        e.title,
                 'milestone',    e.milestone,
                 'occurred_at',  to_char(e.occurred_at at time zone 'UTC',
                                         'YYYY-MM-DD"T"HH24:MI:SS"Z"')) as entry
          from public.social_event e
          join public.friendship f
            on f.status = 'accepted'
           and ((f.account_low = v_caller and f.account_high = e.account_id)
             or (f.account_high = v_caller and f.account_low = e.account_id))
          join public.profile p on p.account_id = e.account_id
          join public.account a on a.id = e.account_id and a.deleted_at is null
         where e.created_at > now() - private.social_event_horizon()
         order by e.occurred_at desc
         limit 50) recent), '[]'::jsonb);
end;
$$;

-- Housekeeping behind the horizon. Not load-bearing — friend_activity already
-- refuses to read past it — this keeps stored state honest about §7.2's
-- retention promise.
create or replace function public.purge_social_events() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.social_event
   where created_at <= now() - private.social_event_horizon();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- MARK: - The owner's profile now carries their own switches

-- Recreated from 0013 with the two sharing flags added, so the app can render
-- the toggles it already has the authority to flip.
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
           'share_override_usage', p.share_override_usage)
    into v_result
    from public.profile p
    join public.account a on a.id = p.account_id
   where p.account_id = v_account;

  return v_result;  -- null when there is no profile yet, which is the answer
end;
$$;

-- MARK: - A friend's profile now carries their shared figures

-- Recreated from 0014 with one addition: accepted friends see the streak
-- figures the owner chose to share. Everyone else's view is unchanged.
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
                 -- Streaks are shared with friends, and only exist while the
                 -- owner shares them (set_social_sharing deletes otherwise).
                 || coalesce((select jsonb_build_object(
                                'commitments_kept', s.commitments_kept,
                                'since_last_override', s.since_last_override)
                               from public.social_streaks s
                              where s.account_id = v_target
                                and v_state = 'friend'
                                and p.share_streaks), '{}'::jsonb)
            from public.profile p
            join public.account a on a.id = p.account_id
           where p.account_id = v_target);
end;
$$;

-- MARK: - Grants

alter table public.social_streaks enable row level security;
revoke all on public.social_streaks from anon, authenticated;
grant select on public.social_streaks to authenticated;

drop policy if exists social_streaks_select_own on public.social_streaks;
create policy social_streaks_select_own on public.social_streaks
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = social_streaks.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

revoke all on function public.set_social_sharing(boolean, boolean) from public, anon;
revoke all on function public.set_social_streaks(int, int) from public, anon;
revoke all on function public.friend_activity() from public, anon;
revoke all on function public.purge_social_events() from public, anon;
revoke all on function public.get_profile(text) from public, anon;

grant execute on function public.set_social_sharing(boolean, boolean) to authenticated;
grant execute on function public.set_social_streaks(int, int) to authenticated;
grant execute on function public.friend_activity() to authenticated;
grant execute on function public.get_profile(text) to authenticated;
-- purge_social_events is for the scheduler (service role), not clients.
