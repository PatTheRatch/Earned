-- A contract may not be born impossible.
--
-- NORTHSTAR invariant 22. An accountability roster is fixed at creation from
-- partners who have *already consented*, and the threshold may never exceed
-- that roster. Hardening "2 of Mom, Dave, Chris" while Dave has never answered
-- would create a contract whose accountability route was dead from birth — and
-- the user would not find out until the moment they needed it.
--
-- A partner who withdraws *afterwards* is a different thing entirely: the deal
-- was real when it hardened, the threshold stands, and the route becomes
-- unavailable if too few remain (§4.3). Earned refuses to author an impossible
-- contract; it does not rewrite one that reality made harder.
--
-- This also corrects a Milestone A bug. 0003 enforced harder-only edits at all
-- times, including *before* hardening — but EarnedKit allows free edits inside
-- the correction window, which is the entire purpose of that window. A user
-- fixing "10 miles" to "10 km" two minutes after committing would have had the
-- edit accepted by the ledger and refused by the server, leaving the commitment
-- stuck unregistered. The restriction also bought nothing: before hardening the
-- user can cancel and recreate, so nothing was being defended. Monotonicity is
-- now enforced exactly where EarnedKit enforces it — from the hardening instant
-- on, where the envelope freezes entirely.

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
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account  uuid;
  v_now      timestamptz := now();
  v_hardens  timestamptz;
  v_existing public.contract_envelope;
  v_row      public.contract_envelope;
  v_is_late  boolean;
  v_bad      int;
  v_eligible int;
  v_count    int;
begin
  select a.id into v_account
    from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  -- A roster is a list of this account's own partners, or it is nothing.
  -- Checked before anything is written, so a probe cannot confirm the
  -- existence of another account's partner id.
  select count(*) into v_bad
    from unnest(p_partner_ids) pid
   where not exists (select 1 from public.partner p
                      where p.id = pid and p.account_id = v_account);
  if v_bad > 0 then
    raise exception 'roster contains partners that do not belong to this account'
      using errcode = '42501';
  end if;

  -- Invariant 22, first half: only consented partners may be counted on.
  select count(*) into v_bad
    from public.partner p
   where p.id = any (p_partner_ids)
     and (p.status <> 'active'
          or exists (select 1 from public.contact_suppression s
                      where s.contact_lookup = p.contact_lookup
                        and s.channel = p.channel));
  if v_bad > 0 then
    raise exception
      'every partner on a roster must have accepted their invitation first'
      using errcode = '23514';
  end if;

  v_eligible := coalesce(array_length(p_partner_ids, 1), 0);

  -- Invariant 22, second half: a threshold must be reachable by the roster it
  -- is a threshold *of*.
  --
  -- An empty roster is exempt, and is not the same failure. "2 of Mom and Dave,
  -- one of whom never answered" is a contract that looks like it has a route
  -- and does not — the user would only discover it at the moment they needed
  -- it. "No partners yet" is simply a commitment with no accountability route,
  -- which is every commitment for every user until they nominate someone, and
  -- the receipt says so plainly rather than pretending.
  if v_eligible > 0 and p_approvals_required > v_eligible then
    raise exception
      'this needs % approvals but only % consented partner(s) are on it — add another '
      'partner who has accepted, or lower the threshold before it hardens',
      p_approvals_required, v_eligible
      using errcode = '23514';
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
    if p_created_at > v_now + interval '5 minutes' then
      raise exception 'creation instant is too far in the future' using errcode = '22008';
    end if;

    -- S13. Registered after the contract had already hardened, so the server
    -- cannot tell an honest offline creation from terms chosen with hindsight.
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

    -- No monotonicity checks here, deliberately. Everything above this point
    -- has established that the contract has NOT hardened, and inside the
    -- correction window EarnedKit permits any edit — that window exists so a
    -- commitment made in haste can be corrected. Refusing an easing edit here
    -- while the ledger accepts it would strand the commitment unregistered,
    -- and would defend nothing: an unhardened commitment can simply be
    -- cancelled and remade. The freeze above is where monotonicity lives, and
    -- it is absolute.

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

    delete from public.contract_envelope_partner cep
     where cep.account_id = v_account
       and cep.commitment_id = p_commitment_id
       and cep.partner_id <> all (p_partner_ids);
  end if;

  insert into public.contract_envelope_partner (account_id, commitment_id, partner_id)
       select v_account, p_commitment_id, pid from unnest(p_partner_ids) pid
  on conflict do nothing;

  -- Reachable, not merely listed. A roster member who has since revoked is
  -- still on the contract and still cannot be asked, and reporting them as
  -- available would be the exact overstatement §4.3 exists to prevent.
  select count(*) into v_count
    from public.contract_envelope_partner cep
    join public.partner p on p.id = cep.partner_id
   where cep.account_id = v_account and cep.commitment_id = p_commitment_id
     and p.status = 'active'
     and not exists (select 1 from public.contact_suppression s
                      where s.contact_lookup = p.contact_lookup and s.channel = p.channel);

  return jsonb_build_object(
    'commitment_id',      v_row.commitment_id,
    'version',            v_row.version,
    'hardens_at',         v_row.hardens_at,
    'is_late',            v_row.is_late,
    'is_hardened',        v_now >= v_row.hardens_at,
    'partner_count',      v_count,
    'approvals_required', v_row.approvals_required,
    'accountability_available',
      (not v_row.is_late) and v_row.withdrawn_at is null and v_count >= v_row.approvals_required,
    'policy_digest',      encode(v_row.policy_digest, 'hex'),
    'registered_at',      v_row.registered_at
  );
end;
$$;

revoke all on function public.register_contract_envelope(
  uuid, text, timestamptz, timestamptz, timestamptz,
  double precision, int, double precision, uuid[], uuid, int) from public, anon;
grant execute on function public.register_contract_envelope(
  uuid, text, timestamptz, timestamptz, timestamptz,
  double precision, int, double precision, uuid[], uuid, int) to authenticated;

-- MARK: - Reading a contract's live standing

-- Registration returns the state at the moment of registration. That is not
-- enough on its own: a roster member can revoke afterwards, and the contract's
-- accountability route can go from live to unavailable without the app doing
-- anything at all. Without a read path the app would keep showing the answer it
-- was given when it registered, which would be the exact overstatement §4.3
-- exists to prevent.
create or replace function public.envelope_status(p_commitment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_row     public.contract_envelope;
  v_now     timestamptz := now();
  v_count   int;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  select * into v_row from public.contract_envelope e
   where e.account_id = v_account and e.commitment_id = p_commitment_id;
  if v_row.commitment_id is null then
    return jsonb_build_object('commitment_id', p_commitment_id, 'registered', false);
  end if;

  select count(*) into v_count
    from public.contract_envelope_partner cep
    join public.partner p on p.id = cep.partner_id
   where cep.account_id = v_account and cep.commitment_id = p_commitment_id
     and p.status = 'active'
     and not exists (select 1 from public.contact_suppression s
                      where s.contact_lookup = p.contact_lookup and s.channel = p.channel);

  return jsonb_build_object(
    'commitment_id',      v_row.commitment_id,
    'registered',         true,
    'version',            v_row.version,
    'hardens_at',         v_row.hardens_at,
    'is_late',            v_row.is_late,
    'is_hardened',        v_now >= v_row.hardens_at,
    'partner_count',      v_count,
    'approvals_required', v_row.approvals_required,
    'accountability_available',
      (not v_row.is_late) and v_row.withdrawn_at is null and v_count >= v_row.approvals_required,
    'policy_digest',      encode(v_row.policy_digest, 'hex'),
    'registered_at',      v_row.registered_at);
end;
$$;

revoke all on function public.envelope_status(uuid) from public, anon;
grant execute on function public.envelope_status(uuid) to authenticated;
