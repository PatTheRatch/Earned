-- The gap between promoting a key and publishing that promotion
-- (docs/accountability-architecture.md §10.3).
--
-- 0008 got the order right: a key must appear in a *published* key set before
-- it may be promoted, so every polling client has had the chance to learn it.
-- What that order guarantees is that clients know the key exists. What it does
-- not guarantee — and what nothing checked until now — is that clients know
-- the key is allowed to *sign*.
--
-- The published document is a snapshot, and it is taken before promotion by
-- construction. So immediately after `promote_grant_key('g1')` the newest
-- published set still says `g1` is `next`, and stays wrong until a human with
-- the offline root key publishes again. Nothing in the schema noticed, and
-- nothing could: publishing needs a key that deliberately does not exist on
-- any server.
--
-- That window is where a whole class of silent failure lives. A client that
-- refuses a signature from a key its key set calls `next` is doing exactly
-- what §10.3 says to do — and would have refused every grant this system has
-- ever produced, because the runbook promoted and stopped. The user would see
-- a locked phone and a signature error, on a system where every component was
-- behaving as designed.
--
-- A client that instead accepts `next` keys has given up the only mechanism
-- that makes publication mean anything: it would honour a signature from a key
-- nobody was ever told could sign.
--
-- Neither of those is fixable on the phone, so this fixes it here. The server
-- refuses to nominate a signing key that the newest published key set does not
-- show as `current`, which converts an invisible client-side lockout into an
-- error an operator reads in the function log, while the affected users still
-- have the Solo route (§11, S8). The cost is one extra `publish_key_set` after
-- every promotion, which the runbook now does and 5.3's check now proves.
--
-- Replaces 0008's version of this function; 0008 is left exactly as applied.

create or replace function public.current_signing_kid() returns text
language plpgsql stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_kid   text;
  v_state text;
  v_doc   jsonb;
begin
  select k.kid into v_kid
    from public.grant_signing_key k
   where k.state = 'current'
     and k.not_before <= now()
     and (k.not_after is null or k.not_after > now());
  if v_kid is null then
    raise exception 'no signing key is current' using errcode = '55000';
  end if;

  -- What clients actually hold, rather than what this table believes. The
  -- newest published document is the only thing an app has ever seen, so it
  -- is read on its own first: a kid absent from the newest set but present in
  -- an older one is precisely the drift being looked for, and a query that
  -- joined across versions would find the stale answer and call it fine.
  select document::jsonb into v_doc
    from public.key_set order by version desc limit 1;
  if v_doc is null then
    raise exception 'no key set has been published' using errcode = '55000';
  end if;

  select key ->> 'state' into v_state
    from jsonb_array_elements(v_doc -> 'keys') as key
   where key ->> 'kid' = v_kid;

  if v_state is null then
    raise exception 'signing key % is not in the published key set; publish_key_set() first', v_kid
      using errcode = '55000';
  end if;
  if v_state <> 'current' then
    raise exception
      'signing key % is % in the published key set, not current; publish_key_set() again after promoting',
      v_kid, v_state
      using errcode = '55000';
  end if;

  return v_kid;
end;
$$;

revoke all on function public.current_signing_kid() from public, anon, authenticated;
grant execute on function public.current_signing_kid() to service_role;
