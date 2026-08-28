# app/

The iOS application: SwiftUI app target plus the Screen Time app extensions (shield configuration, shield action, device activity monitor).

Built with Xcode on a Mac. All domain logic lives in [`packages/EarnedKit`](../packages/EarnedKit/) — this target should stay a thin shell: views, navigation, and adapters between iOS frameworks (FamilyControls, ManagedSettings, DeviceActivity, HealthKit) and EarnedKit events.
