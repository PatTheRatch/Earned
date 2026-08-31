# docs/

Design notes, decision records, and API notes.

The two root documents outrank everything here: [NORTHSTAR.md](../NORTHSTAR.md) (what and why) and [ARCHITECTURE.md](../ARCHITECTURE.md) (how). Anything in this directory that contradicts them is wrong or stale.

## What's here

- [`deployment.md`](deployment.md) — the ordered runbook: an empty Supabase project to a
  partner opening a real approval link, with something to verify after every step.
- [`walkthrough.md`](walkthrough.md) — every screen from fresh install to a live
  commitment, traced against the code that runs it. The honest state-of-the-build.
- [`design-language.md`](design-language.md) — the Deadpan Poster visual system: hierarchy,
  palette, type, and the voice-restraint rules.
- [`earnedkit-semantics.md`](earnedkit-semantics.md) — the rules the engine had to decide
  that the north star leaves open.
- [`strava.md`](strava.md) — whether to integrate Strava, and how. **Tabled**: Apple Health
  already reaches almost every device a user records on, and Earned reads it today. Kept
  for the day server-authoritative completion is the gap worth closing, which is the one
  thing Strava would buy that Health cannot.
- [`accountability-architecture.md`](accountability-architecture.md) — the design and threat
  model for networked Accountability Overrides, including the Contract Envelope that makes
  the server authoritative for a hardened commitment's accountability terms. **Built**
  through signed grants (backend milestones A–F, `backend/README.md`) and wired into the
  app; every product decision is settled — account deletion's product half included
  (§21.2), with only its retention/legal half still under privacy review — and §20 lists
  the launch gates still to clear.
- [`social-architecture.md`](social-architecture.md) — the Social Accountability layer
  (NORTHSTAR §45): profiles, friendships, avatars, commitment sharing, the activity
  shelf, streaks, the privacy model, and the explicit line between enforcement authority
  and social representation. Milestones S1 (profiles + friends + Social tab), S2
  (sharing + events + streak presentation) and S3 (check-in sharing + the quiet
  surface) are built; everything past them is design.
