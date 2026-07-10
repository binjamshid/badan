package net.albayyan.badan.app

import android.content.Context
import android.os.Bundle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.SystemClock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.DepthPolicy
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

    // Live presentation state (Compose-observable).
    var profile by mutableStateOf(profiles.load())
    var isReady by mutableStateOf(false)
    var onboardingComplete by mutableStateOf(prefs.getBoolean(ONBOARDING_KEY, false))

    // MARK: - Lifecycle

    /**
     * Seed on first run (off the main thread), then flip [isReady]. The UI shows a calm loading
     * state until ready.
     */
    suspend fun bootstrap() {
        withContext(Dispatchers.IO) {
            runCatching { seedController.seedIfNeeded(clock.now()) }
        }
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
        profiles.save(profile)
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
     */
    fun applyLaunchOverrides(extras: Bundle?) {
        if (extras == null) return
        extras.getString("badan_lang")?.let { raw ->
            AppLanguage.entries.firstOrNull { it.code == raw }?.let { lang ->
                profile = profile.copy(language = lang)
            }
        }
        extras.getString("badan_depth")?.let { raw ->
            DepthPolicy.entries.firstOrNull { it.code == raw }?.let { depth ->
                profile = profile.copy(depthPolicy = depth)
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
