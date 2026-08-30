-- Milestone A: accounts and the partner skeleton.
--
-- Deliberately thin (NORTHSTAR §34, minimum knowledge). The server learns who
-- the account is and who it is allowed to contact. It learns nothing about
-- what the user does.
--
-- Partner consent, suppression and messaging are NOT in this migration. The
-- columns that carry them exist so the shape is right from the start, but no
-- code reads them yet and no message is ever sent. See
-- docs/accountability-architecture.md §14 for the flow they are waiting for.

create extension if not exists pgcrypto;

create table if not exists public.account (
  id                     uuid primary key default gen_random_uuid(),
  -- The Supabase auth user. Deliberately NOT a foreign key into auth.users:
  -- a cascade here would quietly decide what account deletion does to an
  -- outstanding obligation, and that is D10 — the one decision this design
  -- leaves open pending privacy/legal review. Encoding an answer in a
  -- constraint would be deciding it by accident.
  auth_user_id           uuid        not null unique,
  -- Sign in with Apple's stable subject. The only identifier Earned holds for
  -- a person, and it is opaque: Apple's, not ours, and not an email address.
  apple_user_id          text        not null unique,
  -- Shown to accountability partners. A first name is enough, and it is the
  -- only user-authored text about the account that ever reaches a stranger.
  display_name           text        not null check (length(btrim(display_name)) between 1 and 64),
  -- Blind index of the account's own verified address, so a requester can be
  -- refused when nominating themselves as their own partner (§2.2). Null until
  -- there is a verified address to derive it from.
  verified_email_lookup  bytea,
  created_at             timestamptz not null default now(),
  deleted_at             timestamptz
);

create table if not exists public.partner (
  id                  uuid        primary key default gen_random_uuid(),
  account_id          uuid        not null references public.account(id) on delete cascade,
  display_name        text        not null check (length(btrim(display_name)) between 1 and 64),
  channel             text        not null check (channel in ('sms', 'email')),
  -- Settled as S14: the distinction between an anonymous contact that merely
  -- consented and a partner with their own authenticated Earned account is
  -- built now, and required by nothing. Server-side link delivery stops a
  -- requester from automatically receiving their own approval tokens; it does
  -- not prove a partner is a different human (§2.2), and this column is where
  -- a future policy would be able to tell the difference.
  kind                text        not null default 'unverified_contact'
                        check (kind in ('unverified_contact', 'earned_user')),
  -- Randomised authenticated encryption. Never returned to any client — not to
  -- the partner's own page, and not to the app that nominated them.
  contact_ciphertext  bytea       not null,
  -- HMAC(pepper, normalised contact). Deterministic, so it can carry the unique
  -- constraint below and the cross-account suppression list later. Keyed rather
  -- than a bare digest because the space of phone numbers is small enough to
  -- exhaust offline (§14.1).
  contact_lookup      bytea       not null,
  lookup_key_version  int         not null default 1 check (lookup_key_version >= 1),
  consented_at        timestamptz,
  consent_asked_at    timestamptz,
  consent_resent_at   timestamptz,
  revoked_at          timestamptz,
  created_at          timestamptz not null default now(),
  -- Deterministic, so this constraint actually fires. The ciphertext could
  -- never have carried it: two encryptions of one number differ.
  unique (account_id, channel, contact_lookup)
);

create index if not exists partner_account_idx on public.partner (account_id);
