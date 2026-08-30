-- Override requests: creation, the frozen snapshot, and delivery
-- (docs/accountability-architecture.md §§4.5, 5, 6, 7, 13, 16).
--
-- Build order step 6. The vote endpoint is deliberately a stub here and lands
-- in step 7, with its concurrency tests written first; grants are step 8.
--
-- What this milestone is for, in one line: a request carries no policy. The
-- app sends what it observed and why it is asking; every term that decides
-- the outcome is read from the envelope the server already holds. A modified
-- client asking for a threshold of 1 against a contract that hardened at 2
-- has nothing to modify — there is no threshold field to send.
--
-- The other half is that the requester never touches an approval token. The
-- server mints it, hashes it, stores only the hash, and puts the raw token
-- inside the outbound message and nowhere else. An account holder who could
-- read their own partners' tokens could approve their own request, which
-- would make the entire mechanism theatre — the same property, and the same
-- reason, as the consent tokens in 0006 (S1, S2).

-- Every statement converges on re-run, like everything before it.

-- MARK: - Policy dials

-- An open request expires after 24 hours (S11). Chosen over 48: a tighter
-- window against leaked-link exposure, accepted at the cost of a partner who
-- is asleep or offline overnight. Solo remains available throughout.
create or replace function private.request_lifetime() returns interval
language sql immutable as $$ select interval '24 hours' $$;

-- A resolved request keeps rendering its receipt for 30 days (S15), then goes
-- permanently generic and the snapshot purges (§6.3, §15).
create or replace function private.receipt_window() returns interval
language sql immutable as $$ select interval '30 days' $$;

-- Requests per account per rolling day (§16, "partner fatigue as a bypass").
--
-- The vector is not a compromised server: it is a user who asks five partners
-- every hour until somebody taps approve to make it stop, converting "two
-- humans must agree" into "one human gets annoyed". §16 admits a rate limit is
-- a blunt answer to it, and this is the blunt answer. Three is a judgement,
-- not a derivation — enough for a bad day with several gates, few enough that
-- hourly pestering is impossible. With the partner cap of 5 it also fixes the
-- outbound ceiling §16 asks for: at most 15 messages a day per account.
create or replace function private.max_requests_per_day() returns int
language sql immutable as $$ select 3 $$;

-- MARK: - Hostile text

-- Two fields of user-authored text reach a stranger: the requester's display
-- name and the optional reason (§13). Both are treated as hostile input.
--
-- The partner page renders text and never markup, and never auto-links — that
-- is the real defence and it belongs to the page. This is the other layer: a
-- reason cannot be used to deliver a URL, because Earned would be the thing
-- lending it credibility. Control characters go, whitespace collapses, and
-- anything shaped like a link becomes [link removed].
--
-- Honest about its limits: this stops "type a URL and hope they tap it". It
-- does not stop a determined person describing a domain in words, and it is
-- not trying to — the goal is that Earned never renders a live-looking link
-- it did not author.
create or replace function private.neutralise_text(p_raw text, p_max int)
returns text
language plpgsql immutable
set search_path = private, public, extensions, pg_temp
as $$
declare
  v text;
begin
  if p_raw is null then return null; end if;

  v := regexp_replace(p_raw, '[[:cntrl:]]', ' ', 'g');
  v := regexp_replace(v, '(?i)([a-z][a-z0-9+.-]*://|www\.)\S*', '[link removed]', 'g');
  v := regexp_replace(v, '(?i)\S+\.[a-z]{2,63}(/\S*)?', '[link removed]', 'g');
  v := btrim(regexp_replace(v, '\s+', ' ', 'g'));

  if length(v) > p_max then
    v := btrim(substring(v from 1 for p_max - 1)) || '…';
  end if;
  return v;
end;
$$;

-- MARK: - The request

-- Carries no policy. approvals_required is COPIED from the envelope at
-- creation so that a later envelope change — there should be none after
-- hardening, but belt and braces — cannot move the bar on a request that is
-- already in flight and already described to partners.
create table if not exists public.override_request (
  id                 uuid        primary key default gen_random_uuid(),
  account_id         uuid        not null references public.account(id) on delete cascade,
  commitment_id      uuid        not null,
  -- The ledger's OverrideRequest.id on the device. Makes creation idempotent
  -- across a retry the client could not tell had succeeded.
  client_request_id  uuid        not null,
  envelope_version   int         not null,
  approvals_required int         not null check (approvals_required between 1 and 5),
  state              text        not null default 'open'
                       check (state in ('open', 'granted', 'cancelled', 'moot', 'expired')),
  requested_at       timestamptz not null default now(),
  expires_at         timestamptz not null,
  receipt_expires_at timestamptz not null,
  resolved_at        timestamptz,
  unique (account_id, client_request_id),
  foreign key (account_id, commitment_id)
    references public.contract_envelope(account_id, commitment_id) on delete cascade
);

-- At most one open request per commitment (§4.5 step 4, §16). A partial unique
-- index rather than a check, so the constraint is the database's job.
create unique index if not exists override_request_one_open
  on public.override_request (account_id, commitment_id) where state = 'open';

-- Frozen at request time, never updated (§7). What the partner sees is what
-- they were asked to approve — if the requester logs 12 more minutes after
-- asking, the page still says 18/30, because otherwise the human is answering
-- a question nobody put to them.
create table if not exists public.override_request_snapshot (
  request_id uuid        primary key references public.override_request(id) on delete cascade,
  payload    jsonb       not null,
  created_at timestamptz not null default now()
);

-- One row per partner per request. This row *is* the vote, and later the
-- receipt. `unique (request_id, partner_id)` makes "one partner, one vote" a
-- property of the schema rather than of a code path someone could forget.
create table if not exists public.override_request_recipient (
  id             uuid        primary key default gen_random_uuid(),
  request_id     uuid        not null references public.override_request(id) on delete cascade,
  partner_id     uuid        not null references public.partner(id),
  -- sha256 of a 256-bit token. Never nulled: inertness comes from `status`,
  -- not from destroying the lookup key, so a partner who already voted can
  -- reopen their own receipt instead of being told their link is invalid.
  token_hash     bytea       not null unique,
  status         text        not null default 'pending'
                   check (status in ('pending', 'voted', 'superseded', 'expired', 'withdrawn')),
  vote           text check (vote in ('approve', 'deny')),
  voted_at       timestamptz,
  delivered_at   timestamptz,
  delivery_error text,
  expires_at     timestamptz not null,
  unique (request_id, partner_id),
  check ((vote is null) = (voted_at is null))
);

create index if not exists override_request_recipient_request_idx
  on public.override_request_recipient (request_id);

-- Append-only audit. Carries no PII: no addresses, no message bodies, and any
-- IP or user agent arrives already hashed by the edge function (§15).
create table if not exists public.override_request_event (
  id           bigserial   primary key,
  request_id   uuid        not null references public.override_request(id) on delete cascade,
  kind         text        not null,
  at           timestamptz not null default now(),
  recipient_id uuid,
  detail       jsonb,
  ip_hash      bytea,
  ua_hash      bytea
);

create index if not exists override_request_event_request_idx
  on public.override_request_event (request_id, at);

-- MARK: - Creation

-- The whole of §4.5, in the order §4.5 states it. Every refusal is a distinct
-- message, because the app has to be able to explain which wall it hit — "you
-- can't ask yet, this hardens at 08:15" and "Dave never answered, so there is
-- nobody to ask" are different situations with different next steps, and
-- collapsing them into one error would make the app lie about at least one.
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
    select p.id, p.channel, p.contact_ciphertext
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

    insert into public.message_outbox (channel, to_ciphertext, body)
         values (v_partner.channel, v_partner.contact_ciphertext,
                 private.neutralise_text(v_name, 64)
                 || ' is asking to be let out of a commitment on Earned: "'
                 || v_env.title || '". Have a look and decide: '
                 || private.secret('consent_base_url') || '/a/' || v_token);

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

-- MARK: - What the requesting app may ask

-- Deliberately not a running tally.
--
-- §11 settles the wording for the offline case — "waiting to hear back", never
-- "2 approvals received" — and the same restraint applies online: before
-- resolution the app is told that it is waiting, not who has answered. The
-- decision arrives once, as a signed grant, in step 8. A live tally would also
-- make the requester's screen a side channel onto partners who have not voted
-- yet, which S6 refuses for the partner page for the same reason.
create or replace function public.override_request_status(p_commitment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_req     public.override_request;
  v_now     timestamptz := now();
  v_state   text;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  select * into v_req from public.override_request r
   where r.account_id = v_account and r.commitment_id = p_commitment_id
   order by r.requested_at desc limit 1;

  if v_req.id is null then
    return jsonb_build_object('commitment_id', p_commitment_id, 'open', false);
  end if;

  -- Reported lazily rather than waiting for the sweeper, so an app that polls
  -- at the wrong moment is never told a dead request is still live.
  v_state := v_req.state;
  if v_state = 'open' and v_now > v_req.expires_at then
    v_state := 'expired';
  end if;

  return jsonb_build_object(
    'commitment_id',      p_commitment_id,
    'open',               v_state = 'open',
    'id',                 v_req.id,
    'state',              v_state,
    'approvals_required', v_req.approvals_required,
    'requested_at',       v_req.requested_at,
    'expires_at',         v_req.expires_at,
    'partners_notified',  (select count(*) from public.override_request_recipient rc
                            where rc.request_id = v_req.id));
end;
$$;

-- MARK: - Expiry

-- For a scheduled job. Expiry is also computed lazily wherever it is read, so
-- this sweeper is housekeeping — it makes the stored state match the truth,
-- and nothing depends on it having run.
create or replace function public.expire_override_requests() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_ids uuid[];
begin
  with expired as (
    update public.override_request
       set state = 'expired', resolved_at = now(),
           receipt_expires_at = now() + private.receipt_window()
     where state = 'open' and expires_at <= now()
     returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from expired;

  update public.override_request_recipient
     set status = 'expired'
   where status = 'pending' and request_id = any(v_ids);

  insert into public.override_request_event (request_id, kind)
       select id, 'expired' from unnest(v_ids) as t(id);

  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

-- MARK: - The vote endpoint, deliberately not implemented

-- Step 7, and its concurrency tests get written before it does (§8, §19): N
-- simultaneous votes on a threshold-2 request must produce exactly one
-- transition to `granted`, one grant, and `superseded` for everyone else.
--
-- It exists as a stub so the shape is fixed and so nothing can mistake its
-- absence for permission. It refuses rather than returning a benign answer,
-- because a vote endpoint that silently does nothing is the failure mode
-- worth being loudest about.
create or replace function public.cast_override_vote(p_token text, p_vote text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  raise exception 'the vote endpoint is not implemented yet (build order step 7)'
    using errcode = '0A000';
end;
$$;

-- MARK: - RLS

alter table public.override_request           enable row level security;
alter table public.override_request_snapshot  enable row level security;
alter table public.override_request_recipient enable row level security;
alter table public.override_request_event     enable row level security;

revoke all on public.override_request           from anon, authenticated;
revoke all on public.override_request_snapshot  from anon, authenticated;
revoke all on public.override_request_recipient from anon, authenticated;
revoke all on public.override_request_event     from anon, authenticated;

-- No policy at all, not even SELECT (§18). Unlike `contract_envelope`, where
-- the app is shown what the server believes about its own contract, there is
-- nothing here an app is better off reading directly: the recipient rows carry
-- token hashes and partner identities, and the request itself is served
-- through override_request_status above with the tally withheld.

-- MARK: - Who may call what

revoke all on function public.create_override_request(
  uuid, uuid, double precision, double precision, text, int, int, int, int, text)
  from public, anon;
revoke all on function public.override_request_status(uuid) from public, anon;
revoke all on function public.expire_override_requests() from public, anon, authenticated;
revoke all on function public.cast_override_vote(text, text) from public, anon, authenticated;
revoke all on function private.neutralise_text(text, int) from public, anon, authenticated;
revoke all on function private.request_lifetime() from public, anon, authenticated;
revoke all on function private.receipt_window() from public, anon, authenticated;
revoke all on function private.max_requests_per_day() from public, anon, authenticated;

grant execute on function public.create_override_request(
  uuid, uuid, double precision, double precision, text, int, int, int, int, text)
  to authenticated;
grant execute on function public.override_request_status(uuid) to authenticated;

-- The sweeper and the vote endpoint are the server acting on itself. The vote
-- in particular is reached only by the edge function rendering the partner
-- page: no anonymous client ever touches these tables directly (§18).
grant execute on function public.expire_override_requests() to service_role;
grant execute on function public.cast_override_vote(text, text) to service_role;
