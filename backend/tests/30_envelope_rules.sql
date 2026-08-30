\set ON_ERROR_STOP on
\echo 'contract envelope rules'
set time zone 'UTC';

begin;

-- Two accounts, so "your own" is actually tested against someone else's rows.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-other', 'Someone Else');

select test_assert((select count(*) from public.account) = 2, 'two accounts exist');

-- ensure_account is idempotent: signing in again must not mint a second row.
select public.ensure_account('apple-sub-other', 'Someone Else');
select test_assert((select count(*) from public.account) = 2,
                   'signing in again updates rather than duplicates the account');

select test_sign_in('11111111-1111-1111-1111-111111111111');

-- A partner belonging to Patrick, and one belonging to the other account.
insert into public.partner (account_id, display_name, channel, contact_ciphertext, contact_lookup)
select a.id, 'Mom', 'sms', '\x00'::bytea, '\x01'::bytea
  from public.account a where a.apple_user_id = 'apple-sub-patrick';
insert into public.partner (account_id, display_name, channel, contact_ciphertext, contact_lookup)
select a.id, 'Stranger', 'sms', '\x00'::bytea, '\x02'::bytea
  from public.account a where a.apple_user_id = 'apple-sub-other';

-- MARK: registering an envelope

-- Created now, due in four hours, two-hour configured window. The clamp binds
-- at 4h x 0.125 = 30 minutes, so this is comfortably unhardened.
select public.register_contract_envelope(
  p_commitment_id         => 'aaaaaaaa-0000-0000-0000-000000000001',
  p_title                 => 'Run 30 minutes',
  p_created_at            => now(),
  p_eligible_from         => now(),
  p_deadline              => now() + interval '4 hours',
  p_correction_window     => 7200,
  p_approvals_required    => 2,
  p_accountability_window => 1800);

select test_assert(
  (select hardens_at from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001')
  between now() + interval '29 minutes' and now() + interval '31 minutes',
  'hardening is computed by the server, not accepted from the caller');

select test_assert(
  (select not is_late from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'an envelope registered before hardening is not late');

-- MARK: the client cannot hand the server a hardening instant

-- hardens_at is trigger-computed. Even a direct write as the table owner, which
-- is more access than any client has, cannot plant one.
update public.contract_envelope
   set hardens_at = now() - interval '10 years'
 where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001';
select test_assert(
  (select hardens_at from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001') > now(),
  'a supplied hardening instant is discarded and recomputed');

-- MARK: monotonicity, enforced where the user cannot reach it

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
    p_version => 2) $$,
  'lowering the approval threshold is refused');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '9 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_version => 2) $$,
  'moving the deadline later is refused');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 60,
    p_version => 2) $$,
  'shortening the accountability window is refused');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 3, p_accountability_window => 1800,
    p_version => 1) $$,
  'a version that does not increase is refused, even for a harder edit');

-- The harder edit itself is accepted.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '3 hours',
  p_correction_window => 3600, p_approvals_required => 3, p_accountability_window => 3600,
  p_version => 2);
select test_assert(
  (select approvals_required = 3 and version = 2 from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'a harder edit before hardening is accepted');

-- MARK: rosters

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Someone else''s partner',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_partner_ids => array(select id from public.partner where display_name = 'Stranger')) $$,
  'a roster naming another account''s partner is refused');

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'With a partner',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Mom'));

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'With a partner',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_partner_ids => '{}'::uuid[], p_version => 2) $$,
  'removing a partner before hardening is refused');

-- MARK: the freeze, and the late marking

-- Created three hours ago with a short fuse, so it hardened long before the
-- server ever heard of it. This is S13.
select public.register_contract_envelope(
  p_commitment_id         => 'aaaaaaaa-0000-0000-0000-000000000004',
  p_title                 => 'Registered too late',
  p_created_at            => now() - interval '3 hours',
  p_eligible_from         => now() - interval '3 hours',
  p_deadline              => now() + interval '1 hour',
  p_correction_window     => 900,
  p_approvals_required    => 2,
  p_accountability_window => 1800);

select test_assert(
  (select is_late from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000004'),
  'an envelope that arrives after hardening is marked late');

select test_assert(
  (select not (public.register_contract_envelope(
     p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000005', p_title => 'Late too',
     p_created_at => now() - interval '3 hours', p_eligible_from => now() - interval '3 hours',
     p_deadline => now() + interval '1 hour', p_correction_window => 900,
     p_approvals_required => 1, p_accountability_window => 1800,
     p_partner_ids => array(select id from public.partner where display_name = 'Mom'))
   ->> 'accountability_available')::boolean),
  'a late envelope reports no accountability route even with a reachable roster');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000004', p_title => 'Registered too late',
    p_created_at => now() - interval '3 hours', p_eligible_from => now() - interval '3 hours',
    p_deadline => now() + interval '1 hour', p_correction_window => 900,
    p_approvals_required => 5, p_accountability_window => 3600, p_version => 2) $$,
  'a hardened envelope is frozen even against a harder edit');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-00000000000f', p_title => 'From the future',
    p_created_at => now() + interval '2 days', p_eligible_from => now() + interval '2 days',
    p_deadline => now() + interval '3 days', p_correction_window => 7200,
    p_approvals_required => 2, p_accountability_window => 1800) $$,
  'a creation instant well in the future is refused');

-- MARK: honest reporting

select test_assert(
  (select not (public.register_contract_envelope(
     p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000006', p_title => 'No roster',
     p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
     p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800)
   ->> 'accountability_available')::boolean),
  'an empty roster reports no accountability route rather than pretending');

-- MARK: plan withdrawal, decided from envelope fields alone

select public.register_contract_envelope(
  p_commitment_id => 'bbbbbbbb-0000-0000-0000-000000000001', p_title => 'Monday',
  p_created_at => now() - interval '3 hours', p_eligible_from => now() - interval '3 hours',
  p_deadline => now() + interval '1 hour', p_correction_window => 900,
  p_approvals_required => 2, p_accountability_window => 1800,
  p_plan_id => 'cccccccc-0000-0000-0000-000000000001');

select public.register_contract_envelope(
  p_commitment_id => 'bbbbbbbb-0000-0000-0000-000000000002', p_title => 'Next week',
  p_created_at => now() - interval '3 hours', p_eligible_from => now() + interval '5 days',
  p_deadline => now() + interval '6 days', p_correction_window => 900,
  p_approvals_required => 2, p_accountability_window => 1800,
  p_plan_id => 'cccccccc-0000-0000-0000-000000000001');

select public.withdraw_plan_envelopes('cccccccc-0000-0000-0000-000000000001');

select test_assert(
  (select withdrawn_at is null from public.contract_envelope
    where commitment_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  'cancelling a plan spares an occurrence already inside its window');
select test_assert(
  (select withdrawn_at is not null from public.contract_envelope
    where commitment_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  'cancelling a plan withdraws an occurrence whose window has not opened');

-- MARK: no account, no envelope

select test_sign_out();
select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-00000000000e', p_title => 'Anonymous',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800) $$,
  'an unauthenticated caller cannot register anything');

rollback;
