#!/usr/bin/env bash
# Apply the migrations to a throwaway Postgres and run every test against them.
#
# Requires DATABASE_URL. Migrations run in order; each test file runs in its own
# transaction and rolls back, so ordering between them never matters.
#
# EARNED_LAYOUT=supabase lays the database out the way Supabase does before
# any migration runs — pgcrypto in an `extensions` schema instead of `public`.
# CI runs both layouts, because a pinned search_path that misses `extensions`
# is silent here and fatal there — every function already had that bug once.
set -euo pipefail

cd "$(dirname "$0")/../.."
: "${DATABASE_URL:?set DATABASE_URL to a throwaway Postgres}"

psql() { command psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc "$@"; }

if [ "${EARNED_LAYOUT:-default}" = "supabase" ]; then
  echo "==> supabase layout: pgcrypto lives in the extensions schema"
  psql -q -c "create schema if not exists extensions;
              create extension if not exists pgcrypto with schema extensions;
              grant usage on schema extensions to public;"
fi

# Supabase provisions the anon/authenticated/service_role roles and auth.uid()
# before any migration runs, so the scaffolding that stands in for them has to
# come first here too. Migrations grant to those roles and would fail without.
echo "==> test scaffolding (stands in for what Supabase provides)"
psql -q -f backend/tests/00_bootstrap.sql

echo "==> migrations"
for file in backend/migrations/*.sql; do
  echo "    $file"
  psql -q -f "$file"
done

echo "==> hardening parity (generated from fixtures/hardening-cases.json)"
generated="$(mktemp -t hardening-XXXXXX.sql)"
trap 'rm -f "$generated"' EXIT
python3 backend/tests/generate_hardening_sql.py > "$generated"
psql -q -f "$generated"

# Every .sql in here that is not the bootstrap is a test, and the count is
# checked out loud. `[0-9][0-9]_*.sql` used to be the pattern, which silently
# stopped matching the moment a file reached three digits: 100_grants.sql was
# skipped by every run and every CI job, green, for as long as it existed. A
# test suite that can quietly shrink is worse than a smaller one, so the number
# it ran is now part of its output.
ran=0
for file in backend/tests/*.sql; do
  case "$file" in */00_bootstrap.sql) continue ;; esac
  echo "==> $file"
  psql -q -f "$file"
  ran=$((ran + 1))
done
expected=$(( $(ls backend/tests/*.sql | wc -l) - 1 ))
[ "$ran" -eq "$expected" ] || { echo "ran $ran test files, expected $expected" >&2; exit 1; }
echo "==> $ran test files ran"

echo "==> key rotation drill (real Ed25519, real signatures, the served bytes)"
backend/tests/keyset_drill.sh

echo "==> vote concurrency drill (five real sessions, one starting gun)"
backend/tests/vote_concurrency.sh

echo "==> grant drill (a real grant, signed outside Postgres, verified from the key set)"
backend/tests/grant_drill.sh

echo "==> all backend tests passed"
