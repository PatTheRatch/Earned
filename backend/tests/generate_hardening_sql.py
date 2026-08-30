#!/usr/bin/env python3
"""Turn the shared hardening fixtures into SQL assertions.

fixtures/hardening-cases.json is the single source of truth for when a
commitment's correction window closes. EarnedKit reads it directly in
HardeningParityTests; psql cannot read a JSON file, so this emits the same
cases as assertions against public.earned_hardens_at.

Generated, never hand-edited, and never the place to "fix" a failure: if the
two sides disagree, one of the two implementations of the rule is wrong.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(ROOT, "fixtures", "hardening-cases.json")


def sql_str(value: str) -> str:
    """A SQL string literal. Doubling quotes, not Python's repr."""
    return "'" + str(value).replace("'", "''") + "'"


def assertion(case: dict, prefix: str = "") -> str:
    return (
        "select test_assert(public.earned_hardens_at("
        f"timestamptz {sql_str(case['createdAt'])}, "
        f"timestamptz {sql_str(case['deadline'])}, "
        f"{float(case['correctionWindow'])!r}::double precision"
        f") = timestamptz {sql_str(case['expectedHardensAt'])}, "
        f"{sql_str(prefix + case['name'])});"
    )


def main() -> int:
    with open(FIXTURE) as handle:
        fixture = json.load(handle)

    cases = fixture["cases"]
    if not cases:
        print("fixture contains no cases", file=sys.stderr)
        return 1

    out = [
        "-- GENERATED from fixtures/hardening-cases.json by",
        "-- backend/tests/generate_hardening_sql.py. Do not edit.",
        "\\set ON_ERROR_STOP on",
        "",
        "-- A timezone with daylight saving, deliberately. Two of these cases are",
        "-- an hour wrong if the hardening window is ever added as calendar days",
        "-- rather than absolute seconds.",
        "set time zone 'America/New_York';",
        f"\\echo 'hardening parity: {len(cases)} cases, session tz America/New_York'",
        "",
    ]
    out += [assertion(case) for case in cases]

    # The same set again under UTC, so a pass cannot quietly depend on the
    # session timezone happening to match the one the fixture was written in.
    out += [
        "",
        "set time zone 'UTC';",
        f"\\echo 'hardening parity: {len(cases)} cases, session tz UTC'",
        "",
    ]
    out += [assertion(case, prefix="UTC — ") for case in cases]

    # The constant, asserted separately so a change to it cannot slip through by
    # agreeing with a fixture regenerated from the same changed constant.
    fraction = float(fixture["hardeningFraction"])
    out += [
        "",
        "-- 0.125 is exactly representable in binary, which is why the same",
        "-- multiplication is safe in Swift's Double and Postgres's float8.",
        "select test_assert(public.earned_hardens_at("
        "timestamptz '2000-01-01T00:00:00Z', timestamptz '2000-01-01T08:00:00Z', "
        "1e9::double precision) = timestamptz '2000-01-01T00:00:00Z' + "
        f"make_interval(secs => 28800 * {fraction!r}), "
        f"{sql_str('hardening fraction is ' + repr(fraction))});",
    ]

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
