package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.domain.journal.ContextAnnotator
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.storage.repositories.CorrelationRepository
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.JournalRepository
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min

// ---------------------------------------------------------------------------------------------
// Metric id composition
// ---------------------------------------------------------------------------------------------

/**
 * The `journal.correlation.<behaviorId>.<scoreId>` id pattern (plan §11 EPIC-29), in one place.
 * Mirror of iOS `CorrelationMetricID`.
 *
 * The registry carries the NAMESPACE row (`journal.correlation`) and nothing beneath it: the
 * concrete set is a product of `behaviors.json` and [MetricId.correlatedScores], so enumerating it
 * would add ~90 catalogue rows that never carry data and would rot the moment a behaviour is added.
 * What the namespace row fixes — unit, chart hint, bilingual name, and `sensitiveClass:
 * sensitivePlus` — applies to every id composed here.
 *
 * **Parsing depends on behaviour ids containing no dot.** The score id does (`readiness.score`), so
 * the split is at the FIRST separator after the namespace. `CorrelationEngineGoldenTest` asserts
 * that property against the shipped dictionary, so a future behaviour key with a dot in it fails
 * the suite rather than silently producing ids that parse back to the wrong pair.
 */
object CorrelationMetricId {
    const val NAMESPACE: String = MetricId.journalCorrelationNamespace
    private const val PREFIX: String = "$NAMESPACE."

    fun metricId(behaviorId: String, scoreId: String): String = PREFIX + behaviorId + "." + scoreId

    /** The pair a finding id names, or null if it is not one of ours. Null is a normal answer. */
    fun parse(metricId: String): Pair<String, String>? {
        if (!metricId.startsWith(PREFIX)) return null
        val rest = metricId.removePrefix(PREFIX)
        val dot = rest.indexOf('.')
        if (dot <= 0 || dot == rest.length - 1) return null
        return rest.substring(0, dot) to rest.substring(dot + 1)
    }

    /**
     * Whether an id belongs to this family. The one predicate any sensitivity or export gate should
     * ask, because `MetricRegistry.definition` returns null for a composed id (only the namespace
     * row exists) and a null sensitiveClass reads as "not sensitive" — which for THIS family would
     * be exactly backwards.
     */
    fun isCorrelationMetricId(metricId: String): Boolean = parse(metricId) != null
}

// ---------------------------------------------------------------------------------------------
// Spec (published constants)
// ---------------------------------------------------------------------------------------------

/**
 * The data-driven correlation parameters, resolved once from `journal.correlation` in
 * `algorithms.json`. Mirror of iOS `CorrelationSpec`; the two read the same file, so the gates and
 * the bootstrap settings cannot drift between platforms.
 *
 * A spec that failed to load ([isLoaded] false) makes the engine compute NOTHING rather than fall
 * back to invented constants. For this engine that matters more than most: the constants ARE the
 * honesty guarantee, and a finding computed from an unpublished `minObservedDays` would be
 * indistinguishable, on the stored row, from a gated one.
 */
data class CorrelationSpec(
    val algorithm: AlgorithmVersion,
    val params: Params,
    val isLoaded: Boolean,
) {
    data class Params(
        val lookbackDays: Int,
        /** MANDATORY GATE. Minimum paired days (both arms together). */
        val minObservedDays: Int,
        /** MANDATORY GATE. Minimum days in EACH arm. */
        val minDaysPerArm: Int,
        val bootstrapIterations: Int,
        val bootstrapSeed: Long,
        val ciLowerPercentile: Double,
        val ciUpperPercentile: Double,
        val negligibleDeltaThreshold: Double,
        val smallDeltaThreshold: Double,
        val mediumDeltaThreshold: Double,
        val confidenceFullNDays: Double,
        /** True while the contract entry is `provisional` — carried onto every row written. */
        val algorithmProvisional: Boolean,
    )

    companion object {
        const val ALGORITHM_ID = "journal.correlation"

        fun load(registry: AlgorithmRegistry): CorrelationSpec {
            val definition = registry.definition(ALGORITHM_ID)
                ?: return CorrelationSpec(
                    algorithm = AlgorithmVersion(ALGORITHM_ID, "0", emptyMap(), "0"),
                    params = Params(
                        lookbackDays = 0, minObservedDays = Int.MAX_VALUE, minDaysPerArm = Int.MAX_VALUE,
                        bootstrapIterations = 0, bootstrapSeed = 0L,
                        ciLowerPercentile = 0.0, ciUpperPercentile = 0.0,
                        negligibleDeltaThreshold = 0.0, smallDeltaThreshold = 0.0,
                        mediumDeltaThreshold = 0.0, confidenceFullNDays = 0.0,
                        algorithmProvisional = true,
                    ),
                    isLoaded = false,
                )
            val p = definition.params
            // A missing gate resolves to Int.MAX_VALUE, not to a permissive default: if the contract
            // loses `minObservedDays`, every behaviour is suppressed and nothing is published — the
            // safe direction to fail in for a feature whose value is refusing to speak on thin
            // evidence.
            return CorrelationSpec(
                algorithm = definition.algorithmVersion,
                params = Params(
                    lookbackDays = (p["lookbackDays"] ?: 0.0).toInt(),
                    minObservedDays = p["minObservedDays"]?.toInt() ?: Int.MAX_VALUE,
                    minDaysPerArm = p["minDaysPerArm"]?.toInt() ?: Int.MAX_VALUE,
                    bootstrapIterations = (p["bootstrapIterations"] ?: 0.0).toInt(),
                    bootstrapSeed = (p["bootstrapSeed"] ?: 0.0).toLong(),
                    ciLowerPercentile = p["ciLowerPercentile"] ?: 0.0,
                    ciUpperPercentile = p["ciUpperPercentile"] ?: 0.0,
                    negligibleDeltaThreshold = p["negligibleDeltaThreshold"] ?: 0.0,
                    smallDeltaThreshold = p["smallDeltaThreshold"] ?: 0.0,
                    mediumDeltaThreshold = p["mediumDeltaThreshold"] ?: 0.0,
                    confidenceFullNDays = p["confidenceFullNDays"] ?: 0.0,
                    algorithmProvisional = definition.provisional,
                ),
                isLoaded = true,
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Inputs and outcomes
// ---------------------------------------------------------------------------------------------

/**
 * One local day as the engine sees it: was the behaviour logged, what did the NEXT day's score read,
 * and did the day fall inside a declared context interval.
 *
 * A day only exists here if the user journaled on it at all. That rule is the difference between an
 * honest comparison and an invented one: a day with no journal activity is not evidence the
 * behaviour was absent, it is evidence of nothing, and quietly filing it in the "without" arm would
 * manufacture an arm out of days the user simply did not open the app.
 */
data class CorrelationDay(
    val dayKey: String,
    /** True when the behaviour was asserted that day (an explicit 0 count lands in "without"). */
    val present: Boolean,
    /** Next local day's score. Null days are dropped BEFORE the gates, so the gates judge the
     *  counts that actually feed the comparison. */
    val nextDayScore: Double?,
    /** Whether a ContextStatus was in force. Disclosure only — never a reason to drop the day. */
    val inDeclaredContext: Boolean = false,
    /** The DerivedValue id of the next-day score, for the input manifest (I1 lineage). */
    val nextDayScoreRecordId: String = "",
)

/**
 * Why a behaviour x score pair produced no finding. Suppression is a first-class, *displayable*
 * outcome carrying the shortfall — "come back in about 6 days" — never a silent skip and never a
 * finding with a warning label on it.
 */
sealed class CorrelationSuppressionReason {
    abstract val moreDaysNeeded: Int

    /** Fewer than `minObservedDays` paired days in total. */
    data class TooFewObservedDays(override val moreDaysNeeded: Int) : CorrelationSuppressionReason()

    /** Enough days overall, fewer than `minDaysPerArm` days WITH the behaviour. */
    data class TooFewDaysWithBehavior(override val moreDaysNeeded: Int) : CorrelationSuppressionReason()

    /** Enough days overall, fewer than `minDaysPerArm` days WITHOUT it. */
    data class TooFewDaysWithoutBehavior(override val moreDaysNeeded: Int) : CorrelationSuppressionReason()
}

data class CorrelationSuppression(
    val behaviorId: String,
    val scoreId: String,
    val nObserved: Int,
    val nWith: Int,
    val nWithout: Int,
    val reason: CorrelationSuppressionReason,
)

/**
 * Which way the next-day score leaned, once the interval has had its say. [NO_CLEAR_ASSOCIATION] is
 * a RESULT, not an absence of one.
 */
enum class CorrelationDirection { HIGHER, LOWER, NO_CLEAR_ASSOCIATION }

/**
 * Effect-size wording, from the published Cliff's-delta thresholds (Romano et al. 2006). Used for
 * the strength word only — never to decide whether a finding is shown, which is the interval's job.
 */
enum class CorrelationMagnitude {
    NEGLIGIBLE, SMALL, MEDIUM, LARGE;

    val displayLabel: LocalizedString
        get() = when (this) {
            NEGLIGIBLE -> LocalizedString(en = "negligible", ar = "ضئيل")
            SMALL -> LocalizedString(en = "small", ar = "صغير")
            MEDIUM -> LocalizedString(en = "moderate", ar = "متوسط")
            LARGE -> LocalizedString(en = "large", ar = "كبير")
        }
}

/**
 * One computed association. Everything a card needs at either altitude — the casual sentence and the
 * power-mode numbers are rendered from THIS object, so there is one computation and two
 * presentations rather than two code paths that can disagree (D-5).
 */
data class CorrelationFinding(
    val behaviorId: String,
    val scoreId: String,
    val nObserved: Int,
    val nWith: Int,
    val nWithout: Int,
    /** Cliff's delta. Positive = the next-day score ran HIGHER after the behaviour. */
    val delta: Double,
    val ciLow: Double,
    val ciHigh: Double,
    /** Arm medians — medians rather than means, for the same reason the effect size is
     *  non-parametric: one atypical night should not move the summary of an arm. */
    val medianWith: Double,
    val medianWithout: Double,
    /** Days inside a declared ContextStatus. Disclosed and confidence-capped; never removed. */
    val contextDays: Int,
    val confidence: Double,
    val provisional: Boolean,
    val firstDayKey: String,
    val lastDayKey: String,
) {
    val metricId: String get() = CorrelationMetricId.metricId(behaviorId, scoreId)

    /**
     * `window:<first>..<last>`. A correlation describes a SPAN of days, so it cannot honestly be
     * keyed `day:` — and the span is in the key rather than only in the manifest so two findings
     * over different windows are different rows rather than one overwriting the other on read.
     */
    val periodKey: String get() = "window:$firstDayKey..$lastDayKey"

    /**
     * The interval decides the direction, not the point estimate. A delta of −0.4 with an interval
     * from −0.8 to +0.1 is "no clear association", and rendering it as "lower" because the centre
     * happens to be negative is the exact failure this engine exists to refuse.
     */
    val direction: CorrelationDirection
        get() = when {
            ciLow > 0 -> CorrelationDirection.HIGHER
            ciHigh < 0 -> CorrelationDirection.LOWER
            else -> CorrelationDirection.NO_CLEAR_ASSOCIATION
        }

    val spansZero: Boolean get() = direction == CorrelationDirection.NO_CLEAR_ASSOCIATION

    fun magnitude(params: CorrelationSpec.Params): CorrelationMagnitude {
        val magnitude = abs(delta)
        return when {
            magnitude < params.negligibleDeltaThreshold -> CorrelationMagnitude.NEGLIGIBLE
            magnitude < params.smallDeltaThreshold -> CorrelationMagnitude.SMALL
            magnitude < params.mediumDeltaThreshold -> CorrelationMagnitude.MEDIUM
            else -> CorrelationMagnitude.LARGE
        }
    }

    companion object {
        /**
         * Rebuild a finding from the row and manifest it was stored as — the reader half of the
         * `stat:` contract described on [CorrelationEngine.manifestInputs], pinned by the round-trip
         * test on both platforms. Mirror of iOS `CorrelationFinding.from`.
         *
         * **Nothing in the app calls this yet.** The correlations surface renders the outcomes
         * [CorrelationEngine.recompute] has just returned, never rows re-read from storage: a
         * suppressed pair is deliberately never persisted, so the "not yet, about N more days" half
         * of the screen can only come from a live evaluation, and the findings arrive on the same
         * pass. This reader exists so a stored row is legible on its own terms, and so the writer
         * cannot drift from what a reader would make of it without the round trip failing.
         *
         * **It fails closed.** The interval is what decides the direction, so a manifest that is
         * missing, undecodable, or short of any statistic read here yields NO finding rather than a
         * patched-up one. Defaulting the bounds to the point estimate — the obvious shortcut —
         * rebuilds `ciLow == ciHigh == delta`, which [direction] reads as a confident
         * HIGHER/LOWER over `nObserved == 0`: a statistical claim fabricated out of missing data,
         * which is the one thing this engine exists to refuse. `CorrelationEngineGoldenTest`
         * asserts the refusal.
         */
        fun from(
            metricId: String,
            value: Double,
            periodKey: String,
            confidence: Double?,
            provisional: Boolean,
            manifestInputs: List<InputManifest.Input>,
        ): CorrelationFinding? {
            val pair = CorrelationMetricId.parse(metricId) ?: return null
            val stats = manifestInputs.filter { it.recordId.startsWith("stat:") }
                .associate { it.recordId to it.value }

            // A count has to be a real, non-negative, day-sized number to be one. Anything else is
            // corruption rather than data (and `Double.NaN.toInt()` would quietly become 0).
            fun count(raw: Double?): Int? =
                if (raw == null || !raw.isFinite() || raw < 0.0 || raw > 1_000_000.0) null else raw.toInt()

            val nObserved = count(stats["stat:n"]) ?: return null
            val nWith = count(stats["stat:n_with"]) ?: return null
            val nWithout = count(stats["stat:n_without"]) ?: return null
            val contextDays = count(stats["stat:context_days"]) ?: return null
            val ciLow = stats["stat:ci_low"] ?: return null
            val ciHigh = stats["stat:ci_high"] ?: return null
            val medianWith = stats["stat:median_with"] ?: return null
            val medianWithout = stats["stat:median_without"] ?: return null
            if (!value.isFinite() || !medianWith.isFinite() || !medianWithout.isFinite() ||
                !ciLow.isFinite() || !ciHigh.isFinite() || ciLow > ciHigh
            ) {
                return null
            }

            // A window key we cannot parse degrades to empty day keys rather than to invented ones.
            // That is a safe degradation in a way a missing interval is not: the span is a label,
            // the interval is the claim.
            val window = if (periodKey.startsWith("window:")) {
                periodKey.removePrefix("window:").split("..")
            } else {
                emptyList()
            }
            return CorrelationFinding(
                behaviorId = pair.first, scoreId = pair.second,
                nObserved = nObserved,
                nWith = nWith,
                nWithout = nWithout,
                delta = value,
                ciLow = ciLow,
                ciHigh = ciHigh,
                medianWith = medianWith,
                medianWithout = medianWithout,
                contextDays = contextDays,
                confidence = confidence ?: 0.0,
                provisional = provisional,
                firstDayKey = window.getOrElse(0) { "" },
                lastDayKey = window.getOrElse(1) { "" },
            )
        }
    }
}

sealed class CorrelationOutcome {
    data class Finding(val finding: CorrelationFinding) : CorrelationOutcome()
    data class Suppressed(val suppression: CorrelationSuppression) : CorrelationOutcome()

    val findingOrNull: CorrelationFinding? get() = (this as? Finding)?.finding
    val suppressionOrNull: CorrelationSuppression? get() = (this as? Suppressed)?.suppression
}

// ---------------------------------------------------------------------------------------------
// The statistics
// ---------------------------------------------------------------------------------------------

/**
 * The non-parametric core: Cliff's delta and a percentile bootstrap, and deliberately nothing else.
 * Mirror of iOS `CorrelationMath`, byte-identical by construction.
 *
 * **Why no t-test, anywhere.** The samples this runs on are two handfuls of daily scores — often 7
 * against 9 — drawn from bounded, skewed distributions (a readiness score is capped at 100 and piles
 * up near a person's own typical band). A t-test would assume approximate normality and report a
 * precise-looking p-value computed from a shape the data does not have. Cliff's delta assumes only
 * that the values can be ORDERED, which is exactly what is true of them, and the bootstrap gets its
 * interval from the data instead of from a table.
 */
object CorrelationMath {

    /**
     * Cliff's delta: P(x > y) − P(x < y) over all pairs, x from the behaviour-present arm and y from
     * the behaviour-absent arm. Positive means the next-day score tended to be HIGHER after the
     * behaviour. Ties count for neither side, which is why identical arms give exactly 0.
     *
     * O(n·m) by construction rather than the sorted O(n log n) form, and the naive double loop is
     * the definition itself — a reader can check it against the formula without trusting a rank
     * trick. The cost was measured rather than assumed, because this runs inside the bootstrap: the
     * true worst case (every one of ~28 behaviours x 3 scores clearing the gates with both arms at
     * 60 days, the most `lookbackDays` allows) is ~1 s for the whole batch in an optimised build.
     * That batch has one caller — `loadCorrelations`, which runs it off the main thread — so the
     * cost is TIME TO FIRST RENDER on the correlations screen, behind its loading state, and never
     * main-thread jank. At that latency the readable form wins; if `lookbackDays` or the behaviour
     * vocabulary grows by an order of magnitude, measure again before assuming it still does.
     */
    fun cliffsDelta(with: DoubleArray, without: DoubleArray): Double {
        if (with.isEmpty() || without.isEmpty()) return 0.0
        var greater = 0
        var less = 0
        for (x in with) {
            for (y in without) {
                if (x > y) greater++ else if (x < y) less++
            }
        }
        return (greater - less).toDouble() / (with.size.toLong() * without.size.toLong()).toDouble()
    }

    fun cliffsDelta(with: List<Double>, without: List<Double>): Double =
        cliffsDelta(with.toDoubleArray(), without.toDoubleArray())

    /** The middle value (mean of the two middle values for an even count). */
    fun median(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2.0
    }

    /**
     * splitmix64 — a small, exactly-specified 64-bit generator, written out rather than taken from
     * either platform's standard library.
     *
     * The reason is the whole determinism requirement: `kotlin.random.Random` and Swift's
     * `SystemRandomNumberGenerator` produce different sequences from the same seed, so a bootstrap
     * built on either would give Android and iOS different intervals for identical data — and a
     * "confidence interval" that depends on which phone you hold is not one. Every operation here is
     * a wrapping multiply, an xor or a LOGICAL shift (`ushr`), which is why `Long` reproduces the
     * Swift `UInt64` bit sequence exactly.
     */
    class SplitMix64(seed: Long) {
        private var state: Long = seed

        fun next(): Long {
            state += -0x61c8_8646_80b5_83ebL // 0x9E3779B97F4A7C15
            var z = state
            z = (z xor (z ushr 30)) * -0x40a7_b892_e31b_1a47L // 0xBF58476D1CE4E5B9
            z = (z xor (z ushr 27)) * -0x6b2f_b644_ecce_ee15L // 0x94D049BB133111EB
            return z xor (z ushr 31)
        }

        /**
         * Uniform index in `0 until count`. The high 31 bits are used (`ushr 33`) because
         * splitmix64's low bits are the weakest, and the shifted value is always non-negative so the
         * modulo cannot come back negative the way a signed full-word modulo would.
         */
        fun index(upperBound: Int): Int {
            if (upperBound <= 0) return 0
            return ((next() ushr 33).toInt()) % upperBound
        }
    }

    /**
     * Percentile-method bootstrap interval for Cliff's delta.
     *
     * Stratified: each arm is resampled with replacement to its OWN original size, so the
     * with/without balance of the real sample is preserved in every resample — pooling and
     * re-splitting would silently answer a different question.
     *
     * The draw order is fixed (all "with" draws, then all "without" draws, per iteration) and the
     * seed is a published constant, so the interval is a pure function of the inputs: the same data
     * gives the same interval on a recompute, on the other platform, forever.
     *
     * Index rule, part of the cross-platform contract (see `docs/algorithms/correlations.md`): with
     * B sorted resample deltas, the bounds are `sorted[floor(lo·B)]` and
     * `sorted[min(B−1, ceil(hi·B) − 1)]`. Written out rather than "the 2.5th percentile" because
     * percentile definitions differ between libraries and this one has to be reproducible by hand.
     */
    fun bootstrapInterval(
        with: List<Double>,
        without: List<Double>,
        params: CorrelationSpec.Params,
    ): Pair<Double, Double> {
        val iterations = params.bootstrapIterations
        if (iterations <= 0 || with.isEmpty() || without.isEmpty()) {
            val point = cliffsDelta(with, without)
            return point to point
        }
        val withArray = with.toDoubleArray()
        val withoutArray = without.toDoubleArray()
        val rng = SplitMix64(params.bootstrapSeed)
        val deltas = DoubleArray(iterations)
        val sampleWith = DoubleArray(withArray.size)
        val sampleWithout = DoubleArray(withoutArray.size)

        for (b in 0 until iterations) {
            for (i in withArray.indices) sampleWith[i] = withArray[rng.index(withArray.size)]
            for (i in withoutArray.indices) sampleWithout[i] = withoutArray[rng.index(withoutArray.size)]
            deltas[b] = cliffsDelta(sampleWith, sampleWithout)
        }

        deltas.sort()
        val lowIndex = min(iterations - 1, maxOf(0, floor(params.ciLowerPercentile * iterations).toInt()))
        val highIndex = min(iterations - 1, maxOf(0, ceil(params.ciUpperPercentile * iterations).toInt() - 1))
        return deltas[lowIndex] to deltas[maxOf(lowIndex, highIndex)]
    }

    /**
     * How much weight the finding may claim, as two published factors multiplied: paired days over
     * `confidenceFullNDays` (capped at 1), times `1 − width/2` where 2 is the full range Cliff's
     * delta can span.
     *
     * This is NOT a p-value and must never be rendered as one. It is a display weight, and the
     * numbers it is derived from (n, and the interval) are shown next to it in power mode so the
     * reader can check it rather than take it on faith.
     */
    fun confidence(nObserved: Int, ciLow: Double, ciHigh: Double, params: CorrelationSpec.Params): Double {
        val full = params.confidenceFullNDays
        val sampleFactor = if (full > 0) min(1.0, nObserved / full) else 0.0
        val width = maxOf(0.0, min(2.0, ciHigh - ciLow))
        val precisionFactor = 1.0 - (width / 2.0)
        return maxOf(0.0, min(1.0, sampleFactor * precisionFactor))
    }
}

// ---------------------------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------------------------

/**
 * EPIC-29 — the journal correlation engine. **Its product is the refusal, not the finding.**
 *
 * Anyone can compute a difference between two groups of days. What makes this shippable is what it
 * declines to say: below the published minimum-n gates it emits NOTHING (suppressed, with the
 * shortfall named), and above them an interval that straddles zero is reported as "no clear
 * association" rather than quietly dropped so the list only ever contains hits. A correlations
 * screen that only shows hits is a slot machine with a health theme.
 *
 * Kotlin mirror of iOS `CorrelationEngine`, statement for statement. Android has no DB-backed
 * unit-test harness (see `BaselineEngineGoldenTest`'s note), so the persistence path is covered by
 * the iOS suite; what `CorrelationEngineGoldenTest` pins here is the part that must be
 * byte-identical, because a gate that differs by platform is not a gate: [Companion.evaluate], the
 * statistics, and the rendering.
 *
 * **I7.** Findings are written to the SENSITIVE database ([CorrelationRepository]), never to
 * `badan.db`, because the metric id itself names the behaviour. This class holds no main-database
 * connection at all, which is what makes that structural rather than a rule someone has to remember.
 */
class CorrelationEngine(
    private val journal: JournalRepository,
    private val derivation: DerivationRepository,
    private val findings: CorrelationRepository,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: CorrelationSpec,
) {
    val algorithm: AlgorithmVersion get() = spec.algorithm
    val params: CorrelationSpec.Params get() = spec.params

    /**
     * Recompute every behaviour x score pair over the trailing `lookbackDays` and persist the
     * findings. Returns every outcome — suppressions included — because the correlations screen
     * shows "not yet, about N more days" rows alongside the findings, and a caller that only saw
     * findings would have to re-derive the shortfall itself.
     *
     * Suppressed pairs write NOTHING. That is the storage-level half of the small-n invariant: a
     * suppressed finding does not exist as a row that some future read path could pick up and
     * render without re-checking the gate.
     */
    fun recompute(asOf: Long = clock.now(), tz: String = java.util.TimeZone.getDefault().id): List<CorrelationOutcome> {
        if (!spec.isLoaded || params.lookbackDays <= 0) return emptyList()

        val dayEnd = DayAttribution.addingDays(1, DayAttribution.startOfDay(asOf, tz), tz)
        val windowStart = DayAttribution.addingDays(-params.lookbackDays, dayEnd, tz)

        val entries = journal.entries(windowStart, dayEnd)
        if (entries.isEmpty()) return emptyList()
        val statuses = journal.statusesOverlapping(windowStart, dayEnd)

        // Every day the user journaled at all — the observation frame. A behaviour is "absent" only
        // on a day inside this set, never on a day the app was not opened.
        val observedDayKeys = entries.map { it.dayKey() }.toSet()
        val contextDays = contextDayKeys(observedDayKeys, statuses, { DayAttribution.dateFromDayKey(it, tz) })

        // Behaviours the dictionary named. Free-text `customLabel` entries are deliberately not
        // correlated: two spellings of one habit would split into two under-powered behaviours and
        // both would be suppressed, which reads as a bug rather than as the honest statement that
        // BADAN cannot tell they are the same thing.
        val behaviorIds = entries.mapNotNull { it.behaviorId }.toSortedSet()
        val presentDays = mutableMapOf<String, MutableSet<String>>()
        for (entry in entries) {
            val behaviorId = entry.behaviorId ?: continue
            if (!entry.isPresent) continue
            presentDays.getOrPut(behaviorId) { mutableSetOf() }.add(entry.dayKey())
        }

        // The scores are read over one extra day at the end: the last journaled day pairs with the
        // day AFTER it, which is outside the journal window by construction.
        val firstScoreDayKey = DayAttribution.localDayKey(windowStart, tz)
        val lastScoreDayKey = DayAttribution.localDayKey(DayAttribution.addingDays(1, dayEnd, tz), tz)

        val outcomes = mutableListOf<CorrelationOutcome>()
        val sortedObserved = observedDayKeys.sorted()
        for (scoreId in MetricId.correlatedScores) {
            val scoreByDay = dailyScores(scoreId, firstScoreDayKey, lastScoreDayKey)
            for (behaviorId in behaviorIds) {
                val present = presentDays[behaviorId] ?: emptySet<String>()
                val days = sortedObserved.map { dayKey ->
                    val score = scoreByDay[nextDayKey(dayKey, tz)]
                    CorrelationDay(
                        dayKey = dayKey,
                        present = present.contains(dayKey),
                        nextDayScore = score?.second,
                        inDeclaredContext = contextDays.contains(dayKey),
                        nextDayScoreRecordId = score?.first ?: "",
                    )
                }
                val outcome = evaluate(behaviorId, scoreId, days, spec)
                outcome.findingOrNull?.let { persist(it, days) }
                outcomes.add(outcome)
            }
        }
        return outcomes
    }

    /**
     * Latest score value per local day, keyed by day key, over the window. Filtered on the day-key
     * STRING because `"YYYY-MM-DD"` sorts lexicographically the same way the dates do.
     */
    private fun dailyScores(
        metricId: String,
        fromDayKey: String,
        toDayKey: String,
    ): Map<String, Pair<String, Double>> {
        val out = mutableMapOf<String, Pair<String, Double>>()
        for (row in derivation.latestDerivedSeries(metricId)) {
            if (!row.periodKey.startsWith("day:")) continue
            val dayKey = row.periodKey.removePrefix("day:")
            if (dayKey < fromDayKey || dayKey > toDayKey) continue
            out[dayKey] = row.id to row.value
        }
        return out
    }

    /**
     * Append one finding as a DerivedValue + InputManifest in the sensitive database.
     *
     * Skip-if-identical, matching the other engines: a repeat run over unchanged data appends
     * nothing. A CHANGED belief always appends (I2) — the prior row keeps its own `computedAt` and
     * stays readable as what BADAN thought last week.
     */
    private fun persist(finding: CorrelationFinding, days: List<CorrelationDay>) {
        val existing = findings.latestDerived(finding.metricId, finding.periodKey)
        if (existing != null &&
            existing.value == finding.delta &&
            existing.confidence == finding.confidence &&
            existing.algorithmVersion == spec.algorithm.semver
        ) {
            return
        }
        val now = clock.now()
        val manifest = InputManifest(id = Ulid.newId(), inputs = manifestInputs(finding, days))
        findings.transaction {
            findings.insertManifest(manifest)
            findings.appendDerived(
                DerivedValue(
                    id = Ulid.newId(), metricId = finding.metricId, value = finding.delta, unit = "index",
                    periodKey = finding.periodKey, confidence = finding.confidence,
                    provisional = finding.provisional, algorithmId = spec.algorithm.algorithmId,
                    algorithmVersion = spec.algorithm.semver, inputManifestId = manifest.id,
                    computedAt = now, updatedAt = now, originDeviceId = deviceId,
                ),
            )
        }
    }

    companion object {

        /**
         * The whole decision, as a pure function of the days — no clock, no storage, no I/O. Both
         * platforms' goldens call exactly this, which is what makes "identical across platforms" a
         * property that can be asserted rather than hoped for.
         *
         * Order of operations is load-bearing and is the same order the doc publishes:
         * 1. drop days with no next-day score (they can pair with nothing);
         * 2. split into arms;
         * 3. **check the gates** — and stop here if either fails;
         * 4. only then compute an effect size.
         *
         * Computing first and gating afterwards would produce the same visible result today and a
         * tempting `if (showAnyway)` tomorrow.
         */
        fun evaluate(
            behaviorId: String,
            scoreId: String,
            days: List<CorrelationDay>,
            spec: CorrelationSpec,
        ): CorrelationOutcome {
            val paired = days.filter { it.nextDayScore != null }.sortedBy { it.dayKey }
            val withDays = paired.filter { it.present }
            val withoutDays = paired.filter { !it.present }
            val p = spec.params

            if (!spec.isLoaded || paired.size < p.minObservedDays) {
                return CorrelationOutcome.Suppressed(
                    CorrelationSuppression(
                        behaviorId, scoreId, paired.size, withDays.size, withoutDays.size,
                        CorrelationSuppressionReason.TooFewObservedDays(
                            maxOf(0, p.minObservedDays - paired.size),
                        ),
                    ),
                )
            }
            if (withDays.size < p.minDaysPerArm) {
                return CorrelationOutcome.Suppressed(
                    CorrelationSuppression(
                        behaviorId, scoreId, paired.size, withDays.size, withoutDays.size,
                        CorrelationSuppressionReason.TooFewDaysWithBehavior(p.minDaysPerArm - withDays.size),
                    ),
                )
            }
            if (withoutDays.size < p.minDaysPerArm) {
                return CorrelationOutcome.Suppressed(
                    CorrelationSuppression(
                        behaviorId, scoreId, paired.size, withDays.size, withoutDays.size,
                        CorrelationSuppressionReason.TooFewDaysWithoutBehavior(p.minDaysPerArm - withoutDays.size),
                    ),
                )
            }

            // Values in day order, so the bootstrap's indexed draws are reproducible.
            val withValues = withDays.mapNotNull { it.nextDayScore }
            val withoutValues = withoutDays.mapNotNull { it.nextDayScore }

            val delta = CorrelationMath.cliffsDelta(withValues, withoutValues)
            val interval = CorrelationMath.bootstrapInterval(withValues, withoutValues, p)
            var confidence = CorrelationMath.confidence(paired.size, interval.first, interval.second, p)

            // Context days are COUNTED and capped, never dropped. Removing a travel week would silently
            // change what the finding is about, and the resulting number would describe a life the user
            // did not live. ContextAnnotator's ceiling is the single published value for this (it is
            // deliberately not re-declared in the correlation params block).
            val contextDays = paired.count { it.inDeclaredContext }
            if (contextDays > 0) {
                confidence = min(confidence, ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING)
            }

            return CorrelationOutcome.Finding(
                CorrelationFinding(
                    behaviorId = behaviorId, scoreId = scoreId, nObserved = paired.size,
                    nWith = withDays.size, nWithout = withoutDays.size,
                    delta = delta, ciLow = interval.first, ciHigh = interval.second,
                    medianWith = CorrelationMath.median(withValues),
                    medianWithout = CorrelationMath.median(withoutValues),
                    contextDays = contextDays, confidence = confidence,
                    provisional = p.algorithmProvisional,
                    firstDayKey = paired.firstOrNull()?.dayKey ?: "",
                    lastDayKey = paired.lastOrNull()?.dayKey ?: "",
                ),
            )
        }

        /**
         * Observed days that fall inside any declared status interval. Computed over the observed set
         * rather than by expanding the intervals, so an open-ended "still travelling" status annotates
         * exactly the journaled days it covers and no phantom ones.
         */
        fun contextDayKeys(
            observedDayKeys: Set<String>,
            statuses: List<ContextStatus>,
            dayStartMillis: (String) -> Long?,
            dayLengthMillis: Long = 24L * 60 * 60 * 1000,
        ): Set<String> {
            if (statuses.isEmpty()) return emptySet()
            val out = mutableSetOf<String>()
            for (dayKey in observedDayKeys) {
                val start = dayStartMillis(dayKey) ?: continue
                val end = start + dayLengthMillis
                if (statuses.any { it.deletedAt == null && it.overlaps(start, end) }) out.add(dayKey)
            }
            return out
        }

        /**
         * The manifest a finding files with: its summary statistics, then every day that fed it.
         *
         * **The `stat:` convention.** A DerivedValue carries one number, and a correlation is n, an
         * effect size, two interval bounds and two arm counts. Rather than invent a parallel table or
         * smuggle a JSON blob into a column, the statistics ride in the manifest — which is exactly what
         * the manifest is for — under reserved `stat:<name>` record ids. [CorrelationFinding.from] is
         * the matching reader, and the round trip is asserted, so this is a contract rather than a
         * convention someone has to know.
         *
         * **`weight` carries the arm** for the per-day inputs: 1 = behaviour-present day, 0 = absent. It
         * is the manifest's only per-input slot and the arm IS that input's role in this computation.
         */
        fun manifestInputs(finding: CorrelationFinding, days: List<CorrelationDay>): List<InputManifest.Input> {
            val metricId = finding.metricId
            val inputs = mutableListOf(
                InputManifest.Input("stat:n", metricId, finding.nObserved.toDouble()),
                InputManifest.Input("stat:n_with", metricId, finding.nWith.toDouble()),
                InputManifest.Input("stat:n_without", metricId, finding.nWithout.toDouble()),
                InputManifest.Input("stat:delta", metricId, finding.delta),
                InputManifest.Input("stat:ci_low", metricId, finding.ciLow),
                InputManifest.Input("stat:ci_high", metricId, finding.ciHigh),
                InputManifest.Input("stat:median_with", metricId, finding.medianWith),
                InputManifest.Input("stat:median_without", metricId, finding.medianWithout),
                InputManifest.Input("stat:context_days", metricId, finding.contextDays.toDouble()),
            )
            for (day in days) {
                val score = day.nextDayScore ?: continue
                inputs.add(
                    InputManifest.Input(
                        recordId = day.nextDayScoreRecordId.ifEmpty { "day:${day.dayKey}" },
                        metricId = finding.scoreId,
                        value = score,
                        weight = if (day.present) 1.0 else 0.0,
                    ),
                )
            }
            return inputs
        }

        /**
         * The day key one calendar day after [dayKey]. Calendar arithmetic rather than +86400 so a DST
         * boundary does not shift a score onto the wrong day — the same reason `JournalLog.yesterday`
         * uses calendar addition.
         */
        fun nextDayKey(dayKey: String, tz: String): String {
            val start = DayAttribution.dateFromDayKey(dayKey, tz) ?: return dayKey
            return DayAttribution.localDayKey(DayAttribution.addingDays(1, start, tz), tz)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

/**
 * Turns an outcome into the sentences a card shows, through the shared [InsightTemplateStore].
 * Mirror of iOS `CorrelationRenderer`.
 *
 * **The locked line.** `journal_correlation_not_cause` is appended to EVERY rendered card — the
 * positive, the negative and the null alike — in both languages. It is not conditional and it is not
 * a caller's responsibility: a caller that forgot it would ship a card reading as causal, which is
 * the single failure mode this epic exists to prevent.
 *
 * **Two altitudes, one computation.** [Card.casualText] is a sentence; [Card.powerText] is n, the
 * effect size and the interval as numbers. Both are rendered from the SAME [CorrelationFinding] —
 * there is no second computation for the detailed view (D-5).
 */
object CorrelationRenderer {

    data class Card(
        val metricId: String,
        val templateId: String,
        val casualText: LocalizedString,
        /** Null for a suppressed pair, which has no statistics to show — that is the point. */
        val powerText: LocalizedString?,
        val contextNote: LocalizedString?,
        /** The locked association-not-cause line. Always present. */
        val associationNotCause: LocalizedString,
        val isSuppressed: Boolean,
    ) {
        /** Every line the card renders, in order. */
        val lines: List<LocalizedString>
            get() = buildList {
                add(casualText)
                contextNote?.let { add(it) }
                powerText?.let { add(it) }
                add(associationNotCause)
            }
    }

    const val LOCKED_TEMPLATE_ID = "journal_correlation_not_cause"

    /**
     * The fallback used only if the template store failed to load. Kept verbatim-equal to the
     * contract's copy and asserted so, because a card that lost this line to a packaging failure
     * would be worse than a card that failed to render at all.
     */
    val ASSOCIATION_NOT_CAUSE_FALLBACK = LocalizedString(
        en = "This is an association in your own logged data, not a cause.",
        ar = "هذا ارتباط في بياناتك المسجّلة، وليس سببًا.",
    )

    fun render(
        outcome: CorrelationOutcome,
        behavior: LocalizedString,
        score: LocalizedString,
        templates: InsightTemplateStore,
        params: CorrelationSpec.Params,
    ): Card {
        val locked = templates.template(LOCKED_TEMPLATE_ID)?.text ?: ASSOCIATION_NOT_CAUSE_FALLBACK
        return when (outcome) {
            is CorrelationOutcome.Suppressed -> {
                val s = outcome.suppression
                val templateId = when (s.reason) {
                    is CorrelationSuppressionReason.TooFewObservedDays -> "journal_correlation_needs_days"
                    is CorrelationSuppressionReason.TooFewDaysWithBehavior -> "journal_correlation_needs_with_days"
                    is CorrelationSuppressionReason.TooFewDaysWithoutBehavior -> "journal_correlation_needs_without_days"
                }
                Card(
                    metricId = CorrelationMetricId.metricId(s.behaviorId, s.scoreId),
                    templateId = templateId,
                    casualText = fill(
                        templates, templateId,
                        mapOf(
                            "behavior" to behavior, "score" to score,
                            "days" to plain(s.reason.moreDaysNeeded.toString()),
                            "nWith" to plain(s.nWith.toString()),
                            "nWithout" to plain(s.nWithout.toString()),
                            "n" to plain(s.nObserved.toString()),
                        ),
                    ),
                    powerText = null, contextNote = null,
                    associationNotCause = locked, isSuppressed = true,
                )
            }

            is CorrelationOutcome.Finding -> {
                val f = outcome.finding
                val templateId = when (f.direction) {
                    CorrelationDirection.HIGHER -> "journal_correlation_higher"
                    CorrelationDirection.LOWER -> "journal_correlation_lower"
                    CorrelationDirection.NO_CLEAR_ASSOCIATION -> "journal_correlation_none"
                }
                val counts = mapOf(
                    "behavior" to behavior, "score" to score,
                    "n" to plain(f.nObserved.toString()),
                    "nWith" to plain(f.nWith.toString()),
                    "nWithout" to plain(f.nWithout.toString()),
                )
                Card(
                    metricId = f.metricId,
                    templateId = templateId,
                    casualText = fill(templates, templateId, counts),
                    powerText = fill(
                        templates, "journal_correlation_power_detail",
                        counts + mapOf(
                            "delta" to plain(twoDecimals(f.delta)),
                            "ciLow" to plain(twoDecimals(f.ciLow)),
                            "ciHigh" to plain(twoDecimals(f.ciHigh)),
                            "confidence" to plain(twoDecimals(f.confidence)),
                            "iterations" to plain(params.bootstrapIterations.toString()),
                        ),
                    ),
                    contextNote = if (f.contextDays > 0) {
                        fill(templates, "journal_correlation_context",
                            mapOf("days" to plain(f.contextDays.toString())))
                    } else {
                        null
                    },
                    associationNotCause = locked, isSuppressed = false,
                )
            }
        }
    }

    /** Fill a template in both languages at once, using the same substitution the status-explanation
     *  path uses — extending the existing rendering path rather than forking a second one. */
    private fun fill(
        templates: InsightTemplateStore,
        templateId: String,
        values: Map<String, LocalizedString>,
    ): LocalizedString {
        val template = templates.template(templateId) ?: return LocalizedString(en = "", ar = "")
        return LocalizedString(
            en = InsightEngine.fill(template.textEn, values.mapValues { it.value.en }),
            ar = InsightEngine.fill(template.textAr, values.mapValues { it.value.ar }),
        )
    }

    /** A token that is the same in both languages (a numeral). Digits stay Latin here for the same
     *  reason `InsightEngine.formatValue` leaves them Latin — the Arabic-digit preference lives in
     *  the app-layer customization profile, which the domain layer must not depend on. */
    private fun plain(value: String): LocalizedString = LocalizedString(en = value, ar = value)

    /** Two decimals, ROOT-locale fixed so the string is identical on both platforms and in every
     *  locale — a Cliff's delta rendered as "0,42" in one place and "0.42" in another would break
     *  the cross-platform golden for no gain. */
    fun twoDecimals(value: Double): String = String.format(java.util.Locale.ROOT, "%.2f", value)
}
