# EarnedKit

The pure Swift domain engine: commitments, gates, hardening, the Monotonic Commitment Principle, workout debt, and the override state machine — modeled as an append-only event ledger with current state derived as a pure function of history.

Rules:

- **No UI, no iOS-framework dependencies.** Foundation only. This package must build anywhere Swift builds.
- **State changes are events.** Mutation happens only by appending; invalid transitions (e.g. weakening a hardened commitment) are rejected by the reducer.
- **Every access restriction is explainable** from the ledger — "why am I locked" is a query, never a mystery.

Tested via `swift test` (locally on macOS, and in CI on every push).
