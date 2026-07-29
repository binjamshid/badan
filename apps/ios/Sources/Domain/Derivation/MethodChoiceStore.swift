import Foundation

/// The active method per derived metric, readable from any thread (D-35).
///
/// `CustomizationProfile.methodChoices` is the source of truth and the thing the user edits. This is
/// a mirror of it in `UserDefaults`, kept in step by `AppEnvironment.update`, and it exists for one
/// reason: derivation runs off the main actor — on HealthKit's queues, on `BGTaskScheduler`'s, on
/// detached import tasks — and `AppEnvironment.profile` is main-actor-isolated `@Observable` state
/// that those callers must not touch.
///
/// This is the same shape `BackgroundIngestBridge` already uses for `isHealthKitConnected`: the
/// property for the UI, a `UserDefaults` read for the background, both written together at the one
/// place the value changes. Duplicating the value is the cost; the alternative is a main-actor hop
/// inside the derivation loop, which is worse.
///
/// A missing entry means "use the contract default", so an empty store behaves exactly as BADAN did
/// before methods were selectable.
enum MethodChoiceStore {
    private static let key = "badan.derivation.methodChoices"

    static func choices(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Mirror the profile's choices. Called from `AppEnvironment.update` only — every other reader
    /// treats this as read-only.
    static func write(_ choices: [String: String], defaults: UserDefaults = .standard) {
        if choices.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(choices, forKey: key) }
    }

    /// D-36. Whether calibration may be applied, mirrored for the same off-main-actor reason.
    private static let calibrationKey = "badan.derivation.calibrationEnabled"

    static func calibrationEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Absent means ON, matching the profile's own decode default — a fresh install with no
        // mirror yet must behave the same as one whose profile says true.
        defaults.object(forKey: calibrationKey) as? Bool ?? true
    }

    static func writeCalibrationEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: calibrationKey)
    }

    /// The `algorithmId` derivation should run for `metricId`, resolved against the real contract.
    ///
    /// Goes through `MethodResolver` rather than reading the dictionary directly, so a stored id
    /// that no longer exists falls back to the contract default here exactly as it does on the
    /// surface — the engine and the screen must never disagree about which method is active.
    static func activeAlgorithmId(for metricId: String, contractDefault: String,
                                  registry: AlgorithmRegistry = .shared,
                                  defaults: UserDefaults = .standard) -> String {
        var profile = CustomizationProfile()
        profile.methodChoices = choices(defaults: defaults)
        return MethodResolver.activeAlgorithmId(for: metricId, contractDefault: contractDefault,
                                                profile: profile, registry: registry)
    }
}
