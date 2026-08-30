-- Voting, and what happens when two people tap at once
-- (docs/accountability-architecture.md §§6.2, 8, 12, 15, 17).
--
-- Build order step 7. The concurrency drill that holds this to §19 —
-- tests/vote_concurrency.sh — was written first and watched fail against the
-- stub, because the property that matters here cannot be asserted by reading
-- the code: five real sessions voting in the same instant must produce
-- exactly one transition to `granted`, one resolution, and `superseded` for
-- everyone past the threshold.
--
-- Two functions face the partner page's edge function, and nothing here faces
-- a client at all: the page is server-rendered (§18), the caller is
-- service_role, and the token in the URL is the entire credential. Both
-- functions answer in pages, not errors, because every state of a token has a
-- page a human should see (§6.2) — including the state "this token is not
-- ours", which must be indistinguishable across forged, truncated, expired-
-- and-purged and simply wrong (§19).

-- Every statement converges on re-run, like everything before it.

-- MARK: - Pages

-- What a token resolves to. One shape for both reading and voting, so the
-- renderer has exactly one contract:
--
--   page: 'invalid'   not a live token of ours. Deliberately content-free.
--   page: 'gone'      the receipt window has closed. Permanently generic (§6.3).
--   page: 'request'   pending, open: the snapshot, and Approve / Deny.
--   page: 'receipt'   this partner voted: their vote, when, and the outcome.
--   page: 'resolved'  resolved without their vote. `processed_late` true when
--                     they tried to vote after resolution (§12) — the page
--                     owes them honesty that their tap did not count.
--   page: 'withdrawn' the requester's situation resolved itself (step 9).
--   page: 'expired'   the request lapsed without an answer.
--
-- Every page except 'invalid' and 'gone' carries the frozen snapshot while it
-- still exists — a used or superseded link keeps showing what was asked, for
-- at most the receipt window, and can do nothing (§17).
create or replace function private.approval_page_for(
  rc public.override_request_recipient,
  r  public.override_request,
  p_processed_late boolean default false
) returns jsonb
language plpgsql stable
set search_path = private, public, extensions, pg_temp
as $$
declare
  v_now  timestamptz := now();
  v_page jsonb;
  v_snap jsonb;
begin
  if v_now > r.receipt_expires_at then
    return jsonb_build_object('page', 'gone');
  end if;

  select s.payload into v_snap
    from public.override_request_snapshot s where s.request_id = r.id;

  if rc.status = 'voted' then
    v_page := jsonb_build_object('page', 'receipt',
                                 'vote', rc.vote, 'voted_at', rc.voted_at,
                                 'outcome', r.state);
  elsif rc.status = 'superseded' then
    v_page := jsonb_build_object('page', 'resolved', 'processed_late', p_processed_late);
  elsif rc.status = 'withdrawn' then
    v_page := jsonb_build_object('page', 'withdrawn');
  elsif rc.status = 'expired'
        or v_now > least(rc.expires_at, r.expires_at)
        or r.state = 'expired' then
    v_page := jsonb_build_object('page', 'expired');
  elsif r.state <> 'open' then
    -- Resolved while this recipient was still pending: step 9's close path
    -- will mark them withdrawn; until then the honest page is "resolved".
    v_page := jsonb_build_object('page', 'resolved', 'processed_late', p_processed_late);
  else
    v_page := jsonb_build_object('page', 'request', 'expires_at',
                                 least(rc.expires_at, r.expires_at));
  end if;

  if v_snap is not null then
    v_page := v_page || jsonb_build_object('snapshot', v_snap);
  end if;
  return v_page;
end;
$$;

-- MARK: - Reading a link

-- GET /a/<token>, in substance. Volatile because every open of a live link is
-- an audit event — the audit log is the longest-lived artifact here and
-- carries no PII: the edge function hashes the address and user agent before
-- they reach the database (§15).
create or replace function public.approval_page(
  p_token   text,
  p_ip_hash bytea default null,
  p_ua_hash bytea default null
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_rc public.override_request_recipient;
  v_r  public.override_request;
begin
  if p_token is null or p_token = '' then
    return jsonb_build_object('page', 'invalid');
  end if;

  select rc.* into v_rc from public.override_request_recipient rc
   where rc.token_hash = digest(p_token, 'sha256');
  if v_rc.id is null then
    -- Forged, truncated and foreign tokens land here, and land identically:
    -- constant shape, no timing worth measuring beyond the hash lookup.
    return jsonb_build_object('page', 'invalid');
  end if;

  select r.* into v_r from public.override_request r where r.id = v_rc.request_id;

  insert into public.override_request_event
         (request_id, kind, recipient_id, ip_hash, ua_hash)
       values (v_r.id, 'viewed', v_rc.id, p_ip_hash, p_ua_hash);

  return private.approval_page_for(v_rc, v_r);
end;
$$;

-- MARK: - The vote

-- The entire §8 transaction: record it, recount, decide, supersede — one
-- function call, one transaction, and the FOR UPDATE below is the whole
-- concurrency story. Every voter on a request locks the same request row, so
-- two partners tapping approve in the same instant are serialised here, the
-- count is taken after this voter's own update while the lock is held, and
-- `state = 'open'` guards the transition itself. There is no read-modify-write
-- window because there is no read outside the lock.
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
  v_rc       public.override_request_recipient;
  v_r        public.override_request;
  v_rc_id    uuid;
  v_req_id   uuid;
  v_now      timestamptz := now();
  v_approves int;
begin
  if p_vote not in ('approve', 'deny') then
    -- The page only posts these two. Anything else is a broken caller, not a
    -- partner state, and gets an error rather than a page.
    raise exception 'a vote is approve or deny' using errcode = '22023';
  end if;
  if p_token is null or p_token = '' then
    return jsonb_build_object('page', 'invalid');
  end if;

  -- Lock order, and it is load-bearing: the REQUEST row first, and recipient
  -- rows only ever under it. §8's sketch locked recipient-and-request in one
  -- join, and the concurrency drill promptly deadlocked it: the winning voter
  -- holds the request row and reaches for the losers' recipient rows to
  -- supersede them, while each loser holds its own recipient row and waits
  -- for the request. So voters take no recipient lock at all — one contended
  -- lock, one order, everywhere: creation's lazy expiry and the sweeper both
  -- update the request before its recipients too.
  select rc.id, rc.request_id
    into v_rc_id, v_req_id
    from public.override_request_recipient rc
   where rc.token_hash = digest(p_token, 'sha256');

  if v_rc_id is null then
    return jsonb_build_object('page', 'invalid');
  end if;

  select r.* into v_r
    from public.override_request r
   where r.id = v_req_id
     for update;

  -- Re-read the recipient under the lock: while this voter waited, the
  -- winner may have superseded them, and whatever was committed before the
  -- lock was won is what must be answered from.
  select rc.* into v_rc from public.override_request_recipient rc where rc.id = v_rc_id;

  -- A second vote from the same partner: their prior receipt, unchanged, and
  -- nothing recorded (§19). A vote after resolution: the resolved page with
  -- processed_late, and nothing recorded — the roster in the outcome is
  -- exactly the votes cast before resolution, which is what the partners
  -- were told (§6.2). Both are answered by the state they are already in.
  if v_rc.status <> 'pending' then
    return private.approval_page_for(v_rc, v_r, p_processed_late => true);
  end if;
  if v_r.state <> 'open' then
    return private.approval_page_for(v_rc, v_r, p_processed_late => true);
  end if;

  -- Expiry is honoured here even if no sweeper ever ran: the lapsed request
  -- is retired on the way past, exactly as creation does (0009).
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

  -- Deliberately NOT checked: the partner's live consent state. A partner who
  -- was suppressed or revoked after this token was minted still has a valid
  -- vote (S16) — they were legitimately asked before withdrawing, and
  -- suppression governs future contact, not a decision already placed in
  -- their hands. This is why the guard above reads recipient status and
  -- nothing else.

  update public.override_request_recipient
     set status = 'voted', vote = p_vote, voted_at = v_now
   where id = v_rc.id;

  insert into public.override_request_event
         (request_id, kind, recipient_id, detail, ip_hash, ua_hash)
       values (v_r.id, 'voted', v_rc.id, jsonb_build_object('vote', p_vote),
               p_ip_hash, p_ua_hash);

  -- Denials record a vote, consume no approval slot, and resolve nothing
  -- (S5): a denial is not a veto, and a request every partner has denied
  -- stays open until it expires — correct, because the requester's remaining
  -- route is Solo and it is already ticking.
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

-- The step-6 stub had a narrower signature; it is finished, not replaced.
drop function if exists public.cast_override_vote(text, text);

-- MARK: - The receipt window closes

-- §15, mechanically: when a request's receipt window passes, the snapshot is
-- purged and the recipient rows reduce to status-only — `status` says what
-- happened forever, but what was asked and how each person answered is not
-- kept beyond its purpose. The token hash stays with the row, which is what
-- keeps the link resolving to an honest 'gone' instead of the
-- suspicious-looking 'invalid' (§6.3).
--
-- For a scheduled job, alongside expire_override_requests. Nothing depends on
-- it having run: approval_page already answers 'gone' from the timestamp.
create or replace function public.purge_override_receipts() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_purged int;
begin
  update public.override_request_recipient rc
     set vote = null, voted_at = null
    from public.override_request r
   where r.id = rc.request_id and r.receipt_expires_at < now()
     and rc.voted_at is not null;

  delete from public.override_request_snapshot s
   using public.override_request r
   where r.id = s.request_id and r.receipt_expires_at < now();
  get diagnostics v_purged = row_count;

  return v_purged;
end;
$$;

-- MARK: - Who may call what

-- All of it is the server acting for the partner page. The account holder
-- never votes, never reads a token, and never sees this surface at all: an
-- app that could reach these functions could open its own approval links,
-- which is the one thing this whole design exists to prevent (S1).
revoke all on function public.approval_page(text, bytea, bytea)
  from public, anon, authenticated;
revoke all on function public.cast_override_vote(text, text, bytea, bytea)
  from public, anon, authenticated;
revoke all on function public.purge_override_receipts() from public, anon, authenticated;
revoke all on function private.approval_page_for(
  public.override_request_recipient, public.override_request, boolean)
  from public, anon, authenticated;

grant execute on function public.approval_page(text, bytea, bytea) to service_role;
grant execute on function public.cast_override_vote(text, text, bytea, bytea) to service_role;
grant execute on function public.purge_override_receipts() to service_role;
