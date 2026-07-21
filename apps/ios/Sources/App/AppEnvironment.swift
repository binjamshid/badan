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
    let backgroundRuns: BackgroundRunRepository
    /// EPIC-03. Workout GPS traces. Wired here like every other repository so the workout detail
    /// screen reads routes through the composition root rather than constructing its own
    /// repository against `database.main` — the one place route rows are reachable from should be
    /// visible in the dependency list, not buried in a view model.
    let routes: RouteRepository
    /// EPIC-38 (plan §9.14). The hydration module's append-first drink ledger, its beverage/
    /// container catalogs, goals, and per-day summaries. Wired here — not constructed inside a
    /// hydration view model — for the same reason every sibling repository is: the hydration
    /// surfaces (LogHub's Today card, the full Hydration screen) read one connection to `database.
    /// main`, and "where do logged drinks live?" is answerable from this dependency list.
    let hydration: HydrationRepository

    // Services
    let ingestion: IngestionPipeline
    let baselines: BaselineEngine
    /// EPIC-24/25/26/27 score engines. Constructed here in the composition root (one instance each,
    /// so every surface reads the same wiring) and run — for the three that WRITE — in their
    /// cross-metric order by `derivationCoordinator`. `deviation` writes nothing: it is a pure read
    /// model over the `Baseline` rows the pipeline refreshes, read on demand by the Health Monitor
    /// surface, so it is wired here but never "recomputed" (see `DeviationEngine`).
    let sleepIntelligence: SleepIntelligenceEngine
    let readiness: ReadinessEngine
    let effort: EffortEngine
    let deviation: DeviationEngine
    /// EPIC-23. The one place the writing score engines run in the published sleep → readiness →
    /// effort order (plan §18). The ingest→derive funnel (`SeedController.deriveAndGenerateInsights`)
    /// and the background backfill job (`recomputeScoreBackfill`) both go through it.
    let derivationCoordinator: DerivationCoordinator
    let insightEngine: InsightEngine
    let exporter: ExportRunner
    /// EPIC-04. The background substrate: HealthKit observer wakes, `BGTaskScheduler` tasks, and
    /// the `background_runs` log. Also owns the ingest lock every sync path now goes through —
    /// see `BackgroundIngestBridge.ingestLock`.
    let background: BackgroundCoordinator
    /// EPIC-26. The durable queue for a historical effort/score re-derivation an HR-max/zone edit
    /// requests. Written by `requestEffortBackfill`, drained by the BGProcessing `.scoreBackfill` step.
    let scoreBackfillStore: ScoreBackfillRequestStore

    // Live presentation state
    var profile: CustomizationProfile
    var isReady: Bool = false
    var onboardingComplete: Bool
    /// Whether the user has granted real HealthKit read access (FEAT-01). When `true`,
    /// `resetDemoData()` re-runs the real backfill instead of re-seeding demo data, and
    /// `bootstrap()` never demo-seeds over a connected user — see BUG-07: their `sources` can
    /// still be legitimately empty (a crash interrupted a prior backfill), so bootstrap re-runs
    /// the real ingest→derive chain in that case instead of falling through to
    /// `SeedController.seedIfNeeded`.
    var isHealthKitConnected: Bool
    /// Set if bootstrap's first-run seed hasn't reported `isReady` after a reasonable wait,
    /// so `SplashView` can offer a way forward instead of spinning indefinitely (OPT-071).
    var bootstrapStalled: Bool = false
    /// Non-nil if first-run seeding threw; surfaced instead of being silently discarded so a
    /// genuine setup failure is distinguishable from "no data yet" (OPT-075). `bootstrap()`
    /// holds `isReady` at `false` while this is set so `SplashView` gets a chance to actually
    /// show it (BUG-17) — `dismissBootstrapStall()` is the way past it, same as a stall.
    var bootstrapError: Error?
    /// Non-nil if the most recent user-triggered "Reset demo data" partially or fully failed
    /// (OPT-076). Cleared on the next successful reset attempt. `SettingsScreen` surfaces this
    /// as a transient notice (BUG-17).
    var resetError: Error?
    /// Set when `makeDefault()` had to fall back to a scratch or in-memory database because the
    /// real on-device store couldn't be opened (EDGE-05) — nothing written this session will
    /// survive an app restart. `RootView` shows a calm warning banner while this is `true`.
    var isStorageFallback: Bool = false

    /// BUG-12/13/EDGE-13: the one data-change signal every screen can key its reload off of.
    /// Bumped after anything that can change what's on disk out from under an already-loaded
    /// screen — a pipeline run (bootstrap's first-run seed, `connectHealthKit`'s backfill,
    /// `syncIfStale`'s foreground re-sync), `resetDemoData`, and the sensitive-module
    /// re-enable path in `update(_:)`. Screens fold this into their `.task(id:)` identity
    /// (alongside `profile`) so a bump always forces a reload regardless of the screen's own
    /// staleness guard. Log flows outside this file's scope (Workout/Nutrition/Symptom/
    /// Medication) can't bump this yet — see the fix notes on the screens that read it for how
    /// that gap is covered in the meantime.
    private(set) var dataGeneration: Int = 0

    func bumpDataGeneration() { dataGeneration += 1 }

    /// DEBUG-only staged-feature flags, separate from the persisted `CustomizationProfile`
    /// (FEAT-297).
    let featureFlags = FeatureFlags()

    private let seedController: SeedController
    /// BUG-18: the most recently enqueued lifecycle pipeline task — bootstrap's first-run seed,
    /// `connectHealthKit`'s backfill, or `resetDemoData`'s wipe+reseed. Each new entry point
    /// captures whatever this holds *before* replacing it and awaits that inside its own
    /// detached body, so the three never interleave (e.g. a reset landing mid-backfill) even
    /// though each still runs off the main actor.
    private var pipelineTask: Task<Error?, Never>?
    /// NEW-01: the ingest→derive Task kicked off by the most recent `connectHealthKit()` call —
    /// always the same `Task` instance as `pipelineTask` at the time `connectHealthKit` returns —
    /// so onboarding can await its completion (bounded by a timeout) to show a real first fact
    /// without ever blocking indefinitely on backfill duration. `nil` on the demo/skip path.
    private var backfillTask: Task<Error?, Never>?
    /// BUG-02: when the most recent foreground `syncIfStale()` last actually ran (started, not
    /// finished) — `nil` until the first one fires. Read/written only on the main actor.
    ///
    /// Readable (not private) so Diagnostics can show it: "when did this app last try to sync?"
    /// is the first question any support conversation starts with, and until now nothing in the
    /// app could answer it.
    private(set) var lastSyncAt: Date?
    /// BUG-02: true from the moment `syncIfStale()` dispatches its detached task until that task
    /// (and anything it was chained behind) finishes, so a second `.active` transition arriving
    /// before the first sync lands is a no-op rather than a second overlapping ingest.
    private var isSyncInFlight = false

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
        // Bound as a local (not just `self.catalog`) so the two engine closures below can capture it
        // without capturing a not-yet-fully-initialized `self` — the same pattern the background
        // bridge uses for `main`/`backgroundRuns`.
        let catalog = CatalogRepository(main)
        self.catalog = catalog
        self.logging = LoggingRepository(main: main, sensitive: sensitive)
        self.exportJobs = ExportJobRepository(main)
        self.profiles = ProfileRepository(main)
        self.routes = RouteRepository(main)
        self.hydration = HydrationRepository(main: main)
        let backgroundRuns = BackgroundRunRepository(main)
        self.backgroundRuns = backgroundRuns

        self.ingestion = IngestionPipeline(measurements: measurements, catalog: catalog,
                                           reconciliation: reconciliation, registry: registry,
                                           clock: clock, deviceId: deviceId)
        self.baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                        registry: registry, clock: clock, deviceId: deviceId)
        self.sleepIntelligence = SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                                         clock: clock, deviceId: deviceId)
        // Readiness resolves a two-source overnight-HRV conflict by source priority (plan §18). The
        // priority is reconstructed from the persisted source/device catalog via the published
        // `SensorQualityMap` classes (worn sensor > phone), so it needs no new stored column and
        // cannot drift from the sensor-class contract — see `readinessSourcePriority`. Capturing the
        // local `catalog` keeps this off `self` during init.
        self.readiness = ReadinessEngine(derivation: derivation, measurements: measurements,
                                         clock: clock, deviceId: deviceId,
                                         priorityForSource: { sourceId in
                                             AppEnvironment.readinessSourcePriority(sourceId: sourceId, catalog: catalog)
                                         })
        // Effort reads HR max / zones off the live profile per recompute (never a cached copy), so a
        // mid-session HR-max edit is picked up on the next run — the reason it takes a provider, not a
        // stored `UserProfile` (see `EffortEngine`).
        self.effort = EffortEngine(derivation: derivation, measurements: measurements, registry: registry,
                                   clock: clock, deviceId: deviceId,
                                   profileProvider: { try catalog.userProfile() })
        self.deviation = DeviationEngine(derivation: derivation, measurements: measurements,
                                         catalog: catalog, registry: registry, clock: clock)
        self.derivationCoordinator = DerivationCoordinator(baselines: baselines, sleep: sleepIntelligence,
                                                           readiness: readiness, effort: effort)
        self.insightEngine = InsightEngine(insights: insightsRepo, derivation: derivation,
                                           measurements: measurements, templates: templates,
                                           registry: registry, clock: clock, deviceId: deviceId)
        self.exporter = ExportRunner(measurements: measurements, derivation: derivation, logging: logging,
                                     exportJobs: exportJobs, registry: registry, clock: clock,
                                     appVersion: appVersion, deviceId: deviceId,
                                     // EPIC-38: a logged drink is normal-class, so the plain
                                     // share-sheet exporter must carry the drink ledger too — a
                                     // DEFAULT export includes the user's drinks (notes withheld by
                                     // the writer's default redaction), never paywalled or omitted.
                                     hydration: hydration)

        self.profile = (try? profiles.load()) ?? CustomizationProfile()
        self.onboardingComplete = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.isHealthKitConnected = UserDefaults.standard.bool(forKey: Self.healthKitConnectedKey)
        let seedController = SeedController(catalog: catalog, ingestion: ingestion, logging: logging,
                                            measurements: measurements, baselines: baselines,
                                            insightEngine: insightEngine, registry: registry,
                                            clock: clock, deviceId: deviceId,
                                            derivationCoordinator: derivationCoordinator)
        self.seedController = seedController

        // EPIC-04 wiring. The bridge takes closures rather than reaching back into `self`: it is
        // called from HealthKit's queues and from `BGTaskScheduler`'s, neither of which is the
        // main actor this class is isolated to, so it must not hold a reference to it.
        let connectedKey = Self.healthKitConnectedKey
        let scoreBackfillStore = ScoreBackfillRequestStore()
        self.scoreBackfillStore = scoreBackfillStore
        let bridge = BackgroundIngestBridge(
            seedController: seedController,
            main: main,
            // A fresh adapter per ingest, matching every other call site — each one owns its own
            // `pendingAnchors` buffer (DATA-08), so sharing one across concurrent callers would
            // be the exact hazard the ingest lock exists to prevent.
            // EPIC-03: the background port needs the route-consent provider for the same reason
            // the foreground one does — a background wake is an ingest, and an ingest that
            // ignored the toggle would write location rows the user never agreed to. The
            // provider reads `UserDefaults` at call time precisely so it is legal here, off the
            // main actor (see `RouteConsentStore`).
            makePort: { HealthKitAdapter(anchors: ReadAnchorRepository(main), routeConsent: RouteConsentStore()) },
            // Read from `UserDefaults` rather than the `isHealthKitConnected` property: the
            // property is main-actor-isolated `@Observable` state and this closure runs on
            // background queues. Both read the same key, written together in `connectHealthKit()`.
            connected: { UserDefaults.standard.bool(forKey: connectedKey) },
            // EPIC-26: the score-backfill runner shares the ingest lock (so a re-derivation never
            // overlaps an ingest→derive) and the same durable request store the composition root
            // writes to.
            derivationCoordinator: derivationCoordinator,
            scoreBackfillStore: scoreBackfillStore)
        // EPIC-15 wiring. The automation engine composes Phase-1's runner, so it needs a
        // DELIVERY-capable `ExportRunner` — the plain `self.exporter` above is share-sheet-only
        // (built without the template collaborators). This one carries `templates`/`destinations`/
        // `runs`/`cursors`/`routes` and the folder deliverer, so a scheduled template can actually
        // land its file in the user's iCloud/Files folder. It is a second lightweight composition
        // over the SAME `main` connection every other repository holds — not a second write lock.
        // The keychain bookmark store is `AfterFirstUnlockThisDeviceOnly` precisely so a background
        // wake can resolve the folder while the phone is locked (see `KeychainFolderBookmarkStore`).
        let automationRunner = ExportRunner(
            measurements: measurements, derivation: derivation, logging: logging,
            exportJobs: exportJobs, registry: registry, clock: clock,
            appVersion: appVersion, deviceId: deviceId,
            // EPIC-38: a scheduled/automated export must carry drinks too, so a delta or full
            // template run lands the user's hydration exactly as the manual one does.
            hydration: hydration,
            templates: ExportTemplateRepository(main), destinations: ExportDestinationRepository(main),
            runs: ExportRunRepository(main), cursors: ExportCursorRepository(main),
            routes: RouteRepository(main),
            deliverers: [FileFolderDestination(bookmarks: KeychainFolderBookmarkStore())])
        let automationEngine = AutomationEngine(
            schedules: AutomationScheduleRepository(main),
            templates: ExportTemplateRepository(main),
            runner: automationRunner,
            freshness: AutomationDataFreshnessProbe(main),
            notifier: AutomationPauseNotifier(),
            clock: clock)

        self.background = BackgroundCoordinator(runs: backgroundRuns, clock: clock, ingest: bridge,
                                                protectedData: ProtectedDataMonitor(),
                                                automation: automationEngine)

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
        // EDGE-05: previously silent (no way for the user to know their data isn't being
        // persisted) or a hard `try!` crash if even the temp dir failed. Both fallback tiers now
        // set `isStorageFallback` so `RootView` can show a calm, honest warning instead.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-fallback-\(ULID.newID())")
        if let db = try? Database(directory: tmp) {
            let env = AppEnvironment(database: db)
            env.isStorageFallback = true
            return env
        }
        // Last resort: an in-memory SQLite database has no filesystem dependency at all, so
        // it's the one thing left that can still boot the app instead of crashing outright.
        let db = try! Database.inMemoryFallback()
        let env = AppEnvironment(database: db)
        env.isStorageFallback = true
        return env
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
        // BUG-07: a connected user's `sources` being empty does NOT mean "never seeded" — it
        // means a prior backfill (post-connect or a prior reset) was interrupted. Demo-seeding
        // over that would plant fake FakeHealthStore rows into what's supposed to be a real
        // user's history. Only ever fall through to `seedController.seedIfNeeded` (which itself
        // demo-seeds) when HealthKit was never connected in the first place.
        let connected = isHealthKitConnected
        let adapter = connected ? makeHealthKitAdapter() : nil
        // BUG-18: chain onto whatever pipeline task is already in flight (there normally isn't
        // one this early, but a future caller or a fast re-entrant launch could change that)
        // instead of racing it.
        let previous = pipelineTask
        let seedTask = Task.detached(priority: .userInitiated) { [seedController, clock, adapter, connected] () -> Error? in
            _ = await previous?.value
            do {
                if connected {
                    if try seedController.needsBackfillResume(), let adapter {
                        _ = try seedController.ingestHealthData(from: adapter, historyDays: 90, asOf: clock.now())
                        try seedController.deriveAndGenerateInsights(asOf: clock.now())
                    }
                } else {
                    try seedController.seedIfNeeded(asOf: clock.now())
                }
                return nil
            } catch {
                return error
            }
        }
        pipelineTask = seedTask
        let thrown = await seedTask.value
        PerformanceLog.signposter.endInterval("AppEnvironment.bootstrap", signpostState)
        timeoutTask.cancel()

        // OPT-080: if the hosting `.task` was cancelled (e.g. the app was suspended mid-seed),
        // don't let this now-stale continuation flip UI-relevant state.
        guard !Task.isCancelled else { return }

        bootstrapError = thrown
        bootstrapStalled = false
        // BUG-17: only auto-advance past the splash when the seed actually succeeded — flipping
        // `isReady` unconditionally (the old behavior) meant `bootstrapError` was set and
        // immediately superseded by a screen transition in the very same pass, so `SplashView`
        // never got a chance to show it. A thrown error now waits for an explicit
        // `dismissBootstrapStall()` "Continue anyway" tap, mirroring the existing stalled-state
        // pattern.
        if thrown == nil {
            isReady = true
            // BUG-12/13: a first-run seed or resumed backfill just populated the store —
            // whatever screens are already showing (unlikely this early, but a fast re-entrant
            // launch could hit it) should treat it as fresh data.
            bumpDataGeneration()
        }
    }

    /// Skip past a stalled first-run seed (OPT-071) or acknowledge a first-run seed error
    /// (BUG-17) and proceed anyway. The seed itself (if still running) keeps going in the
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
        // EPIC-03/EPIC-01: this method backs "Delete all data"
        // (`PrivacySecuritySettingsScreen`). Wiping the databases while leaving a standing
        // location consent and a full "we already explained ourselves to this person" record
        // behind would contradict what that button promises — the next launch would resume
        // reading routes into an otherwise-empty store, with no explainer ever shown again.
        // Cleared before the purge rather than after so a failure mid-purge still leaves consent
        // revoked, which is the safe direction.
        RouteConsentStore.clear()
        HealthPermissionGate.clearAll()
        let db = database
        let connected = isHealthKitConnected
        let adapter = connected ? makeHealthKitAdapter() : nil
        // BUG-04: `resetAll()` drops `customization_profile` along with every other main-DB
        // table. `ProfileRepository`'s in-memory `cached` (PERF-135) would otherwise keep
        // serving this same-process the pre-reset profile with no idea the underlying row is
        // gone — so nothing re-persists it, and a *later* cold launch (a fresh, uncached
        // repository) reads the now-empty table and silently resets language/theme/etc. to
        // defaults. Capture the live profile now and explicitly re-save it after the reset.
        let liveProfile = profile
        // BUG-18: chain onto any in-flight pipeline task (e.g. a backfill still running from a
        // very recent `connectHealthKit()`) instead of racing it.
        let previous = pipelineTask
        let task = Task.detached(priority: .userInitiated) { [seedController, clock, adapter, profiles] () -> Error? in
            _ = await previous?.value
            do {
                try db.resetAll()
                try profiles.save(liveProfile)
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
        }
        pipelineTask = task
        let thrown = await task.value
        // OPT-076: surface (rather than silently swallow) a reset/reseed failure. The method
        // signature stays `async` (not `throws`) so existing callers keep working; this exposes
        // the outcome via `@Observable` state for a future UI to display.
        resetError = thrown
        profile = (try? profiles.load()) ?? liveProfile
        // BUG-05: every regimen (demo or real) was just wiped or replaced — any reminders still
        // scheduled against the old regimen ids are stale. Cancels (if the preference is off) or
        // reschedules from whatever regimens exist now.
        await refreshMedicationReminders()
        isReady = true
        // BUG-12/13: the store was just wiped and reseeded (or re-backfilled) wholesale — every
        // screen's cached read is now stale regardless of whether the reset fully succeeded.
        bumpDataGeneration()
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
    /// - Parameter requestAuthorization: pass `false` when the caller has ALREADY put the user
    ///   through the system sheets itself — which is exactly what onboarding does now that it
    ///   stages permission bundle by bundle (`HealthPermissionGate`, plan §13.1). Re-requesting
    ///   there would defeat the staging: the adapter's request covers the whole read set, so
    ///   after three explained subset prompts the user would meet a fourth, unexplained sheet
    ///   asking for body measurements and workouts — the blanket prompt staging exists to avoid.
    ///   Defaults to `true`, so `SourcesConnectCard` and every other existing caller is unchanged.
    @discardableResult
    func connectHealthKit(requestAuthorization: Bool = true) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let adapter = makeHealthKitAdapter()
        if requestAuthorization {
            let granted = await adapter.requestAuthorization()
            guard granted else { return false }
        }

        isHealthKitConnected = true
        UserDefaults.standard.set(true, forKey: Self.healthKitConnectedKey)
        // EPIC-04: start observing now rather than waiting for the next launch. `activate()` is
        // a no-op until HealthKit is connected, and this is the first instant it is — a user who
        // connects and then backgrounds the app would otherwise get no background delivery at all
        // until they next cold-launched. Safe to overlap the backfill below: an observer wake
        // that lands mid-backfill finds the ingest lock held and records `throttled` rather than
        // running a second pass.
        background.activate()

        let db = database
        // BUG-18: chain onto any in-flight pipeline task instead of racing it.
        let previous = pipelineTask
        let task = Task.detached(priority: .userInitiated) { [seedController, clock, adapter] () -> Error? in
            _ = await previous?.value
            do {
                // BUG-01: `resetAll()` used to run here — it wipes BOTH databases, deleting the
                // user's own logged medications/symptoms (sensitive DB) and workouts/nutrition/
                // notes (main DB) just because they connected Apple Health. Purge only the
                // ingested/demo *measurement* data instead; manual logs are the user's own and
                // must survive this action. `purgeIngestedData()` also clears `read_anchors`, so
                // the backfill below still starts clean.
                try db.purgeIngestedData()
                // Bootstrap may have demo-seeded manual logs (workouts/notes) and sensitive rows
                // (medications/symptoms) before onboarding even reached this screen. Since a
                // manually-added row can't be told apart from a demo one by content alone, only
                // clear those on the *first* connect after a demo seed — `demoSeedActive` (set
                // by `SeedController.seed()`) is exactly that signal, and it's cleared
                // immediately below so this never fires again, i.e. never touches a connected
                // user's own manual logs added afterward. If the user *had* already logged their
                // own entries mixed in with the demo ones before connecting, those are removed
                // too — an accepted, documented tradeoff (BUG-01).
                if UserDefaults.standard.bool(forKey: SeedController.demoSeedActiveKey) {
                    try db.purgeDemoManualLogs()
                    try db.purgeSensitiveNamespace()
                    UserDefaults.standard.removeObject(forKey: SeedController.demoSeedActiveKey)
                }
                _ = try seedController.ingestHealthData(from: adapter, historyDays: 90, asOf: clock.now())
                try seedController.deriveAndGenerateInsights(asOf: clock.now())
                return nil
            } catch {
                HealthKitConnectLog.logger.error("Post-connect backfill failed: \(String(describing: error), privacy: .public)")
                return error
            }
        }
        pipelineTask = task
        backfillTask = task
        // BUG-05: if the `demoSeedActive` branch above just purged the sensitive DB, any
        // medication reminder still scheduled against one of those now-deleted regimens is
        // stale. Fire-and-forget: doesn't block this method's return (the backfill itself keeps
        // running independently either way), just reconciles reminders once it's done.
        Task { [weak self] in
            let thrown = await task.value
            await self?.refreshMedicationReminders()
            // BUG-12/13: the post-connect purge+backfill above just replaced the store's
            // ingested data — only worth a reload signal if it actually landed.
            if thrown == nil {
                self?.bumpDataGeneration()
            }
        }
        return true
    }

    /// NEW-01: await the backfill+derivation kicked off by the most recent `connectHealthKit()`
    /// call, up to `timeoutSeconds`. Returns `true` if it finished in time, `false` on timeout —
    /// the backfill itself is never cancelled and keeps running in the background regardless;
    /// this only bounds how long onboarding's first-fact card waits for it. Returns `true`
    /// immediately when no connect is in flight (nothing to wait for).
    func awaitBackfillCompletion(timeoutSeconds: Double = 12) async -> Bool {
        guard let task = backfillTask else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await task.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// NEW-01: the onboarding "first fact" payoff — see `FirstFact`. A handful of indexed
    /// SQLite lookups, cheap enough to call directly on the main actor.
    func firstFact() throws -> LocalizedString? {
        try FirstFact.select(insights: insightsRepo, derivation: derivation, format: format)
    }

    /// EPIC-03: every adapter BADAN builds carries the live route-consent provider, so the
    /// decision made on `RouteConsentScreen` is what decides whether a GPS trace is ever read.
    ///
    /// `HealthKitAdapter`'s default is `DeniedRouteConsent` (fail-closed by design — see its
    /// doc), which means an adapter constructed WITHOUT this argument silently ingests no routes
    /// forever. That is the safe failure, not a harmless one: the user's toggle would appear to
    /// do nothing. Both construction sites — this one and `BackgroundIngestBridge`'s `makePort`
    /// in `init` — pass it, and they are the only two.
    private func makeHealthKitAdapter() -> HealthKitAdapter {
        HealthKitAdapter(anchors: ReadAnchorRepository(database.main), routeConsent: RouteConsentStore())
    }

    /// Ask Apple for workout-route read access. Called ONLY from `RouteConsentScreen`, after its
    /// explainer and after BADAN's own consent has already been recorded — see that screen for
    /// why the two gates are written in that order.
    ///
    /// Returns "the sheet completed", never "routes are now readable"; HealthKit does not reveal
    /// read grants. The route screen's copy is written against that limitation rather than
    /// around it.
    func requestRouteAuthorization() async -> Bool {
        await makeHealthKitAdapter().requestRouteAuthorization()
    }

    // MARK: - Foreground incremental sync (BUG-02)

    /// Re-runs ingest→derive on every foreground transition once real HealthKit is connected —
    /// without this, data goes permanently stale after the one connect-time backfill (nothing
    /// else ever re-ingests). Anchored HealthKit queries under `ingestHealthData` make repeat
    /// calls incremental rather than a full re-backfill. Debounced via `SyncDebounce.shouldSync`
    /// (skip if a sync ran too recently) and skipped outright if one is already in flight; always
    /// dispatched off the main actor via the same `pipelineTask` serialization other lifecycle
    /// entry points use, so it can never interleave with a bootstrap/reset/connect backfill.
    /// Failure is logged, never surfaced to the UI (BUG-02 explicitly asks for quiet failure —
    /// the next foreground transition just tries again).
    func syncIfStale() {
        guard isHealthKitConnected else { return }
        let now = clock.now()
        guard !isSyncInFlight, SyncDebounce.shouldSync(lastSync: lastSyncAt, now: now) else { return }

        isSyncInFlight = true
        lastSyncAt = now
        let previous = pipelineTask
        // EPIC-04: the ingest→derive chain that used to be inline here now runs through
        // `BackgroundCoordinator.runForegroundSync`, which is the same funnel observer wakes and
        // BG tasks use. Two things change and nothing else does: this sync now takes the ingest
        // lock (so it can no longer overlap a background wake — see
        // `BackgroundIngestBridge.ingestLock`), and it writes a `foregroundSync` row to
        // `background_runs` so Diagnostics can tell "background never fires on this device" apart
        // from "nothing ever syncs at all". Same adapter, same 90-day window, same quiet-failure
        // contract (BUG-02).
        let task = Task.detached(priority: .utility) { [background, clock] () -> Error? in
            _ = await previous?.value
            return background.runForegroundSync(now: clock.now())
        }
        pipelineTask = task
        Task { [weak self] in
            let thrown = await task.value
            guard let self else { return }
            self.isSyncInFlight = false
            if let thrown {
                SyncLog.logger.error("Foreground sync failed: \(String(describing: thrown), privacy: .public)")
            } else {
                self.bumpDataGeneration()
            }
        }
    }

    // MARK: - Effort backfill (EPIC-26 HR-max/zone edit)

    /// Queue a historical effort/score re-derivation and nudge the background substrate to run it.
    /// Called by the HR-max/zone editor AFTER it saves the profile: editing the max redraws every HR
    /// zone, so every effort score in the window is now computed against stale zones and must be
    /// re-derived (append-only supersession, I2 — the old rows are kept, the new ones win by
    /// `computedAt`). The work runs in a `BGProcessingTask` — deferrable, heavy, checkpointed — never
    /// on the editor's thread; this only records the request and asks for a wake. `historyDays` bounds
    /// the window to the ingested history (a shorter window would leave older scores stale).
    func requestEffortBackfill(historyDays: Int = BackgroundIngestBridge.historyDays) {
        let from = DayAttribution.addingDays(-historyDays, to: clock.now(), tz: TimeZone.current.identifier)
        scoreBackfillStore.request(from: from, to: clock.now())
        background.scheduleScoreBackfillProcessing()
    }

    // MARK: - Medication reminders (NEW-02/UX-02)

    /// Reschedule medication reminders from the *current* active regimens — but only if the
    /// user has enabled the preference AND notifications are already authorized. Never prompts
    /// (uses `isAuthorized()`, not `requestAuthorizationIfNeeded()`), so it's safe to call at
    /// launch and after any regimen create/edit/delete. Self-heals scheduling after a reboot,
    /// timezone change, or language change (content is re-rendered in the current language).
    ///
    /// BUG-05: the preference-off/unauthorized paths used to just `return`, leaving whatever was
    /// already scheduled in place — e.g. after a sensitive-data purge or a data reset that wiped
    /// every regimen, stale reminders kept firing for medications that no longer exist. Both
    /// early-out paths now explicitly cancel instead of doing nothing.
    func refreshMedicationReminders() async {
        guard profile.notifications.medicationReminders,
              await NotificationScheduler.shared.isAuthorized() else {
            await NotificationScheduler.shared.cancelAllMedicationReminders()
            remindersTruncatedCount = 0
            return
        }
        let regimens = (try? logging.regimens(activeOnly: true)) ?? []
        remindersTruncatedCount = await NotificationScheduler.shared.rescheduleMedicationReminders(
            regimens: regimens, enabled: true, language: language, now: now())
    }

    /// (F6) How many medication reminders iOS's 64-pending ceiling pushed out of the current
    /// plan; 0 in the ordinary case. Surfaced in Settings — the OS drops the overflow with no
    /// error, so without this the user simply stops being reminded about some of their
    /// medication and is never told. See `MedicationReminderPlan.capped`.
    private(set) var remindersTruncatedCount: Int = 0

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
        // BUG-06: a connected HealthKit user's sensitive store being empty means it was
        // legitimately purged (or never populated) — never demo-seed fake "Vitamin D"/
        // "Magnesium" regimens and fabricated symptoms into a real user's medical record. Only
        // ever demo-seed for a disconnected (demo-mode) user.
        let connected = isHealthKitConnected

        // EDGE-18: a scheduled medication reminder's rendered content is language-specific
        // (`NotificationScheduler.rescheduleMedicationReminders` renders in `language`), but
        // nothing previously re-fired it on a language switch — only launch and regimen edits
        // did. Fire-and-forget; no debounce needed since a settings toggle is already a
        // deliberate, infrequent user action.
        if previous.language != p.language && p.notifications.medicationReminders {
            Task { [weak self] in
                await self?.refreshMedicationReminders()
            }
        }

        Task.detached(priority: .utility) { [weak self, profiles, seedController, clock] in
            do {
                try profiles.save(p)
            } catch {
                await MainActor.run { self?.profile = previous }
                return
            }
            if sensitiveJustEnabled && !connected {
                try? seedController.seedSensitiveIfNeeded(asOf: clock.now())
                // BUG-12/13: re-enabling the sensitive module can re-seed rows the sensitive-
                // gated screens (Home's meds module, LogHub, Timeline) had already decided not
                // to show while it was off.
                await MainActor.run { self?.bumpDataGeneration() }
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

    // MARK: - Readiness source priority (EPIC-25)

    /// Sensor classes worn on the body, which outrank a phone as the source of an overnight vital —
    /// the same "watch > phone" ordering ingestion assigns for dedup, but reconstructed at read time
    /// from the published `SensorQualityMap` classes rather than a stored column that could go stale.
    private static let wornSensorClasses: Set<String> = ["wrist_wearable", "ring_wearable", "chest_strap"]

    /// The dedup priority of the source that wrote a reading, for Readiness's two-source overnight-HRV
    /// tie-break (plan §18: "conflicting HRV same-night → priority source wins"). Resolved from the
    /// persisted source + its devices through the shared sensor-class contract, so it never duplicates
    /// ingestion's keyword list and cannot drift from it. `0` (equal, falls to the engine's
    /// deterministic `updatedAt`/`sourceId` tie-break) when the source or its class can't be resolved —
    /// the honest default, not a guessed winner. Called a handful of times per Readiness compute, on
    /// the (serialized, off-main) derivation path.
    static func readinessSourcePriority(sourceId: String, catalog: CatalogRepository) -> Int {
        guard let source = try? catalog.source(id: sourceId) else { return 0 }
        let devices = (try? catalog.devices(sourceId: sourceId)) ?? []
        let classId = SensorQualityMap.shared.classId(for: source, devices: devices)
        if wornSensorClasses.contains(classId) { return 2 }
        if classId == "phone_handset" { return 1 }
        return 0
    }
}

private enum HealthKitConnectLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "HealthKitConnect")
}

private enum SyncLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "ForegroundSync")
}

/// BUG-02: the pure debounce rule behind `AppEnvironment.syncIfStale()` — factored out so it's
/// headlessly testable (`SyncBusFixTests`) without standing up HealthKit or a database. Not
/// `private` so the test target can see it.
enum SyncDebounce {
    /// Never re-sync more often than this — a foreground transition is common (switching apps,
    /// glancing at a notification), and HealthKit's anchored queries are cheap but not free.
    static let minInterval: TimeInterval = 5 * 60

    /// `true` when enough time has passed since the last sync (or none has ever run) to allow
    /// another one.
    static func shouldSync(lastSync: Date?, now: Date) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= minInterval
    }
}
