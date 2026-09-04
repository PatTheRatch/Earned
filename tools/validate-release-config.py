#!/usr/bin/env python3
"""Check that the project can still produce a signable, distributable build.

Everything here is a failure mode that has either already happened once or is
silent when it happens — which is the same thing on a project whose signing
paperwork lives in two files and a developer portal.

The one that motivated this: `project.yml` warns, in a comment, that declaring
the app's entitlements through XcodeGen's `entitlements:` block regenerates the
file as an empty dict and *silently strips* Family Controls, Sign in with Apple
and HealthKit. The build stays green. The app installs. Screen Time
authorization then fails on device with a sandbox error, days later, with
nothing in the diff to explain it.

Deliberately not a linter. It asserts the specific facts a TestFlight build
depends on, each with a message naming what breaks if it is wrong. Add a check
when something bites, not when something could theoretically be checked.

Run: python3 tools/validate-release-config.py
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"

# The three Screen Time bundle identifiers. Family Controls is granted per
# bundle id and reviewed separately for each extension, so this list is also the
# list of Apple approvals TestFlight waits on (docs/family-controls-request.md).
APP_BUNDLE_ID = "com.pattheratch.earned"
MONITOR_BUNDLE_ID = "com.pattheratch.earned.monitor"
SHIELD_BUNDLE_ID = "com.pattheratch.earned.shield"
APP_GROUP = "group.com.pattheratch.earned"

# Every Screen Time extension, checked by the same rules rather than by name.
# The monitor was checked individually and the shield was added later; a second
# hand-written block is how the second extension ends up with the first one's
# bugs and none of its guards.
#
#   (target, label, bundle id, entitlements file, extension point, what breaks)
EXTENSIONS = (
    ("EarnedMonitor", "the monitor", MONITOR_BUNDLE_ID,
     "EarnedMonitor/EarnedMonitor.entitlements",
     "com.apple.deviceactivity.monitor-extension",
     "nothing applies a shield while the app is closed"),
    ("EarnedShield", "the shield", SHIELD_BUNDLE_ID,
     "EarnedShield/EarnedShield.entitlements",
     "com.apple.ManagedSettings.shield-configuration-service",
     "a blocked app shows Apple's default grey card instead of the deal"),
)

FAMILY_CONTROLS = "com.apple.developer.family-controls"
APP_GROUPS = "com.apple.security.application-groups"
HEALTHKIT = "com.apple.developer.healthkit"
APPLE_SIGNIN = "com.apple.developer.applesignin"

failures: list[str] = []
checks = 0


def check(condition: object, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def load_yaml(path: Path) -> dict:
    with path.open() as handle:
        return yaml.safe_load(handle)


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def main() -> int:
    spec = load_yaml(APP / "project.yml")
    targets = spec.get("targets", {})

    check("Earned" in targets, "project.yml has no Earned target")
    for target_name, label, _, _, _, consequence in EXTENSIONS:
        check(target_name in targets,
              f"project.yml has no {target_name} target — {consequence}")

    app = targets.get("Earned", {})
    app_settings = app.get("settings", {}).get("base", {})
    info = app.get("info", {}).get("properties", {})
    extensions = [
        (label, targets.get(name, {}), bundle_id, entitlements_path, point)
        for name, label, bundle_id, entitlements_path, point, _ in EXTENSIONS
    ]

    # --- Bundle identifiers -------------------------------------------------
    # Each extension must be a child of the app's identifier: iOS refuses to
    # embed one whose bundle id is not prefixed by its host's.
    check(app_settings.get("PRODUCT_BUNDLE_IDENTIFIER") == APP_BUNDLE_ID,
          f"the app's bundle id is not {APP_BUNDLE_ID}; Family Controls and the "
          "App ID's capabilities are registered against that exact string")
    for label, target, bundle_id, _, _ in extensions:
        settings = target.get("settings", {}).get("base", {})
        check(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == bundle_id,
              f"{label}'s bundle id is not {bundle_id}")
        check(str(settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")).startswith(
                  APP_BUNDLE_ID + "."),
              f"{label}'s bundle id is not prefixed by the app's; iOS refuses to "
              "embed the extension")

    # --- Versioning --------------------------------------------------------
    # You → About reads these at runtime. A build a tester cannot name is a bug
    # report nobody can act on.
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        check(app_settings.get(key), f"the app has no {key}")
        for label, target, _, _, _ in extensions:
            settings = target.get("settings", {}).get("base", {})
            check(settings.get(key),
                  f"{label} has no {key}; an extension whose version disagrees "
                  "with its host is rejected at upload")
            check(app_settings.get(key) == settings.get(key),
                  f"app and {label} {key} disagree; App Store Connect rejects "
                  "the upload")
    # A build setting only reaches the bundle if the plist asks for it by name.
    # Every target must ask, for opposite reasons: the app so You → About can
    # name the build, the extensions so their versions match their host.
    # Checking the settings alone is what let the monitor ship XcodeGen's
    # default 1.0/1 against the app's own version — green here, refused at
    # upload.
    plists = [("the app", info)] + [
        (label, target.get("info", {}).get("properties", {}))
        for label, target, _, _, _ in extensions
    ]
    for label, properties in plists:
        check(properties.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)",
              f"{label}'s Info.plist does not carry CFBundleShortVersionString: "
              "$(MARKETING_VERSION); the setting above is inert and XcodeGen "
              "writes its own default into the bundle instead")
        check(properties.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)",
              f"{label}'s Info.plist does not carry CFBundleVersion: "
              "$(CURRENT_PROJECT_VERSION); the setting above is inert and "
              "XcodeGen writes its own default into the bundle instead")

    # --- Entitlements: the silent-strip failure -----------------------------
    # CODE_SIGN_ENTITLEMENTS is the only reference the build needs, and the app
    # target must NOT use XcodeGen's `entitlements:` block: with no
    # `properties`, XcodeGen regenerates the file as an empty dict.
    check(app_settings.get("CODE_SIGN_ENTITLEMENTS") == "Earned/Earned.entitlements",
          "the app's CODE_SIGN_ENTITLEMENTS is not set to its checked-in "
          "entitlements file; the signed binary would claim nothing")
    for label, target, _, entitlements_path, _ in extensions:
        settings = target.get("settings", {}).get("base", {})
        check(settings.get("CODE_SIGN_ENTITLEMENTS") == entitlements_path,
              f"{label}'s CODE_SIGN_ENTITLEMENTS is not set to its entitlements "
              "file")
    # Every target, not just the app: the monitor had this exact bug, and an
    # extension is the worse place to have it — a stripped app entitlement fails
    # Screen Time authorization loudly on the next launch, while a stripped
    # *extension* entitlement fails only in the situations nobody is watching.
    for name, target in [("Earned", app)] + [
        (name, targets.get(name, {})) for name, *_ in EXTENSIONS
    ]:
        check("entitlements" not in target,
              f"the {name} target declares an `entitlements:` block. XcodeGen "
              "treats that as 'generate this file', so with no `properties` it "
              "deletes the checked-in entitlements and writes an empty dict — "
              "silently stripping Family Controls, the App Group, Sign in with "
              "Apple and HealthKit on every `xcodegen generate`, with a green "
              "build either side of it. Use CODE_SIGN_ENTITLEMENTS alone")

    app_ent = load_plist(APP / "Earned" / "Earned.entitlements")
    extension_ents = [
        (label, load_plist(APP / entitlements_path))
        for label, _, _, entitlements_path, _ in extensions
    ]

    check(app_ent.get(FAMILY_CONTROLS) is True,
          "the app is missing the Family Controls entitlement; Screen Time "
          "authorization fails with a sandbox error")
    for label, entitlements in extension_ents:
        check(entitlements.get(FAMILY_CONTROLS) is True,
              f"{label} is missing the Family Controls entitlement. It runs as "
              "its own process against Screen Time, so it needs the capability "
              "on its own — granted per bundle id, and reviewed separately for "
              "distribution")
    # Without this, `registerForRemoteNotifications` returns no token and no
    # error — the exact silent failure the rest of this file exists to catch.
    ICLOUD_CONTAINER = "iCloud.com.pattheratch.earned"
    check(app_ent.get("com.apple.developer.icloud-services") == ["CloudKit"],
          "the app is missing the CloudKit entitlement; the ledger has no backup "
          "and deleting the app clears every commitment and all debt")
    check(app_ent.get("com.apple.developer.icloud-container-identifiers")
          == [ICLOUD_CONTAINER],
          f"the iCloud container is not exactly [{ICLOUD_CONTAINER}]")
    mirror = (APP / "Earned" / "Store" / "LedgerMirror.swift").read_text()
    check(f'"{ICLOUD_CONTAINER}"' in mirror,
          "LedgerMirror names a different container from the entitlement, so the "
          "backup is written somewhere nothing ever reads it back")

    check(app_ent.get("aps-environment") in ("development", "production"),
          "the app is missing aps-environment; remote notifications register "
          "silently to nothing, so an invitation never reaches the other phone")
    check(app_ent.get(HEALTHKIT) is True,
          "the app is missing the HealthKit entitlement; no workout can "
          "complete a commitment")
    check(app_ent.get(APPLE_SIGNIN) == ["Default"],
          "the app is missing the Sign in with Apple entitlement; accounts, "
          "partners and the social layer all hang off it")

    # --- App Group: the other silent failure -------------------------------
    # Without a group both processes can reach, the container URL is nil, the
    # plan is never read, and the monitor wakes on time to shield nothing.
    check(app_ent.get(APP_GROUPS) == [APP_GROUP],
          f"the app's App Group is not exactly [{APP_GROUP}]")
    for label, entitlements in extension_ents:
        check(entitlements.get(APP_GROUPS) == [APP_GROUP],
              f"{label}'s App Group is not exactly [{APP_GROUP}]; nothing the "
              "app writes ever reaches it, and the failure is silent — the "
              "extension loads, runs, and reads an empty container")
        check(app_ent.get(APP_GROUPS) == entitlements.get(APP_GROUPS),
              f"the app and {label} list different App Groups")

    source = (APP / "Earned" / "Enforcement" / "ShieldPlan.swift").read_text()
    check(f'"{APP_GROUP}"' in source,
          f"SharedContainer.identifier is not {APP_GROUP}; the entitlement and "
          "the code that uses it have drifted apart")

    # --- Onboarding asks for nothing it has not explained ------------------
    # The app target has no test bundle, so this is the only place the rule can
    # be enforced automatically. It is worth enforcing: asking for a health
    # permission because somebody installed a commitment app is asking before
    # there is anything to justify it, and the regression is a one-line import
    # away (docs/onboarding.md).
    onboarding = APP / "Earned" / "Onboarding"
    onboarding_source = "\n".join(
        path.read_text() for path in sorted(onboarding.glob("*.swift"))
    )
    check(onboarding_source != "", "no onboarding sources found to check")
    for forbidden, why in (
        ("HealthKit", "imports HealthKit"),
        ("HealthImporter", "reaches for the Health importer"),
        ("requestAccess", "requests Health access"),
    ):
        check(forbidden not in onboarding_source,
              f"onboarding {why}. HealthKit is requested at the first verified "
              "commitment, where the permission has a visible job — not at "
              "install, where nobody has mentioned a workout yet")

    # --- Privacy strings ---------------------------------------------------
    # A missing usage description is not a warning: iOS kills the process the
    # moment the API is touched.
    health_usage = info.get("NSHealthShareUsageDescription", "")
    check(len(str(health_usage).strip()) > 40,
          "NSHealthShareUsageDescription is missing or too short to be an "
          "honest consent sentence; iOS terminates the app when HealthKit is "
          "first touched")
    check("read" in str(health_usage).lower(),
          "NSHealthShareUsageDescription should say what is read and why — "
          "that sheet is the entire consent conversation")

    # --- Distribution ------------------------------------------------------
    check(info.get("ITSAppUsesNonExemptEncryption") is False,
          "ITSAppUsesNonExemptEncryption is not declared. Without it every "
          "TestFlight upload stops to ask the same export-compliance question "
          "by hand (docs/release.md §2)")
    check(info.get("CFBundleIconName") == "AppIcon",
          "CFBundleIconName is not set; the icon shows as a grey placeholder "
          "with no build error to explain it")
    icon = APP / "Earned" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
    check(icon.is_file(),
          "the 1024pt app icon is missing; App Store Connect rejects the upload")

    # --- Wiring ------------------------------------------------------------
    dependencies = app.get("dependencies", [])
    for target_name, label, _, _, point, consequence in EXTENSIONS:
        target = targets.get(target_name, {})
        check(any(d.get("target") == target_name for d in dependencies),
              f"the app does not depend on {target_name}, so the extension is "
              f"never embedded and ships as dead code — {consequence}")
        declared = (target.get("info", {}).get("properties", {})
                    .get("NSExtension", {}).get("NSExtensionPointIdentifier"))
        check(declared == point,
              f"{label}'s NSExtensionPointIdentifier is not {point}; the system "
              "will never load it for the job it exists to do")
        check(target.get("type") == "app-extension",
              f"{target_name} is not declared as an app-extension")

    # The shield reads its lines out of the App Group, so the file name has to
    # agree across the two processes the same way the group identifier does.
    check("shield-copy.json" in source,
          "SharedContainer no longer names shield-copy.json; the app would "
          "write the shield's copy somewhere the shield does not read, and the "
          "shield would fall back to its stateless line without saying so")

    # --- Report ------------------------------------------------------------
    if failures:
        print(f"release config: {len(failures)} of {checks} checks failed\n")
        for failure in failures:
            print(f"  ✗ {failure}\n")
        return 1
    print(f"release config: {checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
