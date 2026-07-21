package net.albayyan.badan.app

import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.MILLIS_PER_DAY
import net.albayyan.badan.core.SystemClock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.NotificationQuietHours
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.platform.health.HealthConnectAdapter
import net.albayyan.badan.platform.health.HealthDateRange
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.derivation.DerivationCoordinator
import net.albayyan.badan.domain.derivation.DeviationEngine
import net.albayyan.badan.domain.derivation.EffortEngine
import net.albayyan.badan.domain.derivation.InsightEngine
import net.albayyan.badan.domain.derivation.ReadinessEngine
import net.albayyan.badan.domain.derivation.SleepIntelligenceEngine
import net.albayyan.badan.domain.ingestion.IngestionPipeline
import net.albayyan.badan.domain.automation.AutomationEngine
import net.albayyan.badan.domain.automation.ExportRunnerAutomationRunner
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportGenerationService
import net.albayyan.badan.export.ExportRunner
import net.albayyan.badan.export.destinations.RestDestinationAvailability
import net.albayyan.badan.platform.notifications.AndroidAutomationPauseNotifier
import net.albayyan.badan.platform.notifications.AndroidNotificationScheduler
import net.albayyan.badan.platform.notifications.NotificationClass
import net.albayyan.badan.platform.notifications.NotificationDecisionEngine
import net.albayyan.badan.storage.repositories.AutomationDataFreshnessProbe
import net.albayyan.badan.storage.repositories.AutomationScheduleRepository
import net.albayyan.badan.storage.repositories.ExportCursorRepository
import net.albayyan.badan.storage.repositories.ExportDestinationRepository
import net.albayyan.badan.ontology.BeverageCatalog
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.ontology.SensorQualityMap
import net.albayyan.badan.ontology.SymptomDictionary
import net.albayyan.badan.platform.background.BackgroundScheduler
import net.albayyan.badan.storage.Database
import net.albayyan.badan.storage.repositories.BackgroundRunRepository
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.ExportJobRepository
import net.albayyan.badan.storage.repositories.ExportRunRepository
import net.albayyan.badan.storage.repositories.ExportTemplateRepository
import net.albayyan.badan.storage.repositories.HydrationRepository
import net.albayyan.badan.storage.repositories.InsightRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.NotificationDeliveryRepository
import net.albayyan.badan.storage.repositories.NotificationOutcome
import net.albayyan.badan.storage.repositories.ProfileRepository
import net.albayyan.badan.storage.repositories.ReadAnchorRepository
import net.albayyan.badan.storage.repositories.ReconciliationRepository
import net.albayyan.badan.storage.repositories.ReportRepository
import net.albayyan.badan.storage.repositories.RouteRepository
import java.time.Instant
import java.time.ZoneId
import java.util.Calendar
import java.util.TimeZone

/**
 * The composition root and dependency container. Owns the two databases, repositories, services,
 * and the live [CustomizationProfile]. Provided into the Compose tree; screens read repositories
 * / services from here. Mutating [profile] (language / depth / theme) re-renders the whole app
 * because it is Compose-observable. Mirror of the iOS `AppEnvironment`.
 */
class AppEnvironment(context: Context) {

    // Infrastructure
    private val appContext = context.applicationContext
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val clock: Clock = SystemClock()
    val appVersion: String = "0.1.0"
    val deviceId: String = resolveDeviceId()

    val database: Database = Database.forApp(context.filesDir)

    // Ontology
    val registry: MetricRegistry = MetricRegistry(context.assets)
    val symptoms: SymptomDictionary = SymptomDictionary(context.assets)
    val templates: InsightTemplateStore = InsightTemplateStore(context.assets)
    // EPIC-38 built-in beverage vocabulary (`beverages.json`), the curated half of the hydration
    // dictionary-vs-custom split. A dictionary loader beside `symptoms`/`templates`, not a repository.
    val beverages: BeverageCatalog = BeverageCatalog(context.assets)

    // Repositories
    val measurements: MeasurementRepository = MeasurementRepository(database.main)
    val derivation: DerivationRepository = DerivationRepository(database.main)
    val insightsRepo: InsightRepository = InsightRepository(database.main)
    val reconciliation: ReconciliationRepository = ReconciliationRepository(database.main)
    val catalog: CatalogRepository = CatalogRepository(database.main)
    val logging: LoggingRepository = LoggingRepository(database.main, database.sensitive)
    // EPIC-38 hydration ledger + beverage/container catalogs + goals + daily summaries. Main DB — a
    // logged drink is normal-class, not sensitive-plus (§9.14). Consumed by the LogHub hydration
    // surface; the pure ledger/goal logic lives in `domain.hydration`.
    val hydration: HydrationRepository = HydrationRepository(database.main)
    val exportJobs: ExportJobRepository = ExportJobRepository(database.main)
    // EPIC-09/10/16 export surfaces. `export_templates` and `export_runs` already exist (migration
    // v4); these repositories were written in Phase 0 but had no caller until the Compose export
    // surfaces landed. Both are the main DB — a template is a configuration and a run is an event,
    // neither is sensitive-namespace (I7), and the ledger must be readable without unlocking meds.
    val exportTemplates: ExportTemplateRepository = ExportTemplateRepository(database.main)
    val exportRuns: ExportRunRepository = ExportRunRepository(database.main)
    val profiles: ProfileRepository = ProfileRepository(database.main)
    val backgroundRuns: BackgroundRunRepository = BackgroundRunRepository(database.main)
    val routes: RouteRepository = RouteRepository(database.main)
    val readAnchors: ReadAnchorRepository = ReadAnchorRepository(database.main)
    // EPIC-32 notification budget ledger (`notification_deliveries`, migration v8). Main DB — a
    // scheduling decision is operational metadata, not a health record, and the budget must be
    // readable without unlocking the sensitive namespace (I7).
    val notificationDeliveries: NotificationDeliveryRepository =
        NotificationDeliveryRepository(database.main)
    // EPIC-31 periodic-report metadata (`reports`, migration v8). Main DB, and DERIVED: the rendered
    // PDF is a regenerable file; the row is never a source of truth — see [ReportRepository].
    val reports: ReportRepository = ReportRepository(database.main)

    // Services
    val ingestion: IngestionPipeline =
        IngestionPipeline(measurements, catalog, reconciliation, registry, clock, deviceId, routes)
    val baselines: BaselineEngine =
        BaselineEngine(derivation, measurements, registry, clock, deviceId)
    // EPIC-24/25/26/27 score engines. Constructed here in the composition root and — for the three
    // that WRITE — run in cross-metric order by [derivationCoordinator]. [deviation] writes nothing:
    // a pure read model over the `Baseline` rows the pipeline refreshes, read on demand by the Health
    // Monitor surface (see [DeviationEngine]), so it is wired here but never "recomputed".
    val sensorQuality: SensorQualityMap = SensorQualityMap.from(appContext.assets)
    val sleepIntelligence: SleepIntelligenceEngine =
        SleepIntelligenceEngine(derivation, measurements, clock, deviceId)
    // Readiness resolves a two-source overnight-HRV conflict by source priority (plan §18),
    // reconstructed from the persisted source/device catalog via the published sensor-class contract
    // (worn sensor > phone) — no new stored column, cannot drift from that contract. See
    // [readinessSourcePriority].
    val readiness: ReadinessEngine =
        ReadinessEngine(derivation, measurements, clock, deviceId,
            priorityForSource = { sourceId -> readinessSourcePriority(sourceId) })
    // Effort reads HR max / zones off the live profile per recompute (never a cached copy) so a
    // mid-session HR-max edit is picked up on the next run — the reason it takes a provider.
    val effort: EffortEngine =
        EffortEngine(derivation, measurements, registry, clock, deviceId,
            profileProvider = { catalog.userProfile() })
    val deviation: DeviationEngine =
        DeviationEngine(derivation, measurements, catalog, registry, sensorQuality, clock)
    // EPIC-23. The one place the writing score engines run in the published cross-metric order.
    // Wired into the ingest→derive funnel ([syncHealthConnect], [SeedController]) and the background
    // backfill job ([recomputeScoreBackfill]).
    val derivationCoordinator: DerivationCoordinator =
        DerivationCoordinator(baselines, sleepIntelligence, readiness, effort)
    val insightEngine: InsightEngine =
        InsightEngine(insightsRepo, derivation, measurements, templates, registry, clock, deviceId)
    val exporter: ExportRunner =
        ExportRunner(measurements, derivation, logging, exportJobs, registry, clock, appVersion, deviceId,
            hydration = hydration)

    /**
     * EPIC-15 — the scheduling & automation engine, invoked from [SyncWorker] on the periodic wake.
     * Lazy because it is only needed in the background worker, not on the app's first frame.
     *
     * It composes Phase-1's runner, so it needs a DELIVERY-capable [ExportRunner] — the plain
     * [exporter] above is share-sheet-only (no template collaborators). This one carries
     * `templates`/`destinations`/`runs`/`cursors`/`routes` and the folder deliverer, so a scheduled
     * template can land its file in the user's picked tree. Generation happens into the app cache
     * dir (the same scratch space the export UI uses).
     */
    val automationEngine: AutomationEngine by lazy {
        val deliveryRunner = ExportRunner(
            measurements, derivation, logging, exportJobs, registry, clock, appVersion, deviceId,
            templates = ExportTemplateRepository(database.main),
            destinations = ExportDestinationRepository(database.main),
            runs = ExportRunRepository(database.main),
            cursors = ExportCursorRepository(database.main),
            routes = RouteRepository(database.main),
            // EPIC-17: the dedup journal, so a delta run emits suppression-flip `corrections[]` when a
            // dedup decision reversed since the last cursor (the add-only desync guard).
            reconciliation = reconciliation,
            // A scheduled/automation export owns the ledger too — a drink is the user's own data (raw
            // data is never paywalled), so the background lane exports it exactly like the share sheet.
            hydration = hydration,
            // The registered delivery surface of this build, assembled in one place so "what can
            // this build send an export to?" has a single answer. EPIC-20's REST deliverer is
            // deliberately NOT in it — see `RestDestinationAvailability` for the flag, the reason
            // and everything that has to ship alongside it before it is (including the `INTERNET`
            // permission this manifest no longer declares).
            deliverers = RestDestinationAvailability.deliverers(appContext),
        )
        AutomationEngine(
            schedules = AutomationScheduleRepository(database.main),
            templates = ExportTemplateRepository(database.main),
            runner = ExportRunnerAutomationRunner(deliveryRunner, appContext.cacheDir),
            freshness = AutomationDataFreshnessProbe(database.main),
            notifier = AndroidAutomationPauseNotifier(appContext),
            clock = clock,
        )
    }

    /**
     * EPIC-31. The pure periodic-report builder (derived store → typed `ReportModel`) and the thin
     * service that persists its metadata and answers the substrate's "is a weekly report due?". The
     * PDF renderer is stateless (`ReportRenderer`) so it needs no wiring here.
     */
    val reportBuilder: ReportBuilder = ReportBuilder(derivation, logging)
    val reportGeneration: ReportGenerationService = ReportGenerationService(
        builder = reportBuilder,
        reports = reports,
        clock = clock,
        deviceId = deviceId,
        timezone = { TimeZone.getDefault().id },
    )

    private val seedController: SeedController =
        SeedController(catalog, ingestion, logging, measurements, baselines, insightEngine, registry,
            clock, deviceId, prefs, derivationCoordinator)

    /** Whether the user is currently looking at the bundled sample dataset rather than their own
     *  data — drives the sample banner and the Export Center's notice. Compose-observable so
     *  clearing it (a real connect, or "Start empty") removes the banner immediately. */
    var isDemoDataActive by mutableStateOf(seedController.isDemoDataActive)
        private set

    /**
     * Whether Health Connect has actually granted BADAN at least some of the data it asked for —
     * i.e. whether real measurements can arrive at all.
     *
     * Derived from the persisted permission state rather than tracked separately, so it survives
     * process death and cannot drift from what the system actually granted. Compose-observable;
     * refreshed by [recordHealthConnectPermissions] and at bootstrap.
     */
    var isHealthConnected by mutableStateOf(false)
        private set

    private fun readHealthConnectedFromDisk(): Boolean =
        runCatching {
            catalog.permissions("healthConnect")
                .any { it.status == PermissionStatus.GRANTED || it.status == PermissionStatus.PARTIAL }
        }.getOrDefault(false)

    /** The real Health Connect integration boundary (lazy: safe even when no provider is present). */
    val healthConnect: HealthConnectAdapter by lazy {
        HealthConnectAdapter(
            appContext,
            anchors = readAnchors,
            // Now backed by the real toggle `RouteConsentScreen` owns (EPIC-03 UI). Still a lambda
            // rather than a captured value, so turning consent off takes effect on the very next
            // sync instead of the next process launch — the adapter's own doc explains why
            // eventually-consistent consent is not good enough for location data.
            //
            // The default remains `false` (see [isRouteCaptureEnabled]): shipping with it defaulted
            // on would collect GPS traces the user was never asked about.
            routeConsentGranted = { isRouteCaptureEnabled },
            // Per-writer dedup priority the user has edited on the Sources screen. Resolved fresh
            // per sync for the same reason: an edit made now must change the next reconciliation,
            // not the one after a restart.
            writerPriorityOverrides = { writerPriorityOverrides() },
        )
    }

    // MARK: - Route capture consent (EPIC-03, plan §4 rule 11)

    /**
     * Whether BADAN may copy GPS traces out of Health Connect at all.
     *
     * Stored in SharedPreferences rather than in the profile row because it must be readable
     * without opening the database — `HealthConnectAdapter` consults it inside the read loop, and
     * a per-record database round trip there would be a measurable cost on a 10k-point route for a
     * value that changes once a year.
     *
     * Turning it off stops collection but deliberately does not itself delete what was already
     * collected; `RouteConsentScreen` offers that as its own explicit action, because "stop doing
     * this" and "destroy what you have" are two different requests and merging them would surprise
     * a user in one direction or the other.
     */
    var isRouteCaptureEnabled: Boolean
        get() = prefs.getBoolean(ROUTE_CAPTURE_KEY, false)
        set(value) = prefs.edit().putBoolean(ROUTE_CAPTURE_KEY, value).apply()

    // MARK: - Source priority overrides (EPIC-02 multi-writer)

    /**
     * User-set dedup priority per writing package, higher wins — the editable layer over
     * `HcTypeMap.writerPriorityDefaults`.
     *
     * Persisted as a `package=priority` line-delimited string rather than JSON so a corrupt or
     * partially-written value degrades to "ignore the unparseable lines" instead of "lose every
     * override", which matters because the fallback for a lost override is silently reverting to a
     * default ordering the user explicitly disagreed with.
     */
    fun writerPriorityOverrides(): Map<String, Int> {
        val raw = prefs.getString(WRITER_PRIORITY_KEY, null) ?: return emptyMap()
        return raw.lineSequence()
            .mapNotNull { line ->
                val idx = line.lastIndexOf('=')
                if (idx <= 0) return@mapNotNull null
                val pkg = line.substring(0, idx)
                val value = line.substring(idx + 1).toIntOrNull() ?: return@mapNotNull null
                pkg to value
            }
            .toMap()
    }

    fun setWriterPriorityOverrides(overrides: Map<String, Int>) {
        val encoded = overrides.entries
            .sortedBy { it.key }
            .joinToString("\n") { "${it.key}=${it.value}" }
        prefs.edit().putString(WRITER_PRIORITY_KEY, encoded).apply()
    }

    /**
     * Pull recent history from Health Connect through the same ingestion + dedup + derivation path
     * as the seed. Returns the ingest summary (may be all-zero when the user has no HC data yet).
     * Runs entirely off the main thread.
     *
     * [lookbackDays] defaults to the 90-day backfill the connect flow wants. `SyncWorker` (EPIC-05)
     * passes a short catch-up window instead: every write here is idempotent by upstream identity,
     * so a narrow overlapping window is *correct* — it is only the 90-day re-walk, once an hour,
     * that would be indefensible on battery.
     *
     * This is not an interim arrangement waiting on the changes-token read, which is what the
     * previous note claimed (audit finding #4). That read shipped with EPIC-02 and is wired
     * immediately below via `anchors = readAnchors`; `HealthConnectAdapter.readType` resumes from a
     * persisted token whenever it has one. The range stays a parameter because it governs the
     * *fallback* — a token that has expired or been invalidated drops through to a full windowed
     * re-read, and the two callers want visibly different amounts of history when that happens.
     * Both should keep passing one.
     */
    suspend fun syncHealthConnect(
        lookbackDays: Int = 90,
    ): IngestionPipeline.IngestSummary? = withContext(Dispatchers.IO) {
        val now = clock.now()
        val range = HealthDateRange(now - lookbackDays * MILLIS_PER_DAY, now)
        // The user's real data must never land on top of the fabricated seed. Without this, a
        // connected Android user's Home screen mixed 90 days of invented readings with their own
        // and presented the blend as theirs — permanently, since nothing ever removed the seed.
        // iOS has done this at `connectHealthKit` from the start; Android had no purge primitive
        // to call. Runs once, gated on the same flag the banner reads, so it can never touch the
        // data of a user who is already connected.
        purgeDemoSeedIfActive()
        // Batch the ingest + baseline recompute in one transaction (mirrors the seed path) so this
        // recurring sync doesn't pay a commit-per-row cost across up to 90 days of history.
        val summary = runCatching {
            database.main.transaction {
                val result = ingestion.ingest(healthConnect, range)
                // The full score pipeline in cross-metric order (EPIC-23/24/25/26), replacing the
                // bare baseline recompute. It runs inside this one transaction, so each engine reads
                // the prior engine's just-written rows (effort → sleep → readiness) before commit.
                derivationCoordinator.recompute(now)
                result
            }
        }.getOrNull()
        if (summary != null) {
            val tz = java.util.TimeZone.getDefault().id
            for (d in 0..3) runCatching { insightEngine.generate(now - d * MILLIS_PER_DAY, tz) }
        }
        summary
    }

    /**
     * Clear the sample seed the first time real data is about to arrive, then lower the flag.
     *
     * Mirrors iOS's `connectHealthKit` purge seam, including its documented tradeoff: a manual
     * log the user entered while exploring with sample data cannot be told apart from a seeded
     * one by content, so the first connect clears both. It happens exactly once — `demoSeedActive`
     * is cleared here — so a connected user's own logs are never at risk afterwards.
     *
     * `purgeIngestedData` alone would not be enough: the seed also writes workouts/nutrition/notes
     * (main DB) and medications/symptoms (sensitive DB), which are the fabricated rows most likely
     * to be mistaken for the user's own.
     */
    private fun purgeDemoSeedIfActive() {
        if (!seedController.isDemoDataActive) return
        runCatching {
            database.purgeIngestedData()
            database.purgeDemoManualLogs()
            database.purgeSensitiveNamespace()
            prefs.edit().putBoolean(SeedController.DEMO_SEED_ACTIVE_KEY, false).apply()
        }
        // Reflect the cleared flag in the UI even if a step above failed: on a partial failure the
        // banner staying up is the safe direction, so re-read rather than assume.
        val stillDemo = seedController.isDemoDataActive
        CoroutineScope(Dispatchers.Main.immediate).launch { isDemoDataActive = stillDemo }
    }

    /** Persist an honest granted / partial / denied Health Connect permission state for the UI. */
    fun recordHealthConnectPermissions(granted: Set<String>) {
        val required = HealthConnectAdapter.permissions
        val status = when {
            granted.containsAll(required) -> PermissionStatus.GRANTED
            granted.any { it in required } -> PermissionStatus.PARTIAL
            else -> PermissionStatus.DENIED
        }
        runCatching { catalog.upsertPermission(PermissionState("healthConnect", "health", status, clock.now())) }
        isHealthConnected = readHealthConnectedFromDisk()
        reconcileBackgroundSchedule()
    }

    // MARK: - Background sync (EPIC-05)

    /**
     * Whether the hourly [SyncWorker] should do anything when it wakes. Read from disk rather than
     * from the Compose-observable [isHealthConnected], because the worker runs with no Activity
     * alive and this instance's observable state may never have been populated.
     *
     * The Health-Connect-connected half is not a convenience check. `syncHealthConnect` purges the
     * demo seed on its first real ingest, so a background run for a user who has never connected
     * would delete the sample data they are still exploring.
     */
    fun isBackgroundSyncEligible(): Boolean =
        isBackgroundSyncEnabled && isHealthConnectedPersisted()

    /**
     * The connected half of [isBackgroundSyncEligible], on its own.
     *
     * A user-triggered "sync now" gates on *this*, not on the full eligibility check: turning the
     * background-sync preference off means "stop waking my phone on a schedule", not "refuse to
     * sync when I explicitly ask". Gating the one-off on the background preference would leave the
     * button visibly doing nothing for exactly the users who turned the schedule off.
     */
    fun isHealthConnectedPersisted(): Boolean = readHealthConnectedFromDisk()

    /**
     * The user's background-sync preference. Defaults to on for connected users: syncing data the
     * user has already granted is not a new disclosure, and the alternative — silently stale
     * readings until the app is opened — is the thing EPIC-05 exists to fix. The seam is public so
     * the Settings toggle (EPIC-15) has somewhere to land; nothing turns it off today.
     */
    var isBackgroundSyncEnabled: Boolean
        get() = prefs.getBoolean(BACKGROUND_SYNC_KEY, true)
        set(value) {
            prefs.edit().putBoolean(BACKGROUND_SYNC_KEY, value).apply()
            reconcileBackgroundSchedule()
        }

    /**
     * Bring WorkManager's schedule in line with current eligibility. Idempotent at both ends —
     * `schedulePeriodic` uses `ExistingPeriodicWorkPolicy.UPDATE` and `cancelUniqueWork` on absent
     * work is a no-op — so this is safe to call from bootstrap, from permission changes, and from
     * the preference setter without tracking what it did last time.
     */
    fun reconcileBackgroundSchedule() {
        runCatching {
            if (isBackgroundSyncEligible()) {
                BackgroundScheduler.schedulePeriodic(appContext)
            } else {
                BackgroundScheduler.cancelPeriodic(appContext)
            }
        }
    }

    /** Run the sync immediately at the user's request (EPIC-05 expedited one-off). */
    fun requestSyncNow() {
        runCatching { BackgroundScheduler.runNow(appContext) }
    }

    // MARK: - Effort backfill (EPIC-26 HR-max/zone edit)

    /**
     * Queue a historical effort/score re-derivation and enqueue the background job to run it. Called
     * by the HR-max/zone editor after it saves the profile: editing the max redraws every HR zone, so
     * every effort score in the window is now computed against stale zones and must be re-derived
     * (append-only supersession, I2 — old rows kept, new ones win by `computedAt`). The work runs in
     * [SyncWorker]'s backfill path — deferrable, off the editor's thread. A second edit before the job
     * runs WIDENS the stored window to the union so no range is silently narrowed. [historyDays] bounds
     * it to the ingested history.
     */
    fun requestEffortBackfill(historyDays: Int = 90) {
        val now = clock.now()
        val from = now - historyDays.toLong() * MILLIS_PER_DAY
        val unionFrom = minOf(from, prefs.getLong(SCORE_BACKFILL_FROM_KEY, Long.MAX_VALUE))
        val unionTo = maxOf(now, prefs.getLong(SCORE_BACKFILL_TO_KEY, Long.MIN_VALUE))
        prefs.edit().putLong(SCORE_BACKFILL_FROM_KEY, unionFrom).putLong(SCORE_BACKFILL_TO_KEY, unionTo).apply()
        runCatching { BackgroundScheduler.runScoreBackfill(appContext) }
    }

    /** Whether an effort/score backfill is queued (a durable prefs marker). */
    fun hasPendingScoreBackfill(): Boolean =
        prefs.contains(SCORE_BACKFILL_FROM_KEY) && prefs.contains(SCORE_BACKFILL_TO_KEY)

    /**
     * Run the queued effort/score backfill over its window (append-only, I2) in one transaction, then
     * clear the request. Returns the touched-day/session count, or null when nothing is queued. Runs
     * on IO — never the caller's thread. If the re-derivation throws it propagates and the request is
     * left in place, so the next run retries. [SyncWorker] calls this on its backfill path.
     */
    suspend fun runPendingScoreBackfill(): Int? = withContext(Dispatchers.IO) {
        if (!hasPendingScoreBackfill()) return@withContext null
        val from = prefs.getLong(SCORE_BACKFILL_FROM_KEY, 0L)
        val to = prefs.getLong(SCORE_BACKFILL_TO_KEY, clock.now())
        val touched = database.main.transaction { derivationCoordinator.backfill(from, to) }
        prefs.edit().remove(SCORE_BACKFILL_FROM_KEY).remove(SCORE_BACKFILL_TO_KEY).apply()
        touched
    }

    // Live presentation state (Compose-observable). `profile` starts at the default and is
    // replaced by the persisted value once `bootstrap()` loads it off the main thread — screens
    // don't read it until `isReady` flips, so the placeholder is never shown.
    var profile by mutableStateOf(CustomizationProfile())
    var isReady by mutableStateOf(false)
    var onboardingComplete by mutableStateOf(prefs.getBoolean(ONBOARDING_KEY, false))

    // Launch overrides recorded before `profile` has loaded (see [applyLaunchOverrides]); applied
    // on top of the persisted profile once `bootstrap()` loads it, so they can't be clobbered by
    // the async load overwriting an override applied to the placeholder default.
    private var pendingLanguageOverride: AppLanguage? = null
    private var pendingDepthOverride: DepthPolicy? = null

    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // MARK: - Lifecycle

    /**
     * Load the persisted profile and seed on first run (off the main thread), then flip
     * [isReady]. The UI shows a calm loading state until ready.
     */
    suspend fun bootstrap() {
        val loaded = withContext(Dispatchers.IO) {
            var p = profiles.load()
            pendingLanguageOverride?.let { p = p.copy(language = it) }
            pendingDepthOverride?.let { p = p.copy(depthPolicy = it) }
            runCatching { seedController.seedIfNeeded(clock.now()) }
            p
        }
        profile = loaded
        isDemoDataActive = seedController.isDemoDataActive
        isHealthConnected = readHealthConnectedFromDisk()
        // Re-asserted on every launch rather than only at connect time: WorkManager's schedule can
        // be lost to a force-stop, a "clear data", or an OEM cleaner, and an app launch is the one
        // moment BADAN is guaranteed to be running and able to notice.
        reconcileBackgroundSchedule()
        // EPIC-32: the same self-heal for the budgeted decision notifications, and for the same
        // reasons — the enqueued work is one-shot, so a force-stop or an OEM cleaner that drops it
        // would otherwise end the daily cadence silently. Mirrors the iOS launch reconcile in
        // `BADANApp`. A no-op for a user with every class OFF (the default) and it never prompts:
        // requesting POST_NOTIFICATIONS is an explicit-user-action concern owned by Settings.
        reconcileDecisionNotifications()
        isReady = true
    }

    /**
     * The "Start empty" onboarding fork: no sample data, no connect — just an empty store the
     * user fills themselves.
     *
     * Android's onboarding offered no such choice; bootstrap seeded unconditionally and every
     * path led to fabricated data.
     */
    suspend fun startEmpty() {
        isReady = false
        withContext(Dispatchers.IO) {
            runCatching { SeedController.markStartEmpty(database, prefs) }
        }
        isDemoDataActive = seedController.isDemoDataActive
        isReady = true
    }

    /**
     * Delete everything on this device, then restore whatever the user's actual situation is: a
     * connected user's data is re-read from Health Connect, an unconnected user gets the sample
     * set back. Surfaced as "Delete all data" — see [Strings.deleteAllData].
     */
    suspend fun resetDemoData() {
        isReady = false
        withContext(Dispatchers.IO) {
            runCatching { database.resetAll() }
            // Re-seeding restores fabricated data, so the flag must go back up — `seed()` sets
            // it. Previously nothing tracked this at all.
            runCatching { seedController.seed(clock.now()) }
        }
        profile = profiles.load()
        isDemoDataActive = seedController.isDemoDataActive
        isReady = true
    }

    fun completeOnboarding() {
        onboardingComplete = true
        prefs.edit().putBoolean(ONBOARDING_KEY, true).apply()
    }

    // MARK: - Decision-engine notifications (EPIC-32)

    /**
     * The Android I/O shell for notifications: channels, the `POST_NOTIFICATIONS` check, posting and
     * WorkManager scheduling. Every gating decision is made by [NotificationDecisionEngine] before
     * this is touched.
     */
    val notificationScheduler: AndroidNotificationScheduler = AndroidNotificationScheduler(appContext)

    /** The zone every notification day-window and quiet-hours check is evaluated in. */
    private val notificationZone: ZoneId get() = ZoneId.systemDefault()

    /**
     * Whether the user has enabled a given notification class. `MEDS` reads the existing
     * `medicationReminders` preference so the shape matches iOS exactly — but note that Android
     * schedules no medication reminders at all (standing parity debt, see
     * [AndroidNotificationScheduler]), so on this platform that branch gates nothing today. Every
     * other class reads the per-class opt-in map, which defaults every class OFF.
     */
    fun isNotificationClassEnabled(cls: NotificationClass): Boolean =
        if (cls.isMedication) profile.notifications.medicationReminders
        else profile.notifications.classOptIn[cls.code] ?: false

    /**
     * Turn one budgeted class on or off. Persists the preference, then reconciles the OS side:
     * enabling schedules the class's next occurrence (still subject to the budget, quiet hours and
     * the shared ceiling — a toggle is a request, not a guarantee that a notice fits today), and
     * disabling cancels its pending work, clears any notice on screen, and marks its still-scheduled
     * ledger rows `cancelled` so the budget slot it was holding is released.
     */
    fun setNotificationClassEnabled(cls: NotificationClass, enabled: Boolean) {
        update { it.copy(notifications = it.notifications.copy(
            classOptIn = it.notifications.classOptIn + (cls.code to enabled),
        )) }
        if (enabled) {
            notificationScheduler.ensureChannels(language)
            reconcileDecisionNotifications()
        } else {
            notificationScheduler.cancel(cls)
            val at = now()
            ioScope.launch { runCatching { notificationDeliveries.cancelScheduled(cls, at) } }
        }
    }

    /** Persist a change to the shared quiet-hours window and re-reconcile what is scheduled. */
    fun setNotificationQuietHours(quietHours: NotificationQuietHours) {
        update { it.copy(notifications = it.notifications.copy(quietHours = quietHours)) }
        reconcileDecisionNotifications()
    }

    /**
     * The next time [cls] should fire — the next occurrence of its default local hour, on the wall
     * clock rather than by adding 24h, so a DST shift does not walk the reminder an hour per season.
     */
    fun nextDecisionFireAt(cls: NotificationClass, now: Long, zone: ZoneId): Long {
        val local = Instant.ofEpochMilli(now).atZone(zone)
        val hour = NotificationClass.defaultHour(cls)
        val todayAt = local.toLocalDate().atStartOfDay(zone).plusHours(hour.toLong())
        val next = if (todayAt.toInstant().toEpochMilli() > now) todayAt else todayAt.plusDays(1)
        return next.toInstant().toEpochMilli()
    }

    /**
     * Bring the time-based decision notifications in line with the current preferences: schedule each
     * enabled class's next occurrence (subject to the ≤2/day budget, quiet hours, opt-in and the
     * shared ceiling), and cancel any class the user has turned off. Idempotent — safe to call at
     * every launch. A no-op for a user with every class OFF (the default), and it never prompts:
     * requesting `POST_NOTIFICATIONS` is an explicit-user-action concern owned by the settings
     * screen. When notifications are unavailable it cancels rather than leaving stale work queued,
     * mirroring the iOS reconcile path.
     *
     * The evaluation itself runs off the UI thread because it reads the ledger (SQLite).
     */
    fun reconcileDecisionNotifications() {
        ioScope.launch { reconcileDecisionNotificationsBlocking() }
    }

    /**
     * The body of [reconcileDecisionNotifications], run on the caller's thread.
     *
     * `SyncWorker` calls this one rather than the fire-and-forget wrapper: a worker's process can be
     * torn down the instant `doWork` returns, so work handed to [ioScope] from inside it may simply
     * never happen. Everything here reads the ledger (SQLite), so a UI-thread caller must use the
     * wrapper above instead.
     *
     * Why the periodic wake re-runs this at all: the enqueued notification work is a one-shot per
     * class, so once it fires nothing would arm the next day's — a class the user enabled would
     * notify once and go quiet until the next app launch. Riding the existing hourly wake (the same
     * substrate EPIC-15's automations and EPIC-31's reports use) keeps the cadence going without a
     * second schedule of its own. Idempotent per class+day via the ledger, so extra wakes are free.
     */
    fun reconcileDecisionNotificationsBlocking() {
        if (!notificationScheduler.canPost()) {
            notificationScheduler.cancelAll()
            return
        }
        notificationScheduler.ensureChannels(language)
        val lang = language
        val quiet = profile.notifications.quietHours
        for (cls in NotificationClass.timeBased) {
            if (isNotificationClassEnabled(cls)) {
                runCatching {
                    evaluateAndSchedule(cls, nextDecisionFireAt(cls, now(), notificationZone), lang, quiet)
                }
            } else {
                notificationScheduler.cancel(cls)
            }
        }
    }

    /**
     * Raise an event-driven decision notification (deviation, export-health) now, subject to the same
     * budget/opt-in/quiet-hours/ceiling gate, and post it immediately when the engine allows. Returns
     * the verdict so a caller can record or test it. The content is generic and value-free, so
     * raising it leaks nothing onto the lock screen.
     *
     * Nothing calls this yet — not production code, and not the test suite either, which covers the
     * pure engine's verdicts rather than this adapter. It is the seam a deviation detector or the
     * export-health surface will call. Its classes are correspondingly absent from
     * [NotificationClass.userFacing]; wire a producer and add the toggle in the same change.
     *
     * Blocking (it reads the ledger), so a future caller must invoke it from a background context
     * (`SyncWorker` is the intended home), never a Compose click handler.
     */
    fun raiseDecisionNotification(cls: NotificationClass, at: Long = now()): NotificationDecisionEngine.Decision {
        if (!notificationScheduler.canPost()) return NotificationDecisionEngine.Decision.SUPPRESSED_NOT_AUTHORIZED
        notificationScheduler.ensureChannels(language)
        return evaluateAndSchedule(cls, at, language, profile.notifications.quietHours)
    }

    /**
     * The one place a decision notification is gated and, if allowed, scheduled/posted and recorded.
     * Reads the day's ledger count and the pending count, asks the pure engine, and on `SCHEDULED`
     * reserves the ledger row that makes the budget survive the next app open BEFORE handing
     * anything to the OS. Idempotent per class+day via the ledger check.
     *
     * The write order is the whole point. The ≤2/day ceiling is a hard invariant, and the ledger is
     * the only thing that remembers it across process death — so a notification that went out
     * without its row would let the next evaluation read a lower count and quietly deliver a third.
     * Reserving first makes the only possible failure a conservative one: a row with no notification
     * behind it costs the user a nudge, which is visible and self-corrects the next day, where an
     * unaccounted notification breaks an invariant nobody can observe breaking.
     *
     * A suppressed verdict is written to the ledger too (as `suppressed`, which consumes no budget),
     * so "why didn't I get my morning summary?" is answerable from recorded history rather than
     * guesswork — the same reasoning `background_runs` exists for.
     */
    private fun evaluateAndSchedule(
        cls: NotificationClass,
        fireAt: Long,
        language: AppLanguage,
        quietHours: NotificationQuietHours,
    ): NotificationDecisionEngine.Decision {
        val zone = notificationZone
        // Already committed for this class+day — don't stack a duplicate on a second evaluation. The
        // opt-in is re-read rather than assumed: a class the user turned off after its row was
        // written did NOT get scheduled by this call, so reporting `SCHEDULED` would name a verdict
        // that never happened. (The already-written row keeps holding its budget slot until
        // `setNotificationClassEnabled`'s cancel path releases it; that is its job, not this one's.)
        if (notificationDeliveries.hasScheduled(cls, fireAt, zone)) {
            return if (isNotificationClassEnabled(cls)) {
                NotificationDecisionEngine.Decision.SCHEDULED
            } else {
                NotificationDecisionEngine.Decision.SUPPRESSED_OPTED_OUT
            }
        }

        val enabled = isNotificationClassEnabled(cls)
        val context = NotificationDecisionEngine.Context(
            zone = zone,
            optedIn = { enabled },
            quietHours = { quietHours },
            nonMedScheduledToday = notificationDeliveries.countBudgeted(fireAt, zone),
            // Android has no medication-reminder scheduler, so nothing med-shaped is ever pending
            // here. Stated as a literal with this comment rather than silently omitted: the day the
            // Android med scheduler lands, this is the line that must start reporting its count.
            pendingMedCount = 0,
            pendingNonMedCount = notificationDeliveries.pendingNonMedCount(now()),
        )

        val decision = NotificationDecisionEngine.decide(
            NotificationDecisionEngine.Candidate(cls, fireAt), context,
        )
        val at = now()
        if (decision != NotificationDecisionEngine.Decision.SCHEDULED) {
            // Diagnostics only — a suppressed row consumes no budget, so a failed write here changes
            // nothing the user experiences. Logged rather than swallowed all the same.
            recordDecisionLedgerRow(cls, fireAt, NotificationOutcome.SUPPRESSED, at)
            return decision
        }

        // Reserve the budget slot first — see the note above on why the order is load-bearing.
        val reserved = runCatching {
            notificationDeliveries.record(cls, fireAt, NotificationOutcome.SCHEDULED, at, deviceId)
        }.onFailure {
            Log.e(TAG, "decision ledger reservation failed for ${cls.code}; not scheduling", it)
        }.getOrNull() ?: return NotificationDecisionEngine.Decision.SUPPRESSED_LEDGER_UNAVAILABLE

        if (fireAt > at) {
            // The delivery worker closes this row out when it actually posts.
            notificationScheduler.schedule(cls, fireAt, language, at)
        } else {
            val posted = notificationScheduler.post(cls, language)
            // Close the reserved row out honestly: `delivered` when the system took it, `suppressed`
            // (which releases the slot again) when it refused. A failure of THIS write leaves the row
            // `scheduled`, which over-counts the day rather than under-counting it — the safe way to
            // be wrong about a hard ceiling.
            runCatching {
                if (posted) {
                    notificationDeliveries.markDelivered(reserved.id, at)
                } else {
                    notificationDeliveries.transition(reserved.id, NotificationOutcome.SUPPRESSED, at)
                }
            }.onFailure { Log.e(TAG, "closing out the ledger row for ${cls.code} failed", it) }
        }
        return decision
    }

    /**
     * Append one ledger row, swallowing nothing silently: a failed write goes to the log so a missing
     * diagnostic row is inspectable rather than invisible. Only ever used for rows that consume NO
     * budget — the budget-consuming reservation is deliberately not best-effort and lives inline in
     * [evaluateAndSchedule], where its failure changes the outcome.
     */
    private fun recordDecisionLedgerRow(
        cls: NotificationClass,
        fireAt: Long,
        outcome: NotificationOutcome,
        at: Long,
    ) {
        runCatching { notificationDeliveries.record(cls, fireAt, outcome, at, deviceId) }
            .onFailure { Log.e(TAG, "decision ledger write (${outcome.code}) failed for ${cls.code}", it) }
    }

    /** Close out [cls]'s reserved ledger row once the OS has accepted the post (delivery worker). */
    fun markNotificationDelivered(cls: NotificationClass, at: Long) {
        runCatching { notificationDeliveries.markDeliveredForClass(cls, at) }
            .onFailure { Log.e(TAG, "marking ${cls.code} delivered failed", it) }
    }


    // MARK: - Presentation mutations (persisted)

    fun update(mutate: (CustomizationProfile) -> CustomizationProfile) {
        profile = mutate(profile)
        // Persist off the UI thread — settings toggles call this directly from Compose click
        // handlers, and a synchronous SQLite write there is a frame-drop risk.
        val snapshot = profile
        ioScope.launch { profiles.save(snapshot) }
    }

    val language: AppLanguage get() = profile.language
    val depth: DepthPolicy get() = profile.depthPolicy

    fun now(): Long = clock.now()

    /** The shared value formatter bound to the current profile. */
    val format: ValueFormatter get() = ValueFormatter(profile, registry)

    /** Resolve a localized string to the current language. */
    fun s(ls: LocalizedString): String = ls.resolved(language)

    /** The greeting for the current hour. */
    val greeting: LocalizedString
        get() {
            val cal = Calendar.getInstance().apply { timeInMillis = now() }
            return Loc.greeting(cal.get(Calendar.HOUR_OF_DAY))
        }

    // MARK: - Launch overrides

    /**
     * Ephemeral demo / screenshot launch overrides (not persisted). Read from intent extras
     * `badan_lang` (en|ar), `badan_depth` (casual|balanced|power), `badan_skip_onboarding` (1).
     * Called before [bootstrap] loads the persisted profile, so language/depth are recorded as
     * pending and applied on top of the loaded profile in [bootstrap] rather than mutated here
     * directly — otherwise the async load would silently clobber them.
     */
    fun applyLaunchOverrides(extras: Bundle?) {
        if (extras == null) return
        extras.getString("badan_lang")?.let { raw ->
            AppLanguage.entries.firstOrNull { it.code == raw }?.let { lang ->
                pendingLanguageOverride = lang
            }
        }
        extras.getString("badan_depth")?.let { raw ->
            DepthPolicy.entries.firstOrNull { it.code == raw }?.let { depth ->
                pendingDepthOverride = depth
            }
        }
        val skip = extras.getString("badan_skip_onboarding")
        if (skip == "1" || extras.getBoolean("badan_skip_onboarding", false)) {
            onboardingComplete = true
        }
    }

    // MARK: - Device identity

    private fun resolveDeviceId(): String {
        prefs.getString(DEVICE_KEY, null)?.let { return it }
        val id = Ulid.newId()
        prefs.edit().putString(DEVICE_KEY, id).apply()
        return id
    }

    // MARK: - Readiness source priority (EPIC-25)

    /**
     * The dedup priority of the source that wrote a reading, for Readiness's two-source overnight-HRV
     * tie-break (plan §18: "conflicting HRV same-night -> priority source wins"). Resolved from the
     * persisted source + its devices through the shared sensor-class contract (worn sensor > phone),
     * so it never duplicates ingestion's keyword list and cannot drift from it. `0` (equal, falls to
     * the engine's deterministic `updatedAt`/`sourceId` tie-break) when nothing resolves — the honest
     * default, not a guessed winner. Called a handful of times per Readiness compute, on the
     * (serialized, off-main) derivation path.
     */
    private fun readinessSourcePriority(sourceId: String): Int {
        val source = runCatching { catalog.source(sourceId) }.getOrNull() ?: return 0
        val devices = runCatching { catalog.devices(sourceId) }.getOrNull() ?: emptyList()
        return when (sensorQuality.classId(source, devices)) {
            in WORN_SENSOR_CLASSES -> 2
            "phone_handset" -> 1
            else -> 0
        }
    }

    // Registered last, after every property above is initialized, so `shared()` can never hand a
    // caller a half-constructed environment. See [Companion.shared].
    init {
        current = this
    }

    companion object {
        /**
         * EPIC-32. The budget ledger's writes back the ≤2/day invariant, so a failed write is a fact
         * worth surfacing rather than a bare `runCatching {}` away. Nothing logged under this tag
         * names a notification's CONTENT or any health value — only the storage code of the class
         * and the storage error.
         */
        private const val TAG = "BadanNotifications"

        private const val PREFS = "badan.prefs"
        private const val DEVICE_KEY = "badan.deviceId"

        /** Sensor classes worn on the body, which outrank a phone as the source of an overnight vital
         *  — the same "watch > phone" ordering ingestion assigns for dedup, reconstructed at read time
         *  from the published `SensorQualityMap` classes rather than a stored column that could stale. */
        private val WORN_SENSOR_CLASSES = setOf("wrist_wearable", "ring_wearable", "chest_strap")
        private const val ONBOARDING_KEY = "badan.onboardingComplete"
        private const val BACKGROUND_SYNC_KEY = "badan.backgroundSyncEnabled"
        private const val ROUTE_CAPTURE_KEY = "badan.routeCaptureEnabled"
        private const val WRITER_PRIORITY_KEY = "badan.writerPriorityOverrides"
        // EPIC-26 effort-backfill request window (epoch millis); absent keys => nothing queued.
        private const val SCORE_BACKFILL_FROM_KEY = "badan.scoreBackfillFromMillis"
        private const val SCORE_BACKFILL_TO_KEY = "badan.scoreBackfillToMillis"

        @Volatile
        private var current: AppEnvironment? = null

        /**
         * The process-wide environment, for entry points that have no Activity — today that is
         * `SyncWorker` (EPIC-05).
         *
         * Why reuse rather than construct per caller: `AppEnvironment` owns two `SqliteConnection`s,
         * and each connection serializes its own writes behind a `ReentrantReadWriteLock`. Two
         * environments in one process would be two independent locks over the same files, so a
         * worker ingesting while the UI writes a log would fall through to SQLite's own contention
         * handling and surface as `SQLITE_BUSY` — intermittently, under load, and only on real
         * devices.
         *
         * `MainActivity` still constructs its environment directly; the `init` block above registers
         * whatever was built most recently, so the worker picks up the live one. An Activity
         * recreation replaces the registration and leaves the previous environment's connections
         * open, which is pre-existing behaviour (nothing has ever closed them on destroy) and is
         * harmless here: a worker holding the older reference keeps working against valid handles.
         */
        fun shared(context: Context): AppEnvironment =
            current ?: synchronized(this) {
                current ?: AppEnvironment(context.applicationContext)
            }

        /**
         * The background-sync preference without building an `AppEnvironment`. Exists for
         * `BootReceiver`, which runs on the main thread under a short deadline and must not open
         * and migrate two databases to answer one boolean.
         */
        fun isBackgroundSyncEnabledPreference(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(BACKGROUND_SYNC_KEY, true)
    }
}
