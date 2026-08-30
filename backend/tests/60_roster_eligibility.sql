\set ON_ERROR_STOP on
\echo 'invariant 22: a contract may not be born impossible'
set time zone 'UTC';

begin;

-- Leftovers from a previous run's drills — vote_concurrency.sh commits an
-- account with partners and a resolved request — would skew the unqualified
-- counts below. This transaction rolls back, so deleting here is invisible
-- outside it. Requests go first: recipient rows reference partners without a
-- cascade, so a bare account delete would race its own cascade paths.
delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');

-- Mom accepts. Dave is asked and never answers. Chris accepts.
select public.nominate_partner('Mom',   'sms', '+14155550100');
select public.nominate_partner('Dave',  'sms', '+14155550101');
select public.nominate_partner('Chris', 'sms', '+14155550102');
select public.respond_to_invitation(test_token_for('Mom'), true);
select public.respond_to_invitation(test_token_for('Chris'), true);

select test_assert((select count(*) = 2 from public.partner where status = 'active'),
                   'two partners consented, one is still waiting');

-- MARK: - The case that motivated the invariant

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_partner_ids => array(select id from public.partner
                            where display_name in ('Mom', 'Dave', 'Chris'))) $$,
  '2 of Mom/Dave/Chris is refused while Dave has never answered');

select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_partner_ids => array(select id from public.partner where display_name = 'Mom')) $$,
  'a threshold larger than the roster is refused');

-- MARK: - What is allowed

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name in ('Mom', 'Chris')));
select test_assert(
  ((select public.register_contract_envelope(
      p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Run 30 minutes',
      p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
      p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
      p_partner_ids => array(select id from public.partner where display_name in ('Mom', 'Chris')),
      p_version => 2)) ->> 'accountability_available')::boolean,
  '2 of two consented partners is accepted and reports a live route');

-- An empty roster is not the same failure. It is every commitment made before
-- anyone has been nominated, and it reports honestly rather than being refused.
select test_assert(
  not ((select public.register_contract_envelope(
      p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000004', p_title => 'No partners yet',
      p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
      p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800))
   ->> 'accountability_available')::boolean,
  'a commitment with no roster registers, with no accountability route');

-- MARK: - Withdrawal afterwards is a different thing

-- Chris revokes after the contract above hardened in spirit: the threshold
-- stands, and the route simply becomes unavailable.
select public.revoke_partner((select id from public.partner where display_name = 'Chris'));
select test_assert(
  (select approvals_required = 2 from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'a partner leaving never lowers the threshold that was agreed');
select test_assert(
  not ((select public.envelope_status('aaaaaaaa-0000-0000-0000-000000000003'))
       ->> 'accountability_available')::boolean,
  'and the route reports itself unavailable once too few remain');
select test_assert(
  ((select public.envelope_status('aaaaaaaa-0000-0000-0000-000000000003'))
   ->> 'partner_count')::int = 1,
  'the reachable count is what is reported, not the roster length');

-- Still inside the correction window, so the contract can be corrected — but
-- not into an impossible one. The refusal names the two ways out.
select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Run 30 minutes',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
    p_partner_ids => array(select id from public.partner where display_name = 'Mom'),
    p_version => 3) $$,
  'a roster that lost a partner cannot be re-registered at the old threshold');

-- Lowering it is allowed, because the contract has not hardened.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Mom'),
  p_version => 3);
select test_assert(
  ((select public.envelope_status('aaaaaaaa-0000-0000-0000-000000000003'))
   ->> 'accountability_available')::boolean,
  'correcting the threshold before hardening restores a workable contract');

-- MARK: - A suppressed partner is not eligible either

select public.nominate_partner('Sam', 'sms', '+14155550105');
select public.respond_to_invitation(test_token_for('Sam'), false);
select test_raises($$
  select public.register_contract_envelope(
    p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000005', p_title => 'With a refuser',
    p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '4 hours',
    p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
    p_partner_ids => array(select id from public.partner where display_name = 'Sam')) $$,
  'someone who declined cannot be put on a roster');

rollback;
