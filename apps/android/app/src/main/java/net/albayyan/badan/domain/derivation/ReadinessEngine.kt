package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.TimeZone
import net.albayyan.badan.domain.journal.ContextAnnotation
import net.albayyan.badan.domain.journal.ContextAnnotationResolver
import net.albayyan.badan.domain.journal.NO_CONTEXT_ANNOTATIONS

/**
 * EPIC-25 — the morning Readiness composite (`readiness.score` v2), the recovery-equivalent that
 * answers "how do your overnight signals compare with your *own* usual pattern this morning?" on a
 * 0–100 scale. It is the product's transparency differentiator against WHOOP's black box: every score
 * ships with a published formula (`docs/algorithms/readiness.md`), a versioned [AlgorithmVersion], an
 * [InputManifest] of exactly which records fed it, and a confidence flag. Mirror of iOS
 * `ReadinessEngine`.
 *
 * **Four inputs, each read against the person, never a population norm:** overnight HRV, RHR and
 * respiratory rate enter as a personal **z-position** against their EPIC-23 baselines (own median =
 * neutral 50; higher HRV favourable, higher RHR/RR not); `sleep.performance` (from the concurrent
 * `SleepIntelligenceEngine`) enters as its **own normalized value** because it already expresses last
 * night against your personal need, and is a **soft dependency** — absent, its term drops and the
 * score runs as a labelled reduced-input variant, never imputed.
 *
 * The weights (HRV 0.5, RHR 0.2, RR 0.1, sleep 0.2) are **BADAN's own launch weights, deliberately
 * not WHOOP's** — DATA in `algorithms.json` (`composite.readiness_score`) loaded identically on both
 * platforms via [ReadinessSpec], so a divergence is impossible-by-construction.
 *
 * The composite math ([composite]) is pure and static so it produces numbers byte-identical to iOS
 * from the same inputs — that cross-platform identity is the acceptance golden. Everything is
 * append-only and driven by an injected [Clock] (INVARIANT I2): a morning compute writes a fresh
 * [DerivedValue]; late overnight data appends a new row with a fresh `computedAt` while the old row
 * keeps its own algorithm id.
 */
class ReadinessEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: ReadinessSpec = ReadinessSpec.default(),
    /**
     * Source-priority resolver, mirroring the lambda `DedupLite.reconcile` already takes. When two
     * devices report the same night's HRV, the interval-record table keeps BOTH (dedup-lite only
     * reconciles *sessions*), so the engine resolves the conflict at read time by the SAME priority
     * order ingestion assigns (watch > phone), and the winning record's id is what the manifest
     * carries — the anatomy lineage shows which device fed the score. The default `{ 0 }` makes every
     * source equal (deterministic updatedAt/sourceId tie-break); the composition root injects the real
     * priority map.
     */
    private val priorityForSource: (String) -> Int = { 0 },
    /**
     * EPIC-29 (plan §18 "`ContextStatus` … annotate confidence and copy … never the stored value").
     * Resolves what the user declared over the day being scored. A FUNCTION, not a repository: the
     * statuses live in the sensitive database and this engine holds only the main one — see
     * [ContextAnnotationResolver] for why the boundary is crossed this way. Defaults to "no context
     * ever", so an engine constructed without the seam annotates nothing rather than guessing.
     */
    private val contextAnnotations: ContextAnnotationResolver = NO_CONTEXT_ANNOTATIONS,
) {
    /**
     * Frozen v2 identity, resolved from the contract. Superseding the legacy
     * `composite.readiness_score@1.0.0` (the interim MVP composite `BaselineEngine` still appends) is
     * an I2 migration, not a rewrite: this engine writes NEW rows stamped `@2.0.0`; every `@1.0.0` row
     * keeps its old id and is never touched.
     */
    val algorithm: AlgorithmVersion get() = spec.algorithm

    // MARK: - Morning compute (trigger point)

    /**
     * Compute the morning Readiness score for the local day containing [asOf] and, when scoreable,
     * APPEND it as a `readiness.score` [DerivedValue] (v2). Returns the rich result (for the anatomy
     * sheet and tests) or null when the day cannot be honestly scored — fewer than
     * `minInputsToScoreAtAll` inputs present, or the spec did not load. A later call with late data
     * recomputes and appends a fresh row (I2); the write is skipped only when an identical v2 row
     * already exists, but a v1 legacy row never blocks the first v2 write.
     */
    fun compute(asOf: Long, tz: String = TimeZone.getDefault().id): ReadinessResult? {
        if (!spec.isLoaded) return null
        val dayKey = DayAttribution.localDayKey(asOf, tz)

        val samples = resolveInputs(dayKey, asOf, tz)
        val computation = composite(samples, spec.params) ?: return null
        // The declared context for the day being scored. Resolved AFTER the composite and kept
        // BESIDE it: [ReadinessComputation] is the pure, golden-tested output and a context must not
        // be able to reach into it. See [persist] for the one thing it is allowed to touch.
        val dayStart = DayAttribution.startOfDay(asOf, tz)
        val context = contextAnnotations(dayStart, DayAttribution.addingDays(1, dayStart, tz))
        val result = ReadinessResult(dayKey, computation, context)

        persist(result)
        return result
    }

    // MARK: - Input resolution (I/O; the conflict + soft-dependency layer)

    private fun resolveInputs(dayKey: String, asOf: Long, tz: String): List<ReadinessInputSample> {
        val samples = mutableListOf<ReadinessInputSample>()
        for (slot in listOf(ReadinessInput.HRV, ReadinessInput.RHR, ReadinessInput.RESPIRATORY_RATE)) {
            resolveVital(slot, dayKey, asOf, tz)?.let { samples.add(it) }
        }
        resolveSleepPerformance(dayKey)?.let { samples.add(it) }
        return samples
    }

    /**
     * The winning day-record for a vital (source-priority resolved), turned into a personal z-position
     * against its baseline. Null when there is no reading for the day or no baseline yet — a vital
     * with no personal baseline is treated as absent, because scoring it would require a population
     * norm, which v1 forbids.
     */
    private fun resolveVital(slot: ReadinessInput, dayKey: String, asOf: Long, tz: String): ReadinessInputSample? {
        val record = winningRecord(slot.metricId, dayKey, asOf, tz) ?: return null
        val baseline = derivation.latestBaseline(slot.metricId) ?: return null
        val maturity = if (baseline.windowDays > 0) {
            minOf(1.0, baseline.nPoints.toDouble() / baseline.windowDays.toDouble())
        } else {
            0.0
        }
        return ReadinessInputSample(
            input = slot, measuredValue = record.value, z = baseline.z(record.value),
            maturity = maturity, provisional = baseline.provisional,
            recordId = record.id, sourceId = record.provenance.sourceId,
        )
    }

    /**
     * The latest `sleep.performance` derived value for the day, if the sleep engine produced one. Its
     * own confidence/provisional flags flow through so a shaky need estimate can't silently firm up
     * the Readiness number.
     */
    private fun resolveSleepPerformance(dayKey: String): ReadinessInputSample? {
        val perf = derivation.latestDerived(MetricId.sleepPerformance, "day:$dayKey") ?: return null
        return ReadinessInputSample(
            input = ReadinessInput.SLEEP_PERFORMANCE, measuredValue = perf.value, z = null,
            maturity = perf.confidence ?: 1.0, provisional = perf.provisional,
            recordId = perf.id, sourceId = null,
        )
    }

    /**
     * Pick the day's winning interval record for a vital when more than one source reported it.
     * Interval-record vitals are NOT run through dedup-lite (that reconciles sessions), so a phone and
     * a watch each writing last night's HRV both survive. The winner is the highest-priority source;
     * ties break by most-recent `updatedAt`, then the lexicographically smaller `sourceId`. The chosen
     * record's id rides into the manifest, so "which device fed the score" is answerable from lineage.
     */
    private fun winningRecord(metricId: String, dayKey: String, asOf: Long, tz: String): IntervalRecord? {
        val dayStart = DayAttribution.startOfDay(asOf, tz)
        val from = DayAttribution.addingDays(-1, dayStart, tz)
        val to = DayAttribution.addingDays(2, dayStart, tz)
        val onDay = measurements.intervalRecords(metricId, from, to)
            .filter { DayAttribution.localDayKey(it.startAt, it.tzId) == dayKey }
        return onDay.maxWithOrNull { a, b -> if (loses(a, b)) -1 else if (loses(b, a)) 1 else 0 }
    }

    /** True when [a] should lose to [b]: lower priority loses; equal priority, older `updatedAt` loses; exact tie, larger `sourceId` loses. */
    private fun loses(a: IntervalRecord, b: IntervalRecord): Boolean {
        val pa = priorityForSource(a.provenance.sourceId)
        val pb = priorityForSource(b.provenance.sourceId)
        if (pa != pb) return pa < pb
        if (a.updatedAt != b.updatedAt) return a.updatedAt < b.updatedAt
        return a.provenance.sourceId > b.provenance.sourceId
    }

    // MARK: - Persistence (append-only, I2)

    private fun persist(result: ReadinessResult) {
        val periodKey = "day:${result.periodDayKey}"
        // The ONE line a declared context affects, anywhere in this engine. `result.computation.score`
        // below is written verbatim — a context has no expression that could change it
        // ([ContextAnnotation] carries a ceiling and sentences and no value field at all). The capped
        // confidence also enters the skip check, so declaring travel after the fact APPENDS a
        // re-annotated row (I2) instead of being ignored because the value happened to be unchanged.
        val confidence = result.publishedConfidence
        val existing = derivation.latestDerived(MetricId.readinessScore, periodKey)
        // Skip only when an identical *v2* row already exists — a v1 legacy row must never block the
        // first v2 write, or the migration would stall.
        if (existing != null && existing.algorithmId == algorithm.algorithmId &&
            existing.algorithmVersion == algorithm.semver &&
            approximatelyEqual(existing.value, result.computation.score) &&
            approximatelyEqual(existing.confidence ?: -1.0, confidence) &&
            existing.provisional == result.computation.provisional
        ) {
            return
        }

        // One manifest input per PRESENT input. `value` is the raw measured reading (lineage: it
        // resolves through `recordId` to the record, and its device, that fed the score); `weight`
        // carries that input's ADDITIVE CONTRIBUTION to the composite (points out of 100), so the
        // anatomy sheet renders contribution bars straight from the manifest and Σ(weights) == the
        // score by construction. See `docs/algorithms/readiness.md`.
        val manifest = InputManifest(
            id = Ulid.newId(),
            inputs = result.computation.contributions.map {
                InputManifest.Input(recordId = it.recordId, metricId = it.metricId, value = it.measuredValue, weight = it.contribution)
            },
        )
        derivation.insertManifest(manifest)

        val now = clock.now()
        derivation.appendDerived(
            DerivedValue(
                id = Ulid.newId(), metricId = MetricId.readinessScore, value = result.computation.score,
                unit = "score_0_100", periodKey = periodKey, confidence = confidence,
                provisional = result.computation.provisional, algorithmId = algorithm.algorithmId,
                algorithmVersion = algorithm.semver, inputManifestId = manifest.id,
                computedAt = now, updatedAt = now, originDeviceId = deviceId,
            ),
        )
    }

    companion object {
        // MARK: - Pure composite (identical on both platforms — golden-tested)

        /**
         * The weighted composite, pure and deterministic. Each present input → a 0–100 sub-score
         * ([subScore]); present weights are renormalized over whatever is available (a dropped input
         * redistributes its weight, never replaced by a default); the composite is the weighted mean,
         * always in `[0, 100]`. Confidence = weight-coverage × baseline-maturity, which caps a
         * reduced-input score without a separate magic constant (a missing HRV, weight 0.5, can never
         * yield confidence above 0.5). Returns null when fewer than `minInputsToScoreAtAll` inputs are
         * present, or the present weights sum to zero.
         */
        fun composite(present: List<ReadinessInputSample>, params: ReadinessParams): ReadinessComputation? {
            if (present.size < params.minInputsToScoreAtAll) return null
            val presentWeight = present.sumOf { params.weight(it.input) }
            if (presentWeight <= 0.0) return null

            val contributions = present.map { sample ->
                val sub = subScore(sample, params.zClampSigmas)
                val normalizedWeight = params.weight(sample.input) / presentWeight
                ReadinessContribution(
                    input = sample.input, metricId = sample.input.metricId, recordId = sample.recordId,
                    measuredValue = sample.measuredValue, z = sample.z, subScore = sub,
                    normalizedWeight = normalizedWeight, contribution = normalizedWeight * sub,
                    sourceId = sample.sourceId,
                )
            }

            val score = minOf(100.0, maxOf(0.0, contributions.sumOf { it.contribution }))
            // See the iOS ReadinessEngine for the full rationale: IEEE-754 summation of the present
            // weights (0.2 + 0.1 + 0.2) overshoots 0.5 by one ULP, which would push a missing-HRV
            // score's confidence just above the published 0.5 cap this fraction enforces. Round the
            // sub-nano noise away so the invariant holds exactly and identically on both platforms.
            val weightCoverage = kotlin.math.round(presentWeight / params.totalWeight * 1_000_000.0) / 1_000_000.0
            val maturity = present.minOf { it.maturity }
            val confidence = minOf(1.0, maxOf(0.0, weightCoverage * maturity))

            val presentSlots = present.map { it.input }.toSet()
            val hasHrv = presentSlots.contains(ReadinessInput.HRV)
            val variant: ReadinessVariant = if (hasHrv && present.size >= params.minInputsForFullScore) {
                ReadinessVariant.Full
            } else {
                ReadinessVariant.ReducedInput(ReadinessInput.entries.filter { it !in presentSlots })
            }

            val provisional = params.algorithmProvisional || present.any { it.provisional }

            return ReadinessComputation(score, confidence, provisional, variant, contributions)
        }

        /**
         * One input's 0–100 sub-score. Vitals map their clamped, direction-applied z through the
         * neutral 50; sleep performance is already personal-need-relative, so its own value carries
         * through (clamped to `[0, 100]`).
         */
        fun subScore(sample: ReadinessInputSample, zClamp: Double): Double {
            if (sample.input.scoresFromValueDirectly) {
                return minOf(100.0, maxOf(0.0, sample.measuredValue))
            }
            if (zClamp <= 0.0) return 50.0
            val directedZ = sample.input.direction * clamp(sample.z ?: 0.0, -zClamp, zClamp)
            return 50.0 + directedZ / zClamp * 50.0
        }

        fun clamp(x: Double, lo: Double, hi: Double): Double = minOf(hi, maxOf(lo, x))

        private fun approximatelyEqual(a: Double, b: Double, tolerance: Double = 1e-9): Boolean = kotlin.math.abs(a - b) < tolerance
    }
}

// MARK: - Inputs

/**
 * The four Readiness inputs. Each declares which contract weight it draws, whether higher-than-normal
 * is favourable ([direction]), and whether it is already a personal-need-relative value that scores
 * from itself rather than from a baseline z-position ([scoresFromValueDirectly], sleep only). Mirror
 * of iOS `ReadinessInput`.
 */
enum class ReadinessInput(
    val metricId: String,
    /** +1 when a reading above the personal baseline is favourable (HRV), −1 when not (RHR, RR). */
    val direction: Double,
    val scoresFromValueDirectly: Boolean,
    /** The `algorithms.json` param name carrying this input's launch weight. */
    val weightKey: String,
) {
    HRV(MetricId.hrv, 1.0, false, "weightHrv"),
    RHR(MetricId.restingHeartRate, -1.0, false, "weightRhr"),
    RESPIRATORY_RATE(MetricId.respiratoryRate, -1.0, false, "weightRespiratoryRate"),
    SLEEP_PERFORMANCE(MetricId.sleepPerformance, 1.0, true, "weightSleepPerformance"),
}

/**
 * One resolved, present input feeding the composite. [z] is null for [ReadinessInput.SLEEP_PERFORMANCE]
 * (it scores from [measuredValue] directly); [maturity]/[provisional] carry the contributing
 * baseline's (or the sleep term's) calibration state so confidence and the provisional flag stay honest.
 */
data class ReadinessInputSample(
    val input: ReadinessInput,
    val measuredValue: Double,
    val z: Double?,
    val maturity: Double,
    val provisional: Boolean,
    val recordId: String,
    val sourceId: String?,
)

// MARK: - Result read models

/**
 * Which model produced the score. [Full] used the HRV anchor and at least `minInputsForFullScore`
 * inputs; [ReducedInput] names the missing inputs so the surface labels the degradation DISTINCTLY
 * rather than passing a thinner score off as the full one (plan §18 cold-start rule).
 */
sealed interface ReadinessVariant {
    data object Full : ReadinessVariant
    data class ReducedInput(val missing: List<ReadinessInput>) : ReadinessVariant
}

/**
 * One input's line in the anatomy sheet: its raw value, its z-position (vitals), its 0–100 sub-score,
 * the renormalized weight actually applied, and the additive [contribution] (= [normalizedWeight] ·
 * [subScore]) whose sum is the score. [sourceId] names the device the winning record came from.
 */
data class ReadinessContribution(
    val input: ReadinessInput,
    val metricId: String,
    val recordId: String,
    val measuredValue: Double,
    val z: Double?,
    val subScore: Double,
    val normalizedWeight: Double,
    val contribution: Double,
    val sourceId: String?,
)

/**
 * The pure output of the composite — everything the anatomy sheet needs, with no I/O or clock in
 * sight, so both platforms compute byte-identical numbers (the acceptance goldens assert exactly this).
 */
data class ReadinessComputation(
    val score: Double,
    val confidence: Double,
    val provisional: Boolean,
    val variant: ReadinessVariant,
    val contributions: List<ReadinessContribution>,
)

/** A computed Readiness result for a specific local day — the pure computation plus the day it describes. */
/**
 * A computed Readiness result for a specific local day — the pure computation, the day it describes,
 * and whatever the user had declared over that day.
 *
 * The context sits BESIDE the computation, never inside it: `score` is reachable only through
 * [computation], which no context can touch, while the only context-derived quantity this type
 * exposes is [publishedConfidence]. "The number changed because I said I was travelling" therefore
 * has no expression here.
 */
data class ReadinessResult(
    val periodDayKey: String,
    val computation: ReadinessComputation,
    /** What the user declared over this day (NONE = an ordinary day, the common case). */
    val context: ContextAnnotation = ContextAnnotation.NONE,
) {
    /**
     * The confidence that goes on the row: the composite's own, capped by any declared context.
     * Monotonic downward by [ContextAnnotation.applyingTo] — a context can only ever make BADAN less
     * sure. `applyingTo` returns null only for a null input, which this never is.
     */
    val publishedConfidence: Double
        get() = context.applyingTo(computation.confidence) ?: computation.confidence
}

// MARK: - Spec (data-driven params, mirror of BaselineSpec)

/**
 * The numeric params the pure composite needs — the weights, the z clamp, the completeness gates, plus
 * whether the algorithm is still provisional. Resolved once from `composite.readiness_score`; the pure
 * function takes THIS, never the registry, so it stays I/O-free.
 */
data class ReadinessParams(
    val weights: Map<ReadinessInput, Double>,
    val zClampSigmas: Double,
    val minInputsForFullScore: Int,
    val minInputsToScoreAtAll: Int,
    /** From the contract entry's `provisional` flag — a provisional algorithm stamps every row it produces `provisional = true`. */
    val algorithmProvisional: Boolean,
) {
    fun weight(input: ReadinessInput): Double = weights[input] ?: 0.0

    /** The full intended weight mass — the weight-coverage (confidence cap) denominator, read from params rather than assumed 1.0. */
    val totalWeight: Double get() = weights.values.sum()
}

/**
 * The data-driven Readiness spec. The ONLY place the weights, clamp and gates enter the engine — never
 * hardcoded — so the two platforms cannot drift. A spec that failed to load ([isLoaded] == false) makes
 * the engine COMPUTE NOTHING rather than invent constants (mirror of [BaselineSpec]).
 */
data class ReadinessSpec(
    val algorithm: AlgorithmVersion,
    val params: ReadinessParams,
    val isLoaded: Boolean,
) {
    companion object {
        private const val CONTRACT_ID = "composite.readiness_score"

        /**
         * Resolve from a loaded [AlgorithmRegistry]. Returns [unavailable] if the entry or any required
         * param is missing — the engine treats that as "compute nothing", never as a cue to invent one.
         */
        fun load(registry: AlgorithmRegistry): ReadinessSpec {
            val def = registry.definition(CONTRACT_ID) ?: return unavailable
            val weights = HashMap<ReadinessInput, Double>()
            for (input in ReadinessInput.entries) {
                val w = def.params[input.weightKey] ?: return unavailable
                weights[input] = w
            }
            val zClamp = def.params["zClampSigmas"] ?: return unavailable
            val minFull = def.params["minInputsForFullScore"] ?: return unavailable
            val minAny = def.params["minInputsToScoreAtAll"] ?: return unavailable
            val params = ReadinessParams(
                weights = weights, zClampSigmas = zClamp, minInputsForFullScore = minFull.toInt(),
                minInputsToScoreAtAll = minAny.toInt(), algorithmProvisional = def.provisional,
            )
            return ReadinessSpec(def.algorithmVersion, params, isLoaded = true)
        }

        /** The app-default spec, resolved once from the classpath contract mirror (same route as the pure goldens). */
        fun default(): ReadinessSpec = cachedDefault

        private val cachedDefault: ReadinessSpec by lazy { load(AlgorithmRegistry.fromClasspath()) }

        /** The degenerate "the contract did not load" spec. Never produces a score. */
        val unavailable = ReadinessSpec(
            algorithm = AlgorithmVersion(algorithmId = CONTRACT_ID, semver = "0.0.0", introducedIn = "0.0.0"),
            params = ReadinessParams(
                weights = emptyMap(), zClampSigmas = 0.0, minInputsForFullScore = 0,
                minInputsToScoreAtAll = Int.MAX_VALUE, algorithmProvisional = true,
            ),
            isLoaded = false,
        )
    }
}
