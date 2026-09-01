# Beta readiness — B1, multi-user

Whether Earned can be handed to five to ten people who are not Patrick.

Reviewed against `main` at [`5f3ab0c`](https://github.com/PatTheRatch/Earned/commit/5f3ab0c)
(1 September 2026), plus the work on this branch. The central question is not "is it
built" but:

> Can someone install Earned, understand what it does, make a commitment, get restricted at
> the right time, satisfy it, recover from mistakes, and use the social and accountability
> features without Patrick standing beside them?

## How to read a status

"Done" is six different claims, and the gap between the first and the last is where a beta
goes wrong. Every item below is marked with the furthest one that is actually true.

| | Means |
|---|---|
| **BUILT** | The code exists and is believed correct by reading. |
| **TESTED** | An automated test protects it, and that test runs in CI. |
| **DEPLOYED** | The server half is applied to the hosted project and verified there. |
| **SIGNED** | It survives being built into a signed, distributable archive. |
| **DEVICE** | Someone has watched it work on real hardware. |
| **MULTI-USER** | Two or more real accounts have driven it end to end. |

A thing can be BUILT and TESTED and still be worthless: background enforcement is a
DeviceActivity schedule the simulator does not run, and no green tick anywhere in this
repository can tell you it fires. Where that is the case, the item stays a blocker until a
phone says otherwise.

Nothing here is marked from a document. Where the only evidence is another document's
claim, that is said out loud.

## Score

Nine blockers were open at the start of B1. Six are closed in code on this branch; three
cannot be closed from a repository at all, because they are Apple's approval queue, a
hosted backend credential, and a physical iPhone.

| | Count | |
|---|---|---|
| BLOCKER, fixed on this branch | 6 | code merged, CI green |
| BLOCKER, needs Patrick | 3 | Apple portal, device, hosted backend |
| BETA REQUIRED, fixed | 8 | |
| BETA REQUIRED, needs a device or a second person | 4 | |
| PUBLIC BETA | 15 | documented, deliberately not built |

**Earned is not yet distributable.** The honest summary is that the software is in
reasonable shape and the *evidence* is missing: nothing in this product has been proven on
a phone, by two accounts, against the hosted backend, and the one capability the entire
product rests on — a Gate closing while the app is not running — is exactly the capability
that cannot be tested anywhere but on hardware.

---

# BLOCKER

Must be resolved before any external tester receives the app.

## B‑1 · Family Controls (Distribution) for both targets

**Status: EXTERNAL VERIFICATION REQUIRED.** The repository cannot know Apple's answer, and
this document will not guess at it.

Two targets use Screen Time APIs. There is no third; `rg` over `app/` finds
`FamilyControls`, `ManagedSettings` and `DeviceActivity` imports in these and nowhere else.

| | Main app | Monitor extension |
|---|---|---|
| Bundle id | `com.pattheratch.earned` | `com.pattheratch.earned.monitor` |
| Type | Application | `com.apple.deviceactivity.monitor-extension` |
| Entitlement | `com.apple.developer.family-controls` | `com.apple.developer.family-controls` |
| Also needs | `applesignin`, `healthkit`, App Group | App Group |
| Development capability | Self-serve in the portal | Self-serve in the portal |
| Distribution approval | **Required, reviewed by hand** | **Required, reviewed by hand, separately** |
| Request submitted? | **UNKNOWN — Patrick must confirm** | **UNKNOWN — Patrick must confirm** |
| Approved? | **UNKNOWN** | **UNKNOWN** |
| TestFlight profile exists? | **UNKNOWN** | **UNKNOWN** |

Evidence for the left-hand column: `app/project.yml` lines 82–99 and 135–143,
`app/Earned/Earned.entitlements`, `app/EarnedMonitor/EarnedMonitor.entitlements`. Both
entitlement files are checked in and both are verified byte-for-byte by CI
(`tools/validate-release-config.py`, and a `git diff --exit-code` after `xcodegen generate`).

One approval does **not** cover both. Apple grants Family Controls (Distribution) per App
ID, and a Screen Time extension is a separate App ID. A build whose app was approved and
whose extension was not will fail to upload, or will upload and then fail to install — and
the review queue is measured in weeks, not hours, so this is the long pole of the entire
milestone.

**Owner:** Patrick, Apple Developer portal.
**Requires:** Apple setup. No code.
**Verify:** In the portal, Certificates, Identifiers & Profiles → Identifiers → each of the
two App IDs → Family Controls is present *and* not marked as requiring approval; and
Additional Resources → Family Controls Distribution shows an approved request for each. If
either shows nothing, submit using [`family-controls-request.md`](family-controls-request.md),
which is drafted from what the code actually does, and record the submission date here.

## B‑2 · Background enforcement has never run on a phone

**Status: BUILT. Not DEVICE-verified.** This is the most important unproven thing in the
product, and it is unprovable from here.

Everything the extension needs is in place and checked:

- `app/EarnedMonitor/MonitorExtension.swift` overrides `intervalDidStart` and applies the
  shield from the plan in the App Group.
- `app/Earned/Enforcement/ShieldPlan.swift` is compiled into *both* targets from one file,
  so the two processes cannot drift on the format.
- The App Group `group.com.pattheratch.earned` is in both entitlement files, and
  `validate-release-config.py` asserts the two match each other and match the identifier
  hard-coded in `ShieldPlan.swift`.
- `ShieldScheduler` registers the DeviceActivity schedule; `ShieldScheduler.clear()` stops
  every monitored activity and empties the shared plan when authorization is withdrawn.
- `intervalDidEnd` is deliberately empty: the extension never *lifts* a shield, because the
  app is the only thing that knows whether the commitment was met. Fail-closed by design.

None of that is evidence that iOS wakes the extension. The simulator does not run
DeviceActivity schedules, CI signs nothing, and the failure mode — the app shields on next
launch and looks fine — is indistinguishable from success unless someone deliberately
avoids opening the app.

**Owner:** enforcement.
**Requires:** device testing. Signed build on real hardware, which means B‑1 first.
**Verify:** [`beta-test-script.md`](beta-test-script.md) step 7 is written for a tester;
the developer version is the same walk with two additions:

1. Create a commitment with a deadline 20 minutes out; pick one restricted app.
2. Confirm You → Advanced → Diagnostics reads **Screen Time: Granted**, **App Group:
   Reachable**, **Scheduled changes: 1** or more, and a recent **Plan written** time. If
   the App Group is Missing or the plan is absent, stop — the extension cannot work and
   step 5 will fail for a reason that has nothing to do with iOS.
3. Force-quit Earned from the app switcher. Do not open it again.
4. Keep using the phone — this matters; a phone left idle is a different test.
5. After the deadline, open the restricted app. **It must be shielded.**
6. Still without opening Earned, confirm the shield persists across a lock/unlock.
7. Now open Earned, complete the workout, and confirm the shield lifts.
8. **Stale callback:** create a commitment, let the schedule register, then complete the
   commitment *before* the deadline and force-quit. When the deadline passes, the extension
   still wakes. Nothing should be shielded — the plan the app wrote must no longer contain
   a live window. This is the one that catches a fail-closed rule shielding someone who
   already did the work.
9. **Restart:** repeat step 3–5 with a reboot between. DeviceActivity schedules are
   supposed to survive; if they do not, that is a product-shaping fact.

Record the result — including how long after the deadline the shield appeared — in this
section. Until then, this item is a blocker and no amount of green CI changes that.

## B‑3 · Solo Override cannot strand a user

**Status: BUILT and TESTED. Not DEVICE-verified.** Audited this milestone; no path found by
which our infrastructure can trap someone. The audit, failure by failure:

| Failure | What happens |
|---|---|
| Supabase down | `requestOverride` returns early; the local `overrideRequested` event was already appended, so the Solo clock is running. |
| Signed out | Same. Every `AccountStore` method opens with `guard case .signedIn`, and every one of them is a no-op, never a throw. |
| No partner answers | The Solo route is defined as *what happens when nobody answers*: `soloAvailableAt = requestedAt + accountabilityWindow`, computed locally. |
| Push fails | There is no push. Nothing waits on it. |
| Shared-commitment backend down | Shared commitments produce ordinary local commitments with ordinary local override policies. |
| Social APIs fail | `SocialStore` failures set a message and change nothing else. |
| Grant polling fails | Sets `grantFailure`; the Solo clock is unaffected. |
| HealthKit errors | Blocks *completion*, not *escape*. Both override routes remain. |
| Notifications denied | Warnings are a courtesy; the Gate does not depend on them. |
| Airplane mode throughout | Every step of the Solo flow is a local ledger append. |

The reason this holds is structural rather than careful: the Solo Override is a pure
function of the local ledger (`packages/EarnedKit/Sources/EarnedKit/Override.swift`), and
`LockScreenView` appends the local event *before* and unconditionally of the network call —
with the comment saying so, which is how it will stay that way.

Reachable from two places, not one: the red locked notice, and Today → the commitment →
**Ways out**. So a user whose restricted apps happen not to be open can still find the
exit.

**Owner:** EarnedKit + Today.
**Requires:** device testing to confirm, not code.
**Verify:** on a device in airplane mode, request an override, start the Solo challenge,
force-quit mid-challenge, relaunch, and finish it. Then repeat with the phone signed out.
Both must end in an unlock.

## B‑4 · Nobody has installed this from scratch

**Status: NOT VERIFIED.** Every fresh-install path is written and reviewed; none has been
walked on a device with no prior state.

What a true fresh state has to mean: a device (or a wiped install) with no ledger, no
`UserDefaults`, no keychain entry, no Screen Time grant, no Health grant, no account, no
profile, no friends, no partners. Note that **the keychain outlives a delete-and-reinstall
on iOS**, so "delete the app" is not by itself a fresh account; the session restore added
on this branch reads a keychain item that a reinstall leaves behind. It is handled — restore
also requires the `UserDefaults` identity, which a reinstall clears — but a real fresh test
should use a second Apple ID or an erased device rather than trusting that reasoning.

**Owner:** onboarding, auth, Today, Progress, Social.
**Requires:** device testing.
**Verify:** the whole of [`beta-test-script.md`](beta-test-script.md) steps 1–8, on a device
that has never had Earned, watching for: onboarding legible end to end; the Screen Time
sheet appearing; Sign in with Apple; handle setup; **empty Today, empty Progress, empty
Social all saying something rather than nothing**; first restriction picked; first
commitment created; first commitment completed from a real workout.

## B‑5 · Ledger migration safety

**Status: TESTED. Closed on this branch.**

Schema version 6. Golden fixtures now exist for every version that can be on a phone —
v1 through v6 — where before this milestone v3 and v4 had none, and v3/v4 are precisely the
versions that introduced `selfReported` verification and its evidence. A decode regression
there would have silently reinterpreted how a past commitment was proved.

Also closed: `LedgerDocument` used to treat an envelope carrying entries but no `version`
key as version 1, which would have run the v1→v6 migration chain over modern history —
`migrateV1ToV2` mutates entries, so this was a live path to silently rewriting somebody's
past. It now throws `DocumentError.envelopeWithoutVersion`, and an unreadable file is
quarantined rather than replayed. Tests cover: every version's fixture, empty ledgers at
every version, a file from a *newer* build (refused, not downgraded), the missing-version
envelope, and corrupt JSON.

175 EarnedKit tests pass on Linux and macOS in CI.

**Owner:** EarnedKit.
**Requires:** nothing further in code. One device check.
**Verify (device):** before installing a new build over an existing one, copy the old
`ledger.json` off the phone. After upgrading, confirm the commitment count, the debt, and
the override history are unchanged, and that You → Advanced → Diagnostics reports no
quarantined history. The quarantine path itself has no automated test because the app
target has none — see [CI](#ci-and-what-it-actually-protects).

## B‑6 · TestFlight distributability

**Status: BUILT and TESTED, not SIGNED.** The project's *configuration* is now verified on
every push; whether it archives is unknown until someone with a signing identity tries.

Fixed on this branch, and this one was a genuine bypass rather than a papercut: the
`EarnedMonitor` target declared an `entitlements:` block with no `properties`. XcodeGen
treats that as "generate this file", so every single `xcodegen generate` overwrote the
checked-in monitor entitlements with `<dict/>` — stripping Family Controls and the App
Group from the extension. The build stayed green, the extension still signed, iOS still
woke it on schedule, and it shielded nothing, with a nil container URL. The exact bypass
`EarnedMonitor` exists to close, reopened by the build system, invisibly, on every
regeneration.

Two independent guards now: `tools/validate-release-config.py` rejects the declaration, and
CI runs `git diff --exit-code -- 'app/**/*.entitlements'` immediately after generation to
catch any other route to the same effect.

Also landed: explicit `CFBundleShortVersionString` / `CFBundleVersion` (the app now *reads*
them for the About screen), `ITSAppUsesNonExemptEncryption: false`, and a 33-check config
validator covering bundle ids, App Group agreement across both entitlement files and
`ShieldPlan.swift`, privacy strings, and version keys. [`release.md`](release.md) is the
repeatable process.

**Owner:** build config.
**Requires:** Apple setup (B‑1), then one archive.
**Verify:** follow [`release.md`](release.md) end to end. Product → Archive, Distribute →
TestFlight. The failures to expect are provisioning ones, and they will name the missing
capability. Do not put Apple credentials in this repository; CI validates configuration and
deliberately signs nothing.

**Open question for Patrick:** the export-compliance answer is declared as exempt on the
reasoning that Earned's only cryptography is the OS's own HTTPS and CryptoKit Ed25519
*verification*. That reading is written out at `app/project.yml` lines 46–59 so it can be
reviewed rather than remembered. Confirm it once against Apple's current questionnaire.

## B‑7 · Hosted backend parity

**Status: DEPLOYED per `deployment.md`, NOT independently verified this milestone.**

The repository holds 22 migrations, `0001`–`0022`. `deployment.md` records `0013`–`0018`
applied 31 August 2026 and `0019`–`0022` applied 1 September 2026, with an RPC-probe method
that is worth repeating because it needs only the publishable key: PostgREST answers `401` /
`42501` for a function that exists and refuses `anon`, and `404` / `PGRST202` for one that
is not there. Every function from `0019`–`0022` answered `42501` against a made-up-name
control, which also proves the `notify pgrst, 'reload schema'` step landed.

I have no database credential and have not re-run any of it. The whole of the local schema
does pass its own suite: **17 SQL test files plus three drills — key rotation, vote
concurrency, and a real signed grant — green in both the `default` and `supabase` layouts**
against Postgres 16, run locally this milestone as well as in CI.

**Owner:** backend.
**Requires:** hosted backend access.
**Verify, before tester #1** — exact queries:

```sql
-- Every function the app calls, present and refusing anon.
select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by 1;

-- RLS on, on every table that holds anyone's data.
select relname, relrowsecurity from pg_class
where relnamespace = 'public'::regnamespace and relkind = 'r' order by 1;

-- The five cron jobs, all active. Missing announce-shared-starts means a
-- shared window opens and nobody's shelf ever hears about it.
select jobname, schedule, active from cron.job order by jobname;
--   expire-override-requests    */15 * * * *
--   purge-override-receipts     17 3 * * *
--   purge-social-events         23 3 * * *
--   announce-shared-starts      0 * * * *
--   purge-shared-commitments    47 3 * * *

-- A published, current signing key with a root signature over it.
select id, state, published_at from public.signing_key order by published_at desc limit 5;

-- The avatar bucket's caps actually took.
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'avatars';

-- Vault secrets exist (names only; values never leave the vault).
select name from vault.decrypted_secrets order by 1;
```

And from outside, with only the publishable key: `POST /rest/v1/rpc/my_shared_commitments`
must answer `401`/`42501`, and `POST /rest/v1/rpc/definitely_not_a_function` must answer
`404`/`PGRST202`. Both edge functions must respond: `/functions/v1/grants` (401 unsigned)
and the approval page via `earntherest.com/a/<token>`.

## B‑8 · The app offered an invitation it could not send

**Status: FIXED on this branch.**

Partners → Add partner → "Invite by text or email" took a phone number, told the user
"they'll get one message asking whether they're in", and sent nothing. Two halves are
missing, both server-side: nothing drains `message_outbox` (`deployment.md` §6), and the
Worker routes `/c/<token>` to a `consent` edge function that **does not exist** — only
`approval` and `grants` are in `supabase/functions/`. So the invitation is composed and
queued, no message goes out, the link would 404 if it did, and the partner sits at
"awaiting consent" forever.

The damage is not the wasted tap. It is that a user builds a commitment on a roster whose
threshold can never be met, and discovers this at the moment they most need the way out.

Fixed by switching the option off behind `Partner.contactInvitationsDeliverable` and saying
plainly why, in the three places that promised it. Friends who are also on Earned are
unaffected — that path is entirely in-app, needs no outbox and no consent page, and is what
Wave 0 accountability should use. Flip the flag in the same change that lands the drainer
and the consent page.

**Consequence for the milestone:** the stop condition "external accountability works without
app install" **cannot be met in B1** without building an email sender, a consent page, and
domain verification. That is new product surface, which this milestone explicitly excludes.
Recommended: scope Wave 0 to Earned-user partners, and treat external accountability as the
first item of B2.

## B‑9 · A session that did not survive the app closing

**Status: FIXED on this branch.**

`BackendClient` held the access token in memory and nowhere else. Two consequences, both
quiet:

- **Every cold launch was signed out.** Sign in with Apple cannot be replayed silently —
  Apple only issues an identity token in response to a deliberate gesture — so the app was
  signed out until the user happened to tap the button again. Meanwhile the foreground sync
  pass, which is how a partner's approval, a friend's request and a shared roster arrive,
  opens with `guard case .signedIn` and did nothing. The user opens Earned to find out
  whether they have been let off, and Earned does not ask.
- **Supabase access tokens last an hour**, and there was no refresh. A session that stayed
  alive past that failed every call with a 401 no screen could explain.

Fixed: the refresh token is kept in the keychain (`SessionKeychain`,
`kSecAttrAccessibleAfterFirstUnlock`, not `UserDefaults` — it is a credential, and
`UserDefaults` is a plist in the container that goes into unencrypted backups); launch
exchanges it for an access token before the first sync pass; and any authorized call that
meets a 401 refreshes once and retries. Sign-out clears the keychain.

**Owner:** backend client.
**Requires:** device testing to confirm.
**Verify:** sign in, force-quit, relaunch — You should still show the account. Then leave
the app for over an hour and return; the sync pass must succeed without a re-login.

---

# BETA REQUIRED

Must be resolved before going past a one- or two-person test.

## R‑1 · A default commitment could not be completed

**Status: FIXED on this branch.** This was a blocker wearing beta-required clothes.

Health authorization was only requested on the `.appVerified` path. The default tier is
`.selfReported`, and manual logging is `#if DEBUG` only — so in a release build the ordinary
create-a-commitment flow produced a commitment that **no workout could ever satisfy**.
Apple Health is the only route a finished workout has into the ledger. The core loop, in the
default configuration, ended in an override.

Fixed three ways: `requestAccess()` is now called whenever a workout commitment is created
(`NewCommitmentView`) or a shared one accepted (`SharedCommitmentViews`); You → Apple Health
shows the real state with a way to ask again; and an unresolved commitment on a phone that
was never asked says so on its own screen, with a Connect button. The copy never claims
Health *denied* Earned, because Health hides read denials and "not asked" is the only
refusal the app can honestly name.

## R‑2 · Error states on networked screens

**Status: FIXED for the cases found; not exhaustively device-tested.**

Audited every screen that touches the network. Three were lying:

- **Friend profile** showed "NOBODY HERE" for a network failure, exactly as for a handle
  that does not exist. A `ProfileLookup` enum now separates found / not-found / failed, and
  a failure says "COULDN'T ASK" with a retry.
- **Friend search** swallowed failures entirely: a search that never reached the server
  looked identical to a search that found nobody. The failure is now shown above the
  results.
- **The locked notice** claimed partners had been "asked" in a way that implied they had
  been told. There is no push; an Earned partner sees the request next time they open the
  app. It now says so and suggests nudging them.

Not found anywhere: infinite spinners, blank error states, or raw backend text. Server
refusals are passed through deliberately — PostgREST messages here are written for people
("this contract has hardened; its accountability terms are frozen") and are better than
anything a generic handler would substitute.

A fourth was found while auditing permissions: a picked avatar that could not be loaded —
an iCloud original that will not download — was swallowed by a `try?` in both profile
screens. The sheet closed and nothing happened, indistinguishable from a tap that missed.
Both now say what went wrong.

**Still needs a device:** expired auth (now handled by the refresh added in B‑9, unproven),
avatar *upload* failure, and malformed responses. **Requires:** device testing with a second
account and a deliberately broken network.

## R‑3 · Observability

**Status: BUILT.** You → Advanced → Diagnostics, plus You → Beta → About.

Reports app version and build, iOS version and device model, backend host, ledger schema
version and entry count, Screen Time authorization, notification authorization, App Group
and monitor-plan readiness with the plan's timestamp, quarantined-history state, and the
last-run time and outcome of each of the four sync passes — Health import, envelope sync,
grant sync, social sync. Each carries *when* as well as *what*, which is the half that
distinguishes a broken sync from one that has never been attempted.

Deliberately absent: tokens, JWTs, the Apple subject, contact ciphertext, any Health datum,
any commitment title, any friend's handle. Copy and Share buttons; the tester can read the
whole report before sending it.

**Crash reporting: none, and none recommended for Wave 0.** With five to ten known testers,
"tell us what you were doing" plus a TestFlight crash log Patrick can pull from App Store
Connect is proportionate. Revisit at public beta.

## R‑4 · Report a problem

**Status: BUILT. One external dependency.** You → Beta → Report a problem. A description
field, a diagnostics toggle that is on by default with a "see exactly what's included"
preview, and a prefilled mail draft the tester reads before sending. Nothing is attached
without the toggle, and nothing is sent without the tester sending it.

Reports go to **`beta@earntherest.com`** (`ReportProblemView.supportAddress`). **That
mailbox has to exist and be read**, or the whole path ends in a bounce the tester never
sees. Patrick: confirm before tester #1, or change the address.

## R‑5 · Version visibility

**Status: BUILT.** You → Beta → About shows `Earned Beta / 0.1 (1)`, read from
`CFBundleShortVersionString` and `CFBundleVersion`, which `project.yml` now states
explicitly and CI asserts are present in the generated `Info.plist`. Bump
`CURRENT_PROJECT_VERSION` per upload; see [`release.md`](release.md).

## R‑6 · Onboarding clarity

**Status: BUILT. Needs a stranger's eyes.** Two pages added — "Proving you did it" (why
Health is asked for, and that a workout is the only thing that completes a commitment) and
"Ways out" (the three overrides, and that Solo needs nobody). The activation page now says
the authorization is voluntary and that withdrawing it stops enforcement.

**Verify:** hand the phone to someone who has heard nothing about Earned and ask them,
afterwards, what the app does and what happens if they want out. Their answer is the test.

## R‑7 · Permission denial

**Status: BUILT for four of five; one unverifiable from here.**

| Denied | Behaviour |
|---|---|
| Family Controls | The app says plainly it cannot block anything; `refreshShielding()` re-reads on every foreground, and revocation now also stops the DeviceActivity schedules and empties the shared plan, so nothing stale can fire months later if it is re-granted. |
| HealthKit | You → Apple Health shows the state; an unfinishable commitment says so on its own screen (R‑1). |
| Notifications | Warnings stop; Gates are unaffected. Re-read on every foreground. |
| Sign in with Apple cancelled | Everything local keeps working. Cancellation is not treated as an error. |
| Photos | **No denial path exists.** `PhotosPicker` runs out of process, so Earned never sees the library and iOS never asks — which is also why there is no `NSPhotoLibraryUsageDescription` and there should not be. What *did* exist was a silent failure next door: a picked photo that would not load (an iCloud original that will not download) was swallowed by a `try?`, the sheet closed, and nothing happened. Both pickers now say so. |

**Requires:** device testing for all five, and a code read for Photos.

## R‑8 · Destructive actions

**Status: AUDITED. One fixed, one documented gap.**

| Action | What actually happens |
|---|---|
| Sign out | Local commitments, debt and enforcement are untouched. Accountability routes stop working while signed out; Solo does not. **Now behind a confirmation that says this.** |
| Delete account | **Does not exist.** Product semantics are settled (accountability-architecture §21.2); the retention half is a legal question. For beta: by hand, on request. Testers are told. |
| Revoke Screen Time | Everything unshields; the app stops claiming to enforce; schedules are stopped and the plan cleared. Always available and always will be. |
| Revoke Health | Nothing can complete a commitment; only overrides end it. Surfaced (R‑1). |
| Remove friend / block | Social visibility ends both ways. Accountability partnership is *separate* and is not revoked by unfriending — deliberate, since partner authority was consented to independently. |
| Revoke a partner | Never lowers a threshold already agreed. A commitment that loses too many partners becomes *unavailable*, not easier (accountability-architecture §4.3). |
| Leave a shared commitment | The personal commitment stands. The shared agreement loses a participant. |
| **Uninstall / reinstall** | **Wipes the ledger, and with it every commitment and all debt.** This is the cheapest escape path in the product and no UI mentions it. |

That last row is the one worth a decision. It is inherent to storing the ledger in the app
container, it is not fixable inside B1, and it is disclosed to testers in
[`beta-test-script.md`](beta-test-script.md). **Patrick decision:** whether Wave 0 ships
with it acknowledged, or whether B2 moves the ledger somewhere a reinstall does not clear.

## R‑9 · Privacy and tester trust

**Status: DOCUMENTED, with one honest unknown.**

- **Health:** finished workouts only — type, duration, distance, energy. Read, never
  written. Never leaves the phone: a partner sees "18 of 30 minutes", derived on the device.
- **Server:** the commitment's *title*, its times, its roster, and version. Not the
  requirement, not the restriction profile, not any workout.
- **Friends see:** handle, display name, avatar, and whatever the sharing switches allow.
- **Partners see:** the request snapshot — title, self-reported progress, reliability
  counts, optional reason.
- **External contacts:** nothing, because nothing is sent (B‑8).
- **Contact addresses:** normalised, encrypted and blind-indexed server-side; never returned
  to any app.
- **Blocked users:** mutually invisible.
- **Account deletion:** no button. Retention and its legal basis are unresolved and are not
  pretended otherwise.

A privacy page exists at `web/public/privacy.html` and is linked from About.
**Requires:** Patrick to read it against the above before tester #1, since it is the thing a
family member will actually be shown.

## R‑10 · Multi-account matrix

**Status: NOT RUN.** Nothing in this product has been driven by two real accounts. The
matrix is [below](#the-multi-account-matrix).

## R‑11 · Manual test script

**Status: WRITTEN.** [`beta-test-script.md`](beta-test-script.md), for a non-developer:
twelve steps, expected result at each, what to screenshot, how to report, what is already
known, and — first, not last — how to get unstuck.

## R‑12 · CI

**Status: BUILT.** See [below](#ci-and-what-it-actually-protects).

---

# PUBLIC BETA

Documented deliberately, and not built. Required before strangers, not before family.

| | Why it waits |
|---|---|
| **APNs sender and `push_outbox` drainer** | `0022` creates the tables; nothing drains them, by design. Until then everything cross-user arrives when the other person next opens the app. Acceptable at ten people who can be texted; not at a hundred. |
| **Message outbox drainer + consent page** | The other half of B‑8. Email (Resend/Postmark/SES, an afternoon plus DNS) is the cheap road; SMS needs 10DLC registration measured in weeks. |
| **Privacy policy and terms** | A page exists; neither has had legal eyes. |
| **Account deletion policy** | Product half settled, retention half unresolved (D10). |
| **Support workflow** | A mail draft is proportionate to ten people and to nobody more. |
| **Crash reporting** | See R‑3. |
| **Rate-limit tuning** | Three override requests a day and the Worker's ~20/min per IP are guesses that have never met real traffic. |
| **Abuse controls** | Blocking exists; reporting does not. |
| **Email/contact compliance** | CAN-SPAM, 10DLC, unsubscribe semantics — all downstream of the sender that does not exist. |
| **App Store metadata** | Not needed for TestFlight. |
| **Analytics policy** | There are no analytics. Decide the policy before the first event, not after. |
| **Disaster recovery** | Supabase's own backups, untested by us. No restore drill. |
| **Key rotation drill** | The *code* path is drilled in CI (`keyset_drill.sh`, and rotation has been done in anger once). The *operational* drill — rotate the hosted key, confirm phones follow — has not been run. |
| **Accessibility** | Dynamic Type and VoiceOver have not been tested. The design leans on tracked small caps, which is exactly the sort of thing that breaks at accessibility sizes. |
| **Widgets, reactions, gamification, Android, pricing, more commitment types, public discovery** | Out of scope for B1 by instruction, and correctly so. |

---

# The multi-account matrix

Three accounts. A = Patrick, B = a friend also on TestFlight, C = a friend who has *not*
installed Earned. Run before going past two people.

**Social**

| | Expected |
|---|---|
| A searches for B's handle | Found. A failure now says "couldn't ask", not "nobody here" (R‑2). |
| A sends a friend request | B sees it next time B opens the app. There is no push. |
| B accepts | Both see each other. |
| A removes B | Both lose visibility. Any accountability partnership **survives** — check this is understood. |
| A re-adds B | Works; no ghost state. |
| A blocks B | Mutually invisible. Neither can search the other. |
| A unblocks B | Not automatically friends again. |

**Accountability (Earned-user partners)**

| | Expected |
|---|---|
| A nominates B | B gets an ask. Friendship alone does not confer authority. |
| B accepts | B appears under Active for A, and only now is eligible for a roster. |
| A creates a commitment with B on the roster | Envelope registers; Diagnostics shows a recent envelope sync. |
| A requests an override | Local event first. B sees it on next open. |
| B approves | Server resolves; the grant is signed by the edge function. |
| The grant reaches A | On A's next foreground pass. Verified against the published key set under the compiled-in root key. |
| A unlocks | The ledger accepts the grant and the shield lifts. |
| **Stale approval** | A completes the workout *first*, then B approves. A must **not** be "let out" retroactively, and B should be told the ask is moot — the close-request wiring added on this branch. |

**External accountability (C)** — **cannot be tested. See B‑8.** Not deferred by choice of
priority; the delivery mechanism does not exist. Do not promise it to a tester.

**Shared commitments**

| | Expected |
|---|---|
| A creates a shared commitment with B | Agreement created; B invited. |
| B accepts | B gets their **own** commitment, own deadline, own Gate. |
| Different restriction profiles | A and B block different apps. Neither can see the other's choice — Earned itself cannot. |
| A finishes first | Roster updates for both. |
| B finishes late | B's own commitment resolves late; A's history is untouched. |
| A blocks B mid-commitment | Both personal commitments survive. Shared visibility ends. |
| B leaves the shared commitment | B's personal commitment stands. |

---

# CI, and what it actually protects

Every job below ran green on this branch, and every one of them was also run locally this
milestone.

| Job | What it protects | Result |
|---|---|---|
| EarnedKit (Linux + macOS) | The domain engine: gates, hardening, the override ladder, migrations, golden fixtures | **175 tests pass** |
| EarnedMedia (macOS) | Avatar re-encoding | pass (Apple platforms only — it wraps ImageIO) |
| Backend, `default` layout | Schema, RLS, every RPC | **17 files + 3 drills pass** |
| Backend, `supabase` layout | The same, with `pgcrypto` in `extensions` — a pinned `search_path` that misses it is silent locally and fatal in production | **17 files + 3 drills pass** |
| Drills | Key rotation over the exact served bytes; five simultaneous votes cannot double-grant; a real grant signed outside Postgres and verified from the published key set | pass |
| Edge functions + Worker (Deno) | Approval page rendering, grant signing determinism, link routing including cross-origin redirect refusal | **18 tests pass** |
| Release config | 33 checks: bundle ids, entitlements, App Group agreement across both targets and `ShieldPlan.swift`, privacy strings, version keys, export compliance | **pass** |
| iOS app build | The app and extension compile | pass |
| Entitlement drift | `git diff --exit-code` after `xcodegen generate` | **pass — this one caught a real bypass** |

**The gap worth naming:** there is no app-target test bundle, so nothing automated covers
`LedgerStorage` quarantine, `AccountStore` state transitions, or the new session restore.
Adding a target CI does not run would be theatre; adding one CI *does* run means building
for a simulator on every push. Deliberately deferred, and the affected paths are called out
individually above so they are checked by hand instead.

---

# Before tester #1

Patrick, in order. Each of these is a thing only you can do.

1. **Apple portal.** Confirm or submit Family Controls (Distribution) for **both**
   `com.pattheratch.earned` and `com.pattheratch.earned.monitor`. Record the dates in B‑1.
   Everything below waits on this, and Apple's queue is the long pole.
2. **Export compliance.** Confirm the exempt reading in `app/project.yml` against Apple's
   current questionnaire.
3. **Archive.** Follow [`release.md`](release.md). Bump `CURRENT_PROJECT_VERSION`. Confirm
   the extension embeds and the upload is accepted.
4. **Hosted backend.** Run every query in B‑7. Confirm all five cron jobs, a current
   published signing key, and both edge functions responding.
5. **Fresh install (B‑4).** On a device that has never had Earned — ideally a second Apple
   ID. Walk `beta-test-script.md` steps 1–8.
6. **Background enforcement (B‑2).** The full nine-step version. This is the one that
   decides whether Earned is a product. Record how long after the deadline the shield
   appeared.
7. **Solo cannot strand (B‑3).** Airplane mode, force-quit mid-challenge, signed out.
8. **Session survives (B‑9).** Force-quit and relaunch; still signed in. Then leave it an
   hour and confirm the sync pass still works.
9. **Read the privacy page** at `earntherest.com/privacy` as the family member who will be
   shown it, and confirm **`beta@earntherest.com`** actually reaches you (R‑4).
10. **Decide the reinstall question** in R‑8.

Only then: one tester, who is in the same building as you.

# Before 5–10 users

1. The full [multi-account matrix](#the-multi-account-matrix) with B, minus the external
   column.
2. **Tell every tester that external partners are off** and that anything involving another
   person arrives when that person next opens the app. Both are in the script; say it out
   loud as well.
3. Confirm **Report a problem** produces a mail draft you actually receive, from a phone
   that is not yours.
4. Confirm the **ledger survives an upgrade** (B‑5) — install the previous build, make a
   commitment, upgrade, check nothing moved.
5. Watch the rate limits with real traffic. **Three override requests per account per day**
   (`private.max_requests_per_day`) and **five partner nominations**
   (`private.max_nominations_per_day`); the Worker adds roughly 20 requests per minute per IP
   on approval links. Three is tight for a tester who is deliberately exercising the escape
   routes — the script asks for two, and a retry after a failure spends a third. The fourth
   ask is refused with "too many override requests today", which reads like a bug to someone
   testing. Either brief them, or raise the cap for the beta and put it back afterwards.
6. Have a **support answer ready** for the two questions that will come: "how do I get out
   of this" and "how do I delete my account". The first is in the script. The second is
   "message Patrick", and there is no button.

# Still needs a product decision

1. **Reinstall wipes the ledger** (R‑8). Acknowledged, or fixed in B2?
2. **External accountability** (B‑8). B2's first item, or dropped as a concept?
3. **Wave 0 size.** The matrix wants one committed B who will actually run it. Ten testers
   with no B is less informative than two testers with one.
4. **Export compliance** (B‑6).
5. **Account deletion** — the by-hand answer is fine for family, and needs saying before the
   first stranger.
