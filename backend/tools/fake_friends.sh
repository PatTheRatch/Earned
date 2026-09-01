#!/usr/bin/env bash
# Three people who will do whatever you ask, so the social layer can be tested
# by one person with one phone.
#
#   backend/tools/fake_friends.sh seed              # create them
#   backend/tools/fake_friends.sh list              # who they are, and where you stand
#   backend/tools/fake_friends.sh request <handle>  # they ask to be your friend
#   backend/tools/fake_friends.sh accept  <handle>  # they accept the request you sent
#   backend/tools/fake_friends.sh decline <handle>
#   backend/tools/fake_friends.sh remove  <handle>  # they unfriend you
#   backend/tools/fake_friends.sh block   <handle>  # they block you
#   backend/tools/fake_friends.sh unblock <handle>
#   backend/tools/fake_friends.sh reset             # back to strangers, keep the profiles
#   backend/tools/fake_friends.sh clean             # delete everything it made
#
# `accept` and `decline` answer a request *you* sent. A request they sent is
# yours to answer, in the app — which is the point. Asking a fake to accept
# their own request is refused by the server, not by this script.
#
# WHY THIS EXISTS. Friend requests need a second person, and the second person
# needs an Apple ID, a device, and a TestFlight seat — so the entire social
# half of the product (R-10 in docs/beta-readiness.md) has never been driven at
# all. This is the second person: real rows, reached through the same RPCs a
# real phone calls, with `request.jwt.claims` set to their id exactly as the
# SQL test suite does it. Nothing here is a mock. Search runs its real query,
# RLS makes its real decisions, and a block is a real block.
#
# WHAT IT IS NOT. It is not a way to test the *app's* half of sending a
# request — you still do that by tapping. It drives only the other side, which
# is the half a single person cannot reach.
#
# SAFETY. Every account it creates carries an `apple_user_id` beginning
# `fake.friend.`, which no Apple sign-in can produce (Apple's subjects are
# opaque and never contain that string). `clean` deletes exactly the rows
# reachable from those accounts and nothing else. It never writes to your own
# account: your side of every friendship is created by *their* RPC calls, the
# same way a real friend's would be.
#
# These rows live in whatever project you point it at. That is deliberate —
# testing against a pretend backend proves nothing — but it does mean `clean`
# is not optional housekeeping. Run it before you hand the app to anyone.
#
# Requires the Supabase CLI, logged in and linked (`supabase link`). It uses
# the CLI's own access token from the keychain and the Management API's query
# endpoint, so no database password is needed. See docs/deployment.md.
set -euo pipefail

PROJECT_REF="${EARNED_PROJECT_REF:-xqdobukkwqjgbpykwoxk}"
FAKE_PREFIX="fake.friend."

# The cast. Handles are deliberately unlike anything a real user would pick,
# and short enough to type on a phone while testing.
FAKES=(
  "testmaya:Maya:London"
  "testleo:Leo:Berlin"
  "testpriya:Priya:Toronto"
)

token() {
  security find-generic-password -s "Supabase CLI" -a supabase -w 2>/dev/null \
    || { echo "No Supabase CLI token in the keychain. Run: supabase login" >&2; exit 1; }
}

# One query, one round trip. Errors from Postgres come back as JSON with a
# `message` key rather than a non-zero status, so they are surfaced explicitly:
# a silent failure here would look exactly like a feature that does not work.
sql() {
  local out
  out=$(curl -s -X POST \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
    -H "Authorization: Bearer $(token)" \
    -H "Content-Type: application/json" \
    --data "$(python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "$1")")
  if [[ "$out" == *'"message"'* && "$out" != \[* ]]; then
    echo "SQL failed:" >&2
    python3 -c 'import json,sys;print("  "+json.loads(sys.stdin.read()).get("message","?"))' \
      <<<"$out" >&2
    exit 1
  fi
  echo "$out"
}

# Run a statement as one of the fakes. This is the whole trick, and it is the
# same one the test suite uses: the RPCs are SECURITY DEFINER and derive the
# caller from auth.uid(), which reads request.jwt.claims — so setting that
# claim *is* signing in, as far as every function below the API is concerned.
as_fake() {
  local handle="$1" statement="$2"
  sql "select set_config('request.jwt.claims',
                          json_build_object('sub', a.auth_user_id)::text, false)
         from public.account a
         join public.profile p on p.account_id = a.id
        where p.handle = '$handle' and a.apple_user_id like '$FAKE_PREFIX%';
       $statement"
}

# Your handle, worked out rather than asked for: the one profile whose account
# is not one of ours. Guessing wrong here would mean a fake accepting some
# other real person's request, so it refuses rather than picks.
my_handle() {
  local out count
  out=$(sql "select p.handle from public.profile p
               join public.account a on a.id = p.account_id
              where a.apple_user_id not like '$FAKE_PREFIX%' and a.deleted_at is null;")
  count=$(python3 -c 'import json,sys;print(len(json.loads(sys.stdin.read())))' <<<"$out")
  if [[ "$count" != "1" ]]; then
    echo "Expected exactly one real profile, found $count." >&2
    echo "Set EARNED_MY_HANDLE to say which one is you." >&2
    exit 1
  fi
  python3 -c 'import json,sys;print(json.loads(sys.stdin.read())[0]["handle"])' <<<"$out"
}

me() { echo "${EARNED_MY_HANDLE:-$(my_handle)}"; }

require_fake() {
  [[ -n "${1:-}" ]] || { echo "Which one? Try: $0 list" >&2; exit 1; }
}

case "${1:-}" in

seed)
  for entry in "${FAKES[@]}"; do
    IFS=: read -r handle name city <<<"$entry"
    # The account is inserted directly because ensure_account is written for a
    # real Apple token; the profile is not, because upsert_my_profile is the
    # thing being tested and a hand-written row would skip its rules.
    sql "insert into public.account (auth_user_id, apple_user_id, display_name)
         values (gen_random_uuid(), '$FAKE_PREFIX$handle', '$name')
         on conflict (apple_user_id) do nothing;" >/dev/null
    sql "select set_config('request.jwt.claims',
                            json_build_object('sub', a.auth_user_id)::text, false)
           from public.account a where a.apple_user_id = '$FAKE_PREFIX$handle';
         select public.upsert_my_profile('$handle', '$name', '$city', null);" >/dev/null
    echo "  seeded @$handle ($name, $city)"
  done
  echo
  echo "Search for any of those handles in the app. Then:"
  echo "  $0 accept testmaya     # after you send her a request"
  echo "  $0 request testleo     # to test the other direction"
  ;;

list)
  echo "Fake profiles, and where you stand with each:"
  sql "select p.handle, a.display_name,
              coalesce((select f.status || case
                         when f.status = 'pending' and f.requester = a.id
                           then ' (they asked you)'
                         when f.status = 'pending' then ' (you asked them)'
                         else '' end
                        from public.friendship f
                       where (f.account_low = a.id or f.account_high = a.id)
                         and (f.account_low = m.id or f.account_high = m.id)),
                       'no relationship') as standing
         from public.account a
         join public.profile p on p.account_id = a.id
        -- You, identified the same way my_handle() does it: the account with a
        -- profile that is not one of ours. Picking merely the first non-fake
        -- account is not the same thing — demo_request.sh leaves one behind
        -- with no profile, and it sorts first.
        cross join (select a.id from public.account a
                      join public.profile p2 on p2.account_id = a.id
                     where a.apple_user_id not like '$FAKE_PREFIX%'
                       and a.deleted_at is null
                       and p2.handle = '$(me)') m
        where a.apple_user_id like '$FAKE_PREFIX%'
        order by p.handle;" | python3 -c '
import json, sys
rows = json.loads(sys.stdin.read())
if not rows:
    print("  none — run: backend/tools/fake_friends.sh seed"); raise SystemExit
for r in rows:
    handle, name, standing = r["handle"], r["display_name"], r["standing"]
    print("  @%-12s %-8s %s" % (handle, name, standing))'
  ;;

request)  require_fake "${2:-}"; as_fake "$2" \
            "select public.send_friend_request('$(me)');" >/dev/null
          echo "  @$2 has asked to be your friend. Open Social." ;;

accept)   require_fake "${2:-}"; as_fake "$2" \
            "select public.respond_to_friend_request('$(me)', true);" >/dev/null
          echo "  @$2 accepted." ;;

decline)  require_fake "${2:-}"; as_fake "$2" \
            "select public.respond_to_friend_request('$(me)', false);" >/dev/null
          echo "  @$2 declined." ;;

remove)   require_fake "${2:-}"; as_fake "$2" \
            "select public.remove_friend('$(me)');" >/dev/null
          echo "  @$2 removed you." ;;

block)    require_fake "${2:-}"; as_fake "$2" "select public.block_user('$(me)');" >/dev/null
          echo "  @$2 blocked you. You should now be unable to find each other." ;;

unblock)  require_fake "${2:-}"; as_fake "$2" "select public.unblock_user('$(me)');" >/dev/null
          echo "  @$2 unblocked you — which does not make you friends again." ;;

reset)
  # Back to strangers, without re-seeding. Testing the same flow twice needs
  # this more often than `clean` does, and re-seeding would give them new
  # account ids for no reason.
  sql "delete from public.friendship f
        where exists (select 1 from public.account a
                       where a.apple_user_id like '$FAKE_PREFIX%'
                         and a.id in (f.account_low, f.account_high));" >/dev/null
  echo "  Strangers again. The three profiles are still there."
  ;;

clean)
  # Order matters only because friendship references both sides; everything
  # else cascades from account. Deliberately scoped by the fake prefix in
  # every statement rather than by a list of ids computed once, so a bug here
  # deletes nothing rather than something.
  sql "delete from public.friendship f
        where exists (select 1 from public.account a
                       where a.apple_user_id like '$FAKE_PREFIX%'
                         and a.id in (f.account_low, f.account_high));
       delete from public.account where apple_user_id like '$FAKE_PREFIX%';" >/dev/null
  echo "  Gone. Your own account and friendships are untouched."
  ;;

*)
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
