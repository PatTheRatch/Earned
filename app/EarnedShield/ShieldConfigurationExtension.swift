import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen somebody actually meets when they tap a blocked app.
///
/// Everything else in Earned is a surface the user chose to open. This one is
/// the product interrupting them, and it is the only place `NICE TRY.` has ever
/// been allowed to appear (docs/design-language.md): the in-app notice is
/// factual because the user came looking for it, and this one can be wry
/// because they were caught. Both say **THE DEAL STILL STANDS.** in the end,
/// and both are the same red.
///
/// **What this process is not allowed to do.** It is handed an opaque token and
/// a few milliseconds, with no ledger, no network, and a memory ceiling far
/// below the app's. So it decides nothing: the app has already written the
/// lines into the App Group (`ShieldCopy`), and the work here is to read them
/// and lay them out. If the read fails — no container, no file, a copy written
/// by a build that is no longer installed — the shield still appears, still
/// red, still refusing, with a line that needs no state to be true. A shield
/// that fails open is a shield that is not enforcing anything.
///
/// The layout is Apple's and cannot be argued with: icon, title, subtitle, one
/// or two buttons. Font is the system's — `ShieldConfiguration.Label` takes
/// text and a colour and nothing else — so the poster face does not survive
/// here. The brand carries on colour, capitals, and the full stop instead.
class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // Theme.paper / .signal, in the only form this API accepts. Duplicated
    // deliberately rather than shared: pulling SwiftUI's Color across for two
    // constants would drag the design system into an extension that must stay
    // small, and these two values have not moved since the identity was set.
    private static let paper = UIColor(red: 0.949, green: 0.937, blue: 0.914, alpha: 1)
    private static let signal = UIColor(red: 0.910, green: 0.267, blue: 0.180, alpha: 1)

    private func configuration() -> ShieldConfiguration {
        let lines = SharedContainer.loadCopy()?.lines.filter { !$0.isEmpty } ?? []
        let subtitle = lines.isEmpty
            ? ShieldCopy.fallbackLine
            // Every closed Gate, not just the first. A phone held shut by two
            // Gates that names one of them sends the user to satisfy it and
            // find the shield still there, which reads as a broken app rather
            // than as the second deal they made (NORTHSTAR §5, §6).
            : lines.joined(separator: "\n")

        return ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: Self.signal,
            icon: nil,
            title: ShieldConfiguration.Label(text: "NICE TRY.", color: Self.paper),
            subtitle: ShieldConfiguration.Label(text: subtitle,
                                                color: Self.paper.withAlphaComponent(0.85)),
            // There is one button because there is one honest action. A
            // shield action extension cannot open its host app, so a second
            // button offering the ways out would be a button that does not go
            // there — and this is the exact moment at which a promise the app
            // cannot keep costs the most.
            primaryButtonLabel: ShieldConfiguration.Label(text: "THE DEAL STILL STANDS.",
                                                          color: Self.signal),
            primaryButtonBackgroundColor: Self.paper,
            secondaryButtonLabel: nil)
    }

    // Four entry points, one answer. The kind of thing being blocked is not
    // something the user needs explained back to them — they know what they
    // tapped — and Earned shields what it cannot identify anyway (§34), so
    // there is nothing here to vary on.

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }
}
