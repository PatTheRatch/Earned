# Earned — Design Language

Decided August 2026, after reviewing three directions (Receipt / Vault / Deadpan Poster).
This is the brief every screen gets held against.

## The direction

**Brand = Deadpan Poster. Information architecture = simple/native. Language = borrowed
from the Receipt. Vault = discarded.**

It should feel like Apple Reminders got redesigned by someone who makes boxing posters:
printed notice, gym poster, transit warning, legal document. The product is a contract,
and the identity comes from the visual language of commitment documents — stamps, rules,
balances, deadlines, tickets, notices — used as texture, not wallpaper.

## One loud voice

The core discipline: **one loud voice, not five people yelling from different corners of
the kitchen.** Poster typography is reserved for state changes and consequences only:

> LOCKED. · EARNED. · OVERDUE. · NICE TRY.

Everything else is quiet and functional. Three levels, strictly:

| Level | Role | Treatment |
|---|---|---|
| 1 | Current state | Huge. Compressed heavy caps, ~72–96pt. One per screen, or none. |
| 2 | The thing stopping you | Medium-bold grotesk, ~20pt. "18 of 30. 12 to go." |
| 3 | Context | Small. Muted gray. "due 10:00" / "42 min left" / "Saturday." |

If everything is 40-point condensed caps with a thick rule under it, the eyes stop knowing
what matters. The brutality needs breathing room.

## Voice restraint rules

- The app's everyday lock state says **LOCKED.** — factual, not taunting.
- **NICE TRY. / THE DEAL STILL STANDS.** is reserved for the shield — the moment the user
  actually tries to open a restricted app (roadmap step 3). That's when it's funny.
  Anywhere else it becomes exhausting.
- Contract language stays second-person-ownership, softened from the Receipt draft:
  "Your rules. Your deal." and, on a hard lock, "You set this one." — never
  "NO REFUNDS. YOU WROTE THIS." in everyday UI (right idea, too aggressive).
- The red period after the state word is the brand's full stop. It travels with
  LOCKED./EARNED. everywhere.

## Palette

| Token | Value | Use |
|---|---|---|
| paper | `#F2EFE9` | Background everywhere. Off-white, warm. |
| ink | `#141210` | Text, rules, filled buttons. Almost-black. |
| signal | `#E8442E` | Consequences ONLY: overdue, balance due, the period. Never decoration. |
| muted | `#6F6A61` | Level-3 context, secondary copy. |
| field | `#EAE6DC` | Input fields, quiet fills. |

No gradients. No glossy wellness UI. No decorative illustration. Light appearance only —
a printed notice doesn't have a dark mode (revisit if it ever earns one).

## Type

- **Display** (Level 1 + creation-flow questions): SF Compressed, heavy, uppercase.
  System font, so it costs nothing and respects Dynamic Type; a licensed condensed
  grotesque can replace it later behind `Theme.display()`.
- **Functional** (everything else): SF Pro, regular weights. Sentence case.
- Small-caps labels: 11pt bold, +2.5 tracking, muted.

## Texture

- Thick ink rules (4pt) separate blocker rows — sparingly, one context per screen.
- The Free Override is a physical-feeling ticket: `🎟 FREE OVERRIDE × 1 — EARNED, NOT
  GIVEN.` with perforation notches. (The one emoji in the system; it's the brand's.)
- Minimal iconography otherwise. A gray chevron for navigability is acceptable; nothing
  decorative.
- Buttons are square-cornered ink blocks with paper text.

## Where the big words live

- **Today**: EARNED. (full access) / LOCKED. (restricted) — the phone status IS the headline.
- **Lock surface**: red flood + STILL LOCKED. and the itemized deal; "You set this one."
- **Commitment detail, overdue**: OVERDUE.
- **Shield (step 3)**: NICE TRY. / THE DEAL STILL STANDS.
