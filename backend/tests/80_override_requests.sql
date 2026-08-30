\set ON_ERROR_STOP on
\echo 'override requests: the policy comes from the envelope, the token never comes back'
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

-- `now()` is frozen for the whole transaction, and an envelope is marked late
-- the moment it is registered at or after its own hardening time (S13). So a
-- contract that was registered honestly and has *since* hardened cannot exist
-- inside one transaction without help.
--
-- The help is to move the commitment's *creation* time into the past and let
-- the server recompute from it. `hardens_at` cannot be written directly — a
-- trigger recomputes it unconditionally on every insert and update, which is
-- exactly the protection that keeps it beyond a client's reach — so this
-- advances the clock the rule reads and never the rule itself. `is_late` was
-- decided honestly at registration and is deliberately left alone.
create or replace function test_advance_past_hardening(p_commitment_id uuid) returns void
language plpgsql as $$
begin
  update public.contract_envelope
     set created_at    = created_at - interval '4 hours',
         eligible_from = eligible_from - interval '4 hours',
         first_seen_at = first_seen_at - interval '4 hours'
   where commitment_id = p_commitment_id;

  if not exists (select 1 from public.contract_envelope
                  where commitment_id = p_commitment_id and hardens_at < now()) then
    raise exception 'test setup: % did not end up hardened', p_commitment_id;
  end if;
end;
$$;

-- pgcrypto lives in `extensions` on Supabase and in `public` on a bare
-- Postgres, so the test's own hashing has to name both — the same trap the
-- migrations were fixed for, and the reason the suite runs both layouts.
create or replace function test_sha256(p_text text) returns bytea
language sql volatile
set search_path = public, extensions, pg_temp
as $$ select digest(p_text, 'sha256') $$;

select test_sign_in('11111111-1111-1111-1111-111111111111');
select public.ensure_account('apple-sub-patrick', 'Patrick');

select public.nominate_partner('Mom',   'sms', '+14155550100');
select public.nominate_partner('Dave',  'sms', '+14155550101');
select public.nominate_partner('Chris', 'sms', '+14155550102');
select public.respond_to_invitation(test_token_for('Mom'),   true);
select public.respond_to_invitation(test_token_for('Dave'),  true);
select public.respond_to_invitation(test_token_for('Chris'), true);

-- 2 of Mom, Dave and Chris. The threshold this contract hardened at.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000001', p_title => 'Run 30 minutes',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where display_name in ('Mom', 'Dave', 'Chris')));

-- MARK: - Nothing to appeal to

select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000ffff',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a commitment with no envelope cannot be appealed — absence is never permission');

select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a commitment that has not hardened yet is refused — edit or cancel it instead');

-- A contract registered after it had already hardened keeps the Solo route and
-- loses the accountability one, permanently (S13).
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000002', p_title => 'Registered late',
  p_created_at => now() - interval '6 hours', p_eligible_from => now() - interval '6 hours',
  p_deadline => now() + interval '2 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where display_name in ('Mom', 'Dave', 'Chris')));
select test_assert((select is_late from public.contract_envelope
                     where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
                   'an envelope that arrives after hardening is marked late');
select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a late envelope has no accountability route — being offline can close one, never open one');

-- MARK: - The happy path

select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000001');

select test_assert(
  (public.create_override_request(
     'bbbbbbbb-0000-0000-0000-000000000010', 'aaaaaaaa-0000-0000-0000-000000000001',
     18, 30, 'minutes', 8, 10, 2, 1, 'Knee started bothering me.')
   ->> 'partners_notified')::int = 3,
  'a hardened contract with three consented partners asks all three');

select test_assert(
  (select (payload -> 'contract' ->> 'approvals_required')::int = 2
     from public.override_request_snapshot),
  'the snapshot carries the threshold the contract hardened at');
select test_assert(
  (select approvals_required = 2 from public.override_request),
  'and the request copies it from the envelope, not from anything the client sent');

-- MARK: - The threshold has no client-facing surface at all

-- The launch gate is "no code path reads a threshold, roster, window or
-- deadline from a client request body". The strongest form of that is a
-- function with nowhere to put one, asserted against the catalogue rather
-- than against a reading of the source.
select test_assert(
  not exists (
    select 1 from pg_proc p, unnest(p.proargnames) as n
     where p.proname = 'create_override_request'
       and n ~* '(approval|threshold|roster|partner|window|deadline|harden|version)'),
  'create_override_request has no parameter that could carry a policy term');

-- MARK: - The token is the partner's, never the requester's

select test_assert(
  (select public.create_override_request(
     'bbbbbbbb-0000-0000-0000-000000000010', 'aaaaaaaa-0000-0000-0000-000000000001',
     18, 30, 'minutes', 8, 10, 2, 1)::text) !~ '/a/',
  'the response to the requesting device contains no approval link');
select test_assert(
  (select count(*) = 0 from public.override_request_recipient rc
    where rc.token_hash is null),
  'every recipient row holds a token hash');
select test_assert(
  length(test_approval_token_for('Mom')) = 43
    and test_approval_token_for('Mom') ~ '^[A-Za-z0-9_-]+$',
  'the minted token is 43 base64url characters — 256 bits of CSPRNG');
select test_assert(
  test_approval_token_for('Mom') <> test_approval_token_for('Dave'),
  'each partner gets their own token');
select test_assert(
  (select count(*) = 1 from public.override_request_recipient rc
    where rc.token_hash = test_sha256(test_approval_token_for('Mom'))),
  'the stored hash is the sha256 of the token in the message, and only the hash is stored');
select test_assert(
  not exists (select 1 from public.override_request_recipient rc
               where encode(rc.token_hash, 'escape') ~ 'earned\.test'),
  'no raw token is stored anywhere on the recipient row');

-- MARK: - Idempotent creation

select test_assert(
  ((select public.create_override_request(
      'bbbbbbbb-0000-0000-0000-000000000010', 'aaaaaaaa-0000-0000-0000-000000000001',
      18, 30, 'minutes', 8, 10, 2, 1)) ->> 'created')::boolean is false,
  'replaying a client_request_id returns the same request rather than making a second');
select test_assert(
  (select count(*) = 1 from public.override_request),
  'and there is still exactly one request');
select test_assert(
  (select count(*) = 3 from public.message_outbox where body ~ '/a/'),
  'and three people were messaged once, not twice — a retry never re-pesters a roster');

-- MARK: - One open request per commitment

select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000001',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a second open request for the same commitment is refused');

-- MARK: - The snapshot is frozen, and split by who is asserting what

select test_assert(
  (select payload -> 'contract' ->> 'commitment_title' = 'Run 30 minutes'
     from public.override_request_snapshot),
  'the contract half of the snapshot comes from the envelope');
select test_assert(
  (select payload -> 'self_reported' -> 'progress' ->> 'achieved' = '18'
     from public.override_request_snapshot),
  'the self-reported half carries what the device claimed');
select test_assert(
  (select not (payload -> 'contract' ? 'reason')
      and not (payload -> 'contract' ? 'progress')
     from public.override_request_snapshot),
  'nothing the device reported leaks into the half a partner is told to trust');

-- The contract underneath can still move — a harder-only edit, a new version.
-- The snapshot must not follow it. If Patrick logs 12 more minutes after
-- asking, or the title changes, the page still shows what was asked, because
-- otherwise the human is answering a question nobody put to them (§7).
update public.contract_envelope
   set title = 'Run 45 minutes', approvals_required = 3
 where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001';

select test_assert(
  (select payload -> 'contract' ->> 'commitment_title' = 'Run 30 minutes'
     from public.override_request_snapshot),
  'the frozen snapshot does not follow a later change to the contract');
select test_assert(
  (select payload -> 'contract' ->> 'approvals_required' = '2'
     from public.override_request_snapshot),
  'nor a later change to the threshold — partners were asked about the contract as it stood');
select test_assert(
  (select approvals_required = 2 from public.override_request),
  'and the in-flight request keeps the bar it was created against');

-- MARK: - Hostile text (§13)

select test_assert(
  (select payload -> 'self_reported' ->> 'reason' = 'Knee started bothering me.'
     from public.override_request_snapshot),
  'an ordinary reason survives intact');
select test_assert(
  private.neutralise_text('check https://evil.example/pay now', 280) = 'check [link removed] now',
  'a URL in the reason is neutralised — Earned never lends credibility to a link it did not author');
select test_assert(
  private.neutralise_text('go to www.evil.example please', 280) = 'go to [link removed] please',
  'and so is a bare www host');
select test_assert(
  private.neutralise_text('pay me at evil.example/now ok', 280) = 'pay me at [link removed] ok',
  'and so is a bare domain with a path');
select test_assert(
  length(private.neutralise_text(repeat('a', 400), 280)) = 280,
  'an over-long reason is capped rather than refused — the field is optional, not a trap');

-- MARK: - The roster is re-filtered at request time, and the bar never drops

select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000003', p_title => 'Second run',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner
                          where display_name in ('Mom', 'Dave')));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000003');

-- Dave withdraws after the contract was registered. Invariant 22 guaranteed he
-- had consented at registration; it does not follow him forever.
select public.revoke_partner((select id from public.partner where display_name = 'Dave'));

select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000020', 'aaaaaaaa-0000-0000-0000-000000000003',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a roster that has shrunk below the threshold makes accountability unavailable');
select test_assert(
  (select approvals_required = 2 from public.contract_envelope
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'and the threshold does not quietly drop to match who is left');

-- An empty roster is a different situation and says so.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000004', p_title => 'Nobody to ask',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 2, p_accountability_window => 1800);
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000004');
select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000021', 'aaaaaaaa-0000-0000-0000-000000000004',
    18, 30, 'minutes', 8, 10, 2, 1) $$,
  'a commitment with no partners at all is refused with its own reason');

-- MARK: - Rate limiting (§16, partner fatigue)

-- One request already exists. Two more reach the cap of three.
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000005', p_title => 'Third',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Mom'));
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000006', p_title => 'Fourth',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Mom'));
select public.register_contract_envelope(
  p_commitment_id => 'aaaaaaaa-0000-0000-0000-000000000007', p_title => 'Fifth',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Mom'));
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000005');
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000006');
select test_advance_past_hardening('aaaaaaaa-0000-0000-0000-000000000007');

-- Checked on the creating path this time, not only on the idempotent replay:
-- the device that asked never receives a link its partners were sent.
select test_assert(
  (public.create_override_request(
     'bbbbbbbb-0000-0000-0000-000000000030', 'aaaaaaaa-0000-0000-0000-000000000005',
     1, 1, 'session', 8, 10, 2, 1)::text) !~ '/a/',
  'a freshly created request returns no approval link to the requester either');
select public.create_override_request(
  'bbbbbbbb-0000-0000-0000-000000000031', 'aaaaaaaa-0000-0000-0000-000000000006',
  1, 1, 'session', 8, 10, 2, 1);
select test_raises($$
  select public.create_override_request(
    'bbbbbbbb-0000-0000-0000-000000000032', 'aaaaaaaa-0000-0000-0000-000000000007',
    1, 1, 'session', 8, 10, 2, 1) $$,
  'a fourth request in a rolling day is refused — asking five people hourly is an escape route');

-- MARK: - What the requesting app is told

select test_assert(
  (public.override_request_status('aaaaaaaa-0000-0000-0000-000000000001') ->> 'open')::boolean,
  'the app can see that its own request is open');
select test_assert(
  not (public.override_request_status('aaaaaaaa-0000-0000-0000-000000000001')
        ?| array['approvals', 'approvals_so_far', 'votes', 'tally', 'approved']),
  'and is never told a running tally — it is waiting to hear back, not counting votes');
select test_assert(
  not ((public.override_request_status('aaaaaaaa-0000-0000-0000-00000000ffff')
         ->> 'open')::boolean),
  'a commitment with no request reports no request');

-- MARK: - Expiry

-- Backdating the row is the same trick as hardening above: the rule that reads
-- expires_at is untouched, only the clock it is read against.
update public.override_request set expires_at = now() - interval '1 minute'
 where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001';
select test_assert(
  public.override_request_status('aaaaaaaa-0000-0000-0000-000000000001') ->> 'state' = 'expired',
  'an elapsed request reads as expired even before the sweeper has run');
select test_assert(public.expire_override_requests() = 1, 'the sweeper expires exactly the elapsed one');
select test_assert(
  (select count(*) = 3 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001' and rc.status = 'expired'),
  'and every pending recipient of it goes to expired');
select test_assert(
  (select state = 'expired' and resolved_at is not null from public.override_request
    where commitment_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'the request itself is resolved as expired');

-- MARK: - An elapsed request does not hold the commitment hostage

-- A second account, so this is isolated from Patrick's daily budget — and so
-- that one account's requests are visibly not another's.
select test_sign_in('22222222-2222-2222-2222-222222222222');
select public.ensure_account('apple-sub-nina', 'Nina');
select public.nominate_partner('Ada', 'sms', '+14155550200');
select public.respond_to_invitation(test_token_for('Ada'), true);
select public.register_contract_envelope(
  p_commitment_id => 'cccccccc-0000-0000-0000-000000000001', p_title => 'Swim',
  p_created_at => now(), p_eligible_from => now(), p_deadline => now() + interval '8 hours',
  p_correction_window => 7200, p_approvals_required => 1, p_accountability_window => 1800,
  p_partner_ids => array(select id from public.partner where display_name = 'Ada'));
select test_advance_past_hardening('cccccccc-0000-0000-0000-000000000001');

select public.create_override_request(
  'dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001',
  1, 1, 'session', 3, 4, 0, 1);

-- The request elapses, and the sweeper has NOT run. The partial unique index
-- still sees an `open` row for this commitment, so a create that only checked
-- expires_at would walk into a raw constraint violation instead of a request.
update public.override_request set expires_at = now() - interval '1 minute'
 where commitment_id = 'cccccccc-0000-0000-0000-000000000001';

select test_assert(
  ((select public.create_override_request(
      'dddddddd-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001',
      1, 1, 'session', 3, 4, 0, 1)) ->> 'created')::boolean,
  'once a request has elapsed a new one can be made, without waiting for the sweeper');
select test_assert(
  (select count(*) = 1 from public.override_request r
    where r.commitment_id = 'cccccccc-0000-0000-0000-000000000001' and r.state = 'expired'),
  'and the elapsed one was retired on the way past, not left lying open');
select test_assert(
  (select count(*) = 1 from public.override_request_recipient rc
     join public.override_request r on r.id = rc.request_id
    where r.commitment_id = 'cccccccc-0000-0000-0000-000000000001' and rc.status = 'expired'),
  'its recipient went with it, so a stale link cannot still read as pending');
select test_sign_in('11111111-1111-1111-1111-111111111111');

-- MARK: - The vote endpoint (once a loud stub, now real — 0010, tested in 90_voting.sql)

select test_assert(
  public.cast_override_vote('anything', 'approve') = '{"page": "invalid"}'::jsonb,
  'the vote endpoint answers a token that is not ours with the invalid page');

-- MARK: - Row level security

set local role authenticated;
select test_sign_in('11111111-1111-1111-1111-111111111111');
select test_raises($$select count(*) from public.override_request$$,
                   'a signed-in account cannot read override_request directly');
select test_raises($$select count(*) from public.override_request_snapshot$$,
                   'a signed-in account cannot read snapshots directly');
select test_raises($$select count(*) from public.override_request_recipient$$,
                   'a signed-in account cannot read recipient rows — that is where the token hashes are');
select test_raises($$select count(*) from public.override_request_event$$,
                   'a signed-in account cannot read the audit log');
select test_raises($$update public.override_request set approvals_required = 1$$,
                   'a signed-in account cannot lower the threshold on its own in-flight request');
select test_raises($$update public.override_request set state = 'granted'$$,
                   'a signed-in account cannot grant its own request');
select test_raises($$update public.override_request_snapshot
                       set payload = '{}'::jsonb$$,
                   'a signed-in account cannot rewrite what its partners were shown');
select test_raises($$insert into public.override_request_recipient
                       (request_id, partner_id, token_hash, expires_at)
                     values (gen_random_uuid(), gen_random_uuid(), '\x00'::bytea, now())$$,
                   'a signed-in account cannot mint itself a recipient row');
select test_raises($$select public.expire_override_requests()$$,
                   'a signed-in account cannot run the sweeper');
select test_raises($$select public.cast_override_vote('x', 'approve')$$,
                   'a signed-in account cannot reach the vote endpoint');
select test_raises($$select private.neutralise_text('x', 10)$$,
                   'a signed-in account cannot reach into the private schema');
reset role;

set local role anon;
select test_sign_out();
select test_raises($$select count(*) from public.override_request$$,
                   'anon cannot read override_request');
select test_raises($$select count(*) from public.override_request_snapshot$$,
                   'anon cannot read snapshots');
select test_raises($$select count(*) from public.override_request_recipient$$,
                   'anon cannot read recipient rows');
select test_raises($$select count(*) from public.override_request_event$$,
                   'anon cannot read the audit log');
select test_raises($$select public.create_override_request(
                       gen_random_uuid(), gen_random_uuid(), 1, 1, 'x', 0, 0, 0, 0)$$,
                   'anon cannot create a request');
select test_raises($$select public.override_request_status(gen_random_uuid())$$,
                   'anon cannot ask about one');
reset role;

rollback;
