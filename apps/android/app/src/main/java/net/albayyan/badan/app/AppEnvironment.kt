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
import net.albayyan.badan.storage.Database
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.ExportJobRepository
import net.albayyan.badan.storage.repositories.InsightRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.ProfileRepository
import net.albayyan.badan.storage.repositories.ReconciliationRepository
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

    // Services
    val ingestion: IngestionPipeline =
        IngestionPipeline(measurements, catalog, reconciliation, registry, clock, deviceId)
    val baselines: BaselineEngine =
        BaselineEngine(derivation, measurements, registry, clock, deviceId)
    val insightEngine: InsightEngine =
        InsightEngine(insightsRepo, derivation, measurements, templates, registry, clock, deviceId)
    val exporter: ExportRunner =
        ExportRunner(measurements, derivation, logging, exportJobs, registry, clock, appVersion, deviceId)

    private val seedController: SeedController =
        SeedController(catalog, ingestion, logging, measurements, baselines, insightEngine, registry, clock, deviceId)

    /** The real Health Connect integration boundary (lazy: safe even when no provider is present). */
    val healthConnect: HealthConnectAdapter by lazy { HealthConnectAdapter(appContext) }

    /**
     * Pull the last 90 days from Health Connect through the same ingestion + dedup + derivation path
     * as the seed. Returns the ingest summary (may be all-zero when the user has no HC data yet).
     * Runs entirely off the main thread.
     */
    suspend fun syncHealthConnect(): IngestionPipeline.IngestSummary? = withContext(Dispatchers.IO) {
        val now = clock.now()
        val range = HealthDateRange(now - 90L * MILLIS_PER_DAY, now)
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

    /** Persist an honest granted / partial / denied Health Connect permission state for the UI. */
    fun recordHealthConnectPermissions(granted: Set<String>) {
        val required = HealthConnectAdapter.permissions
        val status = when {
            granted.containsAll(required) -> PermissionStatus.GRANTED
            granted.any { it in required } -> PermissionStatus.PARTIAL
            else -> PermissionStatus.DENIED
        }
        runCatching { catalog.upsertPermission(PermissionState("healthConnect", "health", status, clock.now())) }
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
        isReady = true
    }

    suspend fun resetDemoData() {
        isReady = false
        withContext(Dispatchers.IO) {
            runCatching { database.resetAll() }
            runCatching { seedController.seed(clock.now()) }
        }
        profile = profiles.load()
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

    private companion object {
        const val PREFS = "badan.prefs"
        const val DEVICE_KEY = "badan.deviceId"
        const val ONBOARDING_KEY = "badan.onboardingComplete"
    }
}
