import Foundation

/// The telemetry opt-in, mirrored where a background wake can read it (ADR-0011 / D-37).
///
/// `CustomizationProfile.methodologyTelemetryEnabled` is the source of truth and the thing the user
/// toggles; this is its `UserDefaults` shadow, written by `AppEnvironment.update`. The mirror exists
/// because the submission step runs on `BGTaskScheduler`'s queue, and `AppEnvironment.profile` is
/// main-actor-isolated `@Observable` state that must not be touched from there — the same pattern
/// `MethodChoiceStore` and the background bridge's `connected:` closure already use.
///
/// **Absent means OFF.** A fresh install, a cleared defaults domain, or any state where the mirror
/// was never written all resolve to "do not send". That is the one value a missing key must never
/// silently produce the opposite of, for a flag that authorises transmission.
enum TelemetryConsentStore {
    private static let key = "badan.telemetry.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` is false for a missing key — the safe default, relied on deliberately.
        defaults.bool(forKey: key)
    }

    static func write(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
