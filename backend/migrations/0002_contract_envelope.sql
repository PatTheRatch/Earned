-- The Contract Envelope (docs/accountability-architecture.md §4).
--
-- The accountability terms of a commitment, held where the user cannot edit
-- them. This exists because the threat model treats the account holder as the
-- adversary: a modified client that asks for a threshold of 1 against a
-- contract that hardened at 2 must be refused by something it does not control.
--
-- What is deliberately NOT here: HealthKit workouts, Screen Time tokens,
-- restricted app identities, hydration, streaks, debt, reward eligibility.
-- The server learns that an obligation exists, when it hardened and when it is
-- due. It does not learn what the user does about it.

-- Windows are `double precision` seconds rather than integers because
-- EarnedKit's TimeInterval is a Double. Rounding here would be a silent
-- divergence in exactly the arithmetic both sides have to agree on.
create table public.contract_envelope (
  account_id            uuid        not null references public.account(id) on delete cascade,
  commitment_id         uuid        not null,
  plan_id               uuid,
  title                 text        not null check (length(btrim(title)) between 1 and 200),
  -- The commitment's creation instant, not the row's. For a plan occurrence
  -- this is the *plan's* creation instant, because a plan hardens as a whole.
  created_at            timestamptz not null,
  eligible_from         timestamptz not null,
  deadline              timestamptz not null,
  correction_window     double precision not null check (correction_window >= 0),
  approvals_required    int         not null check (approvals_required between 1 and 5),
  accountability_window double precision not null check (accountability_window >= 0),
  version               int         not null default 1 check (version >= 1),
  policy_digest         bytea       not null,
  -- Computed by trigger, never accepted from a caller. Not a generated column
  -- only because the arithmetic needs `to_timestamp` and `extract`, which
  -- Postgres marks STABLE rather than IMMUTABLE; a trigger has no such
  -- constraint and is equally beyond a client's reach.
  hardens_at            timestamptz not null,
  first_seen_at         timestamptz not null default now(),
  -- True when the envelope did not reach the server until the commitment had
  -- already hardened. Settled as S13: the accountability route is unavailable
  -- for such a commitment and the Solo Override remains. Being offline can
  -- close an escape route; it must never open one.
  is_late               boolean     not null default false,
  withdrawn_at          timestamptz,
  registered_at         timestamptz not null default now(),
  primary key (account_id, commitment_id)
);

create index contract_envelope_plan_idx on public.contract_envelope (account_id, plan_id)
  where plan_id is not null;

create table public.contract_envelope_partner (
  account_id    uuid not null,
  commitment_id uuid not null,
  partner_id    uuid not null references public.partner(id) on delete cascade,
  primary key (account_id, commitment_id, partner_id),
  foreign key (account_id, commitment_id)
    references public.contract_envelope(account_id, commitment_id) on delete cascade
);

-- MARK: - Hardening, the rule both sides must agree on

-- When a commitment's correction window closes.
--
--     hardensAt = createdAt + min(correctionWindow, max(0, deadline - createdAt) * 0.125)
--
-- A literal transcription of EarnedKit's `Commitment.hardensAt`, and pinned
-- against the same fixtures: fixtures/hardening-cases.json. Do not "simplify"
-- this without running backend/tests/20_hardening_parity — several obvious
-- rewrites are wrong:
--
--   * `greatest(0, …)` is not decoration. A deadline before creation would
--     otherwise produce a window in the past, and the server would think a
--     commitment hardened before it was made.
--   * Everything is cast to `double precision` so the arithmetic is IEEE-754
--     binary, the same as Swift's TimeInterval. `extract(epoch …)` returns
--     `numeric` on modern Postgres, and exact decimal arithmetic disagrees
--     with binary floating point on values a user can actually produce.
--   * `to_timestamp` on epoch seconds is absolute-time arithmetic. Adding an
--     interval that carries days or months is *calendar* arithmetic, which is
--     an hour wrong across a daylight-saving boundary. Two fixtures exist
--     purely to catch that.
create or replace function public.earned_hardens_at(
  p_created_at        timestamptz,
  p_deadline          timestamptz,
  p_correction_window double precision
) returns timestamptz
language sql
stable
as $$
  select to_timestamp(
    extract(epoch from p_created_at)::double precision
      + least(
          p_correction_window,
          greatest(
            0::double precision,
            extract(epoch from p_deadline)::double precision
              - extract(epoch from p_created_at)::double precision
          ) * 0.125::double precision
        )
  )
$$;

comment on function public.earned_hardens_at is
  'Mirror of EarnedKit Commitment.hardensAt. Pinned by fixtures/hardening-cases.json.';

create or replace function public.contract_envelope_set_hardens_at()
returns trigger language plpgsql as $$
begin
  -- Unconditional: whatever a caller supplied is discarded. The hardening
  -- instant is the server's answer, never an assertion it was handed.
  new.hardens_at := public.earned_hardens_at(
    new.created_at, new.deadline, new.correction_window);
  return new;
end;
$$;

create trigger contract_envelope_hardens_at
  before insert or update on public.contract_envelope
  for each row execute function public.contract_envelope_set_hardens_at();
