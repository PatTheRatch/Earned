-- Nominating a partner, and what happens when they answer.
--
-- Every function here is the server acting on its own: the contact is
-- normalised, hashed and encrypted here, the invitation is composed and queued
-- here, and the token is never returned to the caller. An app that could see
-- the token could consent on its partner's behalf, which would make the whole
-- mechanism theatre.

-- How many partners an account may hold at once (NORTHSTAR §23).
create or replace function private.max_partners() returns int
language sql immutable as $$ select 5 $$;

-- New nominations per account per rolling day. Deliberately low: the harm being
-- prevented is not a compromised server, it is Earned becoming a way to text
-- someone repeatedly.
create or replace function private.max_nominations_per_day() returns int
language sql immutable as $$ select 5 $$;

create or replace function private.invitation_lifetime() returns interval
language sql immutable as $$ select interval '14 days' $$;

-- MARK: - Nominate

create or replace function public.nominate_partner(
  p_display_name text,
  p_channel      text,
  p_contact      text
) returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_account    uuid;
  v_normalized text;
  v_lookup     bytea;
  v_partner    public.partner;
  v_token      text;
  v_now        timestamptz := now();
  v_count      int;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  if length(btrim(coalesce(p_display_name, ''))) = 0 then
    raise exception 'a partner needs a name you will recognise' using errcode = '22023';
  end if;

  v_normalized := public.normalize_contact(p_channel, p_contact);
  v_lookup     := private.contact_lookup(v_normalized);

  -- You are not your own accountability partner. Only catchable where the
  -- account has a verified address of its own; a spare SIM or an email alias
  -- still gets through, and §2.2 says so rather than implying otherwise.
  if exists (select 1 from public.account a
              where a.id = v_account and a.verified_email_lookup = v_lookup) then
    raise exception 'that is your own address — an accountability partner has to be someone else'
      using errcode = '23514';
  end if;

  -- Global, cross-account. The message deliberately does not say whether they
  -- opted out, bounced or complained: that is a stranger's business, and the
  -- person typing the number may well know who they are.
  if exists (select 1 from public.contact_suppression s
              where s.contact_lookup = v_lookup and s.channel = p_channel) then
    raise exception 'Earned can''t send messages to this contact' using errcode = '23514';
  end if;

  select count(*) into v_count from public.partner p
   where p.account_id = v_account and p.status in ('invited', 'active');
  if v_count >= private.max_partners() then
    raise exception 'you can have at most % accountability partners', private.max_partners()
      using errcode = '23514';
  end if;

  select count(*) into v_count from public.partner p
   where p.account_id = v_account and p.created_at > v_now - interval '1 day';
  if v_count >= private.max_nominations_per_day() then
    raise exception 'too many invitations today — try again tomorrow' using errcode = '53400';
  end if;

  select * into v_partner from public.partner p
   where p.account_id = v_account and p.channel = p_channel and p.contact_lookup = v_lookup;

  if v_partner.id is not null then
    -- One consent request per contact per account, ever. A partner the user
    -- removed is not re-askable: that is the whole of the protection.
    raise exception 'you have already invited this contact' using errcode = '23505';
  end if;

  insert into public.partner (account_id, display_name, channel,
                              contact_ciphertext, contact_lookup, status, consent_asked_at)
       values (v_account, btrim(p_display_name), p_channel,
               private.contact_encrypt(v_normalized), v_lookup, 'invited', v_now)
    returning * into v_partner;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.partner_invitation (partner_id, token_hash, expires_at)
       values (v_partner.id, digest(v_token, 'sha256'), v_now + private.invitation_lifetime());

  insert into public.message_outbox (channel, to_ciphertext, body)
       values (p_channel, v_partner.contact_ciphertext,
               (select a.display_name from public.account a where a.id = v_account)
               || ' added you as an accountability partner on Earned. If they ask to be let '
               || 'out of a commitment, you''ll get a message. Reply here: '
               || private.secret('consent_base_url') || '/c/' || v_token);

  -- Note what is not in here: the token.
  return jsonb_build_object('id', v_partner.id, 'display_name', v_partner.display_name,
                            'channel', v_partner.channel, 'status', v_partner.status,
                            'consent_asked_at', v_partner.consent_asked_at);
end;
$$;

-- MARK: - Resend

-- At most one, no sooner than 72 hours, and only if the first went unanswered.
create or replace function public.resend_partner_invitation(p_partner_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_account uuid;
  v_partner public.partner;
  v_first   public.partner_invitation;
  v_token   text;
  v_now     timestamptz := now();
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  select * into v_partner from public.partner p
   where p.id = p_partner_id and p.account_id = v_account;
  if v_partner.id is null then
    raise exception 'no such partner' using errcode = '42501';
  end if;
  if v_partner.status <> 'invited' then
    raise exception 'that invitation has already been answered' using errcode = '23514';
  end if;
  if exists (select 1 from public.contact_suppression s
              where s.contact_lookup = v_partner.contact_lookup
                and s.channel = v_partner.channel) then
    raise exception 'Earned can''t send messages to this contact' using errcode = '23514';
  end if;
  if exists (select 1 from public.partner_invitation i
              where i.partner_id = p_partner_id and i.is_resend) then
    raise exception 'you have already sent a reminder' using errcode = '23514';
  end if;

  select * into v_first from public.partner_invitation i
   where i.partner_id = p_partner_id order by i.sent_at limit 1;
  if v_first.sent_at > v_now - interval '72 hours' then
    raise exception 'a reminder can only be sent 72 hours after the invitation'
      using errcode = '53400';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.partner_invitation (partner_id, token_hash, expires_at, is_resend)
       values (p_partner_id, digest(v_token, 'sha256'),
               v_now + private.invitation_lifetime(), true);
  insert into public.message_outbox (channel, to_ciphertext, body)
       values (v_partner.channel, v_partner.contact_ciphertext,
               'A reminder from Earned: '
               || (select a.display_name from public.account a where a.id = v_account)
               || ' asked you to be an accountability partner. '
               || private.secret('consent_base_url') || '/c/' || v_token);

  update public.partner set consent_resent_at = v_now where id = p_partner_id;
  return jsonb_build_object('id', p_partner_id, 'resent_at', v_now);
end;
$$;

-- MARK: - Respond

-- Called by the edge function that renders the consent page, never by an app.
-- The page is server-rendered and holds the service role; no Supabase
-- credential is ever shipped to a partner's browser (§18).
create or replace function public.respond_to_invitation(p_token text, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_invitation public.partner_invitation;
  v_partner    public.partner;
  v_now        timestamptz := now();
begin
  select * into v_invitation from public.partner_invitation i
   where i.token_hash = digest(coalesce(p_token, ''), 'sha256');
  if v_invitation.id is null then
    raise exception 'this link is not valid' using errcode = '42501';
  end if;
  if v_invitation.responded_at is not null then
    raise exception 'this invitation has already been answered' using errcode = '23514';
  end if;
  if v_now > v_invitation.expires_at then
    raise exception 'this invitation has expired' using errcode = '23514';
  end if;

  select * into v_partner from public.partner p where p.id = v_invitation.partner_id;

  update public.partner_invitation
     set responded_at = v_now,
         response = case when p_accept then 'accepted' else 'declined' end
   where id = v_invitation.id;

  if p_accept then
    update public.partner
       set status = 'active', consented_at = v_now, revoked_at = null
     where id = v_partner.id;
  else
    update public.partner
       set status = 'declined', revoked_at = v_now
     where id = v_partner.id;
    -- The refusal is global. Any other Earned account that types this contact
    -- in later is refused before a message is composed, let alone sent.
    insert into public.contact_suppression (contact_lookup, channel, reason)
         values (v_partner.contact_lookup, v_partner.channel, 'optout')
    on conflict (contact_lookup, channel) do nothing;
    -- Every outstanding invitation to this contact dies with the refusal,
    -- including one another account sent before they answered ours.
    update public.partner_invitation i
       set responded_at = v_now, response = 'declined'
      from public.partner p
     where i.partner_id = p.id
       and p.contact_lookup = v_partner.contact_lookup
       and p.channel = v_partner.channel
       and i.responded_at is null;
    update public.partner p
       set status = 'declined', revoked_at = v_now
     where p.contact_lookup = v_partner.contact_lookup
       and p.channel = v_partner.channel
       and p.status = 'invited';
  end if;

  return jsonb_build_object('accepted', p_accept, 'at', v_now);
end;
$$;

-- MARK: - Revoke

-- The account holder removing a partner. Not a refusal: no suppression row,
-- because this person did not decline anything. It never lowers a threshold —
-- a contract that becomes unreachable becomes unreachable, and that is the
-- direction the Monotonic Commitment Principle points (§4.3).
create or replace function public.revoke_partner(p_partner_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_account uuid;
  v_now     timestamptz := now();
  v_rows    int;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then
    raise exception 'no account for caller' using errcode = '28000';
  end if;

  update public.partner
     set status = 'revoked', revoked_at = v_now
   where id = p_partner_id and account_id = v_account and status <> 'declined';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'no such partner' using errcode = '42501';
  end if;

  update public.partner_invitation
     set responded_at = v_now
   where partner_id = p_partner_id and responded_at is null;

  return jsonb_build_object('id', p_partner_id, 'revoked_at', v_now);
end;
$$;

-- MARK: - Grants

alter table public.contact_suppression  enable row level security;
alter table public.partner_invitation   enable row level security;
alter table public.message_outbox       enable row level security;

revoke all on public.contact_suppression from anon, authenticated;
revoke all on public.partner_invitation  from anon, authenticated;
revoke all on public.message_outbox      from anon, authenticated;

-- No policies at all on these three. Suppression is other people's refusals,
-- invitations carry token hashes, and the outbox holds the links themselves —
-- none of it is the account holder's to read.

revoke all on function public.nominate_partner(text, text, text) from public, anon;
revoke all on function public.resend_partner_invitation(uuid) from public, anon;
revoke all on function public.revoke_partner(uuid) from public, anon;
revoke all on function public.respond_to_invitation(text, boolean) from public, anon, authenticated;
revoke all on function private.secret(text) from public, anon, authenticated;
revoke all on function private.contact_lookup(text) from public, anon, authenticated;
revoke all on function private.contact_encrypt(text) from public, anon, authenticated;

grant execute on function public.nominate_partner(text, text, text) to authenticated;
grant execute on function public.resend_partner_invitation(uuid) to authenticated;
grant execute on function public.revoke_partner(uuid) to authenticated;
grant execute on function public.normalize_contact(text, text) to authenticated;
-- Deliberately service_role only: the consent page is server-rendered.
grant execute on function public.respond_to_invitation(text, boolean) to service_role;
