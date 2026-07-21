package net.albayyan.badan.domain.derivation

import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.ontology.AlgorithmRegistry
import kotlin.math.min

/**
 * How a metric's values are transformed before the robust median/MAD band is drawn over them.
 *
 * [IDENTITY] bands the values directly. [LOG] takes the median and MAD on `ln(value)` and
 * exponentiates the result back — the honest shape for a log-normal vital like HRV (RMSSD/SDNN),
 * whose distribution is right-skewed, so a symmetric linear band would put the lower edge below what
 * the body ever produces and clip the long upper tail (plan §18, `whoop.md` §5). The band that comes
 * back is therefore ASYMMETRIC in linear units, which is the point. Mirror of iOS `BaselineTransform`.
 */
enum class BaselineTransform(val code: String) {
    IDENTITY("identity"),
    LOG("log");

    companion object {
        /**
         * An unknown transform string from a future contract revision reads as [IDENTITY] rather
         * than failing — a metric BADAN does not yet know how to log-band still gets a plain band
         * instead of no baseline at all.
         */
        fun fromContract(raw: String): BaselineTransform = entries.firstOrNull { it.code == raw } ?: IDENTITY
    }
}

/**
 * The calibration maturity of a baseline, surfaced so a score card can say "day 9 of 14" and a
 * still-thin band is never dressed up as an established personal normal (plan §18 cold-start rule).
 * Mirror of iOS `BaselineTier`.
 */
enum class BaselineTier(val code: String) {
    PROVISIONAL("provisional"),
    ESTABLISHING("establishing"),
    ESTABLISHED("established");
}

/**
 * The window (in days) and transform a given metric's baseline is built over, resolved from the
 * contract's per-metric `windowTable` with a fallback to the default window / identity transform.
 */
data class BaselineWindowResolution(val windowDays: Int, val transform: BaselineTransform)

/**
 * The pure output of the baseline math for one metric's windowed values — everything the engine
 * needs to materialize a [Baseline] row, with no I/O or clock in sight, so both platforms compute
 * byte-identical numbers from the same inputs (the acceptance goldens assert exactly this).
 */
data class BaselineComputation(
    val center: Double,
    val spread: Double,
    val bandLow: Double,
    val bandHigh: Double,
    /**
     * Count of daily points that actually fed the band, AFTER outlier rejection — this is what the
     * tier and [provisional] are judged on, so a window padded with rejected spikes does not read as
     * more-calibrated than it is.
     */
    val nPoints: Int,
    val tier: BaselineTier,
) {
    val provisional: Boolean get() = tier == BaselineTier.PROVISIONAL
}

/**
 * The data-driven baseline parameters, resolved once from the algorithm contract
 * (`baseline.rolling_median_mad` in `algorithms.json`). This is the *only* place the window table,
 * MAD constants, outlier threshold and confidence thresholds enter the engine — they are never
 * hardcoded in [BaselineEngine], so the two platforms cannot drift and a change is a reviewable
 * one-line diff in the contract plus a semver bump (plan §15; the whole reason [AlgorithmRegistry]
 * exists — audit finding #5). Mirror of iOS `BaselineSpec`.
 *
 * A spec that failed to load ([isLoaded] == false) makes the engine COMPUTE NOTHING rather than fall
 * back to invented constants — a missing contract is a packaging bug (gated by `AlgorithmRegistryTest`),
 * and a fabricated band would be indistinguishable, on the stored row, from a published one.
 */
data class BaselineSpec(
    val algorithm: AlgorithmVersion,
    val defaultWindowDays: Int,
    val minPoints: Int,
    val madToSigma: Double,
    val bandSigmas: Double,
    val outlierMadThreshold: Double,
    val establishingFraction: Double,
    val retroactiveGraceDays: Int,
    val isLoaded: Boolean,
    private val byMetric: Map<String, BaselineWindowResolution>,
) {
    /**
     * The window + transform for a metric: its explicit `windowTable` rule, else the default window
     * with an identity transform.
     */
    fun resolve(metricId: String): BaselineWindowResolution =
        byMetric[metricId] ?: BaselineWindowResolution(defaultWindowDays, BaselineTransform.IDENTITY)

    companion object {
        private const val CONTRACT_ID = "baseline.rolling_median_mad"

        /**
         * Resolve the spec from a loaded [AlgorithmRegistry]. Returns [unavailable] if the baseline
         * entry or any core constant is missing — the engine treats that as "compute nothing", never
         * as a cue to invent numbers.
         */
        fun load(registry: AlgorithmRegistry): BaselineSpec {
            val def = registry.definition(CONTRACT_ID) ?: return unavailable
            val p = def.params
            val windowDays = p["windowDays"] ?: return unavailable
            val minPoints = p["minPoints"] ?: return unavailable
            val madToSigma = p["madToSigma"] ?: return unavailable
            val bandSigmas = p["bandSigmas"] ?: return unavailable
            val outlierMadThreshold = p["outlierMadThreshold"] ?: return unavailable
            val establishingFraction = p["establishingFraction"] ?: return unavailable
            val retroactiveGraceDays = p["retroactiveGraceDays"] ?: return unavailable

            val byMetric = HashMap<String, BaselineWindowResolution>()
            for (rule in def.windowTable) {
                val resolution = BaselineWindowResolution(rule.windowDays, BaselineTransform.fromContract(rule.transform))
                for (metricId in rule.metrics) byMetric[metricId] = resolution
            }
            return BaselineSpec(
                algorithm = def.algorithmVersion, defaultWindowDays = windowDays.toInt(), minPoints = minPoints.toInt(),
                madToSigma = madToSigma, bandSigmas = bandSigmas, outlierMadThreshold = outlierMadThreshold,
                establishingFraction = establishingFraction, retroactiveGraceDays = retroactiveGraceDays.toInt(),
                isLoaded = true, byMetric = byMetric,
            )
        }

        /**
         * The app-default spec, resolved once from the classpath contract mirror. [BaselineEngine]'s
         * constructor defaults to this so the composition root — which EPIC-23 must not touch — keeps
         * wiring the engine with five arguments while it computes from published data. The classpath
         * route needs no Android Context and is the same one the pure-JVM goldens take.
         */
        fun default(): BaselineSpec = cachedDefault

        private val cachedDefault: BaselineSpec by lazy { load(AlgorithmRegistry.fromClasspath()) }

        /** The degenerate "the contract did not load" spec. Never produces a baseline. */
        val unavailable = BaselineSpec(
            algorithm = AlgorithmVersion(algorithmId = CONTRACT_ID, semver = "0.0.0", introducedIn = "0.0.0"),
            defaultWindowDays = 0, minPoints = 0, madToSigma = 0.0, bandSigmas = 0.0, outlierMadThreshold = 0.0,
            establishingFraction = 0.0, retroactiveGraceDays = 0, isLoaded = false, byMetric = emptyMap(),
        )
    }
}

/**
 * The plain read model the calibration UI renders — "day 9 of 14", the tier, the window, the
 * transform. Derived entirely from a stored [Baseline] (plus the spec for the transform, which the
 * row itself does not carry — it is reconstructable from the metric id via the published window
 * table, so nothing is stored redundantly; see `docs/algorithms/baselines.md`). No I/O, no
 * formatting: the UI lane owns the bilingual strings, this owns the numbers and the state. Mirror of
 * iOS `BaselineCalibration`.
 */
data class BaselineCalibration(
    val metricId: String,
    val tier: BaselineTier,
    /** Distinct daily points behind the band (post outlier rejection). The "9" in "day 9 of 14". */
    val nPoints: Int,
    /** The full window the band aims to fill. The "14" in "day 9 of 14". */
    val windowDays: Int,
    val transform: BaselineTransform,
    /**
     * 0..1 maturity = points / window, clamped. A blunt confidence proxy for the baseline's own
     * maturity dimension (the score engines multiply this by input completeness and source quality,
     * per plan §18); it is NOT presented as the whole confidence number here.
     */
    val maturity: Double,
    val provisional: Boolean,
) {
    companion object {
        /**
         * Build the read model from a materialized baseline. The tier is recomputed from the same
         * thresholds the engine used, so it agrees with the row's stored `provisional` by construction.
         */
        fun from(baseline: Baseline, spec: BaselineSpec): BaselineCalibration {
            val tier = BaselineEngine.classifyTier(baseline.nPoints, baseline.windowDays, spec)
            val maturity = if (baseline.windowDays > 0) {
                min(1.0, baseline.nPoints.toDouble() / baseline.windowDays.toDouble())
            } else {
                0.0
            }
            return BaselineCalibration(
                metricId = baseline.metricId, tier = tier, nPoints = baseline.nPoints,
                windowDays = baseline.windowDays, transform = spec.resolve(baseline.metricId).transform,
                maturity = maturity, provisional = tier == BaselineTier.PROVISIONAL,
            )
        }
    }
}
