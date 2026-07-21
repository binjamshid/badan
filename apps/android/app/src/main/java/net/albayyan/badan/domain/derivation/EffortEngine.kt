package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.EffortParams
import net.albayyan.badan.domain.HRZoneModel
import net.albayyan.badan.domain.HRZones
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.UserProfile
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.exp

/**
 * EPIC-26 — the cardiovascular Effort engine (WHOOP "strain"-equivalent). It answers "how much
 * cardiovascular load did today (or this workout) actually carry?" as a single score on the published
 * BADAN curve, a transparency differentiator against WHOOP's black box: every score ships with a
 * published formula (`docs/algorithms/effort.md`), a versioned [AlgorithmVersion], an [InputManifest]
 * (here, the minutes spent in each zone — which is what the zone-time bars render), and a provisional
 * flag. Mirror of iOS `EffortEngine`.
 *
 * **The model:** minutes are attributed to five HR zones (from the person's own HR max, or their
 * stored [HRZones] override), weighted by intensity, summed into a weighted-minutes load `L`, and
 * mapped through `score = scaleMax · (1 − e^(−k·L))` — **monotonic** and **diminishing**, the
 * WHOOP-familiar shape, asserted as a property test on both platforms. Every constant is DATA in
 * `algorithms.json` ([EffortSpec]), never a literal here, so the two platforms cannot drift.
 *
 * **Two honesty guards:** a phone-only user with no continuous HR gets a distinctly-labelled
 * steps/energy **activity load** under the same `effort.day` id (with an activity unit, not
 * `score_0_100`), never a shaming zero; and the age-derived HR max (real ±10–12 bpm uncertainty) is
 * used only to WEIGHT a provisional, directional score, always overridable by the user's own values.
 *
 * Everything is append-only and driven by an injected [Clock] (INVARIANT I2): editing HR max triggers
 * a historical recompute that APPENDS fresh rows; superseded rows keep their `computedAt`, value and
 * algorithm id. The pure math ([accumulate], [effortScore]) is static so it is byte-identical to iOS.
 *
 * **Declared context (EPIC-29, plan §18) reaches effort as COPY only, and this engine holds no
 * resolver.** A `ContextStatus` may do exactly two things to a derived result: cap its confidence
 * and add a caveat sentence. Effort rows store `confidence = null` — there is no completeness or
 * maturity model behind an effort score in v1; the row's honesty lives in its `provisional` flag
 * and, for the phone-only path, in its unit. There is therefore nothing here for a ceiling to cap,
 * and wiring a `ContextAnnotationResolver` in would be a call whose result is discarded by
 * construction. The caveat still reaches the reader: the effort surfaces resolve it at display time
 * through `ContextCaveats`, exactly as they do for readiness and sleep. If `effort.day` ever gains a
 * real confidence, the resolver belongs here and this paragraph should be deleted in the same change.
 */
class EffortEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: EffortSpec = EffortSpec.default(),
    /**
     * The person's profile (HR max + zone override + birth year). Read via a lambda rather than a
     * stored [UserProfile] so a mid-session HR-max edit is picked up on the next recompute without the
     * engine caching a stale copy. The engine READS the profile and never writes it.
     */
    private val profileProvider: () -> UserProfile? = { null },
) {
    /** Frozen day/workout identities, resolved from the contract. */
    val dayAlgorithm: AlgorithmVersion get() = spec.dayAlgorithm
    val workoutAlgorithm: AlgorithmVersion get() = spec.workoutAlgorithm

    // MARK: - Day effort (trigger point + intraday recompute)

    /**
     * Compute the Effort score for the local day containing [asOf] and APPEND it. Returns the rich
     * result (anatomy sheet, zone-time bars, tests) or null when the day cannot be scored at all — the
     * spec did not load, or there is neither usable HR nor any activity to report (a genuine gap).
     * Missing days are gaps, never zeros. A later call over changed data appends a fresh row (I2); the
     * write is skipped only when an identical row already exists.
     */
    fun computeDay(asOf: Long, tz: String = TimeZone.getDefault().id): EffortResult? {
        if (!spec.isLoaded) return null
        val dayKey = DayAttribution.localDayKey(asOf, tz)
        val dayStart = DayAttribution.startOfDay(asOf, tz)
        val dayEnd = DayAttribution.addingDays(1, dayStart, tz)

        val profile = profileProvider()
        val model = HRZoneModel.resolve(profile?.hrZones, profile?.hrMax, age(profile, asOf, tz), spec.params)

        if (model != null) {
            val samples = hrSamples(dayStart, dayEnd)
            val acc = accumulate(samples, dayEnd / 1000.0, model, spec.params)
            // "Usable HR" = at least one full continuous-sampling interval's worth of attributable
            // time. Phone-only users have 0 (no `heart.hr`); a watch worn during any activity — or even
            // passively all day — clears it and scores a low-but-real effort rather than reduced-input.
            if (acc.coveredSeconds >= spec.params.maxAttributableGapSeconds) {
                val score = effortScore(acc.load, spec.params)
                val result = EffortResult("day:$dayKey", EffortVariant.ZoneBased(acc), score)
                persistZoneBased(result, MetricId.effortDay, dayAlgorithm)
                return result
            }
        }

        val reason = if (model == null) EffortReducedReason.NO_HEART_RATE_MAX else EffortReducedReason.SPARSE_HEART_RATE
        return computeReducedInput(dayKey, dayStart, dayEnd, reason)
    }

    /**
     * The reduced-input activity load for a day with no zone-based score. Built from the day's own
     * active energy (preferred) or, absent that, steps. Emitted under `effort.day` but with the
     * ACTIVITY metric's unit, so a reader distinguishes it from a `score_0_100` row, and never a
     * fabricated 0–100 number (steps carry no intensity — dressing them as a score would be false
     * precision). Null when there is no activity either — an honest gap.
     */
    private fun computeReducedInput(dayKey: String, dayStart: Long, dayEnd: Long, reason: EffortReducedReason): EffortResult? {
        val energy = sumIntervals(MetricId.activeEnergy, dayStart, dayEnd, dayKey)
        val load: ActivityLoad = if (energy != null && energy.first > 0) {
            ActivityLoad(ActivityLoadKind.ACTIVE_ENERGY, energy.first,
                registry.definitionOrFallback(MetricId.activeEnergy).canonicalUnit, energy.second)
        } else {
            val steps = sumIntervals(MetricId.steps, dayStart, dayEnd, dayKey)
            if (steps != null && steps.first > 0) {
                ActivityLoad(ActivityLoadKind.STEPS, steps.first,
                    registry.definitionOrFallback(MetricId.steps).canonicalUnit, steps.second)
            } else {
                return null
            }
        }
        val result = EffortResult("day:$dayKey", EffortVariant.ReducedInput(load, reason), null)
        persistReducedInput(result, load, MetricId.effortDay, dayAlgorithm)
        return result
    }

    // MARK: - Workout effort

    /**
     * Compute effort for every workout session overlapping [from]..[to] and append a row per session
     * (keyed `session:<id>`). A session with continuous HR gets a zone-based score over its own window;
     * one whose watch did not record HR gets the labelled activity load from its energy total.
     */
    fun computeWorkouts(from: Long, to: Long, tz: String = TimeZone.getDefault().id): List<EffortResult> {
        if (!spec.isLoaded) return emptyList()
        val profile = profileProvider()
        val results = ArrayList<EffortResult>()
        for (session in measurements.sessions(SessionKind.WORKOUT, from, to)) {
            computeWorkout(session, profile, tz)?.let { results.add(it) }
        }
        return results
    }

    private fun computeWorkout(session: Session, profile: UserProfile?, tz: String): EffortResult? {
        val periodKey = "session:${session.id}"
        val model = HRZoneModel.resolve(profile?.hrZones, profile?.hrMax, age(profile, session.startAt, tz), spec.params)
        val duration = session.durationSeconds
        if (model != null && duration > 0) {
            val samples = hrSamples(session.startAt, session.endAt)
            val density = hrDensityPerMinute(samples.size, duration)
            if (density >= spec.params.sparseHrMinSamplesPerMinute) {
                val acc = accumulate(samples, session.endAt / 1000.0, model, spec.params)
                val score = effortScore(acc.load, spec.params)
                val result = EffortResult(periodKey, EffortVariant.ZoneBased(acc), score)
                persistZoneBased(result, MetricId.effortWorkout, workoutAlgorithm)
                return result
            }
        }

        val reason = if (model == null) EffortReducedReason.NO_HEART_RATE_MAX else EffortReducedReason.SPARSE_HEART_RATE
        val kj = session.detail.workout?.totals?.energyKj ?: return null
        if (kj <= 0) return null
        val load = ActivityLoad(ActivityLoadKind.ACTIVE_ENERGY, kj, "kJ", listOf(session.id))
        val result = EffortResult(periodKey, EffortVariant.ReducedInput(load, reason), null)
        persistReducedInput(result, load, MetricId.effortWorkout, workoutAlgorithm)
        return result
    }

    // MARK: - Historical backfill (HR-max edit → append + supersede, I2)

    /**
     * Recompute day and workout effort across [from]..[to] and append the results — the entry point the
     * composition lane wires to a checkpointed background job when the user edits their HR max or
     * zones. Because every score is a function of those zones, the whole window is re-derived; because
     * derivation is append-only (I2), that is a plain re-run, not a mutating path. Each changed
     * day/session APPENDS a fresh row; superseded rows keep their `computedAt`, value and algorithm id.
     * Idempotent over unchanged data. Returns the number of days/sessions touched.
     */
    fun recompute(from: Long, to: Long, tz: String = TimeZone.getDefault().id): Int {
        if (!spec.isLoaded) return 0
        var touched = 0
        var day = DayAttribution.startOfDay(from, tz)
        val lastDayStart = DayAttribution.startOfDay(to, tz)
        while (day <= lastDayStart) {
            if (computeDay(day, tz) != null) touched += 1
            day = DayAttribution.addingDays(1, day, tz)
        }
        touched += computeWorkouts(from, to, tz).size
        return touched
    }

    // MARK: - Guidance (readiness-linked, wellness-safe read model)

    /**
     * A wellness-safe daily guidance read model, linked to Readiness. NOT prescriptive and NOT stored:
     * it reads the day's `readiness.score` and returns a DIRECTION plus, when available, a PERSONAL
     * soft ceiling from the user's OWN effort baseline (never a population number). The UI lane owns the
     * bilingual, copy-linted strings; this only supplies the band and the optional number. Null when
     * there is no Readiness score to anchor to.
     */
    fun guidance(asOf: Long, tz: String = TimeZone.getDefault().id): EffortGuidance? {
        val dayKey = DayAttribution.localDayKey(asOf, tz)
        val readiness = derivation.latestDerived(MetricId.readinessScore, "day:$dayKey") ?: return null
        val band = guidanceBand(readiness.value)
        var suggestedCeiling: Double? = null
        if (band == EffortGuidanceBand.GENTLER) {
            val baseline = derivation.latestBaseline(MetricId.effortDay)
            if (baseline != null && !baseline.provisional) suggestedCeiling = baseline.center
        }
        return EffortGuidance(band, readiness.value, readiness.provisional, suggestedCeiling)
    }

    // MARK: - Persistence (append-only, I2)

    private fun persistZoneBased(result: EffortResult, metricId: String, algorithm: AlgorithmVersion) {
        val acc = (result.variant as? EffortVariant.ZoneBased)?.accumulation ?: return
        val score = result.score ?: return
        val unit = registry.definitionOrFallback(metricId).canonicalUnit
        // The algorithm identity is part of the skip check: a version bump that recomputes the same
        // score must still append, or the day's latest row would keep the OLD version id and the
        // change would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        val existing = derivation.latestDerived(metricId, result.periodKey)
        if (existing != null && existing.algorithmId == algorithm.algorithmId &&
            existing.algorithmVersion == algorithm.semver &&
            existing.unit == unit && existing.provisional == spec.params.algorithmProvisional &&
            approximatelyEqual(existing.value, score)
        ) {
            return
        }
        // One manifest input PER ZONE: `value` = minutes in that zone (the zone-time bars read this),
        // `weight` = that zone's weighted-minutes contribution to `L`. `recordId` is a zone token, not a
        // raw-row id, because an effort score aggregates a whole `heart.hr` series (I1/I5).
        val manifest = InputManifest(
            id = Ulid.newId(),
            inputs = acc.minutesPerZone.mapIndexed { i, minutes ->
                InputManifest.Input(recordId = "${result.periodKey}#zone${i + 1}", metricId = MetricId.heartRate,
                    value = minutes, weight = minutes * spec.params.zoneWeights[i])
            },
        )
        derivation.insertManifest(manifest)
        val now = clock.now()
        derivation.appendDerived(
            DerivedValue(
                id = Ulid.newId(), metricId = metricId, value = score, unit = unit,
                periodKey = result.periodKey, confidence = null, provisional = spec.params.algorithmProvisional,
                algorithmId = algorithm.algorithmId, algorithmVersion = algorithm.semver,
                inputManifestId = manifest.id, computedAt = now, updatedAt = now, originDeviceId = deviceId,
            ),
        )
    }

    private fun persistReducedInput(result: EffortResult, load: ActivityLoad, metricId: String, algorithm: AlgorithmVersion) {
        // Same version-aware skip as the zone-based path: a version bump appends even when the
        // reduced-input magnitude is unchanged, so the row's version id never lags the algorithm.
        val existing = derivation.latestDerived(metricId, result.periodKey)
        if (existing != null && existing.algorithmId == algorithm.algorithmId &&
            existing.algorithmVersion == algorithm.semver &&
            existing.unit == load.unit && approximatelyEqual(existing.value, load.magnitude)
        ) {
            return
        }
        val manifest = InputManifest(
            id = Ulid.newId(),
            inputs = load.recordIds.map { InputManifest.Input(recordId = it, metricId = load.kind.metricId, value = load.magnitude) },
        )
        derivation.insertManifest(manifest)
        val now = clock.now()
        // `provisional = true` always — a reduced-input activity load is not the validated zone score;
        // its activity unit (not `score_0_100`) is how the surface labels it.
        derivation.appendDerived(
            DerivedValue(
                id = Ulid.newId(), metricId = metricId, value = load.magnitude, unit = load.unit,
                periodKey = result.periodKey, confidence = null, provisional = true,
                algorithmId = algorithm.algorithmId, algorithmVersion = algorithm.semver,
                inputManifestId = manifest.id, computedAt = now, updatedAt = now, originDeviceId = deviceId,
            ),
        )
    }

    // MARK: - Input readers

    /** Heart-rate samples in [from]..[to] as `(seconds, bpm)` ordered by time. Non-positive readings dropped. */
    private fun hrSamples(from: Long, to: Long): List<HrSample> =
        measurements.rawSamples(MetricId.heartRate, from, to)
            .filter { it.value.isFinite() && it.value > 0 }
            .map { HrSample(it.startAt / 1000.0, it.value) }

    /** Sum an interval metric's values for a local day, with contributing record ids. Null when nothing landed. */
    private fun sumIntervals(metricId: String, from: Long, to: Long, dayKey: String): Pair<Double, List<String>>? {
        val records = measurements.intervalRecords(metricId, from, to)
            .filter { DayAttribution.localDayKey(it.startAt, it.tzId) == dayKey }
        if (records.isEmpty()) return null
        return records.sumOf { it.value } to records.map { it.id }
    }

    /** Age in whole years at [asOf] from `birthYear`, or null when no birth year is recorded. */
    private fun age(profile: UserProfile?, asOf: Long, tz: String): Int? {
        val birthYear = profile?.birthYear ?: return null
        val cal = Calendar.getInstance(TimeZone.getTimeZone(tz))
        cal.timeInMillis = asOf
        val age = cal.get(Calendar.YEAR) - birthYear
        return if (age > 0) age else null
    }

    companion object {
        // MARK: - Pure math (identical on both platforms — golden + property tested)

        /**
         * The published BADAN effort curve: `scaleMax · (1 − e^(−k · L))` over weighted-minutes load
         * `L`. Bounded by `scaleMax`, strictly increasing in `L` and concave (each extra weighted-minute
         * adds less — WHOOP's "harder at the top" shape). Both properties are asserted as property tests.
         */
        fun effortScore(load: Double, params: EffortParams): Double {
            val l = maxOf(0.0, load)
            return params.scaleMax * (1 - exp(-params.logCurveK * l))
        }

        /**
         * Weighted-minutes load `L = Σ (minutes-in-zone · zoneWeight)`. Zone 0 (below Z1) contributes
         * nothing. Strictly monotonic: adding minutes to any zone, or moving a minute to a higher zone,
         * only ever raises `L`.
         */
        fun weightedZoneMinutes(minutesPerZone: List<Double>, zoneWeights: List<Double>): Double {
            var total = 0.0
            for (i in 0 until minOf(minutesPerZone.size, zoneWeights.size)) total += minutesPerZone[i] * zoneWeights[i]
            return total
        }

        /**
         * Attribute HR samples to zones and accumulate the load. Each sample "holds forward" until the
         * next sample or the window end, but a gap longer than `maxAttributableGapSeconds` is clamped —
         * a recording dropout is not credited as time in a zone. Pure and deterministic; identical to
         * iOS (the acceptance golden).
         */
        fun accumulate(samples: List<HrSample>, windowEnd: Double, model: HRZoneModel, params: EffortParams): ZoneAccumulation {
            val ordered = samples.sortedBy { it.t }
            val minutesPerZone = DoubleArray(HRZones.ZONE_COUNT)
            var coveredSeconds = 0.0
            for (i in ordered.indices) {
                val nextInstant = if (i + 1 < ordered.size) ordered[i + 1].t else windowEnd
                val dwell = minOf(maxOf(nextInstant - ordered[i].t, 0.0), params.maxAttributableGapSeconds)
                if (dwell <= 0.0) continue
                coveredSeconds += dwell
                val zone = model.zoneIndex(ordered[i].bpm)
                if (zone in 1..HRZones.ZONE_COUNT) minutesPerZone[zone - 1] += dwell / 60.0
            }
            val load = weightedZoneMinutes(minutesPerZone.toList(), params.zoneWeights)
            return ZoneAccumulation(load, coveredSeconds, minutesPerZone.toList(), ordered.size)
        }

        /** Heart-rate sample density in samples per minute — the sparse-HR gate for workouts. */
        fun hrDensityPerMinute(sampleCount: Int, windowSeconds: Double): Double {
            if (windowSeconds <= 0) return 0.0
            return sampleCount.toDouble() / (windowSeconds / 60.0)
        }

        /**
         * Map a 0–100 Readiness score to a directional guidance band by even thirds — a coarse
         * presentation split that makes no physiological claim (the reasoning `WorkoutEffortBands` uses
         * for its even quarters). `GENTLER` = lowest third; `HEADROOM` = highest; `TYPICAL` otherwise.
         */
        fun guidanceBand(readiness: Double): EffortGuidanceBand {
            if (readiness < 100.0 / 3.0) return EffortGuidanceBand.GENTLER
            if (readiness >= 200.0 / 3.0) return EffortGuidanceBand.HEADROOM
            return EffortGuidanceBand.TYPICAL
        }

        fun approximatelyEqual(a: Double, b: Double, tolerance: Double = 1e-9): Boolean = abs(a - b) < tolerance
    }
}

// MARK: - Read models

/** A `(seconds, bpm)` heart-rate sample fed to the pure [EffortEngine.accumulate]. */
data class HrSample(val t: Double, val bpm: Double)

/**
 * The pure zone accumulation for a window: the weighted-minutes [load] the curve consumes, how many
 * [coveredSeconds] of HR were attributed (the reduced-input gate reads this), the per-zone minutes
 * (Z1…Z5 → indices 0…4), and the raw sample count. No I/O or clock — byte-identical to iOS.
 */
data class ZoneAccumulation(
    val load: Double,
    val coveredSeconds: Double,
    val minutesPerZone: List<Double>,
    val sampleCount: Int,
)

/** Why a day/session produced the reduced-input activity variant instead of a zone-based score. */
enum class EffortReducedReason { SPARSE_HEART_RATE, NO_HEART_RATE_MAX }

/** What kind of movement magnitude the reduced-input activity load is measured in. */
enum class ActivityLoadKind(val metricId: String) {
    ACTIVE_ENERGY(MetricId.activeEnergy),
    STEPS(MetricId.steps),
}

/**
 * The reduced-input activity load: a truthful raw movement magnitude (not a fabricated 0–100 score),
 * its unit, and the record ids that fed it. Persisted under the effort id but with THIS unit, which is
 * how a reader tells a reduced-input row from a zone-based `score_0_100` one.
 */
data class ActivityLoad(
    val kind: ActivityLoadKind,
    val magnitude: Double,
    val unit: String,
    val recordIds: List<String>,
)

/**
 * Which model produced a period's effort. [ZoneBased] carries the full zone accumulation; [ReducedInput]
 * carries the activity load and the reason, so the surface labels the degradation DISTINCTLY.
 */
sealed interface EffortVariant {
    data class ZoneBased(val accumulation: ZoneAccumulation) : EffortVariant
    data class ReducedInput(val load: ActivityLoad, val reason: EffortReducedReason) : EffortVariant
}

/**
 * A computed effort result for one period (a day `day:<key>` or a session `session:<id>`): the variant
 * and the 0–`scaleMax` [score] for zone-based results (null for reduced-input, which has a magnitude).
 */
data class EffortResult(
    val periodKey: String,
    val variant: EffortVariant,
    val score: Double?,
)

/** The directional readiness→effort guidance band. Never a command — a suggestion of range. */
enum class EffortGuidanceBand { GENTLER, TYPICAL, HEADROOM }

/**
 * The wellness-safe guidance read model. [readinessBand] is the direction; [suggestedCeiling] is an
 * OPTIONAL personal number (the user's own effort-baseline centre) offered only on a gentler day with
 * an established baseline. The UI lane turns this into copy; the engine never authors user-facing strings.
 */
data class EffortGuidance(
    val readinessBand: EffortGuidanceBand,
    val readinessScore: Double,
    val readinessProvisional: Boolean,
    val suggestedCeiling: Double?,
)

// MARK: - Spec (data-driven params, mirror of ReadinessSpec/BaselineSpec)

/**
 * The data-driven Effort spec: the ONLY place the scale, zone weights, curve steepness, zone floors,
 * HR-max default and sparse threshold enter the engine — never hardcoded — so the two platforms cannot
 * drift. Resolves `effort.day` (scale, weights, curve, floors, Tanaka constants) and `effort.workout`
 * (the sparse threshold; its scale/curve MUST match `effort.day`'s, asserted by a golden). A spec that
 * failed to load ([isLoaded] == false) makes the engine COMPUTE NOTHING (mirror of [ReadinessSpec]).
 */
data class EffortSpec(
    val dayAlgorithm: AlgorithmVersion,
    val workoutAlgorithm: AlgorithmVersion,
    val params: EffortParams,
    val isLoaded: Boolean,
) {
    companion object {
        private const val DAY_CONTRACT_ID = "effort.day"
        private const val WORKOUT_CONTRACT_ID = "effort.workout"

        /** Resolve from a loaded [AlgorithmRegistry]. Returns [unavailable] if either entry or any required param is missing. */
        fun load(registry: AlgorithmRegistry): EffortSpec {
            val day = registry.definition(DAY_CONTRACT_ID) ?: return unavailable
            val workout = registry.definition(WORKOUT_CONTRACT_ID) ?: return unavailable
            val scaleMax = day.params["scaleMax"] ?: return unavailable
            val k = day.params["logCurveK"] ?: return unavailable
            val hrMaxConstant = day.params["hrMaxConstant"] ?: return unavailable
            val hrMaxAgeCoefficient = day.params["hrMaxAgeCoefficient"] ?: return unavailable
            val sparse = workout.params["sparseHrFallbackMinSamplesPerMinute"] ?: return unavailable
            val weights = ArrayList<Double>(HRZones.ZONE_COUNT)
            val floors = ArrayList<Double>(HRZones.ZONE_COUNT)
            for (z in 1..HRZones.ZONE_COUNT) {
                val w = day.params["zone${z}Weight"] ?: return unavailable
                val f = day.params["zone${z}FloorPctHrMax"] ?: return unavailable
                weights.add(w)
                floors.add(f)
            }
            val params = EffortParams(
                scaleMax = scaleMax, zoneWeights = weights, logCurveK = k, zoneFloorPcts = floors,
                hrMaxConstant = hrMaxConstant, hrMaxAgeCoefficient = hrMaxAgeCoefficient,
                sparseHrMinSamplesPerMinute = sparse, algorithmProvisional = day.provisional,
            )
            return EffortSpec(day.algorithmVersion, workout.algorithmVersion, params, isLoaded = true)
        }

        /** The app-default spec, resolved once from the classpath contract mirror (same route as the pure goldens). */
        fun default(): EffortSpec = cachedDefault

        private val cachedDefault: EffortSpec by lazy { load(AlgorithmRegistry.fromClasspath()) }

        /** The degenerate "the contract did not load" spec. Never produces a score. */
        val unavailable = EffortSpec(
            dayAlgorithm = AlgorithmVersion(algorithmId = DAY_CONTRACT_ID, semver = "0.0.0", introducedIn = "0.0.0"),
            workoutAlgorithm = AlgorithmVersion(algorithmId = WORKOUT_CONTRACT_ID, semver = "0.0.0", introducedIn = "0.0.0"),
            params = EffortParams(
                scaleMax = 0.0, zoneWeights = emptyList(), logCurveK = 0.0, zoneFloorPcts = emptyList(),
                hrMaxConstant = 0.0, hrMaxAgeCoefficient = 0.0, sparseHrMinSamplesPerMinute = 0.0,
                algorithmProvisional = true,
            ),
            isLoaded = false,
        )
    }
}
