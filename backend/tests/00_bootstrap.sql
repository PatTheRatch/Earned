-- Test-only scaffolding for the parts Supabase provides in production.
--
-- Nothing here ships. It exists so the migrations can be run and exercised
-- against a plain Postgres in CI. `auth.uid()` is reproduced from Supabase's
-- own definition rather than simplified — a shim that read the account id
-- some easier way would let these tests pass while production failed.

create schema if not exists auth;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;

-- Become a signed-in user with the given auth uid.
create or replace function test_sign_in(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, false);
end;
$$;

create or replace function test_sign_out() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', false);
end;
$$;

-- Fail loudly with a message naming the expectation, rather than a bare
-- assertion nobody can read in a CI log.
create or replace function test_assert(p_condition boolean, p_what text) returns void
language plpgsql as $$
begin
  if p_condition is not true then
    raise exception 'FAILED: %', p_what;
  end if;
  raise notice '  ok  %', p_what;
end;
$$;

-- Assert that a statement raises. Used for every rule that exists to refuse
-- something: a rule nobody proved refuses anything is decoration.
create or replace function test_raises(p_sql text, p_what text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice '  ok  % (%)', p_what, replace(sqlerrm, E'\n', ' ');
    return;
  end;
  raise exception 'FAILED: expected a refusal — %', p_what;
end;
$$;

-- Contact-crypto keys and the consent link's base URL. Production reads these
-- from Supabase Vault; the GUC fallback exists so the suite runs on a plain
-- Postgres. See private.secret, and the launch gate about key custody.
do $$
declare
  v_db text := current_database();
begin
  execute format('alter database %I set app.contact_pepper = %L', v_db,
                 'test-pepper-not-a-real-secret');
  execute format('alter database %I set app.contact_key = %L', v_db,
                 'test-key-not-a-real-secret');
  execute format('alter database %I set app.consent_base_url = %L', v_db,
                 'https://earned.test');
end
$$;

-- The consent token exists only inside the outbound message — that is the
-- point of it. To exercise the consent flow the suite has to read it the way
-- the consent page's edge function does: by being the server.
-- plpgsql rather than sql, because this file runs *before* the migrations that
-- create the tables it names, and a `language sql` body is parsed at creation.
create or replace function test_token_for(p_display_name text) returns text
language plpgsql as $$
declare
  v_token text;
begin
  select substring(o.body from 'https://earned\.test/c/([0-9a-f]+)')
    into v_token
    from public.message_outbox o
    join public.partner p on p.contact_ciphertext = o.to_ciphertext
   where p.display_name = p_display_name
   order by o.created_at desc
   limit 1;
  return v_token;
end;
$$;
