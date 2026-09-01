-- Milestone SC1: Shared Commitments (NORTHSTAR §46, invariants 30–32;
-- docs/shared-commitments.md).
--
-- A shared commitment is an AGREEMENT, not a group Gate. The server holds the
-- canonical shared terms, the roster, and every invitation's state — and holds
-- nothing about enforcement. Each accepting participant's obligation is an
-- ordinary commitment in their own local ledger, with their own restrictions,
-- verification, Override rules and debt (invariant 30). Nothing in this file
-- can lock or unlock anybody's phone.
--
-- Naming note: `shared_commitment` (0016) is already the witnessing
-- projection — one account showing one of its own commitments to friends.
-- The doing-it-together concept therefore lives in two new tables:
-- `shared_commitment_agreement` (the promise) and
-- `shared_commitment_participant` (who stands where on it). The participant
-- row doubles as the invitation, so an invitation cannot exist twice and a
-- roster cannot disagree with the invitations that built it.
--
-- Trust boundary, same as the rest of Social: participants' progress lines
-- are SOCIAL REPRESENTATION — the client's own account of itself — and
-- nothing on the enforcement path may read them (invariant 28). What the
-- server IS authoritative for: invitation existence and state, the roster,
-- the canonical shared terms and their version, acceptance timestamps, and
-- which personal commitment id belongs to which participant. Only the
-- participant's own session can accept (invariant 31): acceptance is a
-- SECURITY DEFINER function that re-derives the caller from the JWT, so no
-- client can invent another account's consent.

-- MARK: - Dials

create or replace function private.max_shared_participants() returns int
language sql immutable
set search_path = public, private, extensions, pg_temp
as $$ select 8 $$;

create or replace function private.max_shared_creations_per_day() returns int
language sql immutable
set search_path = public, private, extensions, pg_temp
as $$ select 10 $$;

create or replace function private.max_shared_invitations_per_day() returns int
language sql immutable
set search_path = public, private, extensions, pg_temp
as $$ select 30 $$;

-- One timestamp rendering for everything this migration returns, so the wire
-- format is decided in one place (the client parses plain ISO-8601 UTC).
create or replace function private.iso8601(p_at timestamptz) returns text
language sql immutable
set search_path = public, private, extensions, pg_temp
as $$ select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;

-- MARK: - The agreement

-- The canonical shared terms. Frozen the moment anyone besides the creator
-- is bound to them (invariant 32): edit_shared_commitment refuses after the
-- first acceptance, so `terms_version` only ever advances while the promise
-- is still the creator's alone. There is deliberately no versioned
-- re-acceptance machinery — a material change after acceptance is a new
-- agreement, made honestly, not a mutation of this row.
create table if not exists public.shared_commitment_agreement (
  id            uuid primary key default gen_random_uuid(),
  creator       uuid not null references public.account(id) on delete cascade,
  title         text not null check (length(title) between 1 and 80),
  -- The requirement, in EarnedKit's two-dimension sense: an activity filter
  -- and a completion metric, never one fused idea (NORTHSTAR §13).
  activity      text not null
                  check (activity in ('any', 'running', 'walking', 'cycling',
                                      'strength', 'swimming', 'other')),
  metric        text not null
                  check (metric in ('show_up', 'sessions', 'total_duration',
                                    'total_distance', 'active_calories')),
  -- Sessions count, seconds, meters, or kilocalories; null exactly when the
  -- metric is show_up. ('sessions' is schema-ready; the client offers it once
  -- EarnedKit grows a session-count completion metric.)
  target        numeric check ((metric = 'show_up') = (target is null))
                        check (target is null or (target > 0 and target <= 1000000)),
  -- The shared eligible window. Everyone's deadline; each participant's own
  -- eligibleFrom is max(window_start, their acceptance) — decided client-side
  -- where eligibility already lives, stated here because the server refuses
  -- acceptance past the deadline: a commitment cannot be born overdue.
  window_start  timestamptz not null,
  deadline      timestamptz not null,
  terms_version int not null default 1 check (terms_version >= 1),
  -- open      → accepting responses
  -- closed    → the creator cancelled the unstarted future after someone was
  --             bound: no further acceptance, outstanding invitations expired,
  --             everyone already bound keeps exactly what they accepted
  -- cancelled → cancelled before anyone else was bound; nothing survives it
  state         text not null default 'open'
                  check (state in ('open', 'closed', 'cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (deadline > window_start)
);

create index if not exists shared_agreement_creator_idx
  on public.shared_commitment_agreement (creator, created_at desc);

-- MARK: - The participant (and the invitation, which is the same row)

-- One row per (agreement, account), ever. The row's state IS the invitation
-- state machine, so inviting the same friend twice is structurally one ask,
-- and the roster is exactly the rows that answered yes.
--
--   invited   → asked, unanswered; obliges nobody, creates no Gate anywhere
--   accepted  → bound; their personal commitment exists, id recorded here
--   declined  → said no (quiet — the roster simply never shows them)
--   withdrawn → the creator took the ask back before an answer
--   expired   → the question outlived its relevance (deadline passed or the
--               agreement was cancelled/closed while unanswered)
--   left      → was accepted, then left the roster; their personal commitment
--               is untouched by this — leaving is a social act, and no social
--               exit is cheaper than an Override (invariant 32)
create table if not exists public.shared_commitment_participant (
  agreement_id  uuid not null references public.shared_commitment_agreement(id)
                  on delete cascade,
  account_id    uuid not null references public.account(id) on delete cascade,
  state         text not null default 'invited'
                  check (state in ('invited', 'accepted', 'declined',
                                  'withdrawn', 'expired', 'left')),
  invited_at    timestamptz not null default now(),
  responded_at  timestamptz,
  -- Which terms they bound themselves to. In v1 this can only be the current
  -- version (edits stop at first acceptance), but the record is kept per
  -- participant so what was agreed to is never reconstructed from memory.
  accepted_terms_version int,
  -- The participant's own personal commitment id — the same client-minted
  -- uuid space the Contract Envelope and witnessing tables use, and like
  -- them deliberately without a foreign key across systems. It links a
  -- roster line to its owner's obligation; it grants nobody anything.
  commitment_id uuid,
  -- The participant's own verification tier, stated factually so the roster
  -- never claims everyone is equally verified when they are not (§8 of the
  -- design). Representation, not authority.
  verification  text not null default 'self_reported'
                  check (verification in ('self_reported', 'app_verified')),
  -- Self-reported progress against the SHARED target, and the story of how
  -- it ended — same vocabulary as the witnessing table (0016), including the
  -- quiet 'ended' for an Override the owner does not share.
  progress      numeric not null default 0 check (progress >= 0 and progress <= 1000000),
  progress_state text not null default 'open'
                  check (progress_state in ('open', 'kept', 'kept_late',
                                            'overridden', 'ended')),
  resolved_at   timestamptz,
  progress_updated_at timestamptz,
  primary key (agreement_id, account_id),
  -- Bound means bound: an accepted (or formerly accepted) row always knows
  -- which terms were accepted and which commitment came of it.
  check ((state in ('accepted', 'left')) = (commitment_id is not null)),
  check ((state in ('accepted', 'left')) = (accepted_terms_version is not null))
);

create index if not exists shared_participant_account_idx
  on public.shared_commitment_participant (account_id);

-- One personal commitment belongs to at most one agreement — and this is also
-- what makes creation idempotent: retrying create_shared_commitment with the
-- same commitment id finds this row instead of minting a second agreement.
create unique index if not exists shared_participant_commitment_idx
  on public.shared_commitment_participant (account_id, commitment_id)
  where commitment_id is not null;

-- MARK: - Private helpers

-- The roster as one account may see it: accepted and still-open invitations,
-- minus anyone on either side of a block with the viewer (block supersedes —
-- visibility severs both ways, obligations stand). Declined, withdrawn,
-- expired and left rows are simply not roster lines. Field exposure for every
-- read lives here, in one reviewed place.
create or replace function private.shared_roster(p_agreement uuid, p_viewer uuid)
returns jsonb
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'handle',         pr.handle,
           'display_name',   a.display_name,
           'avatar_path',    pr.avatar_path,
           'state',          sp.state,
           'verification',   case when sp.state = 'accepted' then sp.verification end,
           'progress',       case when sp.state = 'accepted' then sp.progress end,
           'progress_state', case when sp.state = 'accepted' then sp.progress_state end,
           'resolved_at',    case when sp.state = 'accepted'
                                  then private.iso8601(sp.resolved_at) end))
           order by sp.invited_at, pr.handle), '[]'::jsonb)
    from public.shared_commitment_participant sp
    join public.account a on a.id = sp.account_id and a.deleted_at is null
    join public.profile pr on pr.account_id = sp.account_id
   where sp.agreement_id = p_agreement
     and sp.state in ('invited', 'accepted')
     and not private.blocked_between(p_viewer, sp.account_id)
$$;

-- The one invitation shape both the creation-time and later invites share.
-- Quiet where quiet is load-bearing; loud only where the caller already
-- knows the state. Returns without error when the target is not invitable
-- for a reason the caller must not be able to distinguish (no such profile,
-- blocked) — the same single refusal shape 0019 uses for nomination.
create or replace function private.invite_shared_participant(
  p_agreement uuid,
  p_caller    uuid,
  p_handle    text
) returns void
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_target uuid := private.account_for_handle(p_handle);
  v_f      public.friendship;
  v_row    public.shared_commitment_participant;
  v_count  int;
begin
  if v_target is null or private.blocked_between(p_caller, v_target) then
    -- Indistinguishable from a stranger: a block must not announce itself.
    raise exception 'you can only invite accepted friends' using errcode = '23514';
  end if;
  if v_target = p_caller then
    raise exception 'you are already in — inviting yourself adds nothing'
      using errcode = '22023';
  end if;

  -- The friendship is the invitation channel, exactly as it is the
  -- nomination channel for earned partners (0019). Consent to a commitment
  -- is never inferred from it (invariant 31) — it only carries the ask.
  v_f := private.friendship_between(p_caller, v_target);
  if v_f.id is null or v_f.status <> 'accepted' then
    raise exception 'you can only invite accepted friends' using errcode = '23514';
  end if;

  select count(*) into v_count
    from public.shared_commitment_participant
   where agreement_id = p_agreement and state in ('invited', 'accepted', 'left');
  if v_count >= private.max_shared_participants() then
    raise exception 'this shared commitment is full' using errcode = '54000';
  end if;

  select count(*) into v_count
    from public.shared_commitment_participant sp
    join public.shared_commitment_agreement sa on sa.id = sp.agreement_id
   where sa.creator = p_caller and sp.account_id <> p_caller
     and sp.invited_at > now() - interval '24 hours';
  if v_count >= private.max_shared_invitations_per_day() then
    raise exception 'too many invitations today — try again tomorrow'
      using errcode = '54000';
  end if;

  select * into v_row from public.shared_commitment_participant
   where agreement_id = p_agreement and account_id = v_target;
  if v_row.account_id is null then
    insert into public.shared_commitment_participant (agreement_id, account_id)
         values (p_agreement, v_target);
  elsif v_row.state = 'invited' then
    return;  -- asking twice is one ask
  elsif v_row.state in ('accepted', 'left') then
    return;  -- already answered yes once; nothing to re-ask
  else
    -- declined / withdrawn / expired: a fresh ask reopens the same row, the
    -- way a friend request after a decline does. Rate limits above are the
    -- defence against pestering.
    update public.shared_commitment_participant
       set state = 'invited', invited_at = now(), responded_at = null
     where agreement_id = p_agreement and account_id = v_target;
  end if;
end;
$$;

-- MARK: - Creating

-- Creates the agreement, seats the creator as its first bound participant,
-- and sends the invitations — one call, because the creator's own Deal was
-- already signed client-side (their commitment id arrives here) and a
-- half-created group helps nobody. Idempotent by commitment id: retrying
-- after a network failure returns the agreement the first call made.
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

  -- The retry path: this commitment already anchors an agreement.
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

  -- Activity/metric/target shape is enforced by the table constraints; the
  -- friendlier messages here are for the two the client could plausibly get
  -- wrong across versions.
  if p_activity not in ('any','running','walking','cycling','strength','swimming','other') then
    raise exception 'not an activity' using errcode = '22023';
  end if;
  if p_metric not in ('show_up','sessions','total_duration','total_distance','active_calories') then
    raise exception 'not a completion metric' using errcode = '22023';
  end if;

  insert into public.shared_commitment_agreement
         (creator, title, activity, metric, target, window_start, deadline)
  values (v_caller, v_title, p_activity, p_metric, p_target, p_window_start, p_deadline)
  returning id into v_id;

  -- The creator is bound from birth: they authored the terms and signed
  -- their own Deal before this call. Their hardening clock is their own and
  -- started client-side; the server records only that they are bound.
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

-- Invite one more accepted friend to a standing agreement. The roster is not
-- frozen by acceptance — more witnesses strengthen the promise, and every
-- participant can see exactly who is on it — but a closed or cancelled
-- agreement asks nobody new, and neither does one past its deadline.
create or replace function public.invite_to_shared_commitment(
  p_id     uuid,
  p_handle text
) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_a      public.shared_commitment_agreement;
begin
  select * into v_a from public.shared_commitment_agreement where id = p_id;
  if v_a.id is null or v_a.creator <> v_caller then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;
  if v_a.state <> 'open' or v_a.deadline <= now() then
    raise exception 'this shared commitment is no longer open' using errcode = '22023';
  end if;
  perform private.invite_shared_participant(p_id, v_caller, p_handle);
end;
$$;

-- Take back an unanswered ask. Quiet when there is nothing to take back.
create or replace function public.withdraw_shared_invitation(
  p_id     uuid,
  p_handle text
) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
begin
  if v_target is null then return; end if;
  update public.shared_commitment_participant sp
     set state = 'withdrawn', responded_at = now()
    from public.shared_commitment_agreement sa
   where sa.id = sp.agreement_id and sa.id = p_id and sa.creator = v_caller
     and sp.account_id = v_target and sp.state = 'invited';
end;
$$;

-- MARK: - Answering

-- Accepting is the moment an obligation begins to exist, and only the
-- invited session can do it (invariant 31). The caller supplies the id of
-- the personal commitment their client is about to create: the server
-- records the binding first, the client appends the commitment to its own
-- ledger on success, and a retry of either half converges — same acceptance,
-- same commitment, nothing half-made.
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

  -- Idempotency before anything else: a duplicate acceptance (double-tap,
  -- network retry, crash-and-retry) is one acceptance. The first recorded
  -- commitment id wins; the answer repeats it so the client can converge.
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
    -- The question outlived its relevance: a commitment cannot be born
    -- overdue. (No state write here — a raise would roll it back anyway;
    -- cancellation already expires its invitations, and a deadline-passed
    -- row is invisible everywhere until the purge collects it.)
    raise exception 'this shared commitment has ended' using errcode = '55000';
  end if;

  if p_accept then
    -- The friendship carried the ask; if it is gone, so is the ask. The
    -- personal commitments of everyone already bound are, as always,
    -- untouched by anything social.
    v_f := private.friendship_between(v_caller, v_a.creator);
    if v_f.id is null or v_f.status <> 'accepted'
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

-- MARK: - Changing course

-- Editing the shared terms is allowed only while the promise is still the
-- creator's alone (invariant 32). After anyone else accepts, the honest
-- moves are cancel_shared_commitment or a fresh agreement.
create or replace function public.edit_shared_commitment(
  p_id           uuid,
  p_title        text,
  p_activity     text,
  p_metric       text,
  p_target       numeric,
  p_window_start timestamptz,
  p_deadline     timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_a      public.shared_commitment_agreement;
  v_title  text;
begin
  select * into v_a from public.shared_commitment_agreement where id = p_id;
  if v_a.id is null or v_a.creator <> v_caller then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;
  if v_a.state <> 'open' then
    raise exception 'this shared commitment is no longer open' using errcode = '22023';
  end if;
  if exists (select 1 from public.shared_commitment_participant
              where agreement_id = p_id and account_id <> v_caller
                and state in ('accepted', 'left')) then
    raise exception 'someone already accepted — the promise is no longer yours alone to change'
      using errcode = '23514';
  end if;

  v_title := private.neutralise_text(p_title, 80);
  if v_title is null or length(v_title) = 0 then
    raise exception 'a shared commitment needs a title' using errcode = '22023';
  end if;
  if p_deadline is null or p_deadline <= now()
     or p_window_start is null or p_window_start >= p_deadline then
    raise exception 'the shared window must open before its deadline, in the future'
      using errcode = '22023';
  end if;

  update public.shared_commitment_agreement
     set title = v_title, activity = p_activity, metric = p_metric,
         target = p_target, window_start = p_window_start, deadline = p_deadline,
         terms_version = terms_version + 1, updated_at = now()
   where id = p_id;
  -- The creator re-binds to their own new terms; outstanding invitations
  -- always present the current version and record it at acceptance.
  update public.shared_commitment_participant
     set accepted_terms_version = v_a.terms_version + 1
   where agreement_id = p_id and account_id = v_caller;

  return jsonb_build_object('terms_version', v_a.terms_version + 1);
end;
$$;

-- Cancel what has not started. Before anyone else is bound this cancels the
-- agreement outright; after, it only closes the door — outstanding
-- invitations expire, nobody new can accept, and everyone already bound
-- keeps exactly the commitment they accepted. Their contracts were never
-- the creator's to take back.
create or replace function public.cancel_shared_commitment(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_a      public.shared_commitment_agreement;
  v_state  text;
begin
  select * into v_a from public.shared_commitment_agreement where id = p_id;
  if v_a.id is null or v_a.creator <> v_caller then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;
  if v_a.state <> 'open' then
    return jsonb_build_object('state', v_a.state);  -- already done; idempotent
  end if;

  v_state := case when exists (select 1 from public.shared_commitment_participant
                                where agreement_id = p_id and account_id <> v_caller
                                  and state in ('accepted', 'left'))
                  then 'closed' else 'cancelled' end;

  update public.shared_commitment_agreement
     set state = v_state, updated_at = now() where id = p_id;
  update public.shared_commitment_participant
     set state = 'expired', responded_at = now()
   where agreement_id = p_id and state = 'invited';

  return jsonb_build_object('state', v_state);
end;
$$;

-- Leaving the roster. A social act only: the leaver's personal commitment —
-- hardened or not — is exactly as escapable afterwards as before, which is
-- to say: complete it, or Override (invariant 32). The creator does not
-- leave their own agreement; they cancel its future.
create or replace function public.leave_shared_commitment(p_id uuid) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_row    public.shared_commitment_participant;
  v_a      public.shared_commitment_agreement;
begin
  select * into v_row from public.shared_commitment_participant
   where agreement_id = p_id and account_id = v_caller;
  if v_row.account_id is null then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;
  if v_row.state = 'left' then return; end if;
  select * into v_a from public.shared_commitment_agreement where id = p_id;
  if v_a.creator = v_caller then
    raise exception 'the creator cancels the future rather than leaving'
      using errcode = '22023';
  end if;
  if v_row.state = 'invited' then
    -- Leaving before answering is declining.
    update public.shared_commitment_participant
       set state = 'declined', responded_at = now()
     where agreement_id = p_id and account_id = v_caller;
    return;
  end if;
  if v_row.state <> 'accepted' then
    raise exception 'no such shared commitment' using errcode = '42501';
  end if;
  update public.shared_commitment_participant
     set state = 'left', responded_at = now()
   where agreement_id = p_id and account_id = v_caller;
end;
$$;

-- MARK: - Progress

-- The participant's own line, self-reported against the shared target —
-- exactly the witnessing pipeline's trust posture (0016), including the
-- server applying the owner's Override-sharing setting rather than the
-- client's claim, and idempotent republishing (the app publishes on every
-- foreground). Addressed by the participant's own commitment id, since
-- that is what the client knows.
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
  v_shares_overrides boolean;
  v_state  text;
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

  return jsonb_build_object('state', v_state);
end;
$$;

-- MARK: - Reading

-- Every shared commitment the caller stands on — bound, or still deciding.
-- The roster shown to each viewer is filtered through their blocks; the
-- shelf is bounded by the same 30-day horizon as the rest of Social,
-- measured from the deadline so a finished week ages out rather than
-- becoming a permanent scoreboard.
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
           'created_by_me', sa.creator = me.account_id,
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

-- The asks waiting on the caller, shaped for an invitation card: who asked,
-- what the promise is, who else is already in. Dead questions — cancelled,
-- past deadline, friendship gone, blocked — simply do not appear.
create or replace function public.my_shared_invitations() returns jsonb
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
           'invited_at',    private.iso8601(mine.invited_at),
           'inviter_handle',       pr.handle,
           'inviter_display_name', a.display_name,
           'inviter_avatar_path',  pr.avatar_path,
           'accepted_count', (select count(*)::int
                                from public.shared_commitment_participant sp
                               where sp.agreement_id = sa.id and sp.state = 'accepted'))
           order by mine.invited_at desc), '[]'::jsonb)
    from (select private.social_caller() as account_id) me
    join public.shared_commitment_participant mine on mine.account_id = me.account_id
    join public.shared_commitment_agreement sa on sa.id = mine.agreement_id
    join public.account a on a.id = sa.creator and a.deleted_at is null
    join public.profile pr on pr.account_id = sa.creator
    join public.friendship f
      on f.account_low = least(me.account_id, sa.creator)
     and f.account_high = greatest(me.account_id, sa.creator)
     and f.status = 'accepted'
   where mine.state = 'invited'
     and sa.state = 'open'
     and sa.deadline > now()
$$;

-- MARK: - Block supersedes (recreating block_user from 0019, additively)

-- Everything 0019's block_user did, plus the shared-commitment rule: a block
-- withdraws any unanswered invitations between the two accounts, in both
-- directions — and that is all it touches. Accepted participants' rows
-- stand (their commitments are theirs; blocking never erases a hardened
-- obligation), and the visibility severing is done where visibility is
-- decided: every roster read filters through blocked_between.
create or replace function public.block_user(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
  v_now    timestamptz := now();
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
                 v_caller < v_target, v_caller > v_target, v_now);
  else
    update public.friendship
       set status = 'blocked',
           blocked_by_low  = blocked_by_low  or (v_caller = account_low),
           blocked_by_high = blocked_by_high or (v_caller = account_high),
           responded_at = v_now
     where id = v_row.id;
  end if;

  -- The cross-system rule. Both directions, pending and active alike, and
  -- an audit-preserving revocation rather than a deletion: old grants keep
  -- the partner rows their votes reference.
  update public.partner p
     set status = 'revoked', revoked_at = v_now
   where ((p.account_id = v_caller and p.earned_account_id = v_target)
       or (p.account_id = v_target and p.earned_account_id = v_caller))
     and p.status in ('invited', 'active');

  -- And the shared-commitment rule: unanswered asks between the pair are
  -- withdrawn, both directions. Nothing else changes here — accepted rows
  -- keep standing, because a block severs sight, never an obligation.
  update public.shared_commitment_participant sp
     set state = 'withdrawn', responded_at = v_now
    from public.shared_commitment_agreement sa
   where sa.id = sp.agreement_id and sp.state = 'invited'
     and ((sa.creator = v_caller and sp.account_id = v_target)
       or (sa.creator = v_target and sp.account_id = v_caller));
end;
$$;

-- MARK: - Housekeeping

-- Agreements age out on the same horizon the reads already refuse to see
-- past, cascading their participant rows with them. For the scheduler, like
-- purge_social_events — deliberately not granted to authenticated.
create or replace function public.purge_shared_commitments() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.shared_commitment_agreement
   where deadline < now() - private.social_event_horizon();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- MARK: - RLS

alter table public.shared_commitment_agreement  enable row level security;
alter table public.shared_commitment_participant enable row level security;
revoke all on public.shared_commitment_agreement  from anon, authenticated;
revoke all on public.shared_commitment_participant from anon, authenticated;
grant select on public.shared_commitment_agreement  to authenticated;
grant select on public.shared_commitment_participant to authenticated;

-- Direct reads are own-perspective only; every cross-account shape goes
-- through the functions above, where field exposure is decided in one place.
drop policy if exists shared_agreement_select_participant on public.shared_commitment_agreement;
create policy shared_agreement_select_participant on public.shared_commitment_agreement
  for select to authenticated
  using (exists (select 1
                   from public.account a
                   join public.shared_commitment_participant sp
                     on sp.account_id = a.id
                  where a.auth_user_id = auth.uid() and a.deleted_at is null
                    and sp.agreement_id = shared_commitment_agreement.id
                    and sp.state in ('invited', 'accepted', 'left')));

drop policy if exists shared_participant_select_own on public.shared_commitment_participant;
create policy shared_participant_select_own on public.shared_commitment_participant
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = shared_commitment_participant.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

-- MARK: - Grants

revoke all on function private.max_shared_participants() from public, anon, authenticated;
revoke all on function private.max_shared_creations_per_day() from public, anon, authenticated;
revoke all on function private.max_shared_invitations_per_day() from public, anon, authenticated;
revoke all on function private.iso8601(timestamptz) from public, anon, authenticated;
revoke all on function private.shared_roster(uuid, uuid) from public, anon, authenticated;
revoke all on function private.invite_shared_participant(uuid, uuid, text) from public, anon, authenticated;

revoke all on function public.create_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz, text[], text) from public, anon;
revoke all on function public.invite_to_shared_commitment(uuid, text) from public, anon;
revoke all on function public.withdraw_shared_invitation(uuid, text) from public, anon;
revoke all on function public.respond_to_shared_invitation(uuid, boolean, uuid, text) from public, anon;
revoke all on function public.edit_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz) from public, anon;
revoke all on function public.cancel_shared_commitment(uuid) from public, anon;
revoke all on function public.leave_shared_commitment(uuid) from public, anon;
revoke all on function public.publish_shared_progress(uuid, numeric, text, timestamptz) from public, anon;
revoke all on function public.my_shared_commitments() from public, anon;
revoke all on function public.my_shared_invitations() from public, anon;
revoke all on function public.block_user(text) from public, anon;
revoke all on function public.purge_shared_commitments() from public, anon, authenticated;

grant execute on function public.create_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz, text[], text) to authenticated;
grant execute on function public.invite_to_shared_commitment(uuid, text) to authenticated;
grant execute on function public.withdraw_shared_invitation(uuid, text) to authenticated;
grant execute on function public.respond_to_shared_invitation(uuid, boolean, uuid, text) to authenticated;
grant execute on function public.edit_shared_commitment(uuid, text, text, text, numeric, timestamptz, timestamptz) to authenticated;
grant execute on function public.cancel_shared_commitment(uuid) to authenticated;
grant execute on function public.leave_shared_commitment(uuid) to authenticated;
grant execute on function public.publish_shared_progress(uuid, numeric, text, timestamptz) to authenticated;
grant execute on function public.my_shared_commitments() to authenticated;
grant execute on function public.my_shared_invitations() to authenticated;
grant execute on function public.block_user(text) to authenticated;
