import Foundation

/// A minimal local flag store for staging in-progress features behind a switch, separate from
/// `CustomizationProfile` (which is the user-facing, persisted-and-synced settings model).
/// `UserDefaults`-backed and DEBUG-only for v1 — no remote config, per the app's no-backend
/// constraint. Flags default to `false` (off) unless explicitly enabled.
final class FeatureFlags {
    private let defaults: UserDefaults
    private static let keyPrefix = "badan.featureFlag."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    #if DEBUG
    func isEnabled(_ flag: String) -> Bool {
        defaults.bool(forKey: Self.keyPrefix + flag)
    }

    func setEnabled(_ enabled: Bool, for flag: String) {
        defaults.set(enabled, forKey: Self.keyPrefix + flag)
    }
    #else
    func isEnabled(_ flag: String) -> Bool { false }
    func setEnabled(_ enabled: Bool, for flag: String) { /* no-op in release builds */ }
    #endif
}
