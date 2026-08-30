// The partner page, as pure functions: page state in, HTML out.
//
// This file deliberately imports nothing and touches no network, so its tests
// run anywhere Deno does. Everything it prints is either authored here or
// passes through escape() — the page renders text and never markup (§13), and
// while the server already URL-neutralises the two user-authored fields, this
// layer escapes them again on principle: the defence a page owes its reader
// belongs to the page.
//
// The wording is the design's wording (§6.2, §7, §11, §12), and two choices
// are worth naming:
//
// - `invalid` and `gone` render identically. Server-side they are different
//   states, but a stranger holding a link must not be able to tell "this was
//   never real" from "this was real once" (§19's indistinguishability,
//   extended to the one place a human sees).
// - The self-reported half is labelled as the requester's phone's account of
//   things (D6), progress and reliability and reason alike, and the contract
//   half carries no such label because the server vouches for it.

export interface Snapshot {
  contract: {
    requester_display_name: string;
    commitment_title: string;
    deadline: string;
    approvals_required: number;
    hardened_at: string;
  };
  self_reported: {
    progress: { achieved: number; required: number; unit: string | null };
    reliability_30d: {
      completed: number;
      of: number;
      override_requests: number;
      missed: number;
    };
    reason: string | null;
  };
  requested_at: string;
}

export interface Page {
  page: "invalid" | "gone" | "request" | "receipt" | "resolved" | "withdrawn" | "expired";
  snapshot?: Snapshot;
  vote?: "approve" | "deny";
  voted_at?: string;
  outcome?: string;
  processed_late?: boolean;
  expires_at?: string;
}

export function escape(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

// One fixed, explicit rendering of an instant. Partners are strangers in
// unknown time zones; a wrong-but-labelled UTC beats a silently local guess.
function when(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "an unknown time";
  const fmt = new Intl.DateTimeFormat("en-GB", {
    day: "numeric", month: "short", year: "numeric",
    hour: "2-digit", minute: "2-digit", timeZone: "UTC",
  });
  return `${fmt.format(date)} UTC`;
}

const style = `
  :root { color-scheme: light; }
  body { margin: 0; background: #f4f2ec; color: #1c1a16;
         font: 16px/1.55 -apple-system, "Segoe UI", system-ui, sans-serif; }
  main { max-width: 34rem; margin: 0 auto; padding: 3rem 1.25rem 4rem; }
  h1 { font-size: 1.35rem; line-height: 1.3; margin: 0 0 1rem; }
  p { margin: 0.6rem 0; }
  .card { background: #fffdf8; border: 1px solid #e2ddd2; border-radius: 12px;
          padding: 1.1rem 1.25rem; margin: 1.25rem 0; }
  .label { font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase;
           color: #8a8578; margin: 0 0 0.35rem; }
  dl { margin: 0; } dt { font-size: 0.8rem; color: #8a8578; margin-top: 0.6rem; }
  dd { margin: 0.1rem 0 0; }
  .actions { display: flex; gap: 0.75rem; margin-top: 1.5rem; }
  button { flex: 1; font: inherit; font-weight: 600; padding: 0.85rem 1rem;
           border-radius: 10px; border: 1px solid #1c1a16; cursor: pointer; }
  .approve { background: #1c1a16; color: #fffdf8; }
  .deny { background: transparent; color: #1c1a16; }
  .quiet { color: #8a8578; font-size: 0.9rem; }
`;

function shell(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${escape(title)}</title>
<style>${style}</style>
</head>
<body><main>${body}</main></body>
</html>`;
}

function snapshotCards(s: Snapshot): string {
  const c = s.contract;
  const r = s.self_reported;
  const name = escape(c.requester_display_name);
  const unit = r.progress.unit ? ` ${escape(r.progress.unit)}` : "";
  const reason = r.reason
    ? `<dt>Their reason</dt><dd>${escape(r.reason)}</dd>`
    : "";
  return `
<div class="card">
  <p class="label">The commitment</p>
  <dl>
    <dt>What they committed to</dt><dd>${escape(c.commitment_title)}</dd>
    <dt>Deadline</dt><dd>${when(c.deadline)}</dd>
    <dt>Locked in since</dt><dd>${when(c.hardened_at)}</dd>
    <dt>Approvals needed to unlock early</dt><dd>${c.approvals_required}</dd>
  </dl>
</div>
<div class="card">
  <p class="label">As reported by ${name}&#39;s phone</p>
  <dl>
    <dt>Progress when they asked</dt>
    <dd>${r.progress.achieved} of ${r.progress.required}${unit}</dd>
    <dt>Last 30 days</dt>
    <dd>${r.reliability_30d.completed} of ${r.reliability_30d.of} completed on time,
        ${r.reliability_30d.missed} missed,
        ${r.reliability_30d.override_requests} override requests</dd>
    ${reason}
  </dl>
</div>`;
}

export function renderPage(page: Page): string {
  const name = page.snapshot
    ? escape(page.snapshot.contract.requester_display_name)
    : "The requester";

  switch (page.page) {
    // One face for a link that never existed and a link whose time has
    // passed: a stranger learns nothing either way.
    case "invalid":
    case "gone":
      return shell("Earned", `
<h1>This link is no longer available.</h1>
<p class="quiet">If someone sent it to you recently, ask them to check in with Earned.</p>`);

    case "request": {
      const s = page.snapshot!;
      return shell(`${s.contract.requester_display_name} is asking`, `
<h1>${name} is asking to be let out of a commitment.</h1>
<p>They named you as someone who can decide. Nobody else sees how you answer.</p>
${snapshotCards(s)}
<form method="post">
  <div class="actions">
    <button class="approve" name="vote" value="approve">Let them out</button>
    <button class="deny" name="vote" value="deny">Hold them to it</button>
  </div>
</form>
<p class="quiet">If you do nothing, this request expires on its own${
        page.expires_at ? ` at ${when(page.expires_at)}` : ""
      }. A no is not a veto; a yes is one of the ${s.contract.approvals_required} needed.</p>`);
    }

    case "receipt": {
      const decided = page.vote === "approve" ? "You approved this" : "You said no";
      const outcome = page.outcome === "granted"
        ? "The request was granted."
        : page.outcome === "open"
        ? "Waiting to hear back."
        : page.outcome === "expired"
        ? "The request expired."
        : "The request was resolved.";
      return shell("Your answer", `
<h1>${decided} on ${when(page.voted_at ?? "")}.</h1>
<p>${outcome}</p>
${page.snapshot ? snapshotCards(page.snapshot) : ""}
<p class="quiet">This page stays available for a while so you can see what you decided.</p>`);
    }

    case "resolved":
      return shell("Already resolved", `
<h1>This request has already been resolved.</h1>
${page.processed_late
  ? `<p>It was settled by the time we processed your answer, so your tap did not change the outcome.</p>`
  : `<p>No action needed.</p>`}
${page.snapshot ? snapshotCards(page.snapshot) : ""}`);

    case "withdrawn":
      return shell("No action needed", `
<h1>${name} sorted this one out themselves.</h1>
<p>No action needed.</p>`);

    case "expired":
      return shell("Request expired", `
<h1>This request expired without an answer.</h1>
<p class="quiet">Nothing more can be done here.</p>
${page.snapshot ? snapshotCards(page.snapshot) : ""}`);
  }
}
