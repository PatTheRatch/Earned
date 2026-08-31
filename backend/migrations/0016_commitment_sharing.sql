-- Milestone S2: commitment sharing and the events it generates
-- (docs/social-architecture.md §7, §9).
--
-- Everything here is SOCIAL REPRESENTATION, not enforcement. The client
-- publishes its own account of a commitment — title, deadline, how it ended —
-- and the server's whole job is distribution to friends under the owner's
-- sharing choices. Nothing on the enforcement path reads these tables, and a
-- modified client that lies here impresses its friends inside a commitment
-- app, which is its own punishment (NORTHSTAR invariant 28).
--
-- Sharing is chosen, never assumed (invariant 26): a commitment reaches this
-- table only because the owner picked Friends for it, hydration never enters
-- the social layer at all, and every default in sight is the private side.

-- The owner's sharing choices that the *server* must know to distribute
-- honestly. Both default off.
alter table public.profile
  add column if not exists share_streaks        boolean not null default false,
  add column if not exists share_override_usage boolean not null default false;

-- One row per commitment the owner currently shares. Deleting the row IS
-- unsharing — visibility changes affect the future honestly, so the row and
-- its events go together (§7.2).
create table if not exists public.shared_commitment (
  account_id    uuid not null references public.account(id) on delete cascade,
  -- The client's own commitment id, opaque here. Same id space the Contract
  -- Envelope uses, but deliberately no foreign key between the two systems:
  -- a commitment can be shared without an envelope and enveloped without
  -- being shared.
  commitment_id uuid not null,
  title         text not null check (length(title) between 1 and 80),
  deadline      timestamptz not null,
  -- 'ended' is the quiet resolution: the commitment stopped being open and
  -- the owner's settings say the *how* is nobody's business (an Override with
  -- share_override_usage off). Friends see that it ended, not why.
  state         text not null default 'open'
                  check (state in ('open', 'kept', 'kept_late', 'overridden', 'ended')),
  resolved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  primary key (account_id, commitment_id)
);

-- The bounded record of things friends may hear about. Rows expire on a
-- 30-day horizon (§7.2): friend_activity refuses to read past it, and
-- purge_social_events deletes behind it. This is a recent-events shelf, not
-- a timeline.
create table if not exists public.social_event (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.account(id) on delete cascade,
  kind          text not null
                  check (kind in ('commitment_shared', 'commitment_kept',
                                  'commitment_kept_late', 'override_used',
                                  'streak_milestone')),
  -- Which shared commitment this came from, so unsharing can withdraw it.
  -- Null for streak milestones.
  commitment_id uuid,
  title         text check (title is null or length(title) between 1 and 80),
  milestone     int  check (milestone is null or milestone > 0),
  occurred_at   timestamptz not null,
  created_at    timestamptz not null default now()
);

create index if not exists social_event_account_created_idx
  on public.social_event (account_id, created_at desc);

-- MARK: - Publishing

-- Create or update one shared commitment, emitting at most one event per real
-- transition. Idempotent by construction: republishing the same state changes
-- nothing and emits nothing, because the app calls this on every foreground.
create or replace function public.publish_shared_commitment(
  p_commitment_id uuid,
  p_title         text,
  p_deadline      timestamptz,
  p_state         text,
  p_resolved_at   timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_title  text;
  v_shares_overrides boolean;
  v_state  text;
  v_old    public.shared_commitment;
  v_kind   text;
begin
  if p_state not in ('open', 'kept', 'kept_late', 'overridden') then
    raise exception 'not a state a client may claim' using errcode = '22023';
  end if;
  v_title := private.neutralise_text(p_title, 80);
  if v_title is null or length(v_title) = 0 then
    raise exception 'a shared commitment needs a title' using errcode = '22023';
  end if;
  if p_deadline is null then
    raise exception 'a shared commitment needs a deadline' using errcode = '22023';
  end if;

  select share_override_usage into v_shares_overrides
    from public.profile where account_id = v_caller;
  -- The server applies the owner's setting, not the client's claim: an
  -- Override with sharing off is stored — and told — as a quiet 'ended'.
  v_state := case when p_state = 'overridden' and not v_shares_overrides
                  then 'ended' else p_state end;

  select * into v_old from public.shared_commitment
   where account_id = v_caller and commitment_id = p_commitment_id;

  insert into public.shared_commitment
         (account_id, commitment_id, title, deadline, state, resolved_at)
  values (v_caller, p_commitment_id, v_title, p_deadline, v_state, p_resolved_at)
  on conflict (account_id, commitment_id) do update
     set title = excluded.title,
         deadline = excluded.deadline,
         state = excluded.state,
         resolved_at = excluded.resolved_at,
         updated_at = now();

  -- Events, one per transition:
  --   fresh share, still open              → commitment_shared
  --   open (or fresh) → terminal state     → the matching terminal event
  --   anything republished unchanged       → nothing
  --   → 'ended'                            → nothing, by design
  if v_old.account_id is null and v_state = 'open' then
    v_kind := 'commitment_shared';
  elsif (v_old.account_id is null or v_old.state = 'open')
        and v_state in ('kept', 'kept_late', 'overridden') then
    v_kind := case v_state
                when 'kept' then 'commitment_kept'
                when 'kept_late' then 'commitment_kept_late'
                else 'override_used'
              end;
  end if;
  if v_kind is not null then
    insert into public.social_event (account_id, kind, commitment_id, title, occurred_at)
         values (v_caller, v_kind, p_commitment_id, v_title,
                 coalesce(p_resolved_at, now()));
  end if;

  return jsonb_build_object('state', v_state);
end;
$$;

-- Unsharing withdraws the commitment and everything it generated, now. No
-- event survives because a friend once saw it (§7.2).
create or replace function public.unshare_commitment(p_commitment_id uuid) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  delete from public.social_event
   where account_id = v_caller and commitment_id = p_commitment_id;
  delete from public.shared_commitment
   where account_id = v_caller and commitment_id = p_commitment_id;
end;
$$;

-- MARK: - RLS

alter table public.shared_commitment enable row level security;
alter table public.social_event      enable row level security;
revoke all on public.shared_commitment from anon, authenticated;
revoke all on public.social_event      from anon, authenticated;
grant select on public.shared_commitment to authenticated;
grant select on public.social_event      to authenticated;

-- Owners read their own sharing state directly; friends only ever read
-- through friend_activity (0017), where the field exposure is decided.
drop policy if exists shared_commitment_select_own on public.shared_commitment;
create policy shared_commitment_select_own on public.shared_commitment
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = shared_commitment.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

drop policy if exists social_event_select_own on public.social_event;
create policy social_event_select_own on public.social_event
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = social_event.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

revoke all on function public.publish_shared_commitment(uuid, text, timestamptz, text, timestamptz)
  from public, anon;
revoke all on function public.unshare_commitment(uuid) from public, anon;
grant execute on function public.publish_shared_commitment(uuid, text, timestamptz, text, timestamptz)
  to authenticated;
grant execute on function public.unshare_commitment(uuid) to authenticated;
