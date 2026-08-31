// The renderer, held to §6.2's table and §13's hostility assumptions.
// Pure functions in, strings out — no network, no Deno APIs, runs anywhere.

import { escape, renderPage, type Page, type Snapshot } from "./render.ts";

function assert(condition: boolean, what: string): void {
  if (!condition) throw new Error(`FAILED: ${what}`);
}

const snapshot: Snapshot = {
  contract: {
    requester_display_name: "Patrick",
    commitment_title: "Run 30 minutes",
    deadline: "2026-08-24T22:00:00Z",
    approvals_required: 2,
    hardened_at: "2026-08-24T08:15:00Z",
  },
  self_reported: {
    progress: { achieved: 18, required: 30, unit: "minutes" },
    reliability_30d: { completed: 8, of: 10, override_requests: 2, missed: 1 },
    reason: "Knee started bothering me.",
  },
  requested_at: "2026-08-24T21:12:04Z",
};

Deno.test("the request page shows the ask, the split, and both buttons", () => {
  const page = renderPage({ page: "request", snapshot, expires_at: "2026-08-25T21:12:04Z" });
  assert(page.includes("Patrick is asking to be let out"), "names the requester");
  assert(page.includes("Run 30 minutes"), "names the commitment");
  assert(page.includes("As reported by Patrick&#39;s phone"),
    "labels the self-reported half as the phone's account (D6)");
  assert(page.includes("18 of 30 minutes"), "shows progress at request time");
  assert(page.includes('value="approve"') && page.includes('value="deny"'),
    "offers exactly the two answers");
  assert(page.includes('method="post"'), "votes by form post, no script");
  assert(!page.includes("<script"), "the page runs nothing in the browser");
});

Deno.test("hostile text is rendered as text, never as markup", () => {
  const hostile = structuredClone(snapshot);
  hostile.contract.requester_display_name = `<img src=x onerror=alert(1)>`;
  hostile.self_reported.reason = `<script>steal()</script> & "quotes" 'too'`;
  hostile.self_reported.progress.unit = `<b>km</b>`;
  const page = renderPage({ page: "request", snapshot: hostile });
  assert(!page.includes("<img"), "a display name cannot smuggle a tag");
  assert(!page.includes("<script>steal"), "a reason cannot smuggle a script");
  assert(!page.includes("<b>km"), "a unit cannot smuggle markup");
  assert(page.includes("&lt;script&gt;steal()&lt;/script&gt;"),
    "the hostile text is still shown — as text");
});

Deno.test("escape covers the five characters that matter", () => {
  assert(escape(`<>&"'`) === "&lt;&gt;&amp;&quot;&#39;", "all five, in order");
});

Deno.test("a forged link and a dead link are the same page", () => {
  const invalid = renderPage({ page: "invalid" });
  const gone = renderPage({ page: "gone" });
  assert(invalid === gone,
    "a stranger cannot tell 'never existed' from 'existed once' (§19)");
  assert(!invalid.includes("Patrick"), "and neither says anything about anyone");
});

Deno.test("receipts say what was decided and how it ended", () => {
  const approved = renderPage({
    page: "receipt", vote: "approve", voted_at: "2026-08-24T21:31:08Z",
    outcome: "granted", snapshot,
  });
  assert(approved.includes("You approved this on 24 Aug 2026"), "the decision, dated");
  assert(approved.includes("The request was granted."), "the outcome");

  const waiting = renderPage({
    page: "receipt", vote: "deny", voted_at: "2026-08-24T21:31:08Z",
    outcome: "open", snapshot,
  });
  assert(waiting.includes("You said no"), "a denial is receipted too");
  assert(waiting.includes("Waiting to hear back."),
    "an open outcome waits — it never counts votes (S6, §11)");
  assert(!waiting.includes("1 of 2"), "no tally, anywhere");
});

Deno.test("a vote processed after resolution is told the truth", () => {
  const late = renderPage({ page: "resolved", processed_late: true, snapshot });
  assert(late.includes("your tap did not change the outcome"),
    "the partner is not left thinking their vote counted (§12)");
  const bystander = renderPage({ page: "resolved", snapshot });
  assert(bystander.includes("No action needed."), "a mere bystander gets calm");
});

Deno.test("expired and withdrawn have their own pages", () => {
  assert(renderPage({ page: "expired", snapshot })
    .includes("expired without an answer"), "expired says so");
  assert(renderPage({ page: "withdrawn", snapshot })
    .includes("Patrick sorted this one out"), "withdrawn credits the requester");
});

Deno.test("a missing reason simply is not there", () => {
  const bare = structuredClone(snapshot);
  bare.self_reported.reason = null;
  const page = renderPage({ page: "request", snapshot: bare });
  assert(!page.includes("Their reason"),
    "no reason row renders — the field is optional by design (§24)");
});
