-- Unified accountability partner invitation
-- (docs/accountability-architecture.md §2.2/S14, docs/social-architecture.md §2).
--
-- S14 built the `earned_user` partner tier into the schema and required it of
-- nothing. This gives it behaviour: an accountability partner can now be an
-- authenticated Earned account, nominated through an accepted friendship with
-- no phone number or email ever entered, consenting in-app instead of through
-- a web link. External partners keep their entire existing flow — no account,
-- no app install, consent and approvals through secure links — untouched.
--
-- The invariant this must not weaken (NORTHSTAR invariant 24): friendship
-- gives social visibility, accountability partnership gives override
-- authority, and neither is ever inferred from the other. Friendship here is
-- the *nomination channel* — the way an ask reaches a person — never the
-- consent. And one explicit cross-system rule joins the two models (NORTHSTAR
-- invariant 29): a block between two accounts revokes the accountability
-- between them, in both directions, and unblocking restores nothing.

-- MARK: - Schema: an account-linked partner identity

-- The authenticated identity of an earned_user partner. Deliberately NOT a
-- foreign key, for 0001's exact reason: a cascade (or a bare FK's refusal)
-- would quietly decide what account deletion does to someone else's
-- accountability roster, and that is D10's still-open half. The nomination
-- function is the referential integrity.
alter table public.partner
  add column if not exists earned_account_id uuid;

comment on column public.partner.earned_account_id is
  'The partner''s own authenticated account, for kind = earned_user. This is '
  'the identity — it survives phone, email and display-name changes. Null for '
  'external partners, whose identity is their encrypted contact.';

-- An earned partner has no contact address — that is the point. The columns
-- become nullable and a shape check makes the two kinds mutually exclusive:
-- an external partner is exactly a contact, an earned partner is exactly an
-- account, and no row is ever both or neither.
alter table public.partner alter column contact_ciphertext drop not null;
alter table public.partner alter column contact_lookup     drop not null;

alter table public.partner drop constraint if exists partner_channel_check;
alter table public.partner add constraint partner_channel_check
  check (channel in ('sms', 'email', 'earned'));

alter table public.partner drop constraint if exists partner_kind_shape_check;
alter table public.partner add constraint partner_kind_shape_check
  check (
    (kind = 'earned_user'
       and earned_account_id is not null
       and channel = 'earned'
       and contact_ciphertext is null
       and contact_lookup is null)
    or
    (kind = 'unverified_contact'
       and earned_account_id is null
       and channel in ('sms', 'email')
       and contact_ciphertext is not null
       and contact_lookup is not null));

-- One logical earned-user relationship per requester/target pair, ever — the
-- same one-row-per-identity rule the contact unique gives external partners.
-- Repeated nominations reuse the row; its status is the relationship's state.
create unique index if not exists partner_earned_pair_idx
  on public.partner (account_id, earned_account_id)
  where earned_account_id is not null;

-- MARK: - Nomination, through a friendship

-- Nominate an accepted friend as an accountability partner. By handle — the
-- only discovery mechanism the social layer speaks — and only a friend: the
-- friendship is the channel the ask travels through, which also means a
-- blocked pair fails here exactly like any pair of strangers, leaking
-- nothing. What friendship never does is consent (invariant 24): the target
-- answers in-app, or this row stays 'invited' forever.
--
-- One deliberate divergence from the external flow: a declined or revoked
-- earned partner CAN be asked again. The external no-re-ask rule protects
-- strangers from unwanted messages to their phone; an Earned user receives
-- asks in-app, behind a friendship they accepted, with block as the stop
-- lever — and block-revoked authority must be re-earnable after an unblock
-- by exactly this fresh ask, or "unblock does not resurrect authority"
-- would mean "block is forever".
create or replace function public.nominate_earned_partner(p_handle text) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller  uuid := private.social_caller();
  v_target  uuid := private.account_for_handle(p_handle);
  v_name    text;
  v_partner public.partner;
  v_now     timestamptz := now();
  v_count   int;
begin
  if v_target = v_caller then
    raise exception 'an accountability partner has to be someone else'
      using errcode = '23514';
  end if;
  -- One refusal for no-such-profile, stranger, pending and blocked alike:
  -- the ask travels through an accepted friendship or it does not travel.
  if v_target is null
     or not exists (select 1 from public.friendship f
                     where f.account_low = least(v_caller, v_target)
                       and f.account_high = greatest(v_caller, v_target)
                       and f.status = 'accepted') then
    raise exception 'you can only nominate an accepted friend'
      using errcode = '23514';
  end if;

  select * into v_partner from public.partner p
   where p.account_id = v_caller and p.earned_account_id = v_target;

  if v_partner.status = 'invited' then
    -- Asked already; idempotent, and no re-notification.
    return jsonb_build_object('id', v_partner.id, 'display_name', v_partner.display_name,
                              'channel', v_partner.channel, 'status', v_partner.status,
                              'consent_asked_at', v_partner.consent_asked_at);
  end if;
  if v_partner.status = 'active' then
    raise exception 'this friend is already an accountability partner'
      using errcode = '23505';
  end if;

  select count(*) into v_count from public.partner p
   where p.account_id = v_caller and p.status in ('invited', 'active');
  if v_count >= private.max_partners() then
    raise exception 'you can have at most % accountability partners', private.max_partners()
      using errcode = '23514';
  end if;

  -- The same daily cap as external nominations, counted across both kinds by
  -- when the ask went out — re-asks move consent_asked_at, so they count.
  select count(*) into v_count from public.partner p
   where p.account_id = v_caller and p.consent_asked_at > v_now - interval '1 day';
  if v_count >= private.max_nominations_per_day() then
    raise exception 'too many invitations today — try again tomorrow' using errcode = '53400';
  end if;

  select a.display_name into v_name from public.account a where a.id = v_target;

  if v_partner.id is not null then
    -- declined or revoked: a fresh ask reopens the same row. The display
    -- name refreshes from the account — the snapshot is a label, the
    -- earned_account_id is the identity.
    update public.partner
       set status = 'invited', display_name = v_name,
           consent_asked_at = v_now, consent_resent_at = null,
           consented_at = null, revoked_at = null
     where id = v_partner.id
    returning * into v_partner;
  else
    insert into public.partner (account_id, display_name, channel, kind,
                                earned_account_id, status, consent_asked_at)
         values (v_caller, v_name, 'earned', 'earned_user',
                 v_target, 'invited', v_now)
      returning * into v_partner;
  end if;

  -- Note what does not happen: no outbox row, no token. The ask is delivered
  -- in-app through my_partner_requests, and the consent credential is the
  -- target's own authenticated session.
  return jsonb_build_object('id', v_partner.id, 'display_name', v_partner.display_name,
                            'channel', v_partner.channel, 'status', v_partner.status,
                            'consent_asked_at', v_partner.consent_asked_at);
end;
$$;

-- MARK: - The ask, as the asked person sees it

-- Incoming nominations: who is asking, and since when. The requester's
-- handle and display name are what a friend already sees; the row id is a
-- random relationship id, not anyone's account.
create or replace function public.my_partner_requests() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',                     p.id,
             'requester_handle',       pr.handle,
             'requester_display_name', a.display_name,
             'asked_at',               p.consent_asked_at)
           order by p.consent_asked_at desc)
      from public.partner p
      join public.account a on a.id = p.account_id and a.deleted_at is null
      join public.profile pr on pr.account_id = p.account_id
     where p.earned_account_id = v_caller
       and p.status = 'invited'), '[]'::jsonb);
end;
$$;

-- Accept or decline. The caller's authenticated session is the consent
-- credential — the exact analogue of the external flow's bearer token, and
-- the reason no contact address was ever needed. Declining writes no
-- suppression row: there is no contact to suppress, and the stop lever for
-- a persistent asker is block, which revokes harder than suppression would.
create or replace function public.respond_to_partner_request(p_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid;
  v_now    timestamptz := now();
  v_rows   int;
begin
  select a.id into v_caller from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_caller is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  update public.partner
     set status = case when p_accept then 'active' else 'declined' end,
         consented_at = case when p_accept then v_now end,
         revoked_at = case when p_accept then null else v_now end
   where id = p_id and earned_account_id = v_caller and status = 'invited';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'no such request' using errcode = '42501';
  end if;

  return jsonb_build_object('accepted', p_accept, 'at', v_now);
end;
$$;

-- MARK: - The partner list, with identity where it exists

-- Replaces the app's direct table read. What it adds over the columns the
-- app selected: the kind, and — for earned partners — the partner's current
-- handle and display name read live from their account, because the
-- authenticated identity is the authority and the stored label is only a
-- snapshot. What it still never exposes: account ids, contact material,
-- blind indexes.
create or replace function public.my_partners() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',                p.id,
             'display_name',      coalesce(ta.display_name, p.display_name),
             'channel',           p.channel,
             'kind',              p.kind,
             'status',            p.status,
             'handle',            tp.handle,
             'consent_asked_at',  p.consent_asked_at,
             'consented_at',      p.consented_at,
             'consent_resent_at', p.consent_resent_at)
           order by p.created_at)
      from public.partner p
      left join public.account ta on ta.id = p.earned_account_id and ta.deleted_at is null
      left join public.profile tp on tp.account_id = p.earned_account_id
     where p.account_id = v_account), '[]'::jsonb);
end;
$$;

-- MARK: - Block supersedes both systems (NORTHSTAR invariant 29)

-- Recreated from 0014 with the one cross-system rule, written explicitly
-- rather than achieved through cascades: a block revokes every live
-- accountability relationship between the two accounts, in both directions.
-- Frozen Contract Envelopes are deliberately untouched — the threshold never
-- lowers, the roster effectively shrinks, and create_override_request's
-- live re-filter (p.status = 'active') is what makes the route honestly
-- unavailable if too few remain. Solo remains throughout. Unblocking
-- restores none of this: the rows stay revoked until a fresh nomination is
-- made and freshly consented to.
create or replace function public.block_user(p_handle text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid := private.social_caller();
  v_target uuid := private.account_for_handle(p_handle);
  v_row    public.friendship;
  v_now    timestamptz := now();
begin
  if v_target is null then
    return;  -- nothing to block; quiet for the same reason requests are
  end if;
  if v_target = v_caller then
    raise exception 'you cannot block yourself' using errcode = '22023';
  end if;

  v_row := private.friendship_between(v_caller, v_target);
  if v_row.id is null then
    insert into public.friendship (account_low, account_high, requester, status,
                                   blocked_by_low, blocked_by_high, responded_at)
         values (least(v_caller, v_target), greatest(v_caller, v_target), v_caller,
                 'blocked',
                 v_caller < v_target, v_caller > v_target, v_now);
  else
    update public.friendship
       set status = 'blocked',
           blocked_by_low  = blocked_by_low  or (v_caller = account_low),
           blocked_by_high = blocked_by_high or (v_caller = account_high),
           responded_at = v_now
     where id = v_row.id;
  end if;

  -- The cross-system rule. Both directions, pending and active alike, and
  -- an audit-preserving revocation rather than a deletion: old grants keep
  -- the partner rows their votes reference.
  update public.partner p
     set status = 'revoked', revoked_at = v_now
   where ((p.account_id = v_caller and p.earned_account_id = v_target)
       or (p.account_id = v_target and p.earned_account_id = v_caller))
     and p.status in ('invited', 'active');
end;
$$;

-- MARK: - Voting, factored so a session can be the credential

-- The vote transaction from 0010, verbatim, parameterised only by how the
-- recipient was resolved: by bearer token (external partners, unchanged) or
-- by authenticated identity (earned partners, new). The locking order, the
-- S16 rule, lazy expiry, threshold resolution and the returned page are the
-- same code for both, because two copies of concurrency-critical logic is
-- how one of them rots.
create or replace function private.cast_vote(
  p_rc_id   uuid,
  p_req_id  uuid,
  p_vote    text,
  p_ip_hash bytea default null,
  p_ua_hash bytea default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_rc       public.override_request_recipient;
  v_r        public.override_request;
  v_now      timestamptz := now();
  v_approves int;
begin
  -- Lock order, and it is load-bearing: the REQUEST row first, and recipient
  -- rows only ever under it (0010's deadlock lesson, unchanged).
  select r.* into v_r
    from public.override_request r
   where r.id = p_req_id
     for update;

  -- Re-read the recipient under the lock: while this voter waited, the
  -- winner may have superseded them, and whatever was committed before the
  -- lock was won is what must be answered from.
  select rc.* into v_rc from public.override_request_recipient rc where rc.id = p_rc_id;

  -- A second vote from the same partner: their prior receipt, unchanged, and
  -- nothing recorded (§19). A vote after resolution: the resolved page with
  -- processed_late, and nothing recorded (§6.2).
  if v_rc.status <> 'pending' then
    return private.approval_page_for(v_rc, v_r, p_processed_late => true);
  end if;
  if v_r.state <> 'open' then
    return private.approval_page_for(v_rc, v_r, p_processed_late => true);
  end if;

  -- Expiry is honoured here even if no sweeper ever ran.
  if v_now > least(v_rc.expires_at, v_r.expires_at) then
    update public.override_request
       set state = 'expired', resolved_at = v_now,
           receipt_expires_at = v_now + private.receipt_window()
     where id = v_r.id and state = 'open';
    update public.override_request_recipient
       set status = 'expired'
     where request_id = v_r.id and status = 'pending';
    insert into public.override_request_event (request_id, kind, recipient_id)
         values (v_r.id, 'expired', v_rc.id);
    select rc.* into v_rc from public.override_request_recipient rc where rc.id = v_rc.id;
    select r.*  into v_r  from public.override_request r  where r.id  = v_r.id;
    return private.approval_page_for(v_rc, v_r);
  end if;

  -- Deliberately NOT checked: the partner's live consent state (S16). A
  -- partner suppressed, revoked — or, now, blocked — after this recipient
  -- row was minted still has a valid vote: they were legitimately asked
  -- before withdrawing. The block rule stops FUTURE requests reaching them,
  -- because create_override_request re-filters on live status.
  update public.override_request_recipient
     set status = 'voted', vote = p_vote, voted_at = v_now
   where id = v_rc.id;

  insert into public.override_request_event
         (request_id, kind, recipient_id, detail, ip_hash, ua_hash)
       values (v_r.id, 'voted', v_rc.id, jsonb_build_object('vote', p_vote),
               p_ip_hash, p_ua_hash);

  -- Denials record a vote, consume no approval slot, and resolve nothing (S5).
  if p_vote = 'approve' then
    select count(*) into v_approves
      from public.override_request_recipient rc
     where rc.request_id = v_r.id and rc.vote = 'approve';

    if v_approves >= v_r.approvals_required then
      update public.override_request
         set state = 'granted', resolved_at = v_now,
             receipt_expires_at = v_now + private.receipt_window()
       where id = v_r.id and state = 'open';

      if found then
        -- In the same transaction, always: a resolved request with a pending
        -- recipient is a page that lies.
        update public.override_request_recipient
           set status = 'superseded'
         where request_id = v_r.id and status = 'pending';
        insert into public.override_request_event (request_id, kind, detail)
             values (v_r.id, 'resolved',
                     jsonb_build_object('outcome', 'granted', 'approvals', v_approves));
      end if;
    end if;
  end if;

  select rc.* into v_rc from public.override_request_recipient rc where rc.id = v_rc.id;
  select r.*  into v_r  from public.override_request r  where r.id  = v_r.id;
  return private.approval_page_for(v_rc, v_r);
end;
$$;

-- The token path, now a thin resolver over the shared core. Same signature,
-- same grants, same behaviour — the concurrency drill holds it to that.
create or replace function public.cast_override_vote(
  p_token   text,
  p_vote    text,
  p_ip_hash bytea default null,
  p_ua_hash bytea default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_rc_id  uuid;
  v_req_id uuid;
begin
  if p_vote not in ('approve', 'deny') then
    raise exception 'a vote is approve or deny' using errcode = '22023';
  end if;
  if p_token is null or p_token = '' then
    return jsonb_build_object('page', 'invalid');
  end if;

  select rc.id, rc.request_id
    into v_rc_id, v_req_id
    from public.override_request_recipient rc
   where rc.token_hash = digest(p_token, 'sha256');

  if v_rc_id is null then
    return jsonb_build_object('page', 'invalid');
  end if;

  return private.cast_vote(v_rc_id, v_req_id, p_vote, p_ip_hash, p_ua_hash);
end;
$$;

-- The authenticated path: an earned partner's session takes the place of the
-- bearer token. The recipient is resolved by who they are, never by an id
-- the client asserts about someone else.
create or replace function public.cast_override_vote_in_app(
  p_recipient_id uuid,
  p_vote         text
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid;
  v_rc_id  uuid;
  v_req_id uuid;
begin
  if p_vote not in ('approve', 'deny') then
    raise exception 'a vote is approve or deny' using errcode = '22023';
  end if;
  select a.id into v_caller from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_caller is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  select rc.id, rc.request_id
    into v_rc_id, v_req_id
    from public.override_request_recipient rc
    join public.partner p on p.id = rc.partner_id
   where rc.id = p_recipient_id and p.earned_account_id = v_caller;

  if v_rc_id is null then
    raise exception 'no such request' using errcode = '42501';
  end if;

  return private.cast_vote(v_rc_id, v_req_id, p_vote);
end;
$$;

-- What an earned partner is currently being asked to decide: one entry per
-- pending recipient row of theirs on an open request, rendered through the
-- same snapshot pipeline the web page uses — same two-part payload, same
-- self-reported labelling, nothing extra.
create or replace function public.my_pending_approvals() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller uuid;
begin
  select a.id into v_caller from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_caller is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  return coalesce((
    select jsonb_agg(private.approval_page_for(rc, r)
                     || jsonb_build_object('recipient_id', rc.id)
           order by r.requested_at desc)
      from public.override_request_recipient rc
      join public.partner p on p.id = rc.partner_id
      join public.override_request r on r.id = rc.request_id
     where p.earned_account_id = v_caller
       and rc.status = 'pending'
       and r.state = 'open'
       and now() <= least(rc.expires_at, r.expires_at)), '[]'::jsonb);
end;
$$;

-- MARK: - Grants

revoke all on function public.nominate_earned_partner(text) from public, anon;
revoke all on function public.my_partner_requests() from public, anon;
revoke all on function public.respond_to_partner_request(uuid, boolean) from public, anon;
revoke all on function public.my_partners() from public, anon;
revoke all on function public.cast_override_vote_in_app(uuid, text) from public, anon;
revoke all on function public.my_pending_approvals() from public, anon;
revoke all on function private.cast_vote(uuid, uuid, text, bytea, bytea) from public, anon, authenticated;
-- cast_override_vote keeps its 0010 posture: service_role only, via the page.

grant execute on function public.nominate_earned_partner(text) to authenticated;
grant execute on function public.my_partner_requests() to authenticated;
grant execute on function public.respond_to_partner_request(uuid, boolean) to authenticated;
grant execute on function public.my_partners() to authenticated;
grant execute on function public.cast_override_vote_in_app(uuid, text) to authenticated;
grant execute on function public.my_pending_approvals() to authenticated;

-- MARK: - Request delivery learns the second kind
-- (create_override_request, recreated from 0009 below with one change: an
-- earned partner gets a recipient row and no outbound message — their
-- delivery surface is my_pending_approvals, and their credential is their
-- session. The token is still minted and immediately discarded, so the
-- not-null unique token_hash keeps its meaning and a raw token never exists
-- outside this transaction for anyone.)

create or replace function public.create_override_request(
  p_client_request_id             uuid,
  p_commitment_id                 uuid,
  p_progress_achieved             double precision,
  p_progress_required             double precision,
  p_progress_unit                 text,
  p_reliability_completed         int,
  p_reliability_of                int,
  p_reliability_override_requests int,
  p_reliability_missed            int,
  p_reason                        text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account   uuid;
  v_name      text;
  v_env       public.contract_envelope;
  v_req       public.override_request;
  v_now       timestamptz := now();
  v_eligible  int;
  v_count     int;
  v_partner   record;
  v_token     text;
  v_sent      int := 0;
begin
  select a.id, a.display_name into v_account, v_name
    from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  -- Idempotent creation (§9.4). A client that retried because it never saw the
  -- response gets the same request back, not a second one — and critically,
  -- not a second round of messages to five people.
  select * into v_req from public.override_request r
   where r.account_id = v_account and r.client_request_id = p_client_request_id;
  if v_req.id is not null then
    return jsonb_build_object(
      'id', v_req.id, 'state', v_req.state, 'created', false,
      'approvals_required', v_req.approvals_required,
      'requested_at', v_req.requested_at, 'expires_at', v_req.expires_at,
      'partners_notified', (select count(*) from public.override_request_recipient rc
                             where rc.request_id = v_req.id));
  end if;

  -- 1. No envelope is never permission (§4.8). There is no fallback, no grace
  --    mode, and no "assume the default".
  select * into v_env from public.contract_envelope e
   where e.account_id = v_account and e.commitment_id = p_commitment_id;
  if v_env.commitment_id is null then
    raise exception 'this commitment is not registered, so there is no contract to appeal to'
      using errcode = '42704';
  end if;

  if v_env.withdrawn_at is not null then
    raise exception 'this commitment was withdrawn' using errcode = '55000';
  end if;

  -- 2. Hardened, on the server's clock and the server's arithmetic. Before
  --    that the commitment can simply be edited or cancelled, which is both
  --    cheaper and more honest than asking three people for permission.
  if v_now < v_env.hardens_at then
    raise exception 'this commitment has not hardened yet (it hardens at %); edit or cancel it instead',
      v_env.hardens_at using errcode = '55000';
  end if;

  -- 3. A late envelope closes the accountability route for good (S13). Being
  --    offline can never open an escape route, only close one.
  if v_env.is_late then
    raise exception 'this commitment was registered after it hardened, so only the Solo route is available'
      using errcode = '55000';
  end if;

  -- 4. One open request per commitment.
  --
  --    Retire anything of this account's that has already elapsed first. The
  --    sweeper is housekeeping and correctness must not depend on its having
  --    run: a user whose request expired an hour ago would otherwise be held
  --    behind a row nobody had got round to, which is the machinery making
  --    someone more stuck than the contract does (§11). This is the same
  --    lazy expiry override_request_status reports, applied before the write.
  update public.override_request r
     set state = 'expired', resolved_at = v_now,
         receipt_expires_at = v_now + private.receipt_window()
   where r.account_id = v_account and r.state = 'open' and r.expires_at <= v_now;

  update public.override_request_recipient rc
     set status = 'expired'
   where rc.status = 'pending'
     and exists (select 1 from public.override_request r
                  where r.id = rc.request_id and r.account_id = v_account
                    and r.state = 'expired' and r.resolved_at = v_now);

  --    The partial unique index enforces the rule too; this exists to say why
  --    rather than surfacing a constraint name, and its condition is now
  --    exactly the index's.
  if exists (select 1 from public.override_request r
              where r.account_id = v_account and r.commitment_id = p_commitment_id
                and r.state = 'open') then
    raise exception 'there is already an open request for this commitment'
      using errcode = '23505';
  end if;

  select count(*) into v_count from public.override_request r
   where r.account_id = v_account and r.requested_at > v_now - interval '1 day';
  if v_count >= private.max_requests_per_day() then
    raise exception 'too many override requests today — try again tomorrow'
      using errcode = '53400';
  end if;

  -- 5 and 6. The roster and the threshold come from the envelope, and the
  --    roster is re-filtered now: invariant 22 guaranteed everyone had
  --    consented at registration, but a partner can withdraw afterwards, and
  --    a stale roster would send an approval link to someone who has since
  --    said no. The threshold does not move when that happens (§4.5) —
  --    Earned refuses to author a way out that never worked, and refuses to
  --    rewrite one that reality made harder.
  select count(*) into v_eligible
    from public.contract_envelope_partner cep
    join public.partner p on p.id = cep.partner_id
   where cep.account_id = v_account and cep.commitment_id = p_commitment_id
     and p.status = 'active'
     and not exists (select 1 from public.contact_suppression s
                      where s.contact_lookup = p.contact_lookup and s.channel = p.channel);

  if v_eligible = 0 then
    raise exception 'this commitment has no accountability partners, so only the Solo route is available'
      using errcode = '55000';
  end if;
  if v_eligible < v_env.approvals_required then
    raise exception 'this contract needs % approvals and only % partners can still be asked',
      v_env.approvals_required, v_eligible using errcode = '55000';
  end if;

  insert into public.override_request
         (account_id, commitment_id, client_request_id, envelope_version,
          approvals_required, requested_at, expires_at, receipt_expires_at)
       values (v_account, p_commitment_id, p_client_request_id, v_env.version,
               v_env.approvals_required, v_now,
               v_now + private.request_lifetime(),
               v_now + private.request_lifetime() + private.receipt_window())
    returning * into v_req;

  -- 7. Freeze the snapshot (§7).
  --
  -- Grouped structurally rather than flat, because §7 requires the page to
  -- render the two halves distinguishably and label the second "as reported
  -- by <name>'s phone" (D6). A flat object with a comment marking the split
  -- would leave the page hardcoding which keys it is allowed to trust, and a
  -- future field would join the wrong half by accident.
  --
  -- Everything under `contract` is the server's own; everything under
  -- `self_reported` came from the device and is advisory — shown to humans
  -- who decide, never an input to an automatic rule. The known gap is stated
  -- in §7: reliability is computed by the requester's own device, so a
  -- tampered ledger can flatter it. Labelling it is the honest interim answer.
  insert into public.override_request_snapshot (request_id, payload)
       values (v_req.id, jsonb_build_object(
         'contract', jsonb_build_object(
           'requester_display_name', private.neutralise_text(v_name, 64),
           'commitment_title',       v_env.title,
           'deadline',               v_env.deadline,
           'approvals_required',     v_env.approvals_required,
           'hardened_at',            v_env.hardens_at),
         'self_reported', jsonb_build_object(
           'progress', jsonb_build_object(
             'achieved', p_progress_achieved,
             'required', p_progress_required,
             'unit',     private.neutralise_text(p_progress_unit, 24)),
           'reliability_30d', jsonb_build_object(
             'completed',         greatest(0, coalesce(p_reliability_completed, 0)),
             'of',                greatest(0, coalesce(p_reliability_of, 0)),
             'override_requests', greatest(0, coalesce(p_reliability_override_requests, 0)),
             'missed',            greatest(0, coalesce(p_reliability_missed, 0))),
           'reason', private.neutralise_text(nullif(btrim(coalesce(p_reason, '')), ''), 280)),
         'requested_at', v_req.requested_at));

  -- Mint one token per surviving partner and queue the message. The token is
  -- 32 bytes of CSPRNG, base64url, 43 characters (§6.1) — guessing it is not a
  -- threat model, it is arithmetic. Only its sha256 is stored, so a database
  -- leak yields hashes and not working links.
  for v_partner in
    select p.id, p.channel, p.contact_ciphertext, p.kind
      from public.contract_envelope_partner cep
      join public.partner p on p.id = cep.partner_id
     where cep.account_id = v_account and cep.commitment_id = p_commitment_id
       and p.status = 'active'
       and not exists (select 1 from public.contact_suppression s
                        where s.contact_lookup = p.contact_lookup and s.channel = p.channel)
     order by p.created_at
  loop
    v_token := rtrim(translate(replace(encode(gen_random_bytes(32), 'base64'), chr(10), ''),
                               '+/', '-_'), '=');

    insert into public.override_request_recipient
           (request_id, partner_id, token_hash, expires_at)
         values (v_req.id, v_partner.id, digest(v_token, 'sha256'), v_req.expires_at);

    -- An earned partner gets no message: their delivery surface is
    -- my_pending_approvals, their credential their session. The minted token
    -- above was hashed and discarded, and never existed anywhere else.
    if v_partner.kind <> 'earned_user' then
      insert into public.message_outbox (channel, to_ciphertext, body)
           values (v_partner.channel, v_partner.contact_ciphertext,
                   private.neutralise_text(v_name, 64)
                   || ' is asking to be let out of a commitment on Earned: "'
                   || v_env.title || '". Have a look and decide: '
                   || private.secret('consent_base_url') || '/a/' || v_token);
    end if;

    v_sent := v_sent + 1;
  end loop;

  insert into public.override_request_event (request_id, kind, detail)
       values (v_req.id, 'created',
               jsonb_build_object('recipients', v_sent,
                                  'approvals_required', v_req.approvals_required,
                                  'envelope_version', v_req.envelope_version));

  -- Note what is not in here: any token, and any partner identity beyond the
  -- count. The requesting device learns that its request exists and how many
  -- people were asked.
  return jsonb_build_object(
    'id', v_req.id, 'state', v_req.state, 'created', true,
    'approvals_required', v_req.approvals_required,
    'requested_at', v_req.requested_at, 'expires_at', v_req.expires_at,
    'partners_notified', v_sent);
end;
$$;
