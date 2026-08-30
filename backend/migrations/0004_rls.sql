-- Row Level Security: default deny, everywhere, no exceptions.
--
-- The posture is not "policies that filter writes". It is that no client role
-- holds write permission on any of these tables at all. Everything a client
-- can change goes through a SECURITY DEFINER function (0003) that re-derives
-- the account from the JWT and enforces the contract rules itself.
--
-- `anon` gets nothing. `authenticated` gets SELECT on its own rows, so the app
-- can show what the server believes, and nothing else.

-- Every statement in this file is written to converge on re-run: a migration
-- set that jams halfway through is worse than one that can simply be applied
-- again.
alter table public.account                   enable row level security;
alter table public.partner                   enable row level security;
alter table public.contract_envelope         enable row level security;
alter table public.contract_envelope_partner enable row level security;

-- Start from zero rather than trusting the defaults of whatever role setup
-- this lands in.
revoke all on public.account                   from anon, authenticated;
revoke all on public.partner                   from anon, authenticated;
revoke all on public.contract_envelope         from anon, authenticated;
revoke all on public.contract_envelope_partner from anon, authenticated;

grant select on public.account                   to authenticated;
grant select on public.partner                   to authenticated;
grant select on public.contract_envelope         to authenticated;
grant select on public.contract_envelope_partner to authenticated;

-- Read your own account, and only while it exists.
drop policy if exists account_select_own on public.account;
create policy account_select_own on public.account
  for select to authenticated
  using (auth_user_id = auth.uid() and deleted_at is null);

-- Partner rows are readable by the account that nominated them. Note what is
-- readable: display name, channel, kind, consent timestamps. The contact
-- ciphertext and its blind index are columns on this table, so a future change
-- that widens what the app reads would expose them — column-level grants are
-- the follow-up when the consent flow lands (§14.1).
drop policy if exists partner_select_own on public.partner;
create policy partner_select_own on public.partner
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = partner.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

drop policy if exists contract_envelope_select_own on public.contract_envelope;
create policy contract_envelope_select_own on public.contract_envelope
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = contract_envelope.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

drop policy if exists contract_envelope_partner_select_own on public.contract_envelope_partner;
create policy contract_envelope_partner_select_own on public.contract_envelope_partner
  for select to authenticated
  using (exists (select 1 from public.account a
                  where a.id = contract_envelope_partner.account_id
                    and a.auth_user_id = auth.uid()
                    and a.deleted_at is null));

-- Deliberately absent: every INSERT, UPDATE and DELETE policy. With RLS on and
-- no permissive policy for a command, that command is refused. Adding one here
-- would hand the threshold back to the client and undo the whole design.

-- Creating your own account row is the one thing a signed-in caller must be
-- able to do before it has an account to be scoped by, so it too is a function
-- rather than a policy.
create or replace function public.ensure_account(
  p_apple_user_id text,
  p_display_name  text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row public.account;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  insert into public.account (auth_user_id, apple_user_id, display_name)
       values (auth.uid(), p_apple_user_id, p_display_name)
  on conflict (auth_user_id) do update
          set display_name = excluded.display_name
    returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'display_name', v_row.display_name,
                            'created_at', v_row.created_at);
end;
$$;

revoke all on function public.ensure_account(text, text) from public, anon;
revoke all on function public.register_contract_envelope(
  uuid, text, timestamptz, timestamptz, timestamptz,
  double precision, int, double precision, uuid[], uuid, int) from public, anon;
revoke all on function public.withdraw_plan_envelopes(uuid) from public, anon;

grant execute on function public.ensure_account(text, text) to authenticated;
grant execute on function public.register_contract_envelope(
  uuid, text, timestamptz, timestamptz, timestamptz,
  double precision, int, double precision, uuid[], uuid, int) to authenticated;
grant execute on function public.withdraw_plan_envelopes(uuid) to authenticated;
