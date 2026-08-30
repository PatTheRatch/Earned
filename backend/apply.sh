#!/usr/bin/env bash
# Apply the migrations to a Supabase project, in order.
#
#   backend/apply.sh "postgresql://postgres.<ref>:<password>@<host>:5432/postgres"
#
# The connection string is in the Supabase dashboard under Project Settings →
# Database → Connection string (URI). It contains your database password, so
# pass it as an argument or in DATABASE_URL — never paste it into a file here.
#
# Safe to run more than once: every statement is written to converge, so a set
# that failed halfway can simply be applied again.
set -euo pipefail

cd "$(dirname "$0")/.."
DB="${1:-${DATABASE_URL:-}}"
if [ -z "$DB" ]; then
  echo "usage: backend/apply.sh <postgres-connection-string>" >&2
  exit 2
fi

for file in backend/migrations/*.sql; do
  echo "==> $file"
  psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$file"
done

echo "==> applied. Set the Vault secrets next — see backend/README.md."
