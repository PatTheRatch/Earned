-- S4: the name a person is actually called, and push that actually arrives.
--
-- Two problems found by two real people on two real phones:
--
--   1. Social surfaces said "Someone". Apple sends a display name exactly
--      once, on the first authorization; every later sign-in — a second
--      device, a reinstall — returns nil. The app substituted the literal
--      string "Someone" and `ensure_account` wrote it straight over the name
--      the user had chosen in profile setup, because the upsert clobbered
--      unconditionally. One re-sign-in was enough to make a person anonymous
--      to their friends, permanently, on every surface at once.
--
--   2. Nothing drained push_outbox, so an invitation was only discovered by
--      opening the app and looking. Two people cannot use a product that
--      requires both of them to guess when to check.

-- MARK: - 1. A name is unknown, not "Someone"

-- Empty means unknown, and readers fall back to the handle. Before this, an
-- unknown name had to be spelled as some word, and every word available is a
-- lie — "Someone" most of all, because it renders identically for everybody
-- and so removes the one thing a social surface exists to show.
alter table public.account drop constraint if exists account_display_name_check;
alter table public.account
  add constraint account_display_name_check
  check (length(btrim(display_name)) between 0 and 64);

-- The clobber, fixed. A sign-in that knows no name must not erase one.
create or replace function public.ensure_account(
  p_apple_user_id text,
  p_display_name  text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row public.account;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  insert into public.account (auth_user_id, apple_user_id, display_name)
       values (auth.uid(), p_apple_user_id,
               coalesce(btrim(p_display_name), ''))
  on conflict (auth_user_id) do update
          -- Only a name that is actually a name may overwrite one. Apple's
          -- silence is not new information about what someone is called.
          set display_name = coalesce(nullif(btrim(excluded.display_name), ''),
                                      public.account.display_name)
    returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'display_name', v_row.display_name,
                            'created_at', v_row.created_at);
end;
$$;

-- What to call an account on a social surface: its name if it has one, its
-- handle if not. Deterministic, recognisable, and never the same string for
-- two different people — which is the whole failure of "Someone".
create or replace function private.social_name(p_account uuid) returns text
language sql stable
set search_path = public, private, extensions, pg_temp
as $$
  select coalesce(nullif(btrim(a.display_name), ''),
                  nullif('@' || p.handle, '@'),
                  'Earned user')
    from public.account a
    left join public.profile p on p.account_id = a.id
   where a.id = p_account;
$$;

-- MARK: - 2. Push that can be delivered

-- Where tapping the notification should land. Never an account id: the
-- recipient is a party to every one of these, so the agreement or request row
-- is theirs to know about, and their friend's account uuid is not.
alter table public.push_outbox add column if not exists route_id uuid;

-- Delivery bookkeeping, so a retry cannot show a person the same ask twice.
-- `sent_at` alone could not: a send that succeeded at APNs and failed to
-- record would be resent forever.
alter table public.push_outbox add column if not exists attempts int not null default 0;
alter table public.push_outbox add column if not exists claimed_at timestamptz;

-- MARK: - Better copy, and the block rule

-- Titles carry the person, because that is the whole point of the
-- notification: bodies are read second, and on a lock screen often not at all.
create or replace function private.enqueue_shared_invitation_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_inviter text;
  v_creator uuid;
  v_title   text;
begin
  select sa.creator, private.social_name(sa.creator), sa.title
    into v_creator, v_inviter, v_title
    from public.shared_commitment_agreement sa
   where sa.id = new.agreement_id;
  if v_creator is null then
    return new;  -- an orphaned agreement asks nobody
  end if;
  -- A block is not merely a filter on reads: it must stop the phone buzzing.
  if private.blocked_between(v_creator, new.account_id) then
    return new;
  end if;
  insert into public.push_outbox (account_id, kind, title, body, route_id)
       values (new.account_id, 'shared_invitation',
               private.neutralise_text(v_inviter, 64) || ' invited you.',
               private.neutralise_text(coalesce(v_title, 'A commitment'), 120),
               new.agreement_id);
  return new;
end;
$$;

create or replace function private.enqueue_partner_request_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_asker text;
begin
  if new.earned_account_id is null then return new; end if;
  if private.blocked_between(new.account_id, new.earned_account_id) then
    return new;
  end if;
  v_asker := private.social_name(new.account_id);
  insert into public.push_outbox (account_id, kind, title, body, route_id)
       values (new.earned_account_id, 'partner_request',
               private.neutralise_text(v_asker, 64)
                 || ' asked you to be an accountability partner.',
               'They want you to hold them to something.', null);
  return new;
end;
$$;

create or replace function private.enqueue_override_approval_push()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_target  uuid;
  v_asker   text;
  v_account uuid;
  v_title   text;
begin
  select p.earned_account_id, r.account_id, e.title
    into v_target, v_account, v_title
    from public.partner p
    join public.override_request r on r.id = new.request_id
    left join public.contract_envelope e
           on e.commitment_id = r.commitment_id and e.account_id = r.account_id
   where p.id = new.partner_id and p.kind = 'earned_user';
  if v_target is null then
    return new;  -- external partners get their link through message_outbox
  end if;
  v_asker := private.social_name(v_account);
  insert into public.push_outbox (account_id, kind, title, body, route_id)
       values (v_target, 'override_approval_request',
               private.neutralise_text(v_asker, 64) || ' needs an approval.',
               -- The commitment's own title only. Never the reason text, which
               -- is the requester's words to a chosen few and not lock-screen
               -- material (docs/accountability-architecture.md §13).
               private.neutralise_text(coalesce(v_title, 'A commitment'), 120),
               new.request_id);
  return new;
end;
$$;

-- MARK: - The sender's side

-- Claim a batch for delivery. `service_role` only: a client that could read
-- this could read other people's device tokens, which is the one thing the
-- table exists to keep.
--
-- Claiming rather than selecting is what makes retries safe. A row is handed
-- out once, and a second sender running concurrently — or the same sender
-- retried after a timeout — will not pick it up again until the claim ages
-- out, so a person is not told twice about one ask.
create or replace function public.claim_push_batch(
  p_limit int default 20,
  p_claim_timeout interval default interval '5 minutes'
) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_rows jsonb;
begin
  with claimed as (
    update public.push_outbox o
       set claimed_at = now(), attempts = o.attempts + 1
     where o.id in (
             select id from public.push_outbox
              where sent_at is null
                and attempts < 5
                and (claimed_at is null or claimed_at < now() - p_claim_timeout)
              order by created_at
              limit greatest(1, least(p_limit, 100))
              for update skip locked)
    returning o.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'kind', c.kind, 'title', c.title, 'body', c.body,
           'route_id', c.route_id,
           'tokens', (select coalesce(jsonb_agg(d.token), '[]'::jsonb)
                        from public.push_device d
                       where d.account_id = c.account_id))), '[]'::jsonb)
    into v_rows
    from claimed c;
  return v_rows;
end;
$$;

-- Delivered, or failed with a reason worth keeping. Separate from claiming so
-- a sender crash leaves the row claimable again rather than lost or resent.
create or replace function public.complete_push(
  p_id uuid, p_error text default null
) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  update public.push_outbox
     set sent_at = case when p_error is null then now() else null end,
         send_error = p_error,
         claimed_at = case when p_error is null then claimed_at else null end
   where id = p_id;
end;
$$;

-- APNs says a token is gone (410 Unregistered). Believing it is the only way
-- the table stays the size of the fleet rather than the size of its history.
create or replace function public.forget_push_token(p_token text) returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  delete from public.push_device where token = p_token;
end;
$$;

-- Retire asks nobody needs any more, so a phone that was off for a week does
-- not wake to a decision that was made without it.
create or replace function public.purge_push_outbox() returns int
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.push_outbox
   where created_at < now() - interval '7 days'
      or (sent_at is not null and sent_at < now() - interval '2 days');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- MARK: - Grants

revoke all on function public.claim_push_batch(int, interval) from public, anon, authenticated;
revoke all on function public.complete_push(uuid, text) from public, anon, authenticated;
revoke all on function public.forget_push_token(text) from public, anon, authenticated;
revoke all on function public.purge_push_outbox() from public, anon, authenticated;
revoke all on function private.social_name(uuid) from public, anon, authenticated;
grant execute on function public.claim_push_batch(int, interval) to service_role;
grant execute on function public.complete_push(uuid, text) to service_role;
grant execute on function public.forget_push_token(text) to service_role;
grant execute on function public.purge_push_outbox() to service_role;
