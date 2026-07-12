import Foundation
import HealthKit
import Observation
import os

/// The composition root and dependency container. Owns the database, repositories, services,
/// and the live `CustomizationProfile`. Injected into the SwiftUI environment; view models
/// read repositories/services from here. Mutating `profile` (language/depth/theme) re-renders
/// the whole app via Observation.
@Observable
@MainActor
final class AppEnvironment {
    // Infrastructure
    let database: Database
    let clock: Clock
    let deviceId: String
    let appVersion: String

    // Ontology
    let registry: MetricRegistry
    let symptoms: SymptomDictionary
    let templates: InsightTemplateStore

    // Repositories
    let measurements: MeasurementRepository
    let derivation: DerivationRepository
    let insightsRepo: InsightRepository
    let reconciliation: ReconciliationRepository
    let catalog: CatalogRepository
    let logging: LoggingRepository
    let exportJobs: ExportJobRepository
    let profiles: ProfileRepository

    // Services
    let ingestion: IngestionPipeline
    let baselines: BaselineEngine
    let insightEngine: InsightEngine
    let exporter: ExportRunner

    // Live presentation state
    var profile: CustomizationProfile
    var isReady: Bool = false
    var onboardingComplete: Bool
    /// Whether the user has granted real HealthKit read access (FEAT-01). When `true`,
    /// `resetDemoData()` re-runs the real backfill instead of re-seeding demo data, and no
    /// bootstrap ever re-seeds demo data over a connected user's real history (their sources
    /// are never empty once connected, so `SeedController.seedIfNeeded`'s gate stays closed).
    var isHealthKitConnected: Bool
    /// Set if bootstrap's first-run seed hasn't reported `isReady` after a reasonable wait,
    /// so `SplashView` can offer a way forward instead of spinning indefinitely (OPT-071).
    var bootstrapStalled: Bool = false
    /// Non-nil if first-run seeding threw; surfaced instead of being silently discarded so a
    /// genuine setup failure is distinguishable from "no data yet" (OPT-075).
    var bootstrapError: Error?
    /// Non-nil if the most recent user-triggered "Reset demo data" partially or fully failed
    /// (OPT-076). Cleared on the next successful reset attempt.
    var resetError: Error?

    /// DEBUG-only staged-feature flags, separate from the persisted `CustomizationProfile`
    /// (FEAT-297).
    let featureFlags = FeatureFlags()

    private let seedController: SeedController

    init(database: Database, clock: Clock = SystemClock()) {
        // Measures the synchronous DB-open + repository-wiring cost on the pre-first-frame
        // critical path (PERF-001) — visible in Instruments' os_signpost track without any
        // functional change; a full async two-phase restructuring is a larger, riskier change
        // than this pass covers.
        let signpostState = PerformanceLog.signposter.beginInterval("AppEnvironment.init")
        defer { PerformanceLog.signposter.endInterval("AppEnvironment.init", signpostState) }

        self.database = database
        self.clock = clock
        self.appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        self.deviceId = AppEnvironment.resolveDeviceId()

        self.registry = MetricRegistry.shared
        self.symptoms = SymptomDictionary.shared
        self.templates = InsightTemplateStore.shared

        let main = database.main
        let sensitive = database.sensitive
        self.measurements = MeasurementRepository(main)
        self.derivation = DerivationRepository(main)
        self.insightsRepo = InsightRepository(main)
        self.reconciliation = ReconciliationRepository(main)
        self.catalog = CatalogRepository(main)
        self.logging = LoggingRepository(main: main, sensitive: sensitive)
        self.exportJobs = ExportJobRepository(main)
        self.profiles = ProfileRepository(main)

        self.ingestion = IngestionPipeline(measurements: measurements, catalog: catalog,
                                           reconciliation: reconciliation, registry: registry,
                                           clock: clock, deviceId: deviceId)
        self.baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                        registry: registry, clock: clock, deviceId: deviceId)
        self.insightEngine = InsightEngine(insights: insightsRepo, derivation: derivation,
                                           measurements: measurements, templates: templates,
                                           registry: registry, clock: clock, deviceId: deviceId)
        self.exporter = ExportRunner(measurements: measurements, derivation: derivation, logging: logging,
                                     exportJobs: exportJobs, registry: registry, clock: clock,
                                     appVersion: appVersion, deviceId: deviceId)

        self.profile = (try? profiles.load()) ?? CustomizationProfile()
        self.onboardingComplete = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.isHealthKitConnected = UserDefaults.standard.bool(forKey: Self.healthKitConnectedKey)
        self.seedController = SeedController(catalog: catalog, ingestion: ingestion, logging: logging,
                                             measurements: measurements, baselines: baselines,
                                             insightEngine: insightEngine, registry: registry,
                                             clock: clock, deviceId: deviceId)
        applyLaunchOverrides()
    }

    /// Ephemeral UI-test / demo launch overrides (not persisted). Set via
    /// SIMCTL_CHILD_BADAN_LANG=ar, SIMCTL_CHILD_BADAN_DEPTH=power, SIMCTL_CHILD_BADAN_SKIP_ONBOARDING=1.
    private func applyLaunchOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["BADAN_LANG"], let lang = AppLanguage(rawValue: raw) { profile.language = lang }
        if let raw = env["BADAN_DEPTH"], let depth = DepthPolicy(rawValue: raw) { profile.depthPolicy = depth }
        if env["BADAN_SKIP_ONBOARDING"] == "1" { onboardingComplete = true }
    }

    static func makeDefault() -> AppEnvironment {
        // If the store can't open, we still want a running app — fall back to a temp dir.
        if let db = try? Database.applicationDefault() {
            return AppEnvironment(database: db)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-fallback")
        let db = try! Database(directory: tmp)
        return AppEnvironment(database: db)
    }

    // MARK: - Lifecycle

    /// Seed on first run, recompute derivations, then flip `isReady`. Runs off the main actor's
    /// critical path; the UI shows a calm loading state until ready.
    ///
    /// Guards against two first-launch failure modes: a stalled seed leaves the user staring at
    /// a non-interactive splash forever (OPT-071), and a thrown seed error used to be discarded
    /// via `try?`, making a genuine setup failure indistinguishable from "no data yet" (OPT-075).
    func bootstrap() async {
        bootstrapStalled = false
        bootstrapError = nil

        // OPT-071: if the seed hasn't finished after a generous wait, let SplashView offer a
        // way forward instead of spinning indefinitely.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !self.isReady else { return }
            self.bootstrapStalled = true
        }

        let signpostState = PerformanceLog.signposter.beginInterval("AppEnvironment.bootstrap")
        let seedTask = Task.detached(priority: .userInitiated) { [seedController, clock] () -> Error? in
            do {
                try seedController.seedIfNeeded(asOf: clock.now())
                return nil
            } catch {
                return error
            }
        }
        let thrown = await seedTask.value
        PerformanceLog.signposter.endInterval("AppEnvironment.bootstrap", signpostState)
        timeoutTask.cancel()

        // OPT-080: if the hosting `.task` was cancelled (e.g. the app was suspended mid-seed),
        // don't let this now-stale continuation flip UI-relevant state.
        guard !Task.isCancelled else { return }

        bootstrapError = thrown
        bootstrapStalled = false
        isReady = true
    }

    /// Skip past a stalled first-run seed (OPT-071). The seed itself keeps running in the
    /// background — this only unblocks the UI so the user isn't stuck with no recourse.
    func dismissBootstrapStall() {
        bootstrapStalled = false
        isReady = true
    }

    /// FEAT-01: a connected-HealthKit user's "delete all data" must not silently paper back over
    /// their real history with demo data. `resetAll()` drops every main-DB table (including
    /// `read_anchors`), so the HealthKit adapter's incremental cursor is gone too by the time
    /// the real re-ingest below runs — a correct, full backfill restart, not a partial resume.
    func resetDemoData() async {
        isReady = false
        resetError = nil
        let db = database
        let connected = isHealthKitConnected
        let adapter = connected ? makeHealthKitAdapter() : nil
        let thrown: Error? = await Task.detached(priority: .userInitiated) { [seedController, clock, adapter] () -> Error? in
            do {
                try db.resetAll()
                if let adapter {
                    _ = try seedController.ingestHealthData(from: adapter, historyDays: 90, asOf: clock.now())
                    try seedController.deriveAndGenerateInsights(asOf: clock.now())
                } else {
                    try seedController.seed(asOf: clock.now())
                }
                return nil
            } catch {
                return error
            }
        }.value
        // OPT-076: surface (rather than silently swallow) a reset/reseed failure. The method
        // signature stays `async` (not `throws`) so existing callers keep working; this exposes
        // the outcome via `@Observable` state for a future UI to display.
        resetError = thrown
        profile = (try? profiles.load()) ?? CustomizationProfile()
        isReady = true
    }

    func completeOnboarding() {
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    // MARK: - HealthKit connect (FEAT-01)

    /// Request real HealthKit read access and, on success, replace whatever demo data bootstrap
    /// already seeded with a real 90-day backfill. Returns `true` once authorization succeeded
    /// (see `HealthKitAdapter.requestAuthorization` for why that isn't the same as "every type
    /// was granted") — callers should proceed to `completeOnboarding()` regardless of the
    /// result, per the "connect now or later, BADAN works either way" promise; the backfill
    /// itself keeps running in the background after this returns, so onboarding never blocks on
    /// ingest duration.
    @discardableResult
    func connectHealthKit() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let adapter = makeHealthKitAdapter()
        let granted = await adapter.requestAuthorization()
        guard granted else { return false }

        isHealthKitConnected = true
        UserDefaults.standard.set(true, forKey: Self.healthKitConnectedKey)

        let db = database
        Task.detached(priority: .userInitiated) { [seedController, clock, adapter] in
            do {
                // Bootstrap already demo-seeded on first launch (it runs before onboarding is
                // even shown) — wipe that before the real backfill so a connected user never
                // ends up with demo rows mixed into their real history (FEAT-01 demo/real
                // boundary). `resetAll()` also clears `read_anchors`, so this is a clean start.
                try db.resetAll()
                _ = try seedController.ingestHealthData(from: adapter, historyDays: 90, asOf: clock.now())
                try seedController.deriveAndGenerateInsights(asOf: clock.now())
            } catch {
                HealthKitConnectLog.logger.error("Post-connect backfill failed: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    private func makeHealthKitAdapter() -> HealthKitAdapter {
        HealthKitAdapter(anchors: ReadAnchorRepository(database.main))
    }

    // MARK: - Presentation mutations (persisted)

    /// Apply a settings change. Updates the in-memory profile immediately for instant UI
    /// feedback, then persists off the main actor (PERF-087) instead of blocking every settings
    /// tap on a synchronous disk write. If the save fails, the in-memory value is rolled back
    /// right away rather than silently reverting on the next launch (OPT-079).
    func update(_ mutate: (inout CustomizationProfile) -> Void) {
        let previous = profile
        var p = profile
        mutate(&p)
        profile = p

        // OPT-200: the sensitive DB is independently purgeable; re-enabling it after a purge
        // never reseeds it unless something explicitly checks for that on this transition.
        let sensitiveJustEnabled = !previous.sensitiveModulesEnabled && p.sensitiveModulesEnabled

        Task.detached(priority: .utility) { [weak self, profiles, seedController, clock] in
            do {
                try profiles.save(p)
            } catch {
                await MainActor.run { self?.profile = previous }
                return
            }
            if sensitiveJustEnabled {
                try? seedController.seedSensitiveIfNeeded(asOf: clock.now())
            }
        }
    }

    var language: AppLanguage { profile.language }
    var depth: DepthPolicy { profile.depthPolicy }

    func now() -> Date { clock.now() }

    // MARK: - Device identity

    private static let deviceKey = "badan.deviceId"
    private static let onboardingKey = "badan.onboardingComplete"
    private static let healthKitConnectedKey = "badan.healthKitConnected"

    private static func resolveDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceKey) { return existing }
        let id = ULID.newID()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }
}

private enum HealthKitConnectLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "HealthKitConnect")
}
