# docs/

Design notes, decision records, and API notes.

The two root documents outrank everything here: [NORTHSTAR.md](../NORTHSTAR.md) (what and why) and [ARCHITECTURE.md](../ARCHITECTURE.md) (how). Anything in this directory that contradicts them is wrong or stale.

## What's here

- [`walkthrough.md`](walkthrough.md) — every screen from fresh install to a live
  commitment, traced against the code that runs it. The honest state-of-the-build.
- [`design-language.md`](design-language.md) — the Deadpan Poster visual system: hierarchy,
  palette, type, and the voice-restraint rules.
- [`earnedkit-semantics.md`](earnedkit-semantics.md) — the rules the engine had to decide
  that the north star leaves open.
- [`accountability-architecture.md`](accountability-architecture.md) — the design and threat
  model for networked Accountability Overrides, including the Contract Envelope that makes
  the server authoritative for a hardened commitment's accountability terms. **Proposed, not
  built** — six decisions in §21.2 are still open, and §20 lists the launch gates.
