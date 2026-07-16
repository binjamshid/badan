package net.albayyan.badan.app

import android.content.SharedPreferences
import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.MILLIS_PER_DAY
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.domain.MedicationRegimen
import net.albayyan.badan.domain.MedicationSchedule
import net.albayyan.badan.domain.NoteEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.SkipReason
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.UserProfile
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.derivation.InsightEngine
import net.albayyan.badan.domain.ingestion.IngestionPipeline
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.platform.health.FakeHealthStore
import net.albayyan.badan.platform.health.HealthDateRange
import net.albayyan.badan.storage.Database
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.TimeZone

/**
 * Makes BADAN runnable and inspectable immediately: on first launch it ingests a deterministic
 * 90-day health history from the [FakeHealthStore] (exercising the real ingestion + dedup path),
 * seeds a handful of manual logs, and computes baselines + insights. Idempotent by presence of
 * sources; Settings' "Delete all data" calls [seed] after a wipe. Faithful port of the iOS
 * `SeedController`. Timestamps are epoch millis; iOS second-offsets are multiplied to millis.
 *
 * Everything it writes is fabricated, so it owns the flag that says so ([isDemoDataActive]) and
 * the two ways that flag is cleared: a real connect (see `AppEnvironment.connectHealthConnect`)
 * and [markStartEmpty].
 */
class SeedController(
    private val catalog: CatalogRepository,
    private val ingestion: IngestionPipeline,
    private val logging: LoggingRepository,
    private val measurements: MeasurementRepository,
    private val baselines: BaselineEngine,
    private val insightEngine: InsightEngine,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
    /**
     * Where the sample-data lifecycle flags live. Needed because "is the user currently looking
     * at fabricated data?" cannot be answered from the database: a seeded row and a real row are
     * the same shape, and `sources` being non-empty says only that SOMETHING was ingested.
     */
    private val prefs: SharedPreferences,
) {
    fun seedIfNeeded(nowMillis: Long) {
        if (catalog.sources().isNotEmpty()) return
        seed(nowMillis)
    }

    /**
     * True while the bundled sample dataset is what the user is looking at — drives
     * `SampleDataBanner` and the Export Center's sample notice.
     *
     * Mirrors iOS's `SeedController.isDemoDataActive`. Android had no such signal at all, which
     * is the root of its honesty gap: with no way to ask the question, every screen presented
     * fabricated readings exactly as it would present the user's own.
     */
    val isDemoDataActive: Boolean
        get() = prefs.getBoolean(DEMO_SEED_ACTIVE_KEY, false)

    fun seed(nowMillis: Long) {
        // Set FIRST, so a crash midway through a long seed still leaves the banner on: the
        // failure mode to avoid is unlabelled fabricated data, and a partial seed is still
        // fabricated data.
        prefs.edit().putBoolean(DEMO_SEED_ACTIVE_KEY, true).apply()
        seedInternal(nowMillis)
    }

    private fun seedInternal(nowMillis: Long) {
        // Resolved fresh on every call (not cached at construction) so a device timezone change
        // before "Settings -> Reset demo data" is honored rather than reseeding under a stale zone.
        val tz = TimeZone.getDefault().id

        // 1. Ingest 90 days of device data (sources/devices, samples, intervals, sessions, dedup).
        val store = FakeHealthStore(clock, 90, tz)
        val range = HealthDateRange(start = nowMillis - 90L * MILLIS_PER_DAY, end = nowMillis)
        ingestion.ingest(store, range)

        // 2. User profile (height for BMI context).
        catalog.saveUserProfile(
            UserProfile(
                id = Ulid.newId(), displayName = null, heightMeters = 1.75,
                birthYear = 1990, createdAt = nowMillis, updatedAt = nowMillis,
            ),
        )

        // 3. Manual logs.
        seedMedications(nowMillis, tz)
        seedSymptoms(nowMillis, tz)
        seedWorkouts(nowMillis, tz)
        seedNutrition(nowMillis, tz)
        logging.upsertNote(
            NoteEntry(
                id = Ulid.newId(),
                text = "Felt a bit run down midweek; slept early to catch up.",
                occurredAt = nowMillis - 2L * MILLIS_PER_DAY, tzId = tz,
                updatedAt = nowMillis, originDeviceId = deviceId,
            ),
        )

        // 4. Derivations + insights.
        baselines.recomputeAll(nowMillis)
        for (dayOffset in 0 until 4) {
            runCatching { insightEngine.generate(nowMillis - dayOffset.toLong() * MILLIS_PER_DAY, tz) }
        }
    }

    // MARK: - Manual log seeds

    /** [daysAgo] full days before [now], nudged by [offsetMillis] so entries land at a stable
     *  time-of-day within that local day rather than exactly on the day boundary. All units are
     *  epoch millis — named so a future edit can't silently swap in a seconds-scale offset. */
    private fun ago(daysAgo: Int, now: Long, offsetMillis: Long = 0L): Long =
        now - daysAgo.toLong() * MILLIS_PER_DAY + offsetMillis

    private fun seedMedications(now: Long, tz: String) {
        val vitD = MedicationRegimen(
            id = Ulid.newId(), name = "Vitamin D", strength = "1000 IU", form = "capsule",
            schedule = MedicationSchedule.Daily(listOf("09:00")),
            startedAt = now - 60L * MILLIS_PER_DAY, updatedAt = now, originDeviceId = deviceId,
        )
        val mag = MedicationRegimen(
            id = Ulid.newId(), name = "Magnesium", strength = "200 mg", form = "tablet",
            schedule = MedicationSchedule.Daily(listOf("21:00")),
            startedAt = now - 30L * MILLIS_PER_DAY, updatedAt = now, originDeviceId = deviceId,
        )
        logging.upsertRegimen(vitD)
        logging.upsertRegimen(mag)

        // A week of adherence: mostly taken, one honest skip (no guilt).
        for (day in 0 until 7) {
            val base = now - day.toLong() * MILLIS_PER_DAY
            logging.insertAdherence(
                AdherenceEvent(
                    id = Ulid.newId(), regimenId = vitD.id, kind = AdherenceKind.TAKEN,
                    scheduledFor = base, occurredAt = base + 600_000L, tzId = tz,
                    updatedAt = now, originDeviceId = deviceId,
                ),
            )
            if (day == 3) {
                logging.insertAdherence(
                    AdherenceEvent(
                        id = Ulid.newId(), regimenId = mag.id, kind = AdherenceKind.SKIPPED,
                        scheduledFor = base, occurredAt = base, tzId = tz,
                        skipReason = SkipReason.FORGOT, updatedAt = now, originDeviceId = deviceId,
                    ),
                )
            } else {
                logging.insertAdherence(
                    AdherenceEvent(
                        id = Ulid.newId(), regimenId = mag.id, kind = AdherenceKind.TAKEN,
                        scheduledFor = base, occurredAt = base + 300_000L, tzId = tz,
                        updatedAt = now, originDeviceId = deviceId,
                    ),
                )
            }
        }
    }

    private fun seedSymptoms(now: Long, tz: String) {
        // (symptomId, severity, daysAgo)
        val samples = listOf(
            SymptomSeed("headache", 4, 1),
            SymptomSeed("fatigue", 6, 3),
            SymptomSeed("poor_sleep", 5, 4),
            SymptomSeed("muscle_ache", 3, 5),
            SymptomSeed("nasal_congestion", 4, 8),
        )
        for (s in samples) {
            logging.insertSymptom(
                SymptomEntry(
                    id = Ulid.newId(), symptomId = s.id, severity = s.severity,
                    occurredAt = ago(s.daysAgo, now, offsetMillis = 40_000_000L),
                    tzId = tz, updatedAt = now, originDeviceId = deviceId,
                ),
            )
        }
    }

    private fun seedWorkouts(now: Long, tz: String) {
        // (type, minutes, daysAgo, kcal, rpe)
        val items = listOf(
            WorkoutSeed("Run", 34.0, 1, 320.0, 6),
            WorkoutSeed("Strength", 48.0, 3, 260.0, 7),
            WorkoutSeed("Walk", 52.0, 4, 180.0, 3),
        )
        for (w in items) {
            val start = ago(w.daysAgo, now, offsetMillis = 30_000_000L)
            logging.upsertWorkout(
                WorkoutEntry(
                    id = Ulid.newId(), activityType = w.type, startAt = start,
                    endAt = start + Math.round(w.minutes * 60.0 * 1000.0), tzId = tz,
                    energyKcal = w.kcal, distanceM = if (w.type == "Run") 5200.0 else null,
                    avgHr = if (w.type == "Run") 148.0 else 120.0, perceivedEffort = w.rpe,
                    updatedAt = now, originDeviceId = deviceId,
                ),
            )
        }
    }

    private fun seedNutrition(now: Long, tz: String) {
        // (description, mealType, kcal, protein, hoursAgo)
        val meals = listOf(
            MealSeed("Oats with yogurt and dates", MealType.BREAKFAST, 420.0, 18.0, 6),
            MealSeed("Grilled chicken and rice", MealType.LUNCH, 640.0, 45.0, 2),
            MealSeed("Coffee", MealType.DRINK, 5.0, 0.0, 7),
        )
        for (m in meals) {
            logging.upsertNutrition(
                NutritionEntry(
                    id = Ulid.newId(), description = m.desc, mealType = m.type,
                    energyKcal = m.kcal, proteinG = m.protein,
                    occurredAt = now - m.hoursAgo.toLong() * 3_600_000L,
                    tzId = tz, updatedAt = now, originDeviceId = deviceId,
                ),
            )
        }
        // Water intake for today.
        logging.upsertNutrition(
            NutritionEntry(
                id = Ulid.newId(), description = "Water", mealType = MealType.DRINK,
                waterMl = 1500.0, occurredAt = now - 3_600_000L,
                tzId = tz, updatedAt = now, originDeviceId = deviceId,
            ),
        )
    }

    private data class SymptomSeed(val id: String, val severity: Int, val daysAgo: Int)
    private data class WorkoutSeed(
        val type: String,
        val minutes: Double,
        val daysAgo: Int,
        val kcal: Double,
        val rpe: Int,
    )
    private data class MealSeed(
        val desc: String,
        val type: MealType,
        val kcal: Double,
        val protein: Double,
        val hoursAgo: Int,
    )

    companion object {
        /**
         * Set while the bundled sample dataset is live; cleared by a real connect or
         * [markStartEmpty]. Mirrors iOS's `demoSeedActiveKey`.
         */
        const val DEMO_SEED_ACTIVE_KEY = "badan.demoSeedActive"

        /**
         * The "Start empty" onboarding fork: throw away whatever bootstrap already seeded before
         * onboarding could ask, and record that the user's store is deliberately empty rather
         * than not-yet-seeded.
         *
         * Uses the same purge primitives the real-connect path uses, so a device that starts
         * empty and one that starts empty via a connect end up in the identical state. Mirror of
         * iOS's `SeedController.markStartEmpty`.
         */
        fun markStartEmpty(database: Database, prefs: SharedPreferences) {
            database.purgeIngestedData()
            database.purgeDemoManualLogs()
            database.purgeSensitiveNamespace()
            prefs.edit().putBoolean(DEMO_SEED_ACTIVE_KEY, false).apply()
        }
    }
}
