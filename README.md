# Earned

> Do what matters first. Earn the rest.

Earned is a commitment system that makes access to distracting technology conditional on doing what you said you would do. You commit while thinking clearly; Earned enforces the deal later.

The core loop: **Commit → Restrict → Complete → Verify → Unlock.**

Read the full product vision in [NORTHSTAR.md](NORTHSTAR.md), and the technical decisions in [ARCHITECTURE.md](ARCHITECTURE.md).

## Layout

- [`app/`](app/) — iOS app + Screen Time extensions (SwiftUI, Xcode)
- [`packages/EarnedKit/`](packages/EarnedKit/) — pure Swift domain engine (event-ledger gate logic)
- [`backend/`](backend/) — Supabase schema and edge functions
- [`docs/`](docs/) — design notes and decision records
