\set ON_ERROR_STOP on
\echo 'grants: signed once, served only when signed, and only to their owner'
set time zone 'UTC';

begin;

-- Leftovers from the drills, which commit on purpose. This transaction rolls
-- back, so clearing them here is invisible outside it.
delete from public.override_request;
delete from public.account;
delete from public.message_outbox;
truncate public.server_grant, public.grant_signing_key, public.key_set cascade;

create or replace function test_b64(p_n int) returns text
language sql volatile
set search_path = public, extensions, pg_temp
as $$ select replace(encode(gen_random_bytes(p_n), 'base64'), chr(10), '') $$;

create or replace function test_advance_past_hardening(p_commitment_id uuid) returns void
language plpgsql as $$
begin
  update public.contract_envelope
     set created_at    = created_at - interval '4 hours',
         eligible_from = eligible_from - interval '4 hours',
         first_seen_at = first_seen_at - interval '4 hours'
   where commitment_id = p_commitment_id;
end;
$$;

-- MARK: - A resolved request to grant against

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.nominate_partner('Mom',  'sms', '+14155550100');
select public.nominate_partner('Dave', 'sms', '+14155550101');
select public.respond_to_invitation(test_token_for('Mom'),  true);
select public.respond_to_invitation(test_token_for('Dave'), true);

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name in ('Mom','Dave')));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000001');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1, 'Knee started bothering me.');

-- MARK: - No key, no grant

select test_assert(
  public.my_grants() = '[]'::jsonb,
  'an open request has no grant to serve');

select public.cast_override_vote(test_approval_token_for('Mom'),  'approve');
select public.cast_override_vote(test_approval_token_for('Dave'), 'approve');
select test_assert((select state = 'granted' from public.override_request),
                   'two approvals resolved the request');

select test_raises($$select public.my_grants()$$,
  'a resolved request with no signing key raises rather than minting an unsignable grant');
select test_assert((select count(*) = 0 from public.server_grant),
                   'and no half-made grant row was left behind');

-- MARK: - With a key, a grant appears — unsigned

set local role service_role;
select public.introduce_grant_key('g1', test_b64(32));
select public.publish_key_set(public.build_key_set_document(), test_b64(64));
select public.promote_grant_key('g1');
-- And published again, because a promotion nobody was told about is a key no
-- client will honour a signature from (0012).
select public.publish_key_set(public.build_key_set_document(), test_b64(64));
reset role;
select test_sign_in('11111111-1111-1111-1111-111111111111');

select test_assert(
  public.my_grants() = '[]'::jsonb,
  'a grant with no signature yet is served to nobody');
select test_assert((select count(*) = 1 from public.server_grant),
                   'but the document was built and frozen, waiting for a signature');
select test_assert(
  (select signature is null and signed_at is null from public.server_grant),
  'and it is honestly unsigned rather than half-signed');

-- MARK: - What the document says

select test_assert(
  (select (document::jsonb ->> 'decision') = 'granted' from public.server_grant),
  'the document records the decision');
select test_assert(
  (select (document::jsonb ->> 'kid') = 'g1' from public.server_grant),
  'and names the key that will sign it, fixed before signing');
select test_assert(
  (select (document::jsonb ->> 'client_request_id')::uuid
            = 'bbbbbbbb-0000-0000-0000-000000000001' from public.server_grant),
  'and the ledger request id the app will match it against');
select test_assert(
  (select document::jsonb ->> 'policy_digest' ~ '^sha256:[0-9a-f]+$'
     from public.server_grant),
  'and the digest of the contract it was granted against');
select test_assert(
  (select jsonb_array_length(document::jsonb -> 'roster') = 2 from public.server_grant),
  'the roster carries both votes');
select test_assert(
  (select bool_and(r ->> 'vote' = 'approve')
     from public.server_grant g, jsonb_array_elements(g.document::jsonb -> 'roster') r),
  'and each says how that partner voted');
select test_assert(
  (select (document::jsonb -> 'roster' -> 0) ? 'partner_display_name'
     from public.server_grant),
  'by name, because the requester is being told who let them out');
select test_assert(
  (select not (document::jsonb ? 'signature') from public.server_grant),
  'the document does not contain its own signature — it could not have been signed if it did');

-- MARK: - Signing happens once

set local role service_role;
select test_assert(
  (select jsonb_array_length(public.unsigned_grants()) = 1),
  'the signer is offered exactly the unsigned document');

select test_assert(
  (public.store_override_grant(
     (select id from public.server_grant), test_b64(64)) ->> 'signed')::boolean,
  'a signature can be attached');
select test_assert(
  not (public.store_override_grant(
        (select id from public.server_grant), test_b64(64)) ->> 'signed')::boolean,
  'but never replaced — an app may already have verified and recorded the first');
select test_assert(
  (select jsonb_array_length(public.unsigned_grants()) = 0),
  'and the signer is not offered it twice');
select test_assert(
  (select count(*) = 1 from public.override_request_event where kind = 'granted'),
  'signing is recorded in the audit log, once');
reset role;

-- MARK: - Now it is served, and it is idempotent

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert(
  jsonb_array_length(public.my_grants()) = 1,
  'a signed grant is served to its owner');
select test_assert(
  (public.my_grants() -> 0 ->> 'commitment_id')::uuid
    = 'aaaaaaaa-0000-0000-0000-000000000001',
  'named by the commitment it releases, which is what the app is holding');
select test_assert(
  (public.my_grants() -> 0 ->> 'document') = (select document from public.server_grant),
  'served byte-for-byte as signed, so the app verifies what it will parse');

select public.my_grants();
select test_assert((select count(*) = 1 from public.server_grant),
                   'polling repeatedly re-serves one grant rather than minting more (§9.4)');

-- MARK: - Someone else's grant is not yours

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-nina', 'Nina');
select test_assert(public.my_grants() = '[]'::jsonb,
                   'another account sees none of it');

-- MARK: - Who may call what

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select count(*) from public.server_grant$$,
                   'the account holder cannot read the grant table');
select test_raises($$update public.server_grant set signature = null$$,
                   'nor unsign one');
select test_raises($$select public.unsigned_grants()$$,
                   'nor ask what is waiting to be signed');
select test_raises($$select public.store_override_grant(gen_random_uuid(), 'x')$$,
                   'and above all cannot sign — that is the line this design exists to draw');
select test_raises($$select private.grant_document(gen_random_uuid(), gen_random_uuid(), 'g1')$$,
                   'nor compose a document to be signed');
reset role;

set local role anon;
select test_sign_out();
select test_raises($$select public.my_grants()$$, 'anon has no grants to ask about');
select test_raises($$select count(*) from public.server_grant$$,
                   'anon cannot read the grant table');
reset role;

rollback;
