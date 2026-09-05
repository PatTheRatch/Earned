# Releasing Earned to TestFlight

The repeatable half of getting a build to a tester. Everything here is a command or a
checkbox; nothing here is a judgement call, and where a judgement call exists it is named as
one and pointed at the person who has to make it.

Read [`docs/beta-readiness.md`](beta-readiness.md) first if this is the first build going to
anyone. This document is *how to ship a build*; that one is *whether this build should be
shipped*.

**None of this can be done by CI or by an agent.** Signing needs Patrick's Apple Developer
account, and Apple credentials are deliberately absent from this repository. What CI can do
— and does, on every push — is check the project configuration that a signing failure would
otherwise reveal to you three days later on a device (`tools/validate-release-config.py`).

---

## 1. What Apple must have approved first

**Family Controls (Distribution), for three bundle identifiers.** Not two — the shield
configuration extension landed after this section was first written, and it is a third App ID
with its own review.

| Target | Bundle id | Needed for TestFlight |
|---|---|---|
| The app | `com.pattheratch.earned` | Family Controls (Distribution) |
| The monitor extension | `com.pattheratch.earned.monitor` | Family Controls (Distribution), **separately** |
| The shield extension | `com.pattheratch.earned.shield` | Family Controls (Distribution), **separately again** |

Development is self-serve and is all an Xcode-to-device build needs. Distribution is reviewed
by a human, takes days to weeks, and is granted per bundle identifier — one approval does not
cover the extensions. See [`docs/family-controls-request.md`](family-controls-request.md) for
the request itself, which is drafted and ready to paste.

Until all three are approved, an archive will upload and then fail validation, or install and
then fail Screen Time authorization on the tester's device with a sandbox error. There is no
way to work around this and no way to check it from the repository — it is a state in Apple's
portal. **If only the app was approved, stop here and request the other two.**

**Also needed once, on the developer portal.** Each of these is a capability the entitlements
file already claims, and a claim the App ID does not carry is a signing failure at archive
time rather than a warning:

- [ ] App Group `group.com.pattheratch.earned` created, and added to **all three** App IDs.
- [ ] HealthKit enabled on `com.pattheratch.earned`.
- [ ] Sign in with Apple enabled on `com.pattheratch.earned`, and the Services ID / key pair
      configured for Supabase ([`docs/deployment.md`](deployment.md) §3).
- [ ] **Push Notifications** enabled on `com.pattheratch.earned`, and an APNs Auth Key created
      ([`deployment.md`](deployment.md) §9).
- [ ] **iCloud** enabled on `com.pattheratch.earned` with **CloudKit** and the container
      `iCloud.com.pattheratch.earned` — this is the ledger's backup, and without it a
      reinstall still clears every commitment and all debt.
- [ ] An App Store Connect app record for `com.pattheratch.earned`.

**And one server-side switch that is easy to miss.** `aps-environment` is
`$(APS_ENVIRONMENT)`, which is `development` in Debug and `production` in Release — so a
TestFlight build registers **production** APNs tokens. The sender must move with it:

```sh
supabase secrets set APNS_HOST=https://api.push.apple.com --project-ref <ref>
```

Sandbox and production are separate APNs environments on separate hosts, and a token minted
for one is refused by the other with `BadDeviceToken`. That refusal reaches the sender's log
and nobody else: to a tester it is simply a notification that never arrives. Expect to run a
mixed fleet during the switchover — your own Debug device holds a sandbox token that the
production host will reject, and `forget_push_token` will quietly drop it, which is correct.

## 2. Export compliance

`project.yml` declares `ITSAppUsesNonExemptEncryption: false`, so TestFlight uploads stop
asking. **Confirm this reading once before the first upload.** The reasoning, recorded in
`project.yml` next to the key:

- The only cryptography Earned performs is HTTPS to Supabase — the OS's own — and Ed25519
  *verification* of grant signatures through CryptoKit.
- Both are exempt uses: encryption provided by the platform, and authentication.
- Earned implements no algorithm of its own and offers no encryption feature to the user.

That is a legal declaration made in Patrick's name, which is why it is written down rather
than remembered. If Apple's questionnaire has changed, change the key rather than the answer.

## 3. Bumping the build number

Both targets, and they must match — App Store Connect rejects an upload whose extension
disagrees with its host. In `app/project.yml`:

```yaml
MARKETING_VERSION: "0.1"        # the version a human says out loud
CURRENT_PROJECT_VERSION: "1"    # +1 on every upload, never reused
```

`CURRENT_PROJECT_VERSION` must increase on every upload for a given `MARKETING_VERSION`;
App Store Connect refuses a duplicate. These reach the tester's screen through You → About,
so a bug report can always be tied to a binary.

```sh
python3 tools/validate-release-config.py    # catches a version the two targets disagree on
```

## 4. The archive

```sh
brew install xcodegen                                        # once
xcodegen generate --spec app/project.yml --project app
git diff --exit-code -- 'app/**/*.entitlements'              # see the warning below
python3 tools/validate-release-config.py
open app/Earned.xcodeproj
```

> **Check that `git diff` line.** XcodeGen writes entitlements files as well as the project
> when a target declares an `entitlements:` block, and with no `properties` it writes an
> empty dict over the checked-in file. The monitor had that bug: Family Controls and the App
> Group were stripped on every regeneration, the build stayed green, the extension signed
> and installed, and it shielded nothing — the exact bypass it exists to close. Both targets
> now reference `CODE_SIGN_ENTITLEMENTS` only, and CI asserts both the declaration and the
> effect, but a non-empty diff here means it has come back.

In Xcode:

1. Select the **Earned** scheme and **Any iOS Device (arm64)** as the destination.
2. Signing & Capabilities → the paid team, *Automatically manage signing* on, for **both**
   the `Earned` and `EarnedMonitor` targets.
3. Product → **Archive**.
4. Organizer → **Distribute App** → **TestFlight & App Store** → Upload.

If the archive fails on signing, the cause is almost always a portal state rather than
anything in the repository: a capability not enabled on an App ID, or Family Controls
(Distribution) not yet approved for the extension. `app/README.md` §"One-time setup" covers
the Development side, which is the same list of capabilities.

## 5. `Backend.plist` — the thing that is not in the repository

`app/Earned/Backend.plist` is gitignored and holds the Supabase project URL and publishable
key. **A build archived without it has no backend at all**: no sign-in, no partners, no
social, no shared commitments. The app is designed to survive this honestly — everything
local keeps working and the account screens say they are unavailable — which means a
misconfigured TestFlight build looks *plausible* rather than broken, and a tester will
report "the social tab is empty" rather than "there is no backend".

- [ ] `Backend.plist` present, pointing at the hosted project (not a local Supabase).
- [ ] After installing the build: You → Advanced → Diagnostics shows a **Backend** host, not
      "Not configured".

See [`backend/README.md`](../backend/README.md) for the two values.

## 6. Before the invite goes out

Run the checklist at the end of [`docs/beta-readiness.md`](beta-readiness.md). The short
version, all of which needs the physical device and none of which any test suite can do:

- [ ] Fresh install on a device that has never had Earned (delete, then install from
      TestFlight — not from Xcode).
- [ ] Onboarding, Screen Time grant, Health grant, Sign in with Apple, profile.
- [ ] One short commitment, Earned force-quit, deadline passes, restricted app is shielded
      **without reopening Earned**.
- [ ] Complete the commitment; the shield lifts.
- [ ] You → Advanced → Diagnostics: App Group *Reachable*, Screen Time *Granted*, Backend a
      real host.
- [ ] You → Beta → Report a problem opens a mail draft that goes somewhere Patrick reads.

## 7. Inviting testers

TestFlight internal testers (up to 100, no Apple review of the build) is the right channel
for Wave 0. External testers require a review pass on the build and a filled-in "What to
Test", so it is a slower loop for family and friends.

Send each tester [`docs/beta-test-script.md`](beta-test-script.md), or a link to it. It is
written for someone who has never heard of a ledger.

- [ ] `beta@earntherest.com` (or whatever `ReportProblemView.supportAddress` says) actually
      delivers to Patrick. It is the only support path in the build.
