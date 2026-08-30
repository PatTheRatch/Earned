\set ON_ERROR_STOP on
\echo 'row level security: default deny'
set time zone 'UTC';

begin;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-other', 'Someone Else');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Patrick''s run',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800);

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Their run',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800);

-- MARK: anon sees nothing at all

set local role anon;
select test_sign_out();

select test_raises('select count(*) from public.account',           'anon cannot read accounts');
select test_raises('select count(*) from public.partner',           'anon cannot read partners');
select test_raises('select count(*) from public.contract_envelope', 'anon cannot read envelopes');
select test_raises('select count(*) from public.contract_envelope_partner',
                   'anon cannot read envelope rosters');
select test_raises($$insert into public.contract_envelope
  (account_id, commitment_id, title, created_at, eligible_from, deadline,
   correction_window, approvals_required, accountability_window, policy_digest, hardens_at)
  values (gen_random_uuid(), gen_random_uuid(), 'x', now(), now(), now() + interval '1 hour',
          0, 1, 0, '\x00'::bytea, now())$$,
  'anon cannot write an envelope');
select test_raises($$select public.register_contract_envelope(
    p_commitment_id => gen_random_uuid(), p_title => 'x', p_created_at => now(),
    p_eligible_from => now(), p_deadline => now() + interval '1 hour',
    p_correction_window => 0, p_approvals_required => 1, p_accountability_window => 0)$$,
  'anon cannot execute the register function');
reset role;

-- MARK: a signed-in caller sees its own rows and no others

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');

select test_assert((select count(*) from public.account) = 1,
                   'a signed-in caller sees only its own account');
select test_assert((select count(*) from public.contract_envelope) = 1,
                   'a signed-in caller sees only its own envelopes');
select test_assert(
  (select title from public.contract_envelope) = 'Patrick''s run',
  'and the one it sees is its own');

-- MARK: writes are refused for everyone, not merely filtered

select test_raises($$update public.contract_envelope set approvals_required = 1$$,
                   'a signed-in caller cannot lower its own threshold by direct update');
select test_raises($$update public.contract_envelope set is_late = false$$,
                   'a signed-in caller cannot clear its own late marking');
select test_raises($$delete from public.contract_envelope$$,
                   'a signed-in caller cannot delete an envelope');
select test_raises($$insert into public.contract_envelope
  (account_id, commitment_id, title, created_at, eligible_from, deadline,
   correction_window, approvals_required, accountability_window, policy_digest, hardens_at)
  values (gen_random_uuid(), gen_random_uuid(), 'forged', now(), now(), now() + interval '1 hour',
          0, 1, 0, '\x00'::bytea, now())$$,
  'a signed-in caller cannot insert an envelope directly');
select test_raises($$update public.account set display_name = 'Someone Else'$$,
                   'a signed-in caller cannot edit its account row directly');

-- Another account's envelope is not merely unreadable: naming it changes nothing.
select test_raises($$update public.contract_envelope
    set approvals_required = 1
  where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000002'$$,
  'naming another account''s envelope does not make it writable');

reset role;
select test_sign_out();

-- MARK: every table that exists has RLS on

select test_assert(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  'every table in public has row level security enabled');

-- MARK: no write policy exists anywhere

select test_assert(
  not exists (
    select 1 from pg_policies
     where schemaname = 'public' and cmd <> 'SELECT'),
  'no INSERT, UPDATE or DELETE policy exists — writes go through functions only');

rollback;
