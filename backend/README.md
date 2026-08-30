# backend/

Supabase project: database schema/migrations and edge functions.

The design and threat model for the first feature — accountability approvals — is
[`docs/accountability-architecture.md`](../docs/accountability-architecture.md) (v0.3). It is
proposed, not accepted: every product decision in it is settled except account deletion
(§21.2), which waits on privacy/legal review, and nothing here should be built against a
guessed answer to that one.

Read §4 first. The server holds a **Contract Envelope** for every commitment — the
accountability terms only, frozen when the commitment hardens — because the approval
threshold and partner roster can never be supplied by a client we treat as adversarial.

MVP scope is deliberately small — the accountability-override flow (NORTHSTAR §23): store override requests, serve the approve/deny page partners open from an SMS/iMessage link, count votes against the configured threshold, and report the outcome to the app.

Longer term this becomes the account-authoritative home of the commitment ledger (NORTHSTAR §§32–33).
