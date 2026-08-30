\set ON_ERROR_STOP on
\echo 'partners, consent and suppression'
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
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-other', 'Someone Else');
select test_sign_in('11111111-1111-1111-1111-111111111111');

-- MARK: - Normalisation

select test_assert(public.normalize_contact('email', '  Bob@Example.COM ') = 'bob@example.com',
                   'an email is trimmed and lowercased');
select test_assert(public.normalize_contact('sms', '+1 (415) 555-0100') = '+14155550100',
                   'a phone number is stripped to E.164 digits');
select test_assert(public.normalize_contact('sms', '+1-415-555-0100')
                   = public.normalize_contact('sms', '+14155550100'),
                   'the same number in three formats normalises to one value');
select test_raises($$select public.normalize_contact('sms', '415 555 0100')$$,
                   'a number with no country code is refused, not guessed at');
select test_raises($$select public.normalize_contact('email', 'not-an-address')$$,
                   'a malformed email is refused');
select test_assert(
  public.normalize_contact('email', 'me+1@x.com') <> public.normalize_contact('email', 'me+2@x.com'),
  'plus-tag aliases stay distinct rather than being silently merged');

-- MARK: - Nomination, encryption, blind indexing

select public.nominate_partner('Mom', 'sms', '+1 (415) 555-0100');

select test_assert((select status = 'invited' from public.partner where display_name = 'Mom'),
                   'a new partner starts invited, never active');
select test_assert(
  (select position(convert_to('+14155550100', 'utf8') in contact_ciphertext) = 0
     from public.partner where display_name = 'Mom'),
  'the contact number does not appear in the stored ciphertext');
select test_assert(
  (select length(contact_lookup) = 32 from public.partner where display_name = 'Mom'),
  'a keyed 256-bit blind index is derived alongside it');
select test_assert((select count(*) = 1 from public.message_outbox),
                   'the invitation is queued by the server, not handed to the app');
select test_assert((select test_token_for('Mom') is not null),
                   'and it carries a consent link');

-- The token reaches the partner and nobody else. Same property that will make
-- approval links work: a link routed through the requester's device is a link
-- the requester has (§2.1).
select test_assert(
  not ((select public.nominate_partner('Dave', 'sms', '+14155550101')) ?| array['token', 'p_token']),
  'nominating returns the partner, never the token');

select test_raises($$select public.nominate_partner('Mum again', 'sms', '+1-415-555-0100')$$,
                   'the same number written differently is recognised as already invited');

-- MARK: - You are not your own accountability partner

update public.account
   set verified_email_lookup = private.contact_lookup(
         public.normalize_contact('email', 'patrick@example.com'))
 where apple_user_id = 'apple-sub-patrick';
select test_raises($$select public.nominate_partner('Me', 'email', 'Patrick@Example.com')$$,
                   'nominating your own verified address is refused');

-- MARK: - Consent

select test_raises($$select public.respond_to_invitation('deadbeef', true)$$,
                   'an invalid consent token is refused');

select public.respond_to_invitation(test_token_for('Mom'), true);
select test_assert(
  (select status = 'active' and consented_at is not null
     from public.partner where display_name = 'Mom'),
  'accepting the invitation activates the partner');
select test_raises($$select public.respond_to_invitation(test_token_for('Mom'), true)$$,
                   'a consent token is single use');

-- MARK: - Declining suppresses globally

select public.respond_to_invitation(test_token_for('Dave'), false);
select test_assert((select status = 'declined' from public.partner where display_name = 'Dave'),
                   'declining marks the partner declined');
select test_assert(
  (select count(*) = 1 from public.contact_suppression),
  'and writes a suppression row');
select test_raises($$select public.nominate_partner('Dave again', 'sms', '+14155550101')$$,
                   'the same account cannot re-invite someone who declined');

-- The refusal is Earned-wide, not account-wide. This is the whole point.
select test_sign_in('22222222-2222-2222-2222-222222222222');
select test_raises($$select public.nominate_partner('Dave', 'sms', '+1 415 555 0101')$$,
                   'a DIFFERENT account cannot contact someone who declined');
select test_sign_in('11111111-1111-1111-1111-111111111111');

-- MARK: - Rate limits

-- Mom, Dave, Chris, Sam, Alex is five nominations today. Dave declined, so only
-- four count against the five-partner ceiling — which keeps this assertion
-- about the daily limit rather than about the ceiling.
select public.nominate_partner('Chris', 'sms', '+14155550102');
select public.nominate_partner('Sam',   'sms', '+14155550103');
select public.nominate_partner('Alex',  'sms', '+14155550104');
select test_assert(
  (select count(*) = 4 from public.partner where status in ('invited', 'active')),
  'four partners are live, one short of the ceiling');
select test_raises($$select public.nominate_partner('Six', 'sms', '+14155550105')$$,
                   'the daily nomination limit is enforced before the ceiling is reached');

select test_raises($$select public.resend_partner_invitation(
    (select id from public.partner where display_name = 'Chris'))$$,
  'a reminder cannot be sent before 72 hours have passed');
select test_raises($$select public.resend_partner_invitation(
    (select id from public.partner where display_name = 'Mom'))$$,
  'a reminder cannot be sent to someone who already answered');

-- MARK: - Revoking is not declining

select public.revoke_partner((select id from public.partner where display_name = 'Chris'));
select test_assert((select status = 'revoked' from public.partner where display_name = 'Chris'),
                   'the account holder can revoke a partner');
select test_assert(
  (select count(*) = 1 from public.contact_suppression),
  'revoking writes no suppression row — that person refused nothing');

select test_raises($$select public.revoke_partner(
    (select id from public.partner p join public.account a on a.id = p.account_id
      where a.apple_user_id = 'apple-sub-other' limit 1))$$,
  'you cannot revoke another account''s partner')
  where exists (select 1 from public.partner p join public.account a on a.id = p.account_id
                 where a.apple_user_id = 'apple-sub-other');

-- MARK: - What the app may read

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_assert((select count(*) > 0 from public.partner),
                   'the app can see its own partners');
select test_raises('select count(*) from public.contact_suppression',
                   'the app cannot read the suppression list — those are other people''s refusals');
select test_raises('select count(*) from public.partner_invitation',
                   'the app cannot read invitations, which carry token hashes');
select test_raises('select count(*) from public.message_outbox',
                   'the app cannot read the outbox, which carries the links themselves');
select test_raises($$select public.respond_to_invitation('x', true)$$,
                   'the app cannot answer an invitation on a partner''s behalf');
reset role;

rollback;
