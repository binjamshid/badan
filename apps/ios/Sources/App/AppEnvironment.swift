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
    /// EPIC-29 (plan §9.9/§9.10). The behavior journal and the declared context intervals. Holds
    /// the SENSITIVE connection only — never `main` — which is what makes I7 structural for these
    /// two families rather than a rule a future writer has to remember (see `JournalRepository`).
    let journal: JournalRepository
    /// EPIC-29. The correlation FINDINGS store — also sensitive-connection-only, and for a stronger
    /// reason than the journal itself: a finding's metric id (`journal.correlation.alcohol.readiness.score`)
    /// names the behaviour in plain text, so the row discloses the habit before any value is read
    /// (see `CorrelationRepository`). Wired here so the correlations surface reads the same store the
    /// engine writes, rather than opening a second connection of its own.
    let correlations: CorrelationRepository
    /// Plan §19. Lineage for file imports (Apple Health archive): one `import_batches` row per
    /// import, every imported measurement row stamped with its id, so an import is resumable and
    /// undoable in one tap. Read by the Settings import surface and `makeAppleHealthImporter()`.
    let importBatches: ImportBatchRepository
    /// EPIC-32 (migration v8). The notification budget ledger — the `notification_deliveries` rows
    /// the decision engine counts against to hold the daily non-med invariant across app opens and
    /// process death. Value-free operational metadata, not health data (see the repository doc).
    let notificationDeliveries: NotificationDeliveryRepository
    /// EPIC-31 (migration v8). Periodic-report METADATA (`reports` rows). The rendered PDF is a
    /// regenerable file; the row is derived and never a source of truth — see `ReportRepository`.
    let reports: ReportRepository
    /// EPIC-33 (Phase 3D). Assembles and writes the bounded ambient snapshot the `BadanWidgets`
    /// extension reads from the shared app-group container — see `AmbientSnapshotWriter`'s header.
    /// Wired here (not constructed ad hoc) so every trigger — `bumpDataGeneration()` below, the
    /// meds-due consent toggle, and the sensitive-records purge, both in
    /// `PrivacySecuritySettingsScreen` — shares the same actor instance (and so the same debounce
    /// state, now genuinely serialized rather than merely intended to be — see the type's header).
    let ambientSnapshotWriter: AmbientSnapshotWriter

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
    /// EPIC-34. The device-gated stress monitor. Wired here — and passed to `derivationCoordinator`
    /// — so `stress.day_trend` rows are written by the real ingest→derive pipeline rather than only
    /// under test. The Health Monitor card still calls `evaluate` (which writes nothing) for the live
    /// surface state, because a hidden day has to explain itself and no stored row can do that.
    let stress: StressEngine
    /// EPIC-29 / plan §18. The I7 seam, resolved once here and shared by every consumer: the score
    /// engines (which apply its confidence ceiling) and the score SURFACES (which render its caveat
    /// sentences through `ContextCaveats`). A function, not the sensitive repository — so a screen
    /// that needs the caveat beside a number never has to hold a sensitive connection to get it.
    /// See `ContextAnnotationResolver`.
    let contextAnnotations: ContextAnnotationResolver
    /// EPIC-23. The one place the writing score engines run in the published sleep → readiness →
    /// effort order (plan §18). The ingest→derive funnel (`SeedController.deriveAndGenerateInsights`)
    /// and the background backfill job (`recomputeScoreBackfill`) both go through it.
    let derivationCoordinator: DerivationCoordinator
    let insightEngine: InsightEngine
    let exporter: ExportRunner
    /// EPIC-31. The pure periodic-report builder (derived store → typed `ReportModel`) and the
    /// service that persists a report's metadata + answers the substrate's "is a weekly report
    /// due?". The PDF renderer is stateless (`ReportRenderer`) so it needs no wiring here.
    let reportBuilder: ReportBuilder
    let reportGeneration: ReportGenerationService
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
    /// Bumped after ANYTHING that can change what's on disk out from under an already-loaded
    /// screen — a pipeline run (bootstrap's first-run seed, `connectHealthKit`'s backfill,
    /// `syncIfStale`'s foreground re-sync), `resetDemoData`, the sensitive-module re-enable path
    /// in `update(_:)`, and — the overwhelming majority of real call sites — a plain manual
    /// log/edit action with no derivation involved at all: a hydration entry, a symptom log, a
    /// medication adherence tap, a workout save, a journal edit, and more (grep `bumpDataGeneration
    /// ()` for the full, current list; this comment does not try to enumerate it, precisely
    /// because the point is that it fires from ordinary writes, not from some closed set of
    /// derivation-triggering flows). Screens fold this into their `.task(id:)` identity (alongside
    /// `profile`) so a bump always forces a reload regardless of the screen's own staleness guard.
    private(set) var dataGeneration: Int = 0

    func bumpDataGeneration() {
        dataGeneration += 1
        // EPIC-33 (Phase 3D): this is a general "something in the user's data changed, refresh
        // anything downstream" signal — NOT a derivation-specific one. The call above already
        // fires from plain log/edit actions with no derivation pass behind them at all (see the
        // doc on `dataGeneration`), and this is exactly the same signal `AmbientSnapshotWriter`
        // needs to refresh what the widgets show, for the same reason: a freshly-logged
        // medication or a freshly-saved workout is just as much "the ambient snapshot might now be
        // stale" as a real score recomputation is. Values are captured here, on the main actor,
        // before crossing into the detached task (matching every other lifecycle entry point in
        // this file) — `writeIfNeeded` debounces internally, so a rapid burst of bumps still
        // writes (and reloads widget timelines) only once.
        let language = profile.language
        let medsDueConsent = profile.consentWidgetMedsDue
        let ambientPrivacy = profile.ambientPrivacy
        let now = clock.now()
        let writer = ambientSnapshotWriter
        Task.detached(priority: .utility) {
            await writer.writeIfNeeded(now: now, tz: TimeZone.current.identifier, language: language,
                                       medsDueConsentGranted: medsDueConsent, privacy: ambientPrivacy)
        }
    }

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
    /// Whether an ingest→derive pass is running right now. `private(set)` rather than `private`
    /// since the Sync-now control needs to show progress and disable itself; only this type may
    /// set it.
    private(set) var isSyncInFlight = false

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
        // A21/D-26: `sensitive:` is what routes `sensitiveClass: sensitivePlus` measured metrics
        // (today exactly `body.glucose`) into `badan_sensitive.db` instead of `badan.db` — see
        // `MeasurementRouting`. Every read and write in this repository routes on the same rule, so
        // no other call site changes.
        self.measurements = MeasurementRepository(main, sensitive: sensitive, registry: MetricRegistry.shared)
        self.derivation = DerivationRepository(main)
        self.insightsRepo = InsightRepository(main)
        self.reconciliation = ReconciliationRepository(main)
        // Bound as a local (not just `self.catalog`) so the two engine closures below can capture it
        // without capturing a not-yet-fully-initialized `self` — the same pattern the background
        // bridge uses for `main`/`backgroundRuns`.
        let catalog = CatalogRepository(main)
        self.catalog = catalog
        self.logging = LoggingRepository(main: main, sensitive: sensitive)
        // EPIC-33 (Phase 3D). Reads the same main-DB repositories every other engine here shares;
        // needs no sensitive-DB access beyond `logging` (medications only — never symptoms).
        // A22/EPIC-42 (Phase 4): `syncToWatch` wires the SAME writer into `WatchSnapshotSync`'s
        // singleton — one dto build, three bounded transports (app-group file, widget-timeline
        // reload, watch application-context push), never a second snapshot-writing mechanism.
        self.ambientSnapshotWriter = AmbientSnapshotWriter(
            derivation: derivation, measurements: measurements, logging: logging,
            insights: insightsRepo, store: AmbientSnapshotStore(), clock: clock,
            syncToWatch: { WatchSnapshotSync.shared.sync($0) })
        self.exportJobs = ExportJobRepository(main)
        // Held in a local as well as on `self`, so the automation-pause notifier can be given THIS
        // repository rather than constructing its own. A second `ProfileRepository` would carry its
        // own cache, which nothing invalidates when the preference is written through this one — the
        // export-health toggle would then appear to do nothing until relaunch.
        let profilesRepo = ProfileRepository(main)
        self.profiles = profilesRepo
        self.routes = RouteRepository(main)
        self.hydration = HydrationRepository(main: main)
        let journal = JournalRepository(sensitive: sensitive)
        self.journal = journal
        self.correlations = CorrelationRepository(sensitive: sensitive)
        self.importBatches = ImportBatchRepository(main)
        self.notificationDeliveries = NotificationDeliveryRepository(main)
        let reportRepo = ReportRepository(main)
        self.reports = reportRepo
        let backgroundRuns = BackgroundRunRepository(main)
        self.backgroundRuns = backgroundRuns

        // `dataConflicts`/`sourcePriorityRules` are built ad hoc over `main` rather than stored on
        // `AppEnvironment` itself, matching the established convention `DataConflictsScreen`'s own
        // doc states for this exact pair of repositories (`AppEnvironment` doesn't pre-wire them).
        self.ingestion = IngestionPipeline(measurements: measurements, catalog: catalog,
                                           reconciliation: reconciliation, registry: registry,
                                           clock: clock, deviceId: deviceId,
                                           dataConflicts: DataConflictRepository(main: main),
                                           sourcePriorityRules: SourcePriorityRuleRepository(main: main))
        self.baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                        registry: registry, clock: clock, deviceId: deviceId)
        // EPIC-29 / plan §18. The I7 seam: `context_statuses` live in the sensitive database and the
        // score engines hold only the main one, so the composition root — the one place that
        // legitimately holds BOTH connections — resolves the annotation and hands the engines a
        // FUNCTION. What crosses is a confidence ceiling and caveat sentences; only the ceiling is
        // ever persisted (a bare number that names no circumstance), so no word like "travelling"
        // reaches `badan.db` and the sensitive purge still takes the disclosure with it.
        // See `ContextAnnotationResolver`. Captures the local `journal` to stay off `self` during init.
        let contextAnnotations: ContextAnnotationResolver = { from, to in
            ContextAnnotator.annotation(from: from, to: to,
                                        statuses: try journal.statuses(overlapping: from, to: to))
        }
        self.contextAnnotations = contextAnnotations
        self.sleepIntelligence = SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                                         clock: clock, deviceId: deviceId,
                                                         contextAnnotations: contextAnnotations)
        // Readiness resolves a two-source overnight-HRV conflict by source priority (plan §18). The
        // priority is reconstructed from the persisted source/device catalog via the published
        // `SensorQualityMap` classes (worn sensor > phone), so it needs no new stored column and
        // cannot drift from the sensor-class contract — see `readinessSourcePriority`. Capturing the
        // local `catalog` keeps this off `self` during init.
        self.readiness = ReadinessEngine(derivation: derivation, measurements: measurements,
                                         clock: clock, deviceId: deviceId,
                                         priorityForSource: { sourceId in
                                             AppEnvironment.readinessSourcePriority(sourceId: sourceId, catalog: catalog)
                                         },
                                         contextAnnotations: contextAnnotations)
        // Effort reads HR max / zones off the live profile per recompute (never a cached copy), so a
        // mid-session HR-max edit is picked up on the next run — the reason it takes a provider, not a
        // stored `UserProfile` (see `EffortEngine`).
        self.effort = EffortEngine(derivation: derivation, measurements: measurements, registry: registry,
                                   clock: clock, deviceId: deviceId,
                                   profileProvider: { try catalog.userProfile() })
        self.deviation = DeviationEngine(derivation: derivation, measurements: measurements,
                                         catalog: catalog, registry: registry, clock: clock)
        let stress = StressEngine(derivation: derivation, measurements: measurements, registry: registry,
                                  clock: clock, deviceId: deviceId,
                                  contextAnnotations: contextAnnotations)
        self.stress = stress
        let mood = MoodEstimateWriter(derivation: derivation, measurements: measurements,
                                      registry: registry, clock: clock, deviceId: deviceId)
        self.derivationCoordinator = DerivationCoordinator(baselines: baselines, sleep: sleepIntelligence,
                                                           readiness: readiness, effort: effort,
                                                           stress: stress, mood: mood)
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
                                     hydration: hydration,
                                     // EPIC-29: the opposite classification — the journal and
                                     // context statuses are sensitive-plus, so passing the
                                     // repository here does NOT put them in a default export. The
                                     // runner gathers them only when `scope.includeSensitive` is
                                     // set; without this argument the Sensitive toggle would
                                     // silently omit families its own copy promises.
                                     journal: journal)

        // EPIC-31. The builder is pure over the derived store (+ adherence counts, I7-safe); the
        // service wraps it with the `reports` store and the "due weekly?" rule. The period timezone
        // is the device's current zone at generation and is recorded on each model.
        let reportBuilder = ReportBuilder(derivation: derivation, logging: logging)
        self.reportBuilder = reportBuilder
        let reportGeneration = ReportGenerationService(
            builder: reportBuilder, reports: reportRepo, clock: clock, deviceId: deviceId,
            timezone: { TimeZone.current.identifier })
        self.reportGeneration = reportGeneration

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
            // EPIC-29: same reasoning, opposite sensitivity — a scheduled template whose scope
            // carries `includeSensitive` must land the journal too, and one that doesn't must not.
            journal: journal,
            templates: ExportTemplateRepository(main), destinations: ExportDestinationRepository(main),
            runs: ExportRunRepository(main), cursors: ExportCursorRepository(main),
            routes: RouteRepository(main),
            // The registered delivery surface of this build, assembled in one place so "what can
            // this build send an export to?" has a single answer. EPIC-20's REST deliverer is
            // deliberately NOT in it — see `RESTDestinationAvailability` for the flag, the reason
            // and everything that has to ship alongside it before it is.
            deliverers: RESTDestinationAvailability.deliverers(
                folderBookmarks: KeychainFolderBookmarkStore()),
            // EPIC-17: the dedup journal, so a delta run emits suppression-flip `corrections[]`
            // when a dedup decision reversed since the last cursor (the add-only desync guard).
            reconciliation: reconciliation)
        let automationEngine = AutomationEngine(
            schedules: AutomationScheduleRepository(main),
            templates: ExportTemplateRepository(main),
            runner: automationRunner,
            freshness: AutomationDataFreshnessProbe(main),
            notifier: AutomationPauseNotifier(profiles: profilesRepo),
            clock: clock)

        self.background = BackgroundCoordinator(runs: backgroundRuns, clock: clock, ingest: bridge,
                                                protectedData: ProtectedDataMonitor(),
                                                automation: automationEngine,
                                                reports: reportGeneration)
        // Set after construction, not passed in: this closure captures `self`, and `self` is not
        // fully initialised until the assignment above completes. `[weak self]` because the
        // coordinator outlives nothing here but the retain cycle would otherwise be permanent, and
        // the hop to the main actor is done here rather than inside the coordinator, which is
        // deliberately off-main and holds no app state.
        self.background.onIngestCompleted = { [weak self] in
            Task { @MainActor in await self?.evaluateEventDrivenNotifications() }
        }

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

    /// STUB-01/COMP-06 (post-onboarding data choice): the honest "actually remove sample data"
    /// action `resetDemoData()` cannot be — `resetDemoData()` intentionally RE-SEEDS a fresh
    /// demo dataset when HealthKit isn't connected (see its own doc; that is the correct,
    /// documented behavior for Settings' "Delete all data" button — its own confirmation copy
    /// says so). This is the counterpart behind `DataConnectionChoiceScreen`'s "Delete sample
    /// data" action: purge only, never reseed, reusing the exact same primitive onboarding's own
    /// "Start empty" already relies on (`SeedController.markStartEmpty`) — a device that starts
    /// empty via onboarding and one that goes empty later via this path land in the identical,
    /// verified-empty state.
    ///
    /// Deliberately does not touch `RouteConsentStore`/`HealthPermissionGate` the way
    /// `resetDemoData()` does — those are HealthKit-connect state, and nothing here connects or
    /// disconnects HealthKit.
    ///
    /// Guarded on `!isHealthKitConnected`: both this method's call sites (the tappable
    /// `SampleDataBanner` and `PrivacySecuritySettingsScreen`'s "Manage sample data" row) are
    /// themselves gated on `SeedController.isDemoDataActive`, which is never true for a connected
    /// user — but a wipe this destructive should not depend solely on its callers staying that
    /// way, so it fails closed (a no-op, not a thrown error) rather than trust that alone.
    ///
    /// No `isReady` bracket (unlike `resetDemoData()`): flipping `isReady` false tears down and
    /// rebuilds `RootView`'s whole `MainTabView` (including resetting `selectedTab`), which would
    /// yank the very sheet this action was invoked from out from under the user mid-purge. The
    /// purge itself is a handful of local `DELETE`s (see `SeedController.markStartEmpty`), not a
    /// 90-day HealthKit backfill — `DataConnectionChoiceScreen`'s own `phase` state already gives
    /// the user a "Deleting…" label for the second or so this takes.
    func deleteSampleData() async {
        resetError = nil
        guard !isHealthKitConnected else { return }
        let db = database
        // BUG-18 pattern: chain onto any in-flight pipeline task instead of racing it.
        let previous = pipelineTask
        let task = Task.detached(priority: .userInitiated) { () -> Error? in
            _ = await previous?.value
            do {
                try SeedController.markStartEmpty(database: db)
                return nil
            } catch {
                return error
            }
        }
        pipelineTask = task
        let thrown = await task.value
        resetError = thrown
        // BUG-05 pattern: demo medications/symptoms were just purged — any reminder still
        // scheduled against one of those regimens is stale.
        await refreshMedicationReminders()
        // BUG-12/13: the store was just purged — every screen's cached read is now stale.
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
    func syncIfStale() { runSync(force: false) }

    /// Sync NOW, ignoring the debounce window. The user asked; that outranks the heuristic.
    ///
    /// `SyncDebounce.minInterval` is five minutes, which is right for automatic foreground syncs
    /// (glancing at a notification and coming back should not re-query HealthKit) but is exactly
    /// what makes the app feel stuck when someone opens it wanting fresh numbers: `syncIfStale`
    /// returns silently, nothing refreshes, and there is no way to say "no, really, now". This is
    /// that way. It still takes the same ingest lock and writes the same `background_runs` row, so
    /// it cannot overlap a background wake and Diagnostics still sees it.
    ///
    /// Returns immediately; observe `isSyncInFlight` for progress.
    func forceSync() { runSync(force: true) }

    private func runSync(force: Bool) {
        guard isHealthKitConnected else { return }
        let now = clock.now()
        // `isSyncInFlight` is honoured even when forcing: a second concurrent run would contend on
        // the ingest lock and finish no sooner, so double-tapping the button is a no-op rather than
        // a way to queue redundant work.
        guard !isSyncInFlight else { return }
        guard force || SyncDebounce.shouldSync(lastSync: lastSyncAt, now: now) else { return }

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

    // MARK: - Decision-engine notifications (EPIC-32)

    /// A deep link a tapped notification asked to open, waiting for the tab shell to consume it.
    /// `@Observable` so `MainTabView` selects the destination tab the moment it is set, then clears
    /// it. `nil` = nothing pending.
    var pendingDeepLink: NotificationDeepLink?

    /// Whether the user has enabled a given notification class. Meds keep the EXISTING
    /// `medicationReminders` preference (so nothing about med reminders changes); every other class
    /// reads the per-class opt-in map, which defaults every class OFF.
    func isNotificationClassEnabled(_ cls: NotificationClass) -> Bool {
        if cls.isMedication { return profile.notifications.medicationReminders }
        return profile.notifications.classOptIn[cls.rawValue] ?? false
    }

    /// Route a tapped notification to its evidence surface (`MainTabView` observes `pendingDeepLink`).
    func openDeepLink(_ link: NotificationDeepLink) { pendingDeepLink = link }

    /// FIX-4 (Phase 3D audit, EPIC-33's own definition-of-done): entry point for the
    /// `badan://deeplink/<token>` URL the four EPIC-33 widgets open
    /// (`WidgetDeepLinkToken.url` in `apps/ios/BadanWidgets/BadanWidgetsBundle.swift`), wired from
    /// `BADANApp.swift`'s `.onOpenURL`. Parses `<token>` out of the URL and resolves it through the
    /// EXACT SAME entry point a tapped notification already uses (`openDeepLink(_:)` above) —
    /// deliberately not a second, parallel routing mechanism. `WidgetDeepLinkToken`'s three tokens
    /// ("readiness", "sleep", "meds") are already exactly `NotificationDeepLink`'s raw values, so
    /// no new case or token remap was needed here — see `WidgetDeepLinkTests.swift`, which checks
    /// both sides against each other.
    ///
    /// A URL with the wrong scheme/host, or a token this build's `NotificationDeepLink` doesn't
    /// recognize (e.g. an OLDER widget extension still installed after an app downgrade), is
    /// silently ignored: opening BADAN at all is still a success, there is simply nowhere further
    /// to route — the same honest-no-op posture `AmbientSnapshotStore`'s N-1 schema tolerance
    /// takes on a shape it doesn't fully recognize, rather than a crash or an error surfaced to
    /// the user for a tap they didn't make wrong.
    func handleDeepLinkURL(_ url: URL) {
        guard url.scheme == "badan", url.host == "deeplink" else { return }
        let token = url.lastPathComponent
        guard let link = NotificationDeepLink(rawValue: token) else { return }
        openDeepLink(link)
    }

    /// The default local fire hour for a time-based class. Constants (not magic literals at the
    /// call site) so the schedule is legible and one place changes it.
    /// SUPERSEDED for `.hydration` (HYD-004/HYD-012, 2026-07-27): hydration's time now comes from
    /// `profile.hydrationReminders` via `nextFireDate(for:after:profile:calendar:)`. The 15:00 case
    /// below survives only as the value `HydrationReminderSettings.legacyDefault` reproduces for an
    /// install that predates the setting, so nobody's existing reminder time changes under them.
    nonisolated static func defaultNotificationHour(_ cls: NotificationClass) -> Int {
        switch cls {
        case .morningReadinessSummary: return 8
        case .eveningWindDown: return 21
        case .hydration: return 15
        default: return 9
        }
    }

    /// The classes reconcile schedules ahead of time. Sourced from `NotificationClass.timeBased`
    /// rather than restated: this used to be an independent array literal that merely happened to
    /// equal `NotificationClass.userFacing`, with no test tying them, so adding a class to one and
    /// not the other would have produced either a toggle with no scheduler or a scheduler with no
    /// toggle — and nothing would have failed.
    private static var timeBasedClasses: [NotificationClass] { NotificationClass.timeBased }

    /// The next time `cls` should fire — the next occurrence of its default local hour.
    nonisolated static func nextDecisionFireDate(for cls: NotificationClass, after now: Date, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.hour = defaultNotificationHour(cls)
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
    }

    /// A stable per-day identifier suffix so re-scheduling the same class+day replaces rather than
    /// stacks a second request.
    static func decisionDayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Bring the time-based decision notifications in line with the current preferences: schedule
    /// each enabled class's next occurrence (subject to the daily budget, quiet hours, opt-in and
    /// the 64-cap), and cancel any class the user has turned off. Idempotent — safe to call at every
    /// launch. A no-op for a user with every class OFF (the default), and never prompts (uses
    /// `isAuthorized()`); when notifications are not authorized it cancels rather than leaving stale
    /// requests, mirroring `refreshMedicationReminders`.
    func reconcileDecisionNotifications() async {
        guard await NotificationScheduler.shared.isAuthorized() else {
            await NotificationScheduler.shared.cancelAllDecisionNotifications()
            return
        }
        // One slot floats when an event-driven class is enabled, so a class that can only fire at
        // the moment something happens is not shut out by classes that reserved their rows hours
        // earlier. See `NotificationDecisionEngine.timeBasedLimit`.
        let limit = NotificationDecisionEngine.timeBasedLimit(
            dailyLimit: profile.notifications.dailyNonMedLimit,
            reserveFloatingSlot: anyEventDrivenClassEnabled)
        // Read once for the whole loop rather than per class: only the wind-down uses these, and
        // they involve a derived-row read plus a fourteen-night session scan.
        let bedtime = bedtimeInputs(now: now())
        // Sorted by priority, not left in registry order. The budget is spent in the order this
        // loop evaluates, so before this the ceiling was decided by wherever a class happened to sit
        // in an array literal — hydration was last, and so was always the one starved.
        for cls in Self.timeBasedClasses.sorted(by: { $0.priority < $1.priority }) {
            guard isNotificationClassEnabled(cls) else {
                await NotificationScheduler.shared.cancelDecisionNotifications(cls)
                continue
            }
            // HYD-004/HYD-012: hydration's fire time comes from the user's own schedule and is
            // suppressed entirely inside a fasting window, so it can legitimately have NO next
            // time — in which case the right action is to cancel, exactly as for an opted-out
            // class. Every other class keeps its fixed daily hour.
            guard let fire = Self.nextFireDate(for: cls, after: now(), profile: profile,
                                               calendar: .current, bedtime: bedtime) else {
                await NotificationScheduler.shared.cancelDecisionNotifications(cls)
                continue
            }
            _ = await evaluateAndScheduleDecision(cls, fireDate: fire, dailyLimitOverride: limit)
        }
    }

    /// Whether any class that can only be raised at the moment it happens is switched on. Drives the
    /// floating-slot reservation above.
    private var anyEventDrivenClassEnabled: Bool {
        NotificationClass.eventDriven.contains { isNotificationClassEnabled($0) }
    }

    // MARK: - Event-driven producers

    /// Everything that is raised because something HAPPENED, rather than because a clock struck.
    ///
    /// Called on every foreground (`BADANApp`'s `scenePhase == .active`) and after a background
    /// ingest completes. Both, deliberately: the background hook is what makes the wake summary
    /// arrive without the user opening the app, and the foreground call is what makes a missed
    /// background run self-heal instead of silently costing the user that day's summary. Idempotent
    /// and never prompting, exactly like `reconcileDecisionNotifications`.
    func evaluateEventDrivenNotifications() async {
        guard await NotificationScheduler.shared.isAuthorized() else { return }
        await evaluateWakeSummary()
        await evaluateGoalReached()
        await evaluateDeviationNotice()
    }

    /// Announce at most one reached goal a day. The ledger's class+day idempotency provides the
    /// "once"; `GoalNotificationPolicy` provides the deterministic "which".
    func evaluateGoalReached() async {
        let cls = NotificationClass.goalReached
        guard isNotificationClassEnabled(cls) else { return }
        guard !notificationDeliveries.hasScheduled(cls, inDayOf: now(), calendar: .current) else { return }
        guard let goals = try? profiles.goals(), !goals.isEmpty else { return }

        let candidates = goals.map { goal in
            GoalNotificationPolicy.Candidate(
                goalId: goal.id,
                active: goal.active,
                evaluation: GoalEvaluation.evaluate(
                    value: GoalMetricValue.current(for: goal.metricId, measurements: measurements,
                                                   derivation: derivation),
                    target: goal.target, direction: goal.direction))
        }
        guard GoalNotificationPolicy.goalToAnnounce(candidates) != nil else { return }
        await raiseDecisionNotification(cls)
    }

    /// Raise the gentle change notice when a fresh vital is genuinely outside the user's usual band.
    ///
    /// `DeviationEngine` is called here rather than from the derivation pipeline, and that is not an
    /// oversight: `DerivationCoordinator` deliberately refuses to run it, because it writes nothing —
    /// it is a pure read model over baselines the pipeline already refreshed, and computing it there
    /// would produce a value the pipeline would immediately discard. So the producer builds it on
    /// demand, exactly as `HealthMonitorScreen` does, and off the main actor for the same reason:
    /// it is ~15–20 small SQLite reads across five vitals.
    ///
    /// `annotation != nil` is the signal. `VitalTile.annotation` is non-nil precisely when a tile is
    /// fresh AND out-of-band or off-usual, which is the same predicate the Health Monitor surface
    /// already renders — so the notification cannot claim something the screen would not show.
    func evaluateDeviationNotice() async {
        let cls = NotificationClass.deviationNotice
        guard isNotificationClassEnabled(cls) else { return }
        guard !notificationDeliveries.hasScheduled(cls, inDayOf: now(), calendar: .current) else { return }

        // `sensorQuality` is not threaded through here the way `HealthMonitorScreen` threads it:
        // that screen holds it as a screen input, `AppEnvironment` has no such property, and
        // `DeviationEngine` already defaults the parameter to `SensorQualityMap.shared` — the same
        // instance the screen passes. Taking the default keeps one source of truth rather than
        // inventing a second handle to it.
        let inputs = (derivation: derivation, measurements: measurements, catalog: catalog,
                      registry: registry, now: now())
        let notable = await Task.detached(priority: .utility) { () -> Bool in
            let engine = DeviationEngine(
                derivation: inputs.derivation, measurements: inputs.measurements,
                catalog: inputs.catalog, registry: inputs.registry, clock: SystemClock())
            guard let model = try? engine.buildReadModel(asOf: inputs.now) else { return false }
            return model.vitals.contains { !$0.isStale && $0.annotation != nil }
        }.value

        guard notable else { return }
        await raiseDecisionNotification(cls)
    }

    /// Raise (or re-time) the morning summary because the user has actually woken up.
    ///
    /// The wake instant comes from the raw `sessions` table — the last primary sleep session's
    /// `endAt` — because no derived row carries a wake time; see `WakeSummaryPolicy`'s own doc for
    /// why persisting one would be the wrong trade.
    func evaluateWakeSummary() async {
        let cls = NotificationClass.morningReadinessSummary
        let calendar = Calendar.current
        let now = now()
        let existing = notificationDeliveries.scheduledRow(cls, inDayOf: now, calendar: calendar)
        let outcome = WakeSummaryPolicy.evaluate(
            now: now,
            wakeInstant: latestWakeInstant(now: now),
            reservation: existing.map {
                .init(scheduledFor: $0.scheduledFor, delivered: $0.outcome == .delivered)
            },
            enabled: isNotificationClassEnabled(cls))

        switch outcome {
        case .fire:
            await raiseDecisionNotification(cls)
        case .retarget:
            if let existing { await retargetDecisionNotification(cls, row: existing, to: now) }
        case .notEnabled, .noWakeRecorded, .wakeTooOld, .wakeInFuture, .alreadySentToday:
            // Nothing to do. Not logged as a suppression row: none of these is a decision the
            // engine made, and writing a ledger row every foreground would flood the very history
            // that exists to answer "why didn't I get my summary?".
            break
        }
    }

    /// The end of the most recent primary sleep session, or `nil` if none is recorded.
    ///
    /// Looks at today's local night and yesterday's, because a night is keyed by the local day its
    /// sleep ENDED on (`DayAttribution.localNight(sessionEnd:tz:)`) and an evaluation running just
    /// after midnight would otherwise miss the night in progress. Takes the last session of the
    /// night rather than the first, so a split night reports when the user finally got up.
    func latestWakeInstant(now: Date) -> Date? {
        let tz = TimeZone.current.identifier
        let todayKey = DayAttribution.localDayKey(now, tz: tz)
        let yesterdayKey = SleepIntelligenceEngine.previousDayKey(todayKey)
        for key in [todayKey, yesterdayKey] {
            if let sessions = try? measurements.allSleepSessions(localNight: key, includeSuppressed: false),
               let last = sessions.last {
                return last.endAt
            }
        }
        return nil
    }

    /// Move an already-reserved notification to a new fire time, keeping its ledger row and its
    /// budget slot.
    ///
    /// This exists because raising the summary again would not work. Reconcile books today's row the
    /// evening before, and `evaluateAndScheduleDecision` short-circuits on
    /// `notificationDeliveries.hasScheduled` — so a 06:40 wake would be deduped away and the user
    /// would still get 08:00, with the wake trigger appearing to do nothing at all. Retargeting
    /// cancels the pending request, re-issues it for `newFireDate`, and updates the row in place, so
    /// the user gets exactly one summary, at the moment they woke, charged once to the budget.
    func retargetDecisionNotification(_ cls: NotificationClass, row: NotificationDelivery,
                                      to newFireDate: Date) async {
        let calendar = Calendar.current
        await NotificationScheduler.shared.cancelDecisionNotifications(cls)
        do {
            try notificationDeliveries.retarget(id: row.id, to: newFireDate, now: now())
        } catch {
            // The request has already been cancelled, so returning here would leave the user with
            // no summary at all. Re-issue anyway and accept a row whose `scheduled_for` is stale by
            // an hour or two: a slightly wrong diagnostic beats a silently dropped notification.
            NotificationLog.logger.error(
                "decision ledger retarget failed for \(cls.rawValue, privacy: .public); scheduling anyway: \(String(describing: error), privacy: .public)")
        }
        let identifier = cls.identifierPrefix + Self.decisionDayKey(newFireDate, calendar: calendar)
        await NotificationScheduler.shared.scheduleDecisionNotification(
            cls, identifier: identifier, fireDate: newFireDate, ledgerRowId: row.id,
            language: language, values: notificationValues(for: cls), calendar: calendar)
    }

    /// The readings a notification may name, or `nil` when the user has not opted in or there is
    /// nothing to show. Only ever built on paths that compose at delivery time — a pre-scheduled
    /// request is written hours before it fires, when tonight's numbers do not exist yet.
    func notificationValues(for cls: NotificationClass) -> NotificationValues? {
        guard profile.notifications.showValuesInNotifications else { return nil }
        guard cls == .morningReadinessSummary else { return nil }
        let values = NotificationValues(
            readiness: readinessPhrase(),
            sleepPerformance: sleepPerformancePhrase(),
            goal: nil)
        return values.isEmpty ? nil : values
    }

    /// "Readiness 68" — the `readiness.score` composite, stated as a bare number with no verdict
    /// attached. Deliberately no band word ("good", "low"): a label is an interpretation, and the
    /// lock screen is the one surface with no room for the evidence behind it.
    private func readinessPhrase() -> LocalizedString? {
        guard let latest = (try? derivation.latestDerivedSeries(metricId: MetricID.readinessScore))?.last
        else { return nil }
        let score = Int(latest.value.rounded())
        return LocalizedString(
            en: "Readiness \(Numerals.format(Double(score), language: .en, arabicDigits: false))",
            ar: "الجاهزية \(Numerals.format(Double(score), language: .ar, arabicDigits: profile.arabicDigits))")
    }

    /// "Sleep 92% of need" — named for what the engine actually computes. Deliberately NOT called a
    /// sleep score: `SleepIntelligenceEngine` produces `sleep.performance` (actual ÷ need) and
    /// `sleep.consistency` (timing regularity) as separate outputs, and the `sleep.score` id sitting
    /// in `registry.json` has no algorithm entry and no producer at all.
    private func sleepPerformancePhrase() -> LocalizedString? {
        guard let latest = (try? derivation.latestDerivedSeries(metricId: MetricID.sleepPerformance))?.last
        else { return nil }
        let percent = Int(latest.value.rounded())
        let en = Numerals.format(Double(percent), language: .en, arabicDigits: false)
        let ar = Numerals.format(Double(percent), language: .ar, arabicDigits: profile.arabicDigits)
        return LocalizedString(en: "Sleep \(en)% of need", ar: "النوم \(ar)٪ من حاجتك")
    }

    /// The next fire instant for a time-based class, or `nil` when the class must stay silent.
    ///
    /// Only `.hydration` can return `nil`, and only because its schedule is user-authored and
    /// fasting-aware (`HydrationReminderPolicy`). Kept as one function rather than special-casing at
    /// the call site so a future class with its own schedule has an obvious place to land.
    /// `nonisolated` because it is a pure function of its arguments — it reads no `AppEnvironment`
    /// state, which is what lets a test exercise the real scheduling seam instead of a copy of it.
    nonisolated static func nextFireDate(for cls: NotificationClass, after now: Date,
                                         profile: CustomizationProfile, calendar: Calendar,
                                         bedtime: BedtimeInputs = .unavailable) -> Date? {
        switch cls {
        case .hydration:
            return HydrationReminderPolicy.nextFireDate(
                after: now, settings: profile.hydrationReminders,
                quietHours: profile.notifications.quietHours, enabled: true, calendar: calendar)
        case .eveningWindDown:
            return BedtimeReminderPolicy.nextFireDate(
                after: now, settings: profile.bedtimeReminders,
                sleepNeedSeconds: bedtime.sleepNeedSeconds, needConfidence: bedtime.needConfidence,
                habitualBedMinute: bedtime.habitualBedMinute,
                quietHours: profile.notifications.quietHours,
                fallbackHour: defaultNotificationHour(.eveningWindDown),
                enabled: true, calendar: calendar)
        default:
            return nextDecisionFireDate(for: cls, after: now, calendar: calendar)
        }
    }

    /// The sleep facts the wind-down's schedule depends on, read once by the caller and handed to
    /// the pure policy.
    ///
    /// They are a parameter rather than something `nextFireDate` fetches because this function is
    /// `nonisolated` and pure — that is what lets a test exercise the real scheduling seam instead
    /// of a copy of it — and reading a repository here would end both properties. The default,
    /// `.unavailable`, resolves to the fixed 21:00 the app has always used, so every existing caller
    /// keeps its current behaviour without being touched.
    struct BedtimeInputs: Equatable, Sendable {
        var sleepNeedSeconds: Double?
        var needConfidence: Double
        /// The user's habitual bedtime as minutes-from-midnight, from their own recent nights.
        var habitualBedMinute: Int?

        static let unavailable = BedtimeInputs(sleepNeedSeconds: nil, needConfidence: 0,
                                               habitualBedMinute: nil)
    }

    /// Read the wind-down's sleep inputs from storage.
    ///
    /// `sleep.need` is read as a derived row, but the habitual bedtime is read from the raw
    /// `sessions` table, because there is no derived row for it: `SleepNight` — the only type that
    /// carries `bedSecondsOfDay` — is an in-memory intermediate inside `SleepIntelligenceEngine`,
    /// and `appendScore` persists five metrics, none of them a bedtime.
    ///
    /// Confidence is not read alongside the need value because `derived_values` stores the number,
    /// not the band. A persisted need therefore counts as usable; the policy's `minConfidence` gate
    /// still applies, and the honest reading of "we have a value but not its band" is to pass the
    /// gate rather than to invent a confidence. `SleepNeedRange.confidence` stays the right input
    /// the day it is available to this layer.
    func bedtimeInputs(now: Date, lookbackNights: Int = 14) -> BedtimeInputs {
        let need = (try? derivation.latestDerivedSeries(metricId: MetricID.sleepNeed))?.last?.value
        return BedtimeInputs(sleepNeedSeconds: need,
                             needConfidence: need == nil ? 0 : 1,
                             habitualBedMinute: habitualBedMinute(now: now, lookbackNights: lookbackNights))
    }

    /// The median start-minute of the user's recent primary sleep sessions, or `nil` if there are
    /// none. Median rather than mean so one 04:00 night does not drag the whole estimate.
    ///
    /// Each session's minute-of-day is computed in that session's OWN timezone, the same way
    /// `SleepIntelligenceEngine.assembleNights` does it — a traveller's bedtime is a local-clock
    /// fact, and converting through the device's current zone would make every night abroad look
    /// like a different habit.
    func habitualBedMinute(now: Date, lookbackNights: Int = 14) -> Int? {
        guard let from = Calendar.current.date(byAdding: .day, value: -lookbackNights, to: now),
              let sessions = try? measurements.sessions(kind: .sleepPrimary, from: from, to: now),
              !sessions.isEmpty
        else { return nil }
        let minutes = sessions
            .map { Int(SleepIntelligenceEngine.localSecondsOfDay(
                epochSeconds: $0.startAt.timeIntervalSince1970, tz: $0.tzId) / 60) }
            // Bedtimes straddle midnight, so the raw minutes cluster at both ends of the day.
            // Fold the small-hours values past midnight before taking a median, or a 23:30 and a
            // 00:30 night average to lunchtime.
            .map { $0 < 12 * 60 ? $0 + 24 * 60 : $0 }
            .sorted()
        guard !minutes.isEmpty else { return nil }
        return BedtimeReminderPolicy.wrap(minutes[minutes.count / 2])
    }

    /// Raise an event-driven decision notification (deviation, export-health) now, subject to the
    /// same budget/opt-in/quiet-hours/cap gate. Returns the engine's verdict so a caller can log or
    /// test it. The content is generic and value-free, so raising it leaks nothing onto the lock
    /// screen.
    ///
    /// Nothing calls this yet — not production code, and not the test suite either, which covers the
    /// pure engine's verdicts rather than this adapter. It is the seam a deviation detector or the
    /// export-health surface will call. Its classes are correspondingly absent from
    /// `NotificationClass.userFacing`; wire a producer and add the toggle in the same change.
    @discardableResult
    func raiseDecisionNotification(_ cls: NotificationClass, at fireDate: Date? = nil) async
        -> NotificationDecisionEngine.Decision {
        guard await NotificationScheduler.shared.isAuthorized() else { return .suppressedNotAuthorized }
        return await evaluateAndScheduleDecision(cls, fireDate: fireDate ?? now())
    }

    /// The one place a decision notification is gated and, if allowed, scheduled + recorded. Reads
    /// the live pending counts and the day's ledger count, asks the pure engine, and on `.scheduled`
    /// reserves the ledger row that makes the budget survive the next app open BEFORE handing the
    /// request to the OS. Idempotent per class+day via the ledger check.
    ///
    /// The write order is the whole point. The daily ceiling is a hard invariant, and the ledger is
    /// the only thing that remembers it across process death — so a notification that reached the OS
    /// without its row would let the next evaluation read a lower count and quietly deliver a third.
    /// Reserving first makes the only possible failure a conservative one: a row with no
    /// notification behind it costs the user a nudge, which is visible and self-corrects the next
    /// day, where an unaccounted notification breaks an invariant nobody can observe breaking.
    ///
    /// `dailyLimitOverride` is how reconcile hands the time-based classes a ceiling one lower than
    /// the user's, to hold a slot for the event-driven ones. `nil` — the event-driven path — means
    /// the user's full limit, which is the point: the floating slot exists FOR that path.
    @discardableResult
    private func evaluateAndScheduleDecision(_ cls: NotificationClass, fireDate: Date,
                                             dailyLimitOverride: Int? = nil) async
        -> NotificationDecisionEngine.Decision {
        let calendar = Calendar.current
        // Already committed for this class+day — don't stack a duplicate on a second evaluation.
        // The opt-in is re-read rather than assumed: a class the user turned off after its row was
        // written did NOT get scheduled by this call, so reporting `.scheduled` would name a verdict
        // that never happened. (The already-written row keeps holding its budget slot until the
        // class's cancel path releases it; that is the cancel path's job, not this one's.)
        if notificationDeliveries.hasScheduled(cls, inDayOf: fireDate, calendar: calendar) {
            return isNotificationClassEnabled(cls) ? .scheduled : .suppressedOptedOut
        }

        let counts = await NotificationScheduler.shared.pendingCounts()
        // Read as plain values (not self-touching closures) so the pure engine stays free of any
        // main-actor capture.
        let enabled = isNotificationClassEnabled(cls)
        let quiet = profile.notifications.quietHours
        let context = NotificationDecisionEngine.Context(
            calendar: calendar,
            optedIn: { _ in enabled },
            quietHours: { _ in quiet },
            nonMedScheduledToday: notificationDeliveries.countBudgeted(inDayOf: fireDate, calendar: calendar),
            pendingMedCount: counts.med,
            pendingNonMedCount: counts.nonMed,
            dailyNonMedLimit: dailyLimitOverride ?? profile.notifications.dailyNonMedLimit)

        let decision = NotificationDecisionEngine.decide(.init(cls, fireDate: fireDate), in: context)
        guard decision == .scheduled else {
            // Record the suppression for diagnostics (it consumes no budget), matching Android, so
            // "why didn't I get my morning summary?" is answerable from history. Best-effort: a
            // failed diagnostic write must not change what the user experiences.
            recordDecisionLedgerRow(cls, scheduledFor: fireDate, outcome: .suppressed)
            return decision
        }

        // Reserve the budget slot first — see the note above on why the order is load-bearing.
        let reserved: NotificationDelivery
        do {
            reserved = try notificationDeliveries.record(cls, scheduledFor: fireDate, outcome: .scheduled,
                                                         now: now(), deviceId: deviceId)
        } catch {
            NotificationLog.logger.error(
                "decision ledger reservation failed for \(cls.rawValue, privacy: .public); not scheduling: \(String(describing: error), privacy: .public)")
            return .suppressedLedgerUnavailable
        }

        let identifier = cls.identifierPrefix + Self.decisionDayKey(fireDate, calendar: calendar)
        await NotificationScheduler.shared.scheduleDecisionNotification(
            cls, identifier: identifier, fireDate: fireDate, ledgerRowId: reserved.id,
            language: language, calendar: calendar)
        return decision
    }

    /// Append one ledger row, swallowing nothing silently: a failed write goes to the log so a
    /// missing diagnostic row is inspectable rather than invisible. Only ever used for rows that
    /// consume NO budget (`suppressed`) — the budget-consuming reservation is deliberately not
    /// best-effort and lives inline above, where its failure changes the outcome.
    private func recordDecisionLedgerRow(_ cls: NotificationClass, scheduledFor: Date,
                                         outcome: NotificationOutcome) {
        do {
            try notificationDeliveries.record(cls, scheduledFor: scheduledFor, outcome: outcome,
                                              now: now(), deviceId: deviceId)
        } catch {
            NotificationLog.logger.error(
                "decision ledger write (\(outcome.rawValue, privacy: .public)) failed for \(cls.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Close out a decision notification's reserved ledger row once the app has actually observed
    /// the notification — a foreground presentation or a tap, routed here by
    /// `NotificationForegroundDelegate`. The row id comes from the request's own `userInfo`, so this
    /// closes the exact row that fired. Mirrors Android's `markNotificationDelivered`.
    ///
    /// Best-effort on purpose: the row already counts against the budget as `scheduled`, so a failed
    /// transition loses a diagnostic distinction and nothing else.
    func markNotificationDelivered(ledgerRowId: String, at date: Date) {
        do {
            try notificationDeliveries.markDelivered(id: ledgerRowId, at: date)
        } catch {
            NotificationLog.logger.error(
                "marking a notification delivered failed: \(String(describing: error), privacy: .public)")
        }
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
        // EPIC-32: decision notifications carry static, language-captured text too, so a language
        // switch must re-render any that are scheduled. Reconcile re-schedules the enabled classes
        // in the new language and is a no-op when none are on (the default).
        if previous.language != p.language {
            Task { [weak self] in
                await self?.reconcileDecisionNotifications()
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

extension AppEnvironment {
    /// Construct the Apple Health archive importer (plan §19) with the composition root's live
    /// collaborators. A factory, not a stored property, because an import is an occasional user-
    /// initiated operation and the importer carries one import's mutable parse state — a fresh
    /// instance per run keeps runs independent. Its `ingest` calls share the single main-DB
    /// connection lock with live sync, so import and sync writes are serialized at that level.
    func makeAppleHealthImporter() -> AppleHealthArchiveImporter {
        AppleHealthArchiveImporter(pipeline: ingestion, batches: importBatches, registry: registry,
                                   derivation: derivationCoordinator, clock: clock)
    }

    /// EPIC-43 ACC-005: construct the GPX/TCX/CSV file importer with the composition root's live
    /// collaborators — the same `ingestion`/`importBatches`/`derivationCoordinator` wiring
    /// `makeAppleHealthImporter()` uses, so a picked file is deduped, provenanced and undoable
    /// exactly like an Apple Health archive or a live sync. A fresh instance per run, for the same
    /// reason `makeAppleHealthImporter()` is a factory rather than a stored property. The route-
    /// consent provider defaults to the real `RouteConsentStore()` (the same standing toggle
    /// `makeHealthKitAdapter()` wires), so a GPX/TCX route is only ever written under the one
    /// consent decision that already governs every other source of workout GPS data.
    func makeFileImporter() -> FileImporter {
        FileImporter(pipeline: ingestion, batches: importBatches, clock: clock,
                    derivation: derivationCoordinator)
    }
}

private enum HealthKitConnectLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "HealthKitConnect")
}

private enum SyncLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "ForegroundSync")
}

/// EPIC-32. The budget ledger's writes back the daily invariant, so a failed write is a fact worth
/// surfacing rather than a `try?` away. Nothing logged here names a class's CONTENT or any health
/// value — only the storage code of the notification class and the storage error.
private enum NotificationLog {
    static let logger = Logger(subsystem: "net.binjamshid.badan", category: "Notifications")
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
