-- Shared Commitments follow-ups, as settled by Patrick after SC1
-- (docs/shared-commitments.md §10, §13; NORTHSTAR §46):
--
--   1. A creator's deletion ORPHANS an agreement other people are bound to,
--      never dissolves it. The roster is everyone's; the creator's exit
--      removes their line and their authorship, nothing anyone else accepted.
--   2. Roster moments become social events on the Recent shelf: acceptance,
--      completion (late stated as late), the shared window opening, and the
--      moment everyone has made it. Never progress ticks, declines, app
--      opens, or roster bookkeeping.
--   3. Push groundwork under the revised rule — no social-engagement push,
--      commitment-relevant push allowed. The server enqueues the actionable
--      asks (a shared-commitment invitation, an accountability-partner
--      request, an override approval request for an in-app partner) into a
--      push outbox; delivery is a deployment concern, exactly as
--      message_outbox already is for SMS/email. Nothing here pushes
--      reactions, streaks, generic activity, or engagement nudges — those
--      kinds deliberately do not exist in the outbox vocabulary.

-- MARK: - 1. Creator deletion orphans, never dissolves

alter table public.shared_commitment_agreement
  alter column creator drop not null;

alter table public.shared_commitment_agreement
  drop constraint if exists shared_commitment_agreement_creator_fkey;
alter table public.shared_commitment_agreement
  add constraint shared_commitment_agreement_creator_fkey
  foreign key (creator) references public.account(id) on delete set null;

comment on column public.shared_commitment_agreement.creator is
  'Null once the creator''s account is gone: the agreement is orphaned, not '
  'dissolved. Bound participants keep their roster and their personal '
  'commitments; nobody can edit, cancel, or invite into an orphaned '
  'agreement, and normal retention purges it when its time comes.';

-- An orphaned agreement has no author to say yes to anyone: outstanding
-- invitations cannot be accepted (the friendship check against a deleted
-- account already fails), and the reads below simply stop offering them.

-- `created_by_me` must stay a boolean when creator is null.
create or replace function public.my_shared_commitments() returns jsonb
language sql
security definer
set search_path = public, private, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            sa.id,
           'title',         sa.title,
           'activity',      sa.activity,
           'metric',        sa.metric,
           'target',        sa.target,
           'window_start',  private.iso8601(sa.window_start),
           'deadline',      private.iso8601(sa.deadline),
           'state',         sa.state,
           'created_by_me', coalesce(sa.creator = me.account_id, false),
           'my_commitment_id', mine.commitment_id,
           'participants',  private.shared_roster(sa.id, me.account_id))
           order by sa.deadline, sa.created_at), '[]'::jsonb)
    from (select private.social_caller() as account_id) me
    join public.shared_commitment_participant mine on mine.account_id = me.account_id
    join public.shared_commitment_agreement sa on sa.id = mine.agreement_id
   where mine.state = 'accepted'
     and sa.state <> 'cancelled'
     and sa.deadline > now() - private.social_event_horizon()
$$;

-- Retention: the deadline horizon as before, plus agreements nobody stands
-- on any more — every participant account deleted, their rows cascaded away —
-- which have nothing left to preserve.
create or replace function public.purge_shared_commitments() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count int;
  v_empty int;
begin
  delete from public.shared_commitment_agreement
   where deadline < now() - private.social_event_horizon();
  get diagnostics v_count = row_count;
  delete from public.shared_commitment_agreement sa
   where not exists (select 1 from public.shared_commitment_participant sp
                      where sp.agreement_id = sa.id);
  get diagnostics v_empty = row_count;
  return v_count + v_empty;
end;
$$;

-- MARK: - 2. Roster moments on the Recent shelf

-- The event vocabulary grows five shared kinds. For these, `commitment_id`
-- carries the AGREEMENT id (the fact they narrate belongs to the group, and
-- it must not collide with the witnessing pipeline's per-commitment
-- withdrawal in unshare_commitment).
alter table public.social_event
  drop constraint if exists social_event_kind_check;
alter table public.social_event
  add constraint social_event_kind_check
  check (kind in ('commitment_shared', 'commitment_kept', 'commitment_kept_late',
                  'override_used', 'streak_milestone',
                  'shared_accepted', 'shared_started', 'shared_completed',
                  'shared_completed_late', 'shared_all_completed'));

-- When the shared window's opening was announced (null = not yet). Set at
-- creation for a window already open — creation itself is the announcement
-- there, via the invitation cards — so the scheduler announces only windows
-- that open later.
alter table public.shared_commitment_agreement
  add column if not exists start_announced_at timestamptz;

-- Recreated from 0021 with one change: a window already open at creation is
-- marked announced, so announce_shared_starts never re-tells it.
create or replace function public.create_shared_commitment(
  p_commitment_id uuid,
  p_title         text,
  p_activity      text,
  p_metric        text,
  p_target        numeric,
  p_window_start  timestamptz,
  p_deadline      timestamptz,
  p_handles       text[],
  p_verification  text default 'self_reported'
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_title  text;
  v_id     uuid;
  v_handle text;
  v_count  int;
begin
  if p_commitment_id is null then
    raise exception 'a shared commitment starts from your own commitment'
      using errcode = '22023';
  end if;

  select agreement_id into v_id
    from public.shared_commitment_participant
   where account_id = v_caller and commitment_id = p_commitment_id;
  if v_id is not null then
    return jsonb_build_object('id', v_id);
  end if;

  v_title := private.neutralise_text(p_title, 80);
  if v_title is null or length(v_title) = 0 then
    raise exception 'a shared commitment needs a title' using errcode = '22023';
  end if;
  if p_deadline is null or p_deadline <= now() then
    raise exception 'the shared deadline must be in the future' using errcode = '22023';
  end if;
  if p_window_start is null or p_window_start >= p_deadline then
    raise exception 'the shared window must open before its deadline'
      using errcode = '22023';
  end if;
  if p_handles is null or array_length(p_handles, 1) is null then
    raise exception 'a shared commitment needs someone to share it with'
      using errcode = '22023';
  end if;
  if p_verification not in ('self_reported', 'app_verified') then
    raise exception 'not a verification tier' using errcode = '22023';
  end if;

  select count(*) into v_count
    from public.shared_commitment_agreement
   where creator = v_caller and created_at > now() - interval '24 hours';
  if v_count >= private.max_shared_creations_per_day() then
    raise exception 'too many shared commitments today — try again tomorrow'
      using errcode = '54000';
  end if;

  if p_activity not in ('any','running','walking','cycling','strength','swimming','other') then
    raise exception 'not an activity' using errcode = '22023';
  end if;
  if p_metric not in ('show_up','sessions','total_duration','total_distance','active_calories') then
    raise exception 'not a completion metric' using errcode = '22023';
  end if;

  insert into public.shared_commitment_agreement
         (creator, title, activity, metric, target, window_start, deadline,
          start_announced_at)
  values (v_caller, v_title, p_activity, p_metric, p_target, p_window_start, p_deadline,
          case when p_window_start <= now() then now() end)
  returning id into v_id;

  insert into public.shared_commitment_participant
         (agreement_id, account_id, state, responded_at,
          accepted_terms_version, commitment_id, verification)
  values (v_id, v_caller, 'accepted', now(), 1, p_commitment_id, p_verification);

  foreach v_handle in array p_handles loop
    perform private.invite_shared_participant(v_id, v_caller, v_handle);
  end loop;

  return jsonb_build_object('id', v_id);
end;
$$;

-- Recreated from 0021: a real acceptance now also tells the acceptor's
-- friends, once. The idempotent early returns emit nothing, so a retried
-- acceptance stays one event.
create or replace function public.respond_to_shared_invitation(
  p_id            uuid,
  p_accept        boolean,
  p_commitment_id uuid default null,
  p_verification  text default 'self_reported'
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_a      public.shared_commitment_agreement;
  v_row    public.shared_commitment_participant;
  v_f      public.friendship;
begin
  select sp.* into v_row from public.shared_commitment_participant sp
   where sp.agreement_id = p_id and sp.account_id = v_caller;
  if v_row.account_id is null then
    raise exception 'no such invitation' using errcode = '42501';
  end if;

  if v_row.state = 'accepted' and p_accept then
    return jsonb_build_object('state', 'accepted',
                              'commitment_id', v_row.commitment_id,
                              'terms_version', v_row.accepted_terms_version);
  end if;
  if v_row.state = 'declined' and not p_accept then
    return jsonb_build_object('state', 'declined');
  end if;
  if v_row.state <> 'invited' then
    raise exception 'no such invitation' using errcode = '42501';
  end if;

  select * into v_a from public.shared_commitment_agreement where id = p_id;
  if v_a.state <> 'open' or v_a.deadline <= now() then
    raise exception 'this shared commitment has ended' using errcode = '55000';
  end if;

  if p_accept then
    v_f := private.friendship_between(v_caller, v_a.creator);
    if v_a.creator is null or v_f.id is null or v_f.status <> 'accepted'
       or private.blocked_between(v_caller, v_a.creator) then
      raise exception 'this invitation is no longer open' using errcode = '22023';
    end if;
    if p_commitment_id is null then
      raise exception 'accepting creates your own commitment — the client must name it'
        using errcode = '22023';
    end if;
    if p_verification not in ('self_reported', 'app_verified') then
      raise exception 'not a verification tier' using errcode = '22023';
    end if;
    update public.shared_commitment_participant
       set state = 'accepted', responded_at = now(),
           accepted_terms_version = v_a.terms_version,
           commitment_id = p_commitment_id,
           verification = p_verification
     where agreement_id = p_id and account_id = v_caller;
    insert into public.social_event (account_id, kind, commitment_id, title, occurred_at)
         values (v_caller, 'shared_accepted', p_id, v_a.title, now());
    return jsonb_build_object('state', 'accepted',
                              'commitment_id', p_commitment_id,
                              'terms_version', v_a.terms_version);
  else
    update public.shared_commitment_participant
       set state = 'declined', responded_at = now()
     where agreement_id = p_id and account_id = v_caller;
    return jsonb_build_object('state', 'declined');
  end if;
end;
$$;

-- Recreated from 0021: a real completion transition now emits its event —
-- late stated as late — and, when it was the last open line on the roster,
-- the everyone-made-it moment, told once, by the person who closed it.
-- Suppressed when the same commitment is also friend-shared through the
-- witnessing pipeline (0016), which already tells the story: one fact, one
-- line, never two.
create or replace function public.publish_shared_progress(
  p_commitment_id uuid,
  p_progress      numeric,
  p_state         text,
  p_resolved_at   timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_row    public.shared_commitment_participant;
  v_a      public.shared_commitment_agreement;
  v_shares_overrides boolean;
  v_state  text;
  v_accepted int;
begin
  if p_state not in ('open', 'kept', 'kept_late', 'overridden') then
    raise exception 'not a state a client may claim' using errcode = '22023';
  end if;
  if p_progress is null or p_progress < 0 or p_progress > 1000000 then
    raise exception 'not a progress figure' using errcode = '22023';
  end if;

  select sp.* into v_row from public.shared_commitment_participant sp
   where sp.account_id = v_caller and sp.commitment_id = p_commitment_id
     and sp.state in ('accepted', 'left');
  if v_row.account_id is null then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;

  select share_override_usage into v_shares_overrides
    from public.profile where account_id = v_caller;
  v_state := case when p_state = 'overridden' and not v_shares_overrides
                  then 'ended' else p_state end;

  update public.shared_commitment_participant
     set progress = p_progress,
         progress_state = v_state,
         resolved_at = p_resolved_at,
         progress_updated_at = now()
   where agreement_id = v_row.agreement_id and account_id = v_caller
     and (progress is distinct from p_progress
          or progress_state is distinct from v_state
          or resolved_at is distinct from p_resolved_at);

  -- Events ride the real transition only: open → done, first told here.
  if v_row.state = 'accepted' and v_row.progress_state = 'open'
     and v_state in ('kept', 'kept_late') then
    select * into v_a from public.shared_commitment_agreement
     where id = v_row.agreement_id;
    if not exists (select 1 from public.shared_commitment
                    where account_id = v_caller and commitment_id = p_commitment_id) then
      insert into public.social_event (account_id, kind, commitment_id, title, occurred_at)
           values (v_caller,
                   case v_state when 'kept' then 'shared_completed'
                                else 'shared_completed_late' end,
                   v_row.agreement_id, v_a.title, coalesce(p_resolved_at, now()));
    end if;
    -- The roster closing: every accepted line done, at least two of them,
    -- and this publish was the one that closed it.
    select count(*) into v_accepted from public.shared_commitment_participant
     where agreement_id = v_row.agreement_id and state = 'accepted';
    if v_accepted >= 2 and not exists (
         select 1 from public.shared_commitment_participant
          where agreement_id = v_row.agreement_id and state = 'accepted'
            and progress_state not in ('kept', 'kept_late')) then
      insert into public.social_event (account_id, kind, commitment_id, title, occurred_at)
           values (v_caller, 'shared_all_completed', v_row.agreement_id, v_a.title, now());
    end if;
  end if;

  return jsonb_build_object('state', v_state);
end;
$$;

-- The shared window opening, announced once per agreement to each bound
-- participant's friends. For the scheduler, beside purge_shared_commitments —
-- deliberately not granted to authenticated.
create or replace function public.announce_shared_starts() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count int := 0;
  v_a     public.shared_commitment_agreement;
begin
  for v_a in select * from public.shared_commitment_agreement
              where state = 'open' and start_announced_at is null
                and window_start <= now() and deadline > now()
              for update
  loop
    insert into public.social_event (account_id, kind, commitment_id, title, occurred_at)
    select sp.account_id, 'shared_started', v_a.id, v_a.title, v_a.window_start
      from public.shared_commitment_participant sp
     where sp.agreement_id = v_a.id and sp.state = 'accepted';
    update public.shared_commitment_agreement
       set start_announced_at = now() where id = v_a.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- MARK: - 3. Push groundwork: the revised rule, in schema

-- The rule (docs/social-architecture.md §9, revised): no social-engagement
-- push; commitment-relevant push allowed. The vocabulary below IS the
-- allow-list — a kind that is not an actionable commitment ask cannot be
-- enqueued, because it cannot be spelled.

create table if not exists public.push_device (
  -- The token is the identity APNs cares about; one account may hold many
  -- devices, and a token re-registered by a new sign-in moves with it.
  token      text primary key check (length(token) between 16 and 512),
  account_id uuid not null references public.account(id) on delete cascade,
  platform   text not null default 'ios' check (platform in ('ios')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists push_device_account_idx
  on public.push_device (account_id);

-- Enqueued asks, drained by a future APNs sender exactly as message_outbox
-- awaits its SMS/email sender: the server composes and queues, delivery is a
-- deployment concern (docs/deployment.md when it lands). Bodies are composed
-- server-side from neutralised text and carry no ids beyond the row's own.
create table if not exists public.push_outbox (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.account(id) on delete cascade,
  kind       text not null
               check (kind in ('shared_invitation', 'partner_request',
                               'override_approval_request')),
  title      text not null check (length(title) between 1 and 80),
  body       text not null check (length(body) between 1 and 200),
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  send_error text
);

create index if not exists push_outbox_unsent_idx
  on public.push_outbox (created_at) where sent_at is null;

-- MARK: - Registration RPCs

create or replace function public.register_push_token(
  p_token    text,
  p_platform text default 'ios'
) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  if p_token is null or length(p_token) not between 16 and 512 then
    raise exception 'not a push token' using errcode = '22023';
  end if;
  if p_platform not in ('ios') then
    raise exception 'not a platform' using errcode = '22023';
  end if;
  insert into public.push_device (token, account_id, platform)
       values (p_token, v_caller, p_platform)
  on conflict (token) do update
     set account_id = excluded.account_id,
         platform = excluded.platform,
         updated_at = now();
end;
$$;

create or replace function public.remove_push_token(p_token text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  delete from public.push_device
   where token = p_token and account_id = v_caller;
end;
$$;

-- MARK: - Enqueue triggers

-- Triggers rather than function edits, so the big concurrency-critical
-- functions (create_override_request especially) stay untouched: the ask
-- becoming a row IS the moment to queue its push, whoever wrote the row.

create or replace function private.enqueue_shared_invitation_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_inviter text;
begin
  select a.display_name into v_inviter
    from public.shared_commitment_agreement sa
    join public.account a on a.id = sa.creator
   where sa.id = new.agreement_id and a.deleted_at is null;
  if v_inviter is null then
    return new;  -- an orphaned agreement asks nobody
  end if;
  insert into public.push_outbox (account_id, kind, title, body)
       values (new.account_id, 'shared_invitation', 'Earned',
               private.neutralise_text(v_inviter, 64)
                 || ' invited you to a commitment.');
  return new;
end;
$$;

drop trigger if exists shared_invitation_push on public.shared_commitment_participant;
create trigger shared_invitation_push
  after insert or update of state on public.shared_commitment_participant
  for each row
  when (new.state = 'invited')
  execute function private.enqueue_shared_invitation_push();

create or replace function private.enqueue_partner_request_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_asker text;
begin
  select a.display_name into v_asker
    from public.account a
   where a.id = new.account_id and a.deleted_at is null;
  if v_asker is null or new.earned_account_id is null then
    return new;
  end if;
  insert into public.push_outbox (account_id, kind, title, body)
       values (new.earned_account_id, 'partner_request', 'Earned',
               private.neutralise_text(v_asker, 64)
                 || ' wants you as an accountability partner.');
  return new;
end;
$$;

drop trigger if exists partner_request_push on public.partner;
create trigger partner_request_push
  after insert or update of status on public.partner
  for each row
  when (new.kind = 'earned_user' and new.status = 'invited')
  execute function private.enqueue_partner_request_push();

create or replace function private.enqueue_override_approval_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_target uuid;
  v_asker  text;
begin
  select p.earned_account_id, a.display_name into v_target, v_asker
    from public.partner p
    join public.override_request r on r.id = new.request_id
    join public.account a on a.id = r.account_id
   where p.id = new.partner_id and p.kind = 'earned_user';
  if v_target is null then
    return new;  -- external partners get their link through message_outbox
  end if;
  insert into public.push_outbox (account_id, kind, title, body)
       values (v_target, 'override_approval_request', 'Earned',
               private.neutralise_text(coalesce(v_asker, 'Someone'), 64)
                 || ' is asking to be let out of a commitment.');
  return new;
end;
$$;

drop trigger if exists override_approval_push on public.override_request_recipient;
create trigger override_approval_push
  after insert on public.override_request_recipient
  for each row
  execute function private.enqueue_override_approval_push();

-- MARK: - RLS

alter table public.push_device enable row level security;
alter table public.push_outbox enable row level security;
revoke all on public.push_device from anon, authenticated;
revoke all on public.push_outbox from anon, authenticated;
-- No policies at all: clients register through the functions above and never
-- read either table; the future sender drains the outbox as service_role.

-- MARK: - Grants

revoke all on function private.enqueue_shared_invitation_push() from public, anon, authenticated;
revoke all on function private.enqueue_partner_request_push() from public, anon, authenticated;
revoke all on function private.enqueue_override_approval_push() from public, anon, authenticated;

revoke all on function public.my_shared_commitments() from public, anon;
revoke all on function public.purge_shared_commitments() from public, anon, authenticated;
revoke all on function public.announce_shared_starts() from public, anon, authenticated;
revoke all on function public.create_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz, text[], text) from public, anon;
revoke all on function public.respond_to_shared_invitation(uuid, boolean, uuid, text) from public, anon;
revoke all on function public.publish_shared_progress(uuid, numeric, text, timestamptz) from public, anon;
revoke all on function public.register_push_token(text, text) from public, anon;
revoke all on function public.remove_push_token(text) from public, anon;

grant execute on function public.my_shared_commitments() to authenticated;
grant execute on function public.create_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz, text[], text) to authenticated;
grant execute on function public.respond_to_shared_invitation(uuid, boolean, uuid, text) to authenticated;
grant execute on function public.publish_shared_progress(uuid, numeric, text, timestamptz) to authenticated;
grant execute on function public.register_push_token(text, text) to authenticated;
grant execute on function public.remove_push_token(text) to authenticated;
