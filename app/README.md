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

CI builds this target on every push, so a compile break shows up without a Mac in the loop.

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
3. **Sign in to Xcode**: Xcode menu → Settings… → Accounts → **+** → Apple ID. A free account
   is fine.
4. **Set the signing team**: in Xcode, select the blue `Earned` project in the left sidebar →
   the `Earned` target → **Signing & Capabilities** → tick *Automatically manage signing* and
   pick your name under **Team**. If it complains the bundle identifier is unavailable, change
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to something unique to you and re-run
   `xcodegen generate`.
5. **Run** (▶︎ or ⌘R). The first launch fails with "Untrusted Developer" — on the phone go to
   Settings → General → VPN & Device Management → tap your Apple ID → **Trust**, then run again.

With a free account the app stops launching after **7 days** and you re-run it from Xcode to
refresh. Enrolling in the Apple Developer Program ($99/yr) removes that, and is required
anyway before enforcement (step 3) can reach the phone.

Want to see it without any of this? Pick any simulator in that same destination menu — it runs
immediately, no signing, no phone. Everything in this build works there except that it's not
on your actual phone.

## What's here now

| Screen | Purpose |
|---|---|
| Onboarding | Teaches Gates one concept per screen, configures the Hydration Gate |
| Today | What do I need to do right now — gate status, overdue work, upcoming commitments |
| Lock screen | The receipt: exactly which Gates are closed and what's left |
| New Commitment | One decision per screen, ending in a hardening deadline |
| History | Streak, debt, 30-day reliability, every commitment and its outcome |
| Settings | Hydration config, reward policy, restricted-app placeholders, manual workout logging |

## What's deliberately missing

This build has **no enforcement**. It tracks Gates and tells you exactly what *would* be
locked, but nothing is shielded yet, because that needs Apple's Screen Time entitlements:

- **FamilyControls / ManagedSettings / DeviceActivity** — app selection and real shielding
  (roadmap step 3). Requires the Family Controls capability and, for TestFlight, Apple's
  approval of the distribution entitlement.
- **HealthKit** — workout verification (step 4). Until then, Settings → Testing logs a
  workout by hand so the full loop can be exercised.
- **Accountability partners** — the approve/deny links need the Supabase backend (step 5).
  Free and Solo overrides work today.

Keeping those capabilities out of the project means this target builds and runs on a free
account with no entitlement paperwork. They arrive with the steps that need them.

## Where state lives

The ledger is JSON in the app's Documents directory. When the Screen Time extensions land it
moves to a shared App Group container so the shield can read gate state — every path goes
through `Store/LedgerStorage.swift` to make that a one-file change.
