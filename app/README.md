# app/

The iOS application: a SwiftUI shell around [`EarnedKit`](../packages/EarnedKit/), which owns
every product rule. Views read projected state and append events; they never decide what is
allowed.

## Building

The Xcode project is generated from [`project.yml`](project.yml) rather than committed, so
project-file merge conflicts can't happen.

**Xcode itself is required** — not just the Command Line Tools. Homebrew and XcodeGen work
without it, so it's easy to get this far and then find nothing opens. Check with:

```sh
ls -d /Applications/Xcode.app        # should exist
```

If it doesn't, install Xcode from the Mac App Store (a large download), open it once to let it
finish setting up, then:

```sh
brew install xcodegen                # once
xcodegen generate --spec app/project.yml --project app
open app/Earned.xcodeproj            # from the repo root
```

`Earned.xcodeproj` is a *package*, not a folder. In Finder it opens Xcode on double-click; if
you find yourself looking at `project.pbxproj` and `project.xcworkspace`, you've browsed
inside it instead — back out and use `open` from Terminal.

**After every `git pull`, re-run `xcodegen generate`.** New or renamed Swift files show up on
disk from the pull, but the `.xcodeproj` is generated (and gitignored) — it only learns about
them when regenerated. Skipping this step is what "Cannot find 'X' in scope" for a file you can
see right there in Finder almost always means. Close and reopen the project in Xcode afterward
so it picks up the change:

```sh
git pull
xcodegen generate --spec app/project.yml --project app
```

CI builds this target on every push, so a compile break in the *code itself* shows up without a
Mac in the loop — but CI always regenerates fresh, so it can't catch this particular class of
"forgot to regenerate locally" issue. If CI is green and Xcode still can't find a type, this is
the first thing to check.

### After a macOS upgrade

A major macOS update usually leaves an installed Xcode intact but unwired: `xcode-select`
points at the Command Line Tools instead of Xcode, and Xcode's components need re-running.
That looks like "Xcode isn't supported" without actually being that. Fix it with:

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -runFirstLaunch
xcodebuild -version                  # confirms the version and that it works
```

If Xcode then launches, you're done — carry on with `xcodegen generate` above. Only if it
refuses to launch at all do you need the beta below.

### On a macOS beta (or a just-released major version)

The Mac App Store's Xcode often can't be installed or run on a macOS that shipped after it.
The fix is to get Xcode from Apple's developer downloads instead of the App Store:

1. Go to <https://developer.apple.com/download/applications/> and sign in. **A free Apple ID
   is enough** — Xcode betas do not require the paid Developer Program.
2. Download the Xcode beta whose major version matches your macOS (macOS 27 → Xcode 27). It's
   a ~10–15 GB `.xip`; expanding it takes a while.
3. Drag it to `/Applications`, then point the command line at it:

   ```sh
   sudo xcode-select -s /Applications/Xcode-beta.app
   xcodebuild -version                 # confirms which Xcode is active
   ```

4. Open Xcode once. Recent versions download simulator runtimes on demand — let it fetch the
   iOS one, or Settings → Components → iOS Simulator.

If your iPhone is also on a beta iOS, this is required rather than optional: an older Xcode
refuses to build for a device running a newer iOS than it knows about.

Rolling macOS back is the other option, but it means erase-and-restore from a backup. The
beta Xcode is far less disruptive.

## Running it on your iPhone

The device picker is **in Xcode's toolbar**, at the top of the window: the box to the right of
the ▶︎ Run button showing the scheme (`Earned`) and a destination. Click the destination half
and your iPhone appears in the list — once the phone is ready for it.

Getting the phone into that list, first time only:

1. **Plug the iPhone in** with a cable, unlock it, and tap **Trust This Computer**.
   (Wireless debugging works later; cable is more reliable for the first run.)
2. **Enable Developer Mode on the phone**: Settings → Privacy & Security → Developer Mode →
   on, then restart the phone. This option only appears after the phone has been connected to
   Xcode once, so do step 1 first.
3. **Sign in to Xcode**: Xcode menu → Settings… → Accounts → **+** → Apple ID. This must be
   the account enrolled in the Apple Developer Program — the project now requests the Family
   Controls entitlement, which a free account cannot provision.
4. **Set the signing team**: in Xcode, select the blue `Earned` project in the left sidebar →
   the `Earned` target → **Signing & Capabilities** → tick *Automatically manage signing* and
   pick your name under **Team**. If it complains the bundle identifier is unavailable, change
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to something unique to you and re-run
   `xcodegen generate`.
5. **Run** (▶︎ or ⌘R). The first launch fails with "Untrusted Developer" — on the phone go to
   Settings → General → VPN & Device Management → tap your Apple ID → **Trust**, then run again.

A paid membership signs builds for a year. (On a free account builds expired after 7 days —
and can no longer sign this target at all, since Family Controls needs a paid team.)

Want to see it without a phone? Pick any simulator in that destination menu. Everything works
there **except the shield** — Screen Time authorization fails on the simulator, so Earned will
show its Gates and report that enforcement is off.

## What's here now

| Screen | Purpose |
|---|---|
| Onboarding | Teaches Gates one concept per screen, configures the Hydration Gate |
| Today | What do I need to do right now — gate status, overdue work, upcoming commitments |
| Lock screen | The receipt: exactly which Gates are closed and what's left |
| New Commitment | One decision per screen, ending in a hardening deadline |
| History | Streak, debt, 30-day reliability, every commitment and its outcome |
| Settings | Hydration config, reward policy, app/website picking, plans, manual workout logging |

## Enforcement

### One-time setup: register the Family Controls capability

The entitlements file in this repo is only half of what Screen Time needs. The
*provisioning profile* must also grant Family Controls, and that only happens
once the capability is registered against the App ID. Until then the app claims
an entitlement its profile doesn't authorize, and authorization fails with:

```
The connection to service named com.apple.FamilyControlsAgent was invalidated:
Connection init failed at lookup with error 159 - Sandbox restriction.
```

Fix it once, in Xcode:

1. Select the blue `Earned` project → the `Earned` target → **Signing & Capabilities**
2. **+ Capability** → **Family Controls**
3. Build and run again

**If Family Controls isn't in the + Capability list**, it is not because you
need to request it — Development is self-serve. The list is filtered by the
selected *team*, and Family Controls only appears for a paid one:

- In **Signing & Capabilities**, check the **Team** dropdown. Enrolling creates
  a new team entry; the free `(Personal Team)` doesn't disappear and Xcode
  often stays on it.
- If the paid team isn't offered at all, Xcode hasn't noticed the membership.
  Xcode → **Settings → Accounts** → select the Apple ID; if the membership
  isn't listed on the right, sign out and back in.
- Failing that, enable it directly on the App ID: developer.apple.com →
  Certificates, Identifiers & Profiles → **Identifiers** →
  `com.pattheratch.earned` → tick **Family Controls** → Save. That is what the
  provisioning profile actually reads. Then toggle "Automatically manage
  signing" off and on to force a profile regeneration.

(The *request form* is only for Family Controls **Distribution**, needed before
TestFlight or the App Store — not to build on your own device.)

This is a one-time action per App ID, not per build. It registers the capability
with the developer portal and regenerates the provisioning profile; re-running
`xcodegen generate` afterwards does not undo it, because the capability lives on
the App ID (server side) and the entitlement key lives in `Earned.entitlements`
(in this repo).

### What enforcement does

Real shielding is on. Settings → Restrictions → grant Screen Time access, then pick apps and
websites per Gate in Apple's own picker. When a Gate is unsatisfied, the union of every closed
Gate's picks is shielded by `ManagedSettingsStore`.

The picker runs in a separate process and returns **opaque tokens**: Earned can shield an app
without ever learning which app it is. That is the Screen Time privacy guarantee (NORTHSTAR
§34), and it is why these screens count restrictions rather than naming them.

**The gap that used to be here is closed, pending device verification.** The shield was
applied only by the app, so a Gate closing while Earned wasn't running stayed unshielded
until the app was next opened — and since there is no reason to open Earned except to make
commitments, not opening it was a complete bypass. The `EarnedMonitor` extension now takes
that half: the app computes when the shield must change and writes a small plan into the
App Group, registers a `DeviceActivity` schedule per change, and the extension applies the
plan when the system wakes it.

Two things this needs that a simulator will not give you: the **App Group**
`group.com.pattheratch.earned` registered in the developer portal and added to both App IDs,
and **Family Controls enabled on the extension's App ID** (`com.pattheratch.earned.monitor`)
as well as the app's. Without the App Group the container URL is nil, the plan is never
read, and the monitor wakes on time to shield nothing — silently. Settings → Testing reports
whether the container is reachable for exactly that reason.

**Before TestFlight or the App Store**, request **Family Controls (Distribution)** in the
developer portal — per bundle id, and separately for each Screen Time extension. Apple reviews
it by hand; allow a few days to a few weeks. Family Controls (Development), which is all this
build needs, is self-serve.

## What's still missing

- **A custom shield screen.** Blocked apps currently show Apple's default shield. The
  `NICE TRY.` surface reserved in `docs/design-language.md` needs a `ShieldConfiguration`
  extension.
- **HealthKit** — workout verification. Until then, Settings → Testing logs a workout by hand
  so the full loop can be exercised.
- **Accountability partners** — the approve/deny links need the Supabase backend. Free and
  Solo overrides work today.

## Where state lives

The ledger is JSON in the app's Documents directory. When the Screen Time extensions land it
moves to a shared App Group container so the shield can read gate state — every path goes
through `Store/LedgerStorage.swift` to make that a one-file change.
