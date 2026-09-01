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

# The two Screen Time bundle identifiers. Family Controls is granted per bundle
# id and reviewed separately for each extension, so this list is also the list
# of Apple approvals TestFlight waits on (docs/family-controls-request.md).
APP_BUNDLE_ID = "com.pattheratch.earned"
MONITOR_BUNDLE_ID = "com.pattheratch.earned.monitor"
APP_GROUP = "group.com.pattheratch.earned"

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
    check("EarnedMonitor" in targets,
          "project.yml has no EarnedMonitor target — nothing applies a shield "
          "while the app is closed")

    app = targets.get("Earned", {})
    monitor = targets.get("EarnedMonitor", {})
    app_settings = app.get("settings", {}).get("base", {})
    monitor_settings = monitor.get("settings", {}).get("base", {})
    info = app.get("info", {}).get("properties", {})
    monitor_info = monitor.get("info", {}).get("properties", {})

    # --- Bundle identifiers -------------------------------------------------
    # The monitor must be a child of the app's identifier: iOS refuses to embed
    # an extension whose bundle id is not prefixed by its host's.
    check(app_settings.get("PRODUCT_BUNDLE_IDENTIFIER") == APP_BUNDLE_ID,
          f"the app's bundle id is not {APP_BUNDLE_ID}; Family Controls and the "
          "App ID's capabilities are registered against that exact string")
    check(monitor_settings.get("PRODUCT_BUNDLE_IDENTIFIER") == MONITOR_BUNDLE_ID,
          f"the monitor's bundle id is not {MONITOR_BUNDLE_ID}")
    check(str(monitor_settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")).startswith(
              APP_BUNDLE_ID + "."),
          "the monitor's bundle id is not prefixed by the app's; iOS refuses to "
          "embed the extension")

    # --- Versioning --------------------------------------------------------
    # You → About reads these at runtime. A build a tester cannot name is a bug
    # report nobody can act on.
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        check(app_settings.get(key), f"the app has no {key}")
        check(monitor_settings.get(key),
              f"the monitor has no {key}; an extension whose version disagrees "
              "with its host is rejected at upload")
    check(app_settings.get("MARKETING_VERSION")
          == monitor_settings.get("MARKETING_VERSION"),
          "app and monitor MARKETING_VERSION disagree; App Store Connect "
          "rejects the upload")
    check(app_settings.get("CURRENT_PROJECT_VERSION")
          == monitor_settings.get("CURRENT_PROJECT_VERSION"),
          "app and monitor CURRENT_PROJECT_VERSION disagree; App Store Connect "
          "rejects the upload")
    # A build setting only reaches the bundle if the plist asks for it by name.
    # Both targets must ask, for opposite reasons: the app so You → About can
    # name the build, the monitor so its version matches its host. Checking the
    # settings alone is what let the monitor ship XcodeGen's default 1.0/1
    # against the app's own version — green here, refused at upload.
    for label, properties in (("the app", info), ("the monitor", monitor_info)):
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
    check(monitor_settings.get("CODE_SIGN_ENTITLEMENTS")
          == "EarnedMonitor/EarnedMonitor.entitlements",
          "the monitor's CODE_SIGN_ENTITLEMENTS is not set to its entitlements "
          "file")
    # Both targets, not just the app: the monitor had this exact bug, and it is
    # the worse place to have it — a stripped app entitlement fails Screen Time
    # authorization loudly on the next launch, while a stripped *monitor*
    # entitlement fails only in the one situation nobody is watching.
    for name, target in (("Earned", app), ("EarnedMonitor", monitor)):
        check("entitlements" not in target,
              f"the {name} target declares an `entitlements:` block. XcodeGen "
              "treats that as 'generate this file', so with no `properties` it "
              "deletes the checked-in entitlements and writes an empty dict — "
              "silently stripping Family Controls, the App Group, Sign in with "
              "Apple and HealthKit on every `xcodegen generate`, with a green "
              "build either side of it. Use CODE_SIGN_ENTITLEMENTS alone")

    app_ent = load_plist(APP / "Earned" / "Earned.entitlements")
    monitor_ent = load_plist(APP / "EarnedMonitor" / "EarnedMonitor.entitlements")

    check(app_ent.get(FAMILY_CONTROLS) is True,
          "the app is missing the Family Controls entitlement; Screen Time "
          "authorization fails with a sandbox error")
    check(monitor_ent.get(FAMILY_CONTROLS) is True,
          "the monitor is missing the Family Controls entitlement. It shields "
          "on its own, so it needs the capability on its own — granted per "
          "bundle id, and reviewed separately for distribution")
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
    check(monitor_ent.get(APP_GROUPS) == [APP_GROUP],
          f"the monitor's App Group is not exactly [{APP_GROUP}]; the shield "
          "plan never crosses between the two processes and closed-app "
          "enforcement silently does nothing")
    check(app_ent.get(APP_GROUPS) == monitor_ent.get(APP_GROUPS),
          "the app and the monitor list different App Groups")

    source = (APP / "Earned" / "Enforcement" / "ShieldPlan.swift").read_text()
    check(f'"{APP_GROUP}"' in source,
          f"SharedContainer.identifier is not {APP_GROUP}; the entitlement and "
          "the code that uses it have drifted apart")

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
    check(any(d.get("target") == "EarnedMonitor" for d in dependencies),
          "the app does not depend on EarnedMonitor, so the extension is never "
          "embedded and closed-app enforcement ships as dead code")
    extension_point = (monitor.get("info", {}).get("properties", {})
                       .get("NSExtension", {}).get("NSExtensionPointIdentifier"))
    check(extension_point == "com.apple.deviceactivity.monitor-extension",
          "the monitor's NSExtensionPointIdentifier is not the DeviceActivity "
          "monitor point; the system will never wake it")
    check(monitor.get("type") == "app-extension",
          "EarnedMonitor is not declared as an app-extension")

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
