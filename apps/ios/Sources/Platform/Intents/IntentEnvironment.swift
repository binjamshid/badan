import Foundation

/// How an App Intent reaches the app's composition root (EPIC-19).
///
/// App Intents declared in the app target run **in the app's own process** — iOS launches BADAN
/// (foreground or background) to perform them — so `BADANApp.init()` has always run by the time
/// `perform()` is called. That is what makes registration, rather than construction, the correct
/// shape here: `AppEnvironment` owns two `SQLiteConnection`s, and each serializes its writes
/// behind its own lock. A second environment built for the intent would be a second lock over the
/// same files, so a `LogWaterIntent` writing while a screen writes would fall through to SQLite's
/// own contention handling and surface as intermittent `SQLITE_BUSY` on device only. This is the
/// same reasoning Android's `AppEnvironment.shared(context)` records for `SyncWorker`.
///
/// It also matters for what the user *sees*: an intent that wrote through its own environment
/// would not bump the live `dataGeneration`, so a water log made from Siri would be invisible on
/// an already-loaded Log tab until the screen happened to reload.
///
/// The fallback exists so an intent can still do its job if registration ever hasn't happened
/// (a launch path that reaches an intent before the `App` initializer — not a path that exists
/// today, but a crash here would be a Siri failure with no diagnosis). It builds the same
/// environment `BADANApp` would and caches it, so at worst there is one extra environment, never
/// one per invocation.
@MainActor
enum IntentEnvironment {
    private static var registered: AppEnvironment?

    /// Called once from `BADANApp.init()`. Idempotent; a later call replaces the reference (an
    /// app re-init after a background launch is the case).
    static func register(_ environment: AppEnvironment) {
        registered = environment
    }

    static func resolve() -> AppEnvironment {
        if let registered { return registered }
        let fallback = AppEnvironment.makeDefault()
        registered = fallback
        return fallback
    }
}
