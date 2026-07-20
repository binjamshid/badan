package net.albayyan.badan.app

import android.content.Context
import android.os.Bundle
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
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.platform.health.HealthConnectAdapter
import net.albayyan.badan.platform.health.HealthDateRange
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.derivation.InsightEngine
import net.albayyan.badan.domain.ingestion.IngestionPipeline
import net.albayyan.badan.export.ExportRunner
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.ontology.SymptomDictionary
import net.albayyan.badan.platform.background.BackgroundScheduler
import net.albayyan.badan.storage.Database
import net.albayyan.badan.storage.repositories.BackgroundRunRepository
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.ExportJobRepository
import net.albayyan.badan.storage.repositories.InsightRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.ProfileRepository
import net.albayyan.badan.storage.repositories.ReadAnchorRepository
import net.albayyan.badan.storage.repositories.ReconciliationRepository
import net.albayyan.badan.storage.repositories.RouteRepository
import java.util.Calendar

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

    // Repositories
    val measurements: MeasurementRepository = MeasurementRepository(database.main)
    val derivation: DerivationRepository = DerivationRepository(database.main)
    val insightsRepo: InsightRepository = InsightRepository(database.main)
    val reconciliation: ReconciliationRepository = ReconciliationRepository(database.main)
    val catalog: CatalogRepository = CatalogRepository(database.main)
    val logging: LoggingRepository = LoggingRepository(database.main, database.sensitive)
    val exportJobs: ExportJobRepository = ExportJobRepository(database.main)
    val profiles: ProfileRepository = ProfileRepository(database.main)
    val backgroundRuns: BackgroundRunRepository = BackgroundRunRepository(database.main)
    val routes: RouteRepository = RouteRepository(database.main)
    val readAnchors: ReadAnchorRepository = ReadAnchorRepository(database.main)

    // Services
    val ingestion: IngestionPipeline =
        IngestionPipeline(measurements, catalog, reconciliation, registry, clock, deviceId, routes)
    val baselines: BaselineEngine =
        BaselineEngine(derivation, measurements, registry, clock, deviceId)
    val insightEngine: InsightEngine =
        InsightEngine(insightsRepo, derivation, measurements, templates, registry, clock, deviceId)
    val exporter: ExportRunner =
        ExportRunner(measurements, derivation, logging, exportJobs, registry, clock, appVersion, deviceId)

    private val seedController: SeedController =
        SeedController(catalog, ingestion, logging, measurements, baselines, insightEngine, registry,
            clock, deviceId, prefs)

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
                baselines.recomputeAll(now)
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

    // Registered last, after every property above is initialized, so `shared()` can never hand a
    // caller a half-constructed environment. See [Companion.shared].
    init {
        current = this
    }

    companion object {
        private const val PREFS = "badan.prefs"
        private const val DEVICE_KEY = "badan.deviceId"
        private const val ONBOARDING_KEY = "badan.onboardingComplete"
        private const val BACKGROUND_SYNC_KEY = "badan.backgroundSyncEnabled"
        private const val ROUTE_CAPTURE_KEY = "badan.routeCaptureEnabled"
        private const val WRITER_PRIORITY_KEY = "badan.writerPriorityOverrides"

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
