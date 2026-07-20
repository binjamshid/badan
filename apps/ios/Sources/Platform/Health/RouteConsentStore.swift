import Foundation

/// The persisted answer to "may BADAN read the GPS traces your watch already saved?" — the one
/// concrete `RouteConsentProviding` the app ships (EPIC-03 task 6, plan §4.11/§13.1).
///
/// **Why `UserDefaults` and not `CustomizationProfile`.** Consent is read at the instant a route
/// would be written, from whichever thread the ingest happens to be on: a foreground sync, a
/// `BGProcessingTask`, or a HealthKit observer wake. `CustomizationProfile` lives on
/// `AppEnvironment`, which is `@MainActor`-isolated, so a background ingest cannot legally read
/// it — and hopping to the main actor mid-ingest to ask would be both slower and, if the app is
/// suspended, indefinitely blocked. This mirrors exactly what `AppEnvironment` already does for
/// `isHealthKitConnected` (see `BackgroundIngestBridge`'s `connected:` closure), which is the
/// same problem with the same shape.
///
/// **Why a `struct` with no stored state.** `RouteConsentProviding` is `Sendable` and the
/// provider is captured by closures that cross actor boundaries. Holding a `UserDefaults`
/// reference would make that a concurrency question; reading `.standard` at call time makes it a
/// non-question, and `UserDefaults` is documented as thread-safe.
///
/// **Fail-closed in three separate ways**, because every one of them is a case where the
/// defensible answer is "no routes":
///   1. Nothing ever recorded → not granted (the `bool(forKey:)` default).
///   2. A recorded grant against an OLDER `policyVersion` → not granted. Consent is to a
///      specific explainer text (see `RouteConsent.policyVersion`); if that text is rewritten to
///      describe a wider use, the old grant must expire rather than silently cover wording the
///      user never read. Re-consenting is one tap on the route screen, and the rows already
///      captured keep their own honest `consent_snapshot` either way.
///   3. A grant with no `decidedAt` → treated as never decided, since "granted" with no moment
///      attached is not a record anyone could stand behind.
struct RouteConsentStore: RouteConsentProviding {

    // Namespaced under `badan.routeConsent.*` alongside `badan.healthKitConnected` — one flat
    // key per field rather than an encoded blob so a future migration can read/repair a single
    // field without decoding, and so a corrupt value degrades to its fail-closed default instead
    // of taking the whole record with it.
    static let grantedKey = "badan.routeConsent.granted"
    static let policyVersionKey = "badan.routeConsent.policyVersion"
    static let decidedAtKey = "badan.routeConsent.decidedAt"

    init() {}

    func routeConsent() -> RouteConsent { Self.current }

    /// The live consent, resolved through all three fail-closed rules above.
    static var current: RouteConsent {
        let defaults = UserDefaults.standard
        let recordedVersion = defaults.string(forKey: policyVersionKey)
        let decidedAt = defaults.object(forKey: decidedAtKey) as? Double
        let granted = defaults.bool(forKey: grantedKey)
            && recordedVersion == RouteConsent.currentPolicyVersion
            && decidedAt != nil
        return RouteConsent(
            granted: granted,
            policyVersion: recordedVersion ?? RouteConsent.currentPolicyVersion,
            decidedAt: decidedAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// `true` when the stored decision was made against an explainer version BADAN no longer
    /// ships — i.e. the toggle reads "off" not because the user turned it off but because the
    /// copy they agreed to is gone. The route screen says so rather than presenting a silently
    /// reset switch, which would look like a bug or, worse, like BADAN quietly dropping a
    /// permission the user believes is still on.
    static var needsReconsent: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: grantedKey), let recorded = defaults.string(forKey: policyVersionKey) else {
            return false
        }
        return recorded != RouteConsent.currentPolicyVersion
    }

    /// Record the user's decision. Always stamps the CURRENT policy version, so a grant is only
    /// ever attached to the text actually on screen when it was given.
    ///
    /// Turning consent off deliberately leaves `decidedAt` and the version in place: "declined on
    /// 3 March against route-consent-v1" is a more useful record than a blank, and neither field
    /// can make `current.granted` true on its own.
    static func record(granted: Bool, decidedAt: Date) {
        let defaults = UserDefaults.standard
        defaults.set(granted, forKey: grantedKey)
        defaults.set(RouteConsent.currentPolicyVersion, forKey: policyVersionKey)
        defaults.set(decidedAt.timeIntervalSince1970, forKey: decidedAtKey)
    }

    /// Wipe the decision entirely — used by "delete all data" style flows, where leaving a
    /// standing location grant behind would contradict what that action promises.
    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: grantedKey)
        defaults.removeObject(forKey: policyVersionKey)
        defaults.removeObject(forKey: decidedAtKey)
    }
}
