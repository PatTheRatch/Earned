# Earned — Design Language

v2 · August 2026 · the ground-up UI rebuild. v1 (Deadpan Poster, decided after the
Receipt / Vault / Poster review) stands underneath this; v2 is what happened when the
whole app — not just Today — was held to it. This is the brief every screen gets held
against.

## The direction

**Swiss editorial system + sports scoreboard + legal receipt.**

Not skeuomorphism, not paper textures, not retro cosplay. Deliberate, clear, slightly
severe, factual, typographic, alive when state changes. Earned should feel like a product
that remembers the deal. The failure mode v2 exists to kill: *Today looked like Earned;
the rest looked like an app containing Earned.*

## Principle 1 — poster for state, native for interaction

Display typography (compressed heavy caps) is punctuation, not prose. It is for
declarations only:

> CLEAR. · LOCKED. · OVERDUE. · KEPT. · THE DEAL · NICE TRY. · COMMIT

One per screen, or none. Questions in the creation flow count as that screen's one
declaration. Everything a user *touches* — forms, pickers, names, helper copy — is calm
system type with native iOS behaviour underneath. `Theme.metric` (condensed heavy, below
display) is the scoreboard voice for headline figures: `87% KEPT`, `6 IN A ROW`.

## Principle 2 — fewer cards

No white rounded rectangle per conceptual block. Grouping comes from whitespace, thick
rules (4pt, sparingly), hairlines, scale and alignment. The four top-level tabs are
`PosterPage`s — no List chrome at all. Cards only where a container genuinely means
something (the Free Override ticket).

## Principle 3 — more state, less configuration

The app answers: what do I owe, am I clear, what happens next, how am I doing, who can
see me. Configuration recedes into destinations under **You**; the app is a living
system, not a control panel.

## Principle 4 — progressive disclosure

The product reasoning is good and must not all be visible at once. Primary UI carries
one-line summaries; the paragraph lives behind `InfoButton` sheets, secondary screens,
or the onboarding. The exception: contract semantics being agreed to right now (the
hardening warning on THE DEAL) stay visible, in full, never truncated.

## Principle 5 — color means something

| Token | Value | Use |
|---|---|---|
| paper | `#F2EFE9` | Background everywhere. Off-white, warm. |
| ink | `#141210` | Default authority: text, rules, filled buttons. |
| signal | `#E8442E` | Consequence ONLY: overdue, locked, deadline risk, the brand's full stop. Never decoration. |
| muted | `#6F6A61` | Context, secondary copy, non-consequence status. |
| field | `#EAE6DC` | Input fields, quiet fills, avatar ground. |
| divider | ink @ 15% | Hairlines. |

No gradients. No glossy wellness UI. Light appearance only — a printed notice doesn't
have a dark mode.

## Information architecture

Four human jobs, not four database nouns:

| Tab | Job | Holds |
|---|---|---|
| **Today** | What do I owe right now? | State word, gates, obligations, the two actions. The emotional center; always the launch tab. |
| **Progress** | Is this working? | `87% KEPT` headline, streak figures, escapes and misses at second weight, plans, the record. |
| **Social** | Who sees me? | You + your figures, approvals waiting on you, accountability asks, requests, people, the Recent shelf. |
| **You** | Who am I / how is this configured? | Identity header, then destinations: Profile, Accountability partners, Account · Hydration, Restrictions, Plans · Free Overrides · Warnings, Advanced. |

Navigation is the native TabView, ink-tinted: platform behaviour and accessibility are
not up for reinvention.

## Component system (`Design/Theme.swift`, `Design/Components.swift`)

| Primitive | Job |
|---|---|
| `PosterPage` | Page scaffold: paper, left-aligned, one padding constant. |
| `PageHeader` | Masthead: EARNED kicker + the page's declaration. |
| `StateWord` | The declaration with the brand's red full stop. |
| `ThickRule` / `HairRule` | Loud and quiet grouping. |
| `Metric` | Scoreboard figure + quiet caption. |
| `PosterRow` | Rule, small-caps label, one bold line, quiet context — the unit Today taught the rest of the app. |
| `ReceiptRow` | One printed term of a contract: label column, bold value. |
| `ChoiceRow` | Selectable answer with a square marker; replaces pickers dropped into poster layouts. |
| `DestinationRow` | A navigation destination with its current value. |
| `EmptyState` | Product explanation, never "no data available". |
| `StatusTag` | KEPT / OVERDUE / REQUEST SENT; signal only for consequence. |
| `InfoButton` | The ⓘ that opens the reasoning on demand. |
| `PosterButtonStyle` / `UnderlineButtonStyle` | The one act per screen, and the quiet action beside it. |
| `TicketView` | The Free Override — the one emoji in the system. |
| `AvatarView` | Image or initials; identity degrades to typography. |

Spacing: `Theme.pagePadding` 24 · `rowSpacing` 14 · `blockSpacing` 28. Buttons ≥44pt
tap targets.

## Voice restraint rules

- Everyday lock state says **LOCKED.**; full access on Today says **CLEAR.** —
  **EARNED.** is reserved for the unlock moment itself (the full-access notice), so the
  masthead never reads "EARNED / EARNED."
- **NICE TRY. / THE DEAL STILL STANDS.** stay reserved for the shield and the lock
  notice — the moments they're earned. The shield now exists (`app/EarnedShield/`), and it
  is the only place `NICE TRY.` appears: the in-app notice is factual because the user came
  looking for it, and the shield can be wry because they were caught. Apple's layout is
  fixed and its labels take no font, so this is the one Earned surface where the poster face
  does not survive — the brand carries on signal red, capitals, and the full stop.
- Copy is deadpan, factual, concise, playful only when earned: "12 MIN LEFT." ·
  "YOU SET THIS ONE." Never "You've got this!", never "Level up!".
- Second-person ownership: "Your rules. Your deal."
- The red period travels with every state word.

## The Deal

The strongest screen after Today: a printed receipt between two thick rules — DO /
COUNTS / BY / VERIFIED BY / ESCAPE / VISIBLE TO / HARDENS (hardens in signal, the one
consequence on the page) — the correction-window control, the full hardening sentence,
and COMMIT. Sharing is a visibility question with its own step; escape mechanics are
contract mechanics with theirs; the two never share a screen.

## Motion

Almost none. State flips, progress updates, the lock/unlock transition. No bouncing, no
confetti, no celebratory spectacle — a completion feels satisfying because the
typography changes what it declares.

## Empty states

Explain the product: `NO FRIENDS YET. / Add someone who'll notice when you keep your
word.` · `NOT ENOUGH HISTORY YET. / Keep a few commitments and this starts telling a
story.`

## Developer surface

No "Testing" section ships. Manual workout logging and other test tools are `#if DEBUG`
under You → Advanced; diagnostics counts stay, quietly.

## Accessibility

Dynamic Type respected in body/system type; display faces carry `minimumScaleFactor`
and combined VoiceOver labels; 44pt targets; native navigation semantics throughout.
Contract language is never allowed to truncate.

## App icon

The mark is **`E.`** — the poster lockup at its shortest, four drawn rectangles plus the
signal-red stop. Regenerate with `python3 tools/make-appicon.py`; the script is the
source of truth.
