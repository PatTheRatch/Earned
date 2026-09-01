-- Close an open override request when the requester's situation resolves
-- (docs/accountability-architecture.md §12, §6.2, §6.3).
--
-- Build order step 9. The schema (0009) reserved the terminal states
-- `cancelled` and `moot`; the approval page (0010) already renders the
-- `withdrawn` recipient page; and EarnedKit already moots the request locally
-- (testWorkoutMootsOpenRequest) — but nothing on the server ever produced
-- those states. Until now an approval link stayed live (and approvable,
-- minting a grant) for the full 24-hour lifetime even after the requester
-- finished the workout or withdrew the ask. This is the missing writer.
--
-- The courtesy message goes to external partners only — the exact analogue of
-- create_override_request's delivery rule (0019): an earned_user partner has
-- no contact address and no outbox row; their surface is my_pending_approvals,
-- which simply stops listing the request once its recipients leave `pending`.

create or replace function public.close_override_request(
  p_commitment_id uuid,
  p_outcome       text
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
  v_name    text;
  v_req     public.override_request;
  v_now     timestamptz := now();
  v_body    text;
begin
  select a.id, a.display_name into v_account, v_name
    from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  if p_outcome not in ('moot', 'cancelled') then
    raise exception 'an outcome is moot or cancelled' using errcode = '22023';
  end if;

  -- The caller's latest request for this commitment, and nothing else. An
  -- account can only ever close its own request, and a commitment nobody asked
  -- about is a no-op — not an error, and not someone else's request.
  select * into v_req from public.override_request r
   where r.account_id = v_account and r.commitment_id = p_commitment_id
   order by r.requested_at desc limit 1;

  if v_req.id is null then
    return jsonb_build_object('commitment_id', p_commitment_id, 'open', false);
  end if;

  -- Lazy expiry, the same retirement create_override_request applies before
  -- its own write: an open request that has elapsed is expired even if the
  -- sweeper has not run, and there is then no open request left to close.
  if v_req.state = 'open' and v_req.expires_at <= v_now then
    update public.override_request
       set state = 'expired', resolved_at = v_now,
           receipt_expires_at = v_now + private.receipt_window()
     where id = v_req.id and state = 'open';
    update public.override_request_recipient
       set status = 'expired'
     where request_id = v_req.id and status = 'pending';
    return jsonb_build_object(
      'commitment_id', p_commitment_id, 'state', 'expired', 'id', v_req.id);
  end if;

  -- Idempotent: only an open request is closed. A granted, expired, or
  -- already moot/cancelled request returns its state untouched — votes already
  -- cast stand, and no second round of messages goes out.
  if v_req.state <> 'open' then
    return jsonb_build_object(
      'commitment_id', p_commitment_id, 'state', v_req.state, 'id', v_req.id);
  end if;

  -- The close. §6.3 collapses the receipt window immediately on moot and
  -- cancellation, so a leaked link cannot re-render the frozen snapshot past
  -- resolution — it resolves to the generic `gone` page rather than the
  -- `withdrawn` courtesy (§6.2). That is deliberate: the courtesy reaches the
  -- human through the outbox message below (§12), and the link was always the
  -- fallback path, not the primary one.
  update public.override_request
     set state = p_outcome, resolved_at = v_now,
         receipt_expires_at = v_now
   where id = v_req.id and state = 'open';

  -- Every still-pending recipient is withdrawn: their link stops mattering.
  update public.override_request_recipient
     set status = 'withdrawn'
   where request_id = v_req.id and status = 'pending';

  -- A courtesy message to the external partners who were asked, so an
  -- interrupted human learns it resolved. An earned_user partner gets nothing
  -- here: their surface is my_pending_approvals, and the row simply leaves
  -- `pending` so it stops being listed.
  v_body := private.neutralise_text(v_name, 64)
            || case when p_outcome = 'moot'
                     then ' finished the commitment. No action needed.'
                     else ' cancelled the request. No action needed.' end;

  insert into public.message_outbox (channel, to_ciphertext, body)
    select p.channel, p.contact_ciphertext, v_body
      from public.override_request_recipient rc
      join public.partner p on p.id = rc.partner_id
     where rc.request_id = v_req.id
       and p.kind <> 'earned_user'
       and not exists (select 1 from public.contact_suppression s
                        where s.contact_lookup = p.contact_lookup
                          and s.channel = p.channel);

  insert into public.override_request_event (request_id, kind, detail)
       values (v_req.id, 'resolved', jsonb_build_object('outcome', p_outcome));

  return jsonb_build_object(
    'commitment_id', p_commitment_id, 'state', p_outcome, 'id', v_req.id);
end;
$$;

-- The requesting app is the caller: the account holder closes their own
-- request. Nobody anonymous, and never a different account.
revoke all on function public.close_override_request(uuid, text) from public, anon;
grant execute on function public.close_override_request(uuid, text) to authenticated;
