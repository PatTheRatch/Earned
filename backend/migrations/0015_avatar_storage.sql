-- Milestone S1: avatars (docs/social-architecture.md §6).
--
-- One private Storage bucket, `avatars`, holding one current image per
-- account at `<account_id>/<random-uuid>.jpg`. The path carries an opaque
-- uuid and a random name — no handle, no contact information.
--
-- The visibility *rule* lives here in public functions so the plain-Postgres
-- test suite can hold it to the design; the storage policies at the bottom
-- delegate to those functions and are guarded on the `storage` schema
-- existing, because CI's bare Postgres has no Supabase Storage to police.
--
-- Replacement is revocation: `profile.avatar_path` points at the current
-- object, and visibility for everyone but the owner is defined as *being
-- someone's current avatar* — so the moment the pointer moves, the replaced
-- object is unreadable by anyone else, before its deletion even lands.

-- MARK: - The rules, testable without Storage

-- Does this object name sit inside the caller's own folder, shaped like an
-- avatar? The write-side rule: an account writes under its own id, nothing
-- else, nowhere else.
create or replace function public.avatar_path_is_mine(p_name text) returns boolean
language plpgsql stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_account uuid;
begin
  select a.id into v_account from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_account is null then return false; end if;
  return p_name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'
     and split_part(p_name, '/', 1) = v_account::text;
end;
$$;

-- May the caller read this object? The read-side rule (§6.3):
--   owner            — yes, current or not (it is their file)
--   accepted friend  — yes, if it is the owner's current avatar
--   stranger         — yes, if current avatar and the owner is discoverable
--   either side of a block, anon, or a replaced object — no
create or replace function public.avatar_is_visible(p_name text) returns boolean
language plpgsql stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_viewer uuid;
  v_owner  uuid;
  v_current boolean;
  v_friends boolean;
begin
  select a.id into v_viewer from public.account a
   where a.auth_user_id = auth.uid() and a.deleted_at is null;
  if v_viewer is null then return false; end if;

  if p_name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$' then return false; end if;
  begin
    v_owner := split_part(p_name, '/', 1)::uuid;
  exception when others then
    return false;
  end;

  if v_owner = v_viewer then return true; end if;

  select p.avatar_path = p_name, p.discoverable
    into v_current, v_friends  -- v_friends reused below; here it is discoverable
    from public.profile p
    join public.account a on a.id = p.account_id and a.deleted_at is null
   where p.account_id = v_owner;
  if v_current is distinct from true then return false; end if;

  if private.blocked_between(v_viewer, v_owner) then return false; end if;

  if exists (select 1 from public.friendship f
              where f.account_low = least(v_viewer, v_owner)
                and f.account_high = greatest(v_viewer, v_owner)
                and f.status = 'accepted') then
    return true;
  end if;

  return v_friends;  -- a stranger sees it exactly where they'd see the profile
end;
$$;

-- Point the profile at a freshly uploaded object. Returns the path it
-- replaced so the client can delete the orphan; the *visibility* of the old
-- object died with this update either way.
create or replace function public.set_my_avatar(p_path text) returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller   uuid := private.social_caller();
  v_previous text;
begin
  if p_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'
     or split_part(p_path, '/', 1) <> v_caller::text then
    raise exception 'not your avatar path' using errcode = '22023';
  end if;

  select p.avatar_path into v_previous from public.profile p
   where p.account_id = v_caller;
  update public.profile
     set avatar_path = p_path, updated_at = now()
   where account_id = v_caller;
  -- The path being replaced, so the client can delete the orphaned object.
  return jsonb_build_object('previous', v_previous);
end;
$$;

create or replace function public.clear_my_avatar() returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_caller   uuid := private.social_caller();
  v_previous text;
begin
  select p.avatar_path into v_previous from public.profile p
   where p.account_id = v_caller;
  update public.profile
     set avatar_path = null, updated_at = now()
   where account_id = v_caller;
  return jsonb_build_object('previous', v_previous);
end;
$$;

revoke all on function public.avatar_path_is_mine(text) from public, anon;
revoke all on function public.avatar_is_visible(text) from public, anon;
revoke all on function public.set_my_avatar(text) from public, anon;
revoke all on function public.clear_my_avatar() from public, anon;

grant execute on function public.avatar_path_is_mine(text) to authenticated;
grant execute on function public.avatar_is_visible(text) to authenticated;
grant execute on function public.set_my_avatar(text) to authenticated;
grant execute on function public.clear_my_avatar() to authenticated;

-- MARK: - The bucket and its policies, where Storage exists

-- Supabase only. The client talks to Storage with the user's own JWT; no
-- administration credential is ever in the app. The bucket enforces the
-- server-side caps — 1 MB, JPEG only — so the client's re-encode is a
-- courtesy, not the boundary.
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent (plain Postgres) — bucket and policies skipped';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
       values ('avatars', 'avatars', false, 1048576, array['image/jpeg'])
  on conflict (id) do update
          set public = false,
              file_size_limit = 1048576,
              allowed_mime_types = array['image/jpeg'];

  execute 'drop policy if exists avatars_read on storage.objects';
  execute $pol$
    create policy avatars_read on storage.objects
      for select to authenticated
      using (bucket_id = 'avatars' and public.avatar_is_visible(name))
  $pol$;

  execute 'drop policy if exists avatars_insert on storage.objects';
  execute $pol$
    create policy avatars_insert on storage.objects
      for insert to authenticated
      with check (bucket_id = 'avatars' and public.avatar_path_is_mine(name))
  $pol$;

  execute 'drop policy if exists avatars_update on storage.objects';
  execute $pol$
    create policy avatars_update on storage.objects
      for update to authenticated
      using (bucket_id = 'avatars' and public.avatar_path_is_mine(name))
      with check (bucket_id = 'avatars' and public.avatar_path_is_mine(name))
  $pol$;

  execute 'drop policy if exists avatars_delete on storage.objects';
  execute $pol$
    create policy avatars_delete on storage.objects
      for delete to authenticated
      using (bucket_id = 'avatars' and public.avatar_path_is_mine(name))
  $pol$;
end
$$;
