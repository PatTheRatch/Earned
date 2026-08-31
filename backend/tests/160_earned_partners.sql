\set ON_ERROR_STOP on
\echo 'earned-user partners: nominated through friendship, consented in-app, revoked by block'
set time zone 'UTC';

begin;

delete from public.override_request;
delete from public.account;
delete from public.message_outbox;

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

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');
select public.upsert_my_profile('patrick', 'Patrick');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-maya', 'Maya');
select public.upsert_my_profile('maya', 'Maya');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.ensure_account('apple-sub-dave', 'Dave');
select public.upsert_my_profile('dave', 'Dave');
select test_sign_in('44444444-4444-4444-4444-444444444444');
select public.ensure_account('apple-sub-lurker', 'Lurker');

-- Patrick and Maya are friends. Dave is not.
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);

-- MARK: - The ask travels through a friendship, or it does not travel

select test_sign_in('44444444-4444-4444-4444-444444444444');
select test_raises($$select public.nominate_earned_partner('patrick')$$,
                   'no profile, no nomination');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select public.nominate_earned_partner('patrick')$$,
                   'you are not your own accountability partner');
select test_raises($$select public.nominate_earned_partner('dave')$$,
                   'a friend request accepted is the prerequisite — a stranger is refused');
select test_raises($$select public.nominate_earned_partner('22222222-2222-2222-2222-222222222222')$$,
                   'an account uuid is not a handle and nominates nobody');

select public.nominate_earned_partner('maya');
select public.nominate_earned_partner('@Maya');
select test_assert((select count(*) = 1 from public.partner where kind = 'earned_user'),
                   'asking twice is one pending nomination');
select test_assert((select status = 'invited' and channel = 'earned'
                       and earned_account_id is not null
                       and contact_ciphertext is null and contact_lookup is null
                     from public.partner where kind = 'earned_user'),
                   'an earned partner is exactly an account — no contact material at all');
select test_assert((select count(*) = 0 from public.message_outbox),
                   'and no message goes out — the ask is delivered in-app');

select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_partners()) entry,
          jsonb_object_keys(entry) k
    where k not in ('id', 'display_name', 'channel', 'kind', 'status', 'handle',
                    'consent_asked_at', 'consented_at', 'consent_resent_at')),
  'my_partners exposes no account ids, no contact material, no blind indexes');
select test_assert(
  (select entry ->> 'handle' = 'maya'
     from jsonb_array_elements(public.my_partners()) entry
    where entry ->> 'kind' = 'earned_user'),
  'the earned partner carries their live handle — identity, not a copied label');

-- MARK: - Consent is the target''s authenticated act, and nobody else''s

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_partner_requests() -> 0 ->> 'requester_handle' = 'patrick',
                   'the asked person sees who is asking');
select test_assert(
  (select count(*) = 0
     from jsonb_array_elements(public.my_partner_requests()) entry,
          jsonb_object_keys(entry) k
    where k not in ('id', 'requester_handle', 'requester_display_name', 'asked_at')),
  'and exactly that — no auth ids, no apple subjects');

select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_raises(
  $$select public.respond_to_partner_request(
      (select id from public.partner where kind = 'earned_user'), true)$$,
  'only the nominated account can answer — nobody manufactures another''s consent');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_partner_request(
  (select id from public.partner where kind = 'earned_user'), true);
select test_assert((select status = 'active' and consented_at is not null
                     from public.partner where kind = 'earned_user'),
                   'acceptance activates the partnership');

-- MARK: - Friendship and accountability move independently (invariant 24)

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.remove_friend('maya');
select test_assert((select status = 'active' from public.partner where kind = 'earned_user'),
                   'removing the friendship does not revoke accountability');

select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.revoke_partner((select id from public.partner where kind = 'earned_user'));
select test_assert((select status = 'revoked' from public.partner where kind = 'earned_user'),
                   'the account holder can revoke an earned partner like any other');
select test_assert((select status = 'accepted' from public.friendship),
                   'and revoking accountability does not touch the friendship');

-- MARK: - Decline, and the deliberate re-ask divergence

select public.nominate_earned_partner('maya');
select test_assert((select count(*) = 1 from public.partner where kind = 'earned_user'),
                   'a re-ask reopens the same row — one relationship per pair, ever');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_partner_request(
  (select id from public.partner where kind = 'earned_user'), false);
select test_assert((select status = 'declined' from public.partner where kind = 'earned_user'),
                   'declining records declined, and writes no suppression row');
select test_assert((select count(*) = 0 from public.contact_suppression),
                   'there is no contact to suppress; block is the stop lever');

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_earned_partner('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_partner_request(
  (select id from public.partner where kind = 'earned_user'), true);

-- MARK: - A mixed roster: delivery splits, authority does not

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_partner('Mom', 'sms', '+14155550100');
select public.respond_to_invitation(test_token_for('Mom'), true);

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where status = 'active'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000001');

select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
  18, 30, 'minutes', 8, 10, 2, 1);

select test_assert((select count(*) = 2 from public.override_request_recipient),
                   'both kinds of partner become recipients');
select test_assert((select count(*) = 1 from public.message_outbox
                     where body like '%/a/%'),
                   'but only the external partner gets a link — Maya''s surface is in-app');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.my_pending_approvals() -> 0 ->> 'page' = 'request'
                   and public.my_pending_approvals() -> 0 -> 'snapshot' -> 'contract'
                         ->> 'commitment_title' = 'Run 30 minutes',
                   'the in-app ask renders the same frozen snapshot as the web page');

select test_sign_in('33333333-3333-3333-3333-333333333333');
select test_raises(
  $$select public.cast_override_vote_in_app(
      (select rc.id from public.override_request_recipient rc
        join public.partner p on p.id = rc.partner_id
       where p.kind = 'earned_user'), 'approve')$$,
  'a recipient id in someone else''s hands is worthless — the session is the credential');

select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_assert(public.cast_override_vote_in_app(
                     (select rc.id from public.override_request_recipient rc
                       join public.partner p on p.id = rc.partner_id
                      where p.kind = 'earned_user'), 'approve') ->> 'page' = 'receipt',
                   'an earned partner votes with their session and gets their receipt');
select test_sign_in('44444444-4444-4444-4444-444444444444');
select test_sign_out();
set local role service_role;
select test_assert(public.cast_override_vote(test_approval_token_for('Mom'), 'approve')
                     ->> 'page' = 'receipt',
                   'the token path is untouched — Mom votes exactly as before');
reset role;
select test_assert((select state = 'granted' from public.override_request),
                   'two approvals across the two kinds resolve the request');

-- MARK: - Block supersedes both systems, in both directions

-- Maya also nominates Patrick, so the reverse relationship exists too.
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.nominate_earned_partner('patrick');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.respond_to_partner_request(
  (select id from public.partner where earned_account_id =
    (select account_id from public.profile where handle = 'patrick')), true);

-- A second envelope frozen on the mixed roster, before the block.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Cycle 45 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where account_id = (select account_id from public.profile
                                               where handle = 'patrick')
                            and status = 'active'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000002');

select public.block_user('maya');
select test_assert((select count(*) = 2 from public.partner
                     where kind = 'earned_user' and status = 'revoked'),
                   'the block revokes the accountability between them, both directions');
select test_assert((select status = 'active' from public.partner where display_name = 'Mom'),
                   'and touches no external partner');
select test_assert((select state = 'granted' from public.override_request),
                   'the grant that already happened stays granted');
select test_assert((select count(*) = 2 from public.override_request_recipient
                     where vote = 'approve'),
                   'and the votes that explain it are still on the record');

select test_assert((public.envelope_status('aaaaaaaa-0000-0000-0000-000000000002')
                      ->> 'approvals_required')::int = 2,
                   'the frozen threshold does not lower');
select test_assert((public.envelope_status('aaaaaaaa-0000-0000-0000-000000000002')
                      ->> 'accountability_available')::boolean = false,
                   'the route becomes honestly unavailable instead');
select test_raises(
  $$select public.create_override_request(
      'bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002',
      1, 2, 'workouts', 8, 10, 2, 1)$$,
  'a new request against that contract is refused — Solo remains, as ever');

select test_raises($$select public.nominate_earned_partner('maya')$$,
                   'no new nomination across a block — it reads as any non-friend');

-- MARK: - Unblock does not resurrect authority

select public.unblock_user('maya');
select test_raises($$select public.nominate_earned_partner('maya')$$,
                   'unblocked strangers still cannot nominate — friendship first');
select public.send_friend_request('maya');
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.respond_to_friend_request('patrick', true);
select test_assert((select count(*) = 2 from public.partner
                     where kind = 'earned_user' and status = 'revoked'),
                   'refriending alone restores no authority — the rows stay revoked');
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_earned_partner('maya');
select test_assert((select status = 'invited' from public.partner
                     where account_id = (select account_id from public.profile
                                          where handle = 'patrick')
                       and kind = 'earned_user'),
                   'a fresh ask is required, and fresh consent after it');

-- MARK: - An external partner who later joins Earned is not merged

-- Dave joins Patrick''s friends. Nominating him creates a NEW earned
-- relationship; Mom''s external row — whoever she may be — is untouched.
-- Nothing infers that two identities are one person, whatever the names say.
select public.send_friend_request('dave');
select test_sign_in('33333333-3333-3333-3333-333333333333');
select public.respond_to_friend_request('patrick', true);
select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.nominate_earned_partner('dave');
select test_assert((select count(*) = 1 from public.partner where display_name = 'Mom'
                     and kind = 'unverified_contact' and status = 'active'),
                   'the external identity stands alone, unmerged and unaffected');

-- MARK: - Anon

set local role anon;
select test_sign_out();
select test_raises($$select public.nominate_earned_partner('maya')$$, 'anon nominates nobody');
select test_raises($$select public.my_partner_requests()$$, 'anon is asked nothing');
select test_raises($$select public.my_pending_approvals()$$, 'anon approves nothing');
select test_raises($$select public.my_partners()$$, 'anon has no partners');
reset role;

rollback;
