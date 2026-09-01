-- Raise the override-request cap for Wave 0, and say when it goes back.
--
-- 0009 set three requests per account per day, and the reasoning there still
-- holds for a real user: "enough for a bad day with several gates, few enough
-- that hourly pestering is impossible."
--
-- A beta tester is not a real user. They are being *asked* to exercise the
-- escape routes — docs/beta-test-script.md walks two override requests on
-- purpose, and a single retry after a failed one spends the third. The fourth
-- ask is then refused with "too many override requests today", which to
-- someone who was told to go and break things reads as the bug they were
-- recruited to find. The cap would be measuring the test rather than the
-- product.
--
-- Ten, for the same reason three was three: a judgement, not a derivation.
-- High enough that nobody deliberately probing the escape ladder hits it in an
-- afternoon, low enough that the §16 outbound ceiling stays bounded — with the
-- partner cap of 5 unchanged, at most 50 approval messages per account per day
-- rather than 15. At Wave 0 scale that ceiling is theoretical; at public beta
-- it would not be, which is the other half of why this is temporary.
--
-- **This migration is meant to be reverted.** It is written as its own file
-- rather than an edit to 0009 so that the raise is visible in review, survives
-- `apply.sh` (a hand-edit on the hosted project does not — the next apply
-- silently restores three, which is exactly the kind of drift that gets
-- discovered by a tester rather than by us), and can be undone by deleting
-- nothing and adding one more file that sets it back.
--
-- Revert when Wave 0 ends, before Earned is offered to anyone who was not
-- personally recruited: add `00NN_restore_override_request_cap.sql` containing
-- this same function returning 3. Do not simply delete this file — a migration
-- that has been applied somewhere cannot be un-applied by disappearing from
-- the repository.

create or replace function private.max_requests_per_day() returns int
language sql immutable as $$ select 10 $$;

-- 0009 revoked this from every role and nothing about that changes here, but
-- `create or replace` preserves the existing grants rather than resetting
-- them, so this is a restatement of the guarantee, not a repair of it.
revoke all on function private.max_requests_per_day() from public, anon, authenticated;
