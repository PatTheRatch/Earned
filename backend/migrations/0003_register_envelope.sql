-- The only write path into a Contract Envelope.
--
-- SECURITY DEFINER with a pinned search_path, because no client role holds
-- write permission on these tables at all (0004). Every rule the server must
-- enforce independently of the device lives in here: hardening, the freeze,
-- monotonicity, roster ownership, and the late marking.

create or replace function public.contract_policy_digest(
  p_created_at            timestamptz,
  p_eligible_from         timestamptz,
  p_deadline              timestamptz,
  p_correction_window     double precision,
  p_approvals_required    int,
  p_accountability_window double precision,
  p_partner_ids           uuid[]
) returns bytea
language sql
immutable
-- pgcrypto is in `extensions` on Supabase and `public` on a plain Postgres.
-- Without this the function inherits the caller's pinned path and cannot find
-- digest() at all.
set search_path = public, extensions, pg_temp
as $$
  -- Canonical by construction: UTC to the microsecond, fixed-scale numerics
  -- rather than float text, and a sorted roster. Two servers holding the same
  -- contract must produce the same bytes.
  select digest(
    concat_ws('|',
      to_char(p_created_at    at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
      to_char(p_eligible_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
      to_char(p_deadline      at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
      round(p_correction_window::numeric, 6)::text,
      p_approvals_required::text,
      round(p_accountability_window::numeric, 6)::text,
      coalesce((select string_agg(pid::text, ',' order by pid::text)
                  from unnest(p_partner_ids) pid), '')
    ), 'sha256');
$$;

create or replace function public.register_contract_envelope(
  p_commitment_id         uuid,
  p_title                 text,
  p_created_at            timestamptz,
  p_eligible_from         timestamptz,
  p_deadline              timestamptz,
  p_correction_window     double precision,
  p_approvals_required    int,
  p_accountability_window double precision,
  p_partner_ids           uuid[] default '{}'::uuid[],
  p_plan_id               uuid   default null,
  p_version               int    default 1
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account  uuid;
  v_now      timestamptz := now();
  v_hardens  timestamptz;
  v_existing public.contract_envelope;
  v_row      public.contract_envelope;
  v_is_late  boolean;
  v_bad      int;
  v_count    int;
begin
  select a.id into v_account
    from public.account a
   where a.auth_user_id = auth.uid()
     and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  -- A roster is a list of this account's own partners, or it is nothing. This
  -- is checked before anything is written so a probe cannot confirm the
  -- existence of another account's partner id.
  select count(*) into v_bad
    from unnest(p_partner_ids) pid
   where not exists (select 1 from public.partner p
                      where p.id = pid and p.account_id = v_account);
  if v_bad > 0 then
    raise exception 'roster contains partners that do not belong to this account'
      using errcode = '42501';
  end if;

  if p_eligible_from > p_deadline then
    raise exception 'the eligible period must open before the deadline'
      using errcode = '23514';
  end if;

  v_hardens := public.earned_hardens_at(p_created_at, p_deadline, p_correction_window);

  select * into v_existing
    from public.contract_envelope e
   where e.account_id = v_account and e.commitment_id = p_commitment_id;

  if v_existing.commitment_id is null then
    -- A creation instant in the future would push hardening out of reach and
    -- dodge the late marking. Small skew is ordinary; a lot of it is a claim.
    if p_created_at > v_now + interval '5 minutes' then
      raise exception 'creation instant is too far in the future' using errcode = '22008';
    end if;

    -- S13. The envelope arrived after the contract had already hardened, so the
    -- server cannot tell an honest offline creation from terms chosen with
    -- hindsight. Recorded, and the accountability route stays shut.
    v_is_late := v_now >= v_hardens;

    insert into public.contract_envelope (
      account_id, commitment_id, plan_id, title, created_at, eligible_from, deadline,
      correction_window, approvals_required, accountability_window, version,
      policy_digest, hardens_at, is_late)
    values (
      v_account, p_commitment_id, p_plan_id, p_title, p_created_at, p_eligible_from, p_deadline,
      p_correction_window, p_approvals_required, p_accountability_window, p_version,
      public.contract_policy_digest(p_created_at, p_eligible_from, p_deadline,
        p_correction_window, p_approvals_required, p_accountability_window, p_partner_ids),
      v_hardens, v_is_late)
    returning * into v_row;
  else
    -- The freeze. Measured against the hardening instant the server already
    -- holds, not the one these arguments imply.
    if v_now >= v_existing.hardens_at then
      raise exception 'this contract has hardened; its accountability terms are frozen'
        using errcode = '23514';
    end if;
    if p_version <= v_existing.version then
      raise exception 'envelope version must increase' using errcode = '23514';
    end if;
    if p_plan_id is distinct from v_existing.plan_id then
      raise exception 'a commitment cannot change which plan it belongs to'
        using errcode = '23514';
    end if;

    -- Monotonicity, enforced a second time and somewhere the user cannot reach.
    -- EarnedKit enforces the same rule in the ledger; a patched client that
    -- lets itself ease a contract locally still finds the original terms here.
    if p_deadline > v_existing.deadline then
      raise exception 'the deadline may only move earlier' using errcode = '23514';
    end if;
    if p_eligible_from < v_existing.eligible_from then
      raise exception 'the eligible period may only open later' using errcode = '23514';
    end if;
    if p_approvals_required < v_existing.approvals_required then
      raise exception 'approvals required may only rise' using errcode = '23514';
    end if;
    if p_accountability_window < v_existing.accountability_window then
      raise exception 'the accountability window may only lengthen' using errcode = '23514';
    end if;
    if p_correction_window > v_existing.correction_window then
      raise exception 'the correction window may only shorten' using errcode = '23514';
    end if;

    -- Partners may be added before hardening, never removed: dropping people
    -- you would have to convince is an easing edit, and adding a contact you
    -- control is the self-approval move played slowly (§2.2).
    select count(*) into v_bad
      from public.contract_envelope_partner cep
     where cep.account_id = v_account
       and cep.commitment_id = p_commitment_id
       and cep.partner_id <> all (p_partner_ids);
    if v_bad > 0 then
      raise exception 'partners may be added before hardening, never removed'
        using errcode = '23514';
    end if;

    update public.contract_envelope e
       set plan_id               = p_plan_id,
           title                 = p_title,
           created_at            = p_created_at,
           eligible_from         = p_eligible_from,
           deadline              = p_deadline,
           correction_window     = p_correction_window,
           approvals_required    = p_approvals_required,
           accountability_window = p_accountability_window,
           version               = p_version,
           policy_digest         = public.contract_policy_digest(p_created_at, p_eligible_from,
                                     p_deadline, p_correction_window, p_approvals_required,
                                     p_accountability_window, p_partner_ids),
           registered_at         = v_now
     where e.account_id = v_account and e.commitment_id = p_commitment_id
    returning * into v_row;
  end if;

  insert into public.contract_envelope_partner (account_id, commitment_id, partner_id)
       select v_account, p_commitment_id, pid from unnest(p_partner_ids) pid
  on conflict do nothing;

  select count(*) into v_count
    from public.contract_envelope_partner cep
   where cep.account_id = v_account and cep.commitment_id = p_commitment_id;

  return jsonb_build_object(
    'commitment_id',       v_row.commitment_id,
    'version',             v_row.version,
    'hardens_at',          v_row.hardens_at,
    'is_late',             v_row.is_late,
    'is_hardened',         v_now >= v_row.hardens_at,
    'partner_count',       v_count,
    'approvals_required',  v_row.approvals_required,
    -- Honest rather than optimistic: a registered envelope whose roster cannot
    -- reach its own threshold has no accountability route either.
    'accountability_available',
      (not v_row.is_late) and v_row.withdrawn_at is null and v_count >= v_row.approvals_required,
    'policy_digest',       encode(v_row.policy_digest, 'hex'),
    'registered_at',       v_row.registered_at
  );
end;
$$;

-- Plan cancellation, the one legitimate easing operation, verified from
-- envelope fields alone rather than trusted from the client: an occurrence is
-- withdrawn exactly when EarnedKit withdraws it — not yet hardened, or its
-- eligible window has not opened (§4.6).
--
-- The predicate below mirrors the `planCancelled` case in EarnedKit's
-- State.applying. Unlike hardening it is not pinned by a shared fixture: it is
-- two comparisons with none of hardening's float, timezone or clamping
-- subtleties, and both sides are covered by their own tests. It is still a
-- duplicated rule, so change one and change the other.
create or replace function public.withdraw_plan_envelopes(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_now     timestamptz := now();
  v_ids     uuid[];
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  with withdrawn as (
    update public.contract_envelope e
       set withdrawn_at = v_now
     where e.account_id = v_account
       and e.plan_id = p_plan_id
       and e.withdrawn_at is null
       and (v_now < e.hardens_at or e.eligible_from > v_now)
    returning e.commitment_id
  )
  select coalesce(array_agg(commitment_id), '{}'::uuid[]) into v_ids from withdrawn;

  return jsonb_build_object('withdrawn', to_jsonb(v_ids), 'at', v_now);
end;
$$;
