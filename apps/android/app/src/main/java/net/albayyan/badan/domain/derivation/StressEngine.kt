package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow
import net.albayyan.badan.domain.journal.ContextAnnotation
import net.albayyan.badan.domain.journal.ContextAnnotationResolver
import net.albayyan.badan.domain.journal.NO_CONTEXT_ANNOTATIONS

/**
 * EPIC-34 — the device-gated stress monitor. **The gate is the feature.** Mirror of iOS `StressEngine`.
 *
 * Plan §11 calls a real-time stress index "the biggest false-precision trap in the plan", and the
 * reason is physical, not editorial: a watch-class wearable writes a handful of HRV samples a day,
 * most of them overnight. A live "your stress is 62 right now" built on that would be fiction with a
 * ring around it. So this engine's primary output is not a number — it is a DECISION about whether
 * BADAN has earned the right to say anything at all:
 *
 * 1. **Density detector.** Daytime HRV sampling rate (samples per WAKING hour — sleep sessions
 *    excluded, because daytime is the entire point) measured over a trailing week.
 * 2. **Three surface states, and only three** ([StressSurface], a sealed type so a surface cannot
 *    invent a fourth): [StressSurface.Dense] (vendor-grade, Phase 4 — the intraday index is NOT
 *    implemented here and [StressEngine.INTRADAY_INDEX_IMPLEMENTED] says so in code),
 *    [StressSurface.Moderate] (a DAILY low-confidence trend, confidence capped by the contract), and
 *    [StressSurface.Hidden] (no surface, plus an explanation of why — the default for watch-only data,
 *    phrased as a fact about the DEVICE, never about the user or about BADAN).
 * 3. **No live number, ever, on phone/watch-class data.** Every value is keyed `day:<key>` and
 *    describes a window ending on that day; [StressTrend] carries that window so a surface cannot
 *    relabel it "now". No notifications are raised from this engine in this phase.
 *
 * **The trend method** (published in `docs/algorithms/stress.md`): each day's daytime HRV samples
 * collapse to a robust median; that daily value is read as a log-domain z against the person's own
 * recent *daytime* reference (median + MAD over `referenceWindowDays`); the z is inverted (lower HRV
 * than usual = more autonomic load) and mapped onto 0–100 around a neutral 50; the trend is the
 * recency-weighted mean of those daily loads across a sliding window.
 *
 * The reference is deliberately **not** the EPIC-23 `heart.hrv` baseline: that baseline is dominated
 * by overnight readings, and overnight HRV runs systematically higher than daytime HRV, so reading a
 * daytime median against it would print "elevated load" every day. Daytime is compared with daytime
 * or with nothing.
 *
 * Append-only and clock-injected (INVARIANT I2). The whole decision core ([evaluate], [classify],
 * [dailyLoad], [trendValue]) is pure and static so it gates at byte-identical boundaries to iOS — a
 * gate that differs by platform is not a gate.
 */
class StressEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: StressSpec = StressSpec.default(),
    /**
     * EPIC-29 (plan §18). What the user declared over the day being persisted. A function, not the
     * sensitive repository — see [ContextAnnotationResolver]. Only [compute] consults it: [evaluate]
     * is the read path and stores nothing, so there is nothing there for a ceiling to cap.
     */
    private val contextAnnotations: ContextAnnotationResolver = NO_CONTEXT_ANNOTATIONS,
) {
    /** Frozen identity, resolved from the contract. Rows already written keep their old id (I2). */
    val algorithm: AlgorithmVersion get() = spec.algorithm

    // MARK: - Evaluate (the gate) + compute (the gate, then maybe a row)

    /**
     * Decide what — if anything — may be shown for the local day containing [asOf]. **Writes
     * nothing**: this is the read path, safe to call when the answer is "hidden", which is the common
     * case. Returns Hidden(CONTRACT_UNAVAILABLE) when the contract did not load — an engine with no
     * constants computes nothing rather than inventing them.
     */
    fun evaluate(asOf: Long, tz: String = TimeZone.getDefault().id): StressSurface {
        if (!spec.isLoaded) return StressSurface.Hidden(StressAbsenceReason.CONTRACT_UNAVAILABLE)
        return evaluate(gatherDaytimeBuckets(asOf, tz), spec.params)
    }

    /**
     * Evaluate the day and, when the gate allows a trend, APPEND it as a `stress.day_trend`
     * [DerivedValue]. A hidden day writes nothing at all — an absence is not stored as a zero, a null
     * row or a "no data" sentinel; it is simply absent, and the surface explains it. A repeat call
     * over unchanged data is skipped by the value+version guard; a changed value, or a bumped
     * algorithm version, always appends (I2 auditability).
     */
    fun compute(asOf: Long, tz: String = TimeZone.getDefault().id): StressSurface {
        val surface = evaluate(asOf, tz)
        surface.trend?.let {
            // A hidden day never reaches here, so a hidden day also never resolves a context — the
            // "hidden days write nothing" rule covers the sensitive read too, not just the row.
            val dayStart = DayAttribution.startOfDay(asOf, tz)
            persist(it, contextAnnotations(dayStart, DayAttribution.addingDays(1, dayStart, tz)))
        }
        return surface
    }

    // MARK: - Input gathering (I/O)

    /**
     * One bucket per local day over the longest window either half of the method needs, oldest first,
     * ending on [asOf]'s local day.
     *
     * "Daytime" is the day's clock time minus every SLEEP session overlapping it — primary sleep and
     * naps alike. A nap is chronologically daytime but physiologically sleep, and HRV recorded during
     * one says nothing about waking autonomic load, so it is excluded rather than counted as a dense
     * daytime hour (which would be the easiest way to accidentally unlock the gate).
     */
    private fun gatherDaytimeBuckets(asOf: Long, tz: String): List<StressDayBucket> {
        val days = maxOf(spec.params.densityWindowDays, spec.params.referenceWindowDays)
        val today = DayAttribution.startOfDay(asOf, tz)
        val windowStart = DayAttribution.addingDays(-(days - 1), today, tz)
        val windowEnd = DayAttribution.addingDays(1, today, tz)

        val hrv = measurements.intervalRecords(MetricId.hrv, windowStart, windowEnd)
            .filter { it.value.isFinite() && it.value > 0 }
        // A sleep session that STARTED before the window can still cover its first morning, so the
        // session query reaches back a day further than the buckets do.
        val sleepWindows = measurements
            .sessions(null, DayAttribution.addingDays(-1, windowStart, tz), windowEnd)
            .filter { it.kind.isSleep }
            .map { it.startAt to it.endAt }

        val buckets = ArrayList<StressDayBucket>()
        var dayStart = windowStart
        while (dayStart < windowEnd) {
            val dayEnd = DayAttribution.addingDays(1, dayStart, tz)
            val asleepMillis = overlapMillis(sleepWindows, dayStart, dayEnd)
            val dayMillis = (dayEnd - dayStart).toDouble() // 23/24/25h — DST-correct via Calendar
            // Samples are placed by their INSTANT inside the day's window, not by each record's own
            // timezone (the day-attribution rule the sibling engines use for daily aggregates). The
            // question here is "how much of this waking window did the device sample", which is an
            // arithmetic over real elapsed time — attributing a reading to a different calendar day
            // than the hours it is being divided by would break the rate, not fix it.
            val samples = hrv
                .filter { it.startAt in dayStart until dayEnd && !isAsleep(it.startAt, sleepWindows) }
                .map { it.value }
            buckets.add(
                StressDayBucket(
                    dayKey = DayAttribution.localDayKey(dayStart, tz),
                    daytimeHours = maxOf(0.0, dayMillis - asleepMillis) / 3_600_000.0,
                    daytimeHrv = samples,
                ),
            )
            dayStart = dayEnd
        }
        return buckets
    }

    // MARK: - Persistence (append-only, I2)

    private fun persist(trend: StressTrend, context: ContextAnnotation = ContextAnnotation.NONE) {
        val periodKey = "day:${trend.dayKey}"
        val unit = registry.definitionOrFallback(MetricId.stressDayTrend).canonicalUnit
        // The only thing a declared context reaches in this engine. `trend.value` goes onto the row
        // verbatim below; the ceiling stacks UNDER the contract's own density cap by the same `min`,
        // so a moderate-density trend declared inside a travel window ends up at the lower of the
        // two — never above either.
        val confidence = context.applyingTo(trend.confidence) ?: trend.confidence
        // The algorithm identity is part of the skip check: a version bump that recomputes the same
        // value must still append, or the day's latest row would keep the OLD version id and the
        // change would go unrecorded (mirrors ReadinessEngine/EffortEngine).
        val existing = derivation.latestDerived(MetricId.stressDayTrend, periodKey)
        if (existing != null && existing.algorithmId == algorithm.algorithmId &&
            existing.algorithmVersion == algorithm.semver && existing.unit == unit &&
            existing.provisional == trend.provisional &&
            approximatelyEqual(existing.value, trend.value) &&
            approximatelyEqual(existing.confidence ?: -1.0, confidence)
        ) {
            return
        }
        // One manifest input per CONTRIBUTING DAY: `value` = that day's daytime HRV median, `weight` =
        // the recency weight it carried. `recordId` is a day token rather than a raw-row id because a
        // day's value aggregates every daytime sample on it — the lineage is "the daytime `heart.hrv`
        // samples on this day" (I1/I5), exactly as EffortEngine does with its zone tokens.
        val manifest = InputManifest(
            id = Ulid.newId(),
            inputs = trend.contributions.map {
                InputManifest.Input(
                    recordId = "day:${it.dayKey}#daytime_hrv", metricId = MetricId.hrv,
                    value = it.dayValue, weight = it.weight,
                )
            },
        )
        derivation.insertManifest(manifest)
        val now = clock.now()
        derivation.appendDerived(
            DerivedValue(
                id = Ulid.newId(), metricId = MetricId.stressDayTrend, value = trend.value, unit = unit,
                periodKey = periodKey, confidence = confidence, provisional = trend.provisional,
                algorithmId = algorithm.algorithmId, algorithmVersion = algorithm.semver,
                inputManifestId = manifest.id, computedAt = now, updatedAt = now, originDeviceId = deviceId,
            ),
        )
    }

    companion object {
        /**
         * Whether this build computes the dense-density intraday index. **False, and stated in code.**
         * The Dense surface state exists so the shape is fixed and the read model is honest about what
         * it holds; the intraday index itself is Phase-4 work behind vendor ingestion. A surface
         * reading Dense must render the daily trend and say the intraday view is not available yet.
         */
        const val INTRADAY_INDEX_IMPLEMENTED = false

        // MARK: - Pure decision core (identical on both platforms — golden-tested)

        /**
         * The whole gate-then-trend decision, pure. [buckets] are consecutive local days, oldest
         * first, with the day being evaluated LAST. Both platforms run exactly this, so the
         * boundaries cannot drift between them.
         */
        fun evaluate(buckets: List<StressDayBucket>, params: StressParams): StressSurface {
            val today = buckets.lastOrNull() ?: return StressSurface.Hidden(StressAbsenceReason.NO_DAYTIME_HRV)

            val density = measureDensity(buckets, params)
            val state = classify(density, params)
            if (state == StressDensityState.INSUFFICIENT) {
                return StressSurface.Hidden(absenceReason(density, params))
            }

            // Daily values: a day with too few daytime samples is a GAP, never an imputed value. The
            // day's value is the MEDIAN of its daytime samples — robust, so one artefactual reading
            // cannot carry the day.
            val dayValues = HashMap<String, Double>()
            for (bucket in buckets) {
                if (bucket.daytimeHrv.size >= params.minDaytimeSamplesPerDay) {
                    dayValues[bucket.dayKey] = BaselineEngine.median(bucket.daytimeHrv)
                }
            }

            // The personal DAYTIME reference over the trailing reference window (log domain — HRV is
            // right-skewed, matching docs/algorithms/baselines.md).
            val referenceValues = buckets.takeLast(params.referenceWindowDays).mapNotNull { dayValues[it.dayKey] }
            val reference = if (referenceValues.size >= params.minReferenceDays) reference(referenceValues) else null
            if (reference == null) {
                return StressSurface.Hidden(StressAbsenceReason.STILL_LEARNING_DAYTIME_PATTERN)
            }

            // The sliding trend window ends on the evaluated day; days inside it that produced no
            // value are simply absent (gaps, not zeros). Age comes from the bucket ORDER — the buckets
            // are already consecutive calendar days, so this stays correct across DST and month ends.
            val trendDays = buckets.takeLast(params.trendWindowDays)
            val lastIndex = trendDays.size - 1
            val contributions = trendDays.mapIndexedNotNull { index, bucket ->
                val value = dayValues[bucket.dayKey] ?: return@mapIndexedNotNull null
                StressDayContribution(
                    dayKey = bucket.dayKey, dayValue = value,
                    load = dailyLoad(value, reference, params),
                    weight = recencyWeight((lastIndex - index).toDouble(), params),
                )
            }
            if (contributions.size < params.minTrendDays) {
                return StressSurface.Hidden(StressAbsenceReason.TOO_FEW_RECENT_DAYS)
            }

            val value = trendValue(contributions)
            val cap = if (state == StressDensityState.DENSE) params.denseConfidenceCap else params.moderateConfidenceCap
            val coverage = contributions.size.toDouble() / maxOf(1, params.trendWindowDays)
            val maturity = minOf(1.0, referenceValues.size.toDouble() / maxOf(1, params.referenceWindowDays))
            val confidence = minOf(cap, maxOf(0.0, coverage * maturity))
            // A moderate-density trend is provisional BY CONSTRUCTION, independent of whether the
            // algorithm's own constants are validated: sparse daytime sampling cannot produce an
            // established reading, and the row must say so wherever it is read.
            val provisional = params.algorithmProvisional || state != StressDensityState.DENSE

            val trend = StressTrend(
                dayKey = today.dayKey, value = value, band = band(value, params),
                confidence = confidence, provisional = provisional, densityState = state,
                density = density, daysPresent = contributions.size, windowDays = params.trendWindowDays,
                contributions = contributions,
            )
            return if (state == StressDensityState.DENSE) StressSurface.Dense(trend) else StressSurface.Moderate(trend)
        }

        /**
         * Daytime HRV sampling density over the trailing `densityWindowDays` buckets. Counts EVERY
         * daytime sample, including those on days too thin to contribute a value — density is a
         * question about how the device samples, not about which days end up usable.
         */
        fun measureDensity(buckets: List<StressDayBucket>, params: StressParams): StressDensity {
            val window = buckets.takeLast(params.densityWindowDays)
            val samples = window.sumOf { it.daytimeHrv.size }
            val hours = window.sumOf { it.daytimeHours }
            val daysWithSamples = window.count { it.daytimeHrv.isNotEmpty() }
            return StressDensity(
                samplesPerHour = if (hours > 0) samples / hours else 0.0,
                daytimeSamples = samples, daytimeHours = hours,
                daysWithSamples = daysWithSamples, windowDays = window.size,
            )
        }

        /**
         * The gate itself. Thresholds are contract data; the ordering (dense before moderate) and the
         * inclusive `>=` boundaries are the published behaviour — a value exactly ON a threshold
         * clears it, which is what the boundary fixtures on both platforms pin.
         */
        fun classify(density: StressDensity, params: StressParams): StressDensityState {
            if (density.daytimeHours < params.minDaytimeHoursInWindow ||
                density.daysWithSamples < params.minDaysWithDaytimeSamples
            ) {
                return StressDensityState.INSUFFICIENT
            }
            if (density.samplesPerHour >= params.denseMinSamplesPerHour) return StressDensityState.DENSE
            if (density.samplesPerHour >= params.moderateMinSamplesPerHour) return StressDensityState.MODERATE
            return StressDensityState.INSUFFICIENT
        }

        /**
         * Why a window failed the gate. Ordered most-specific first so the explanation names the
         * actual obstacle: no daytime readings at all is a different sentence from "some, but not
         * often enough", and both differ from "the week has barely any waking time recorded".
         */
        fun absenceReason(density: StressDensity, params: StressParams): StressAbsenceReason {
            if (density.daytimeSamples == 0) return StressAbsenceReason.NO_DAYTIME_HRV
            if (density.daytimeHours < params.minDaytimeHoursInWindow) return StressAbsenceReason.NOT_ENOUGH_WAKING_COVERAGE
            if (density.daysWithSamples < params.minDaysWithDaytimeSamples) return StressAbsenceReason.TOO_FEW_DAYS_COVERED
            return StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE
        }

        /**
         * The personal daytime reference: robust centre and spread of `ln(value)`. Null when nothing
         * usable survives (all non-positive) — no reference, no reading.
         */
        fun reference(values: List<Double>): StressReference? {
            val usable = values.filter { it > 0 }
            if (usable.isEmpty()) return null
            val logs = usable.map { ln(it) }
            val center = BaselineEngine.median(logs)
            return StressReference(center, BaselineEngine.mad(logs, center), usable.size)
        }

        /**
         * One day's autonomic-load sub-score on 0–100, where **50 is your own usual**. The sign is
         * inverted relative to HRV: a daytime median BELOW your reference reads above 50 (more load),
         * above it reads below 50. A zero-spread reference (a perfectly flat fortnight) yields exactly
         * the neutral 50 rather than an infinite z — flat data is not evidence of anything.
         */
        fun dailyLoad(dayValue: Double, reference: StressReference, params: StressParams): Double {
            if (dayValue <= 0 || reference.logMad <= 0 || params.zClampSigmas <= 0) return 50.0
            val z = (ln(dayValue) - reference.logCenter) / (params.madToSigma * reference.logMad)
            val clamped = minOf(params.zClampSigmas, maxOf(-params.zClampSigmas, z))
            return 50 - clamped / params.zClampSigmas * 50
        }

        /**
         * Recency weight for a day [ageDays] before the evaluated day: `0.5^(ageDays / halfLifeDays)`.
         * In DAYS — there is no intraday smoothing constant in this engine because there is no
         * intraday output to smooth.
         */
        fun recencyWeight(ageDays: Double, params: StressParams): Double {
            if (params.trendHalfLifeDays <= 0) return 1.0
            return 0.5.pow(maxOf(0.0, ageDays) / params.trendHalfLifeDays)
        }

        /**
         * The published trend value: the recency-weighted mean of the present daily loads. Bounded to
         * 0–100 by construction (a convex combination of values already in that range).
         */
        fun trendValue(contributions: List<StressDayContribution>): Double {
            val totalWeight = contributions.sumOf { it.weight }
            if (totalWeight <= 0) return 50.0
            return contributions.sumOf { it.load * it.weight } / totalWeight
        }

        /**
         * Coarse direction band around the neutral 50. Deliberately blunt: the honest output of a
         * sparse-input trend is a direction, and a band boundary is easier to defend than a decimal.
         */
        fun band(value: Double, params: StressParams): StressTrendBand = when {
            value > 50 + params.bandNeutralHalfWidth -> StressTrendBand.HIGHER_THAN_USUAL
            value < 50 - params.bandNeutralHalfWidth -> StressTrendBand.LOWER_THAN_USUAL
            else -> StressTrendBand.ABOUT_USUAL
        }

        /**
         * Total milliseconds of `[from, to)` covered by any of [windows]. Overlapping sleep sessions
         * (two devices recording the same night, both still live because dedup suppresses rather than
         * deletes) are unioned, not summed — double-counting them would shrink the waking day and
         * inflate the samples-per-hour rate, precisely the direction the gate must never err in.
         */
        fun overlapMillis(windows: List<Pair<Long, Long>>, from: Long, to: Long): Double {
            val clipped = windows
                .map { maxOf(it.first, from) to minOf(it.second, to) }
                .filter { it.first < it.second }
                .sortedBy { it.first }
            if (clipped.isEmpty()) return 0.0
            var total = 0L
            var runStart = clipped[0].first
            var runEnd = clipped[0].second
            for (i in 1 until clipped.size) {
                val (s, e) = clipped[i]
                if (s <= runEnd) {
                    runEnd = maxOf(runEnd, e)
                } else {
                    total += runEnd - runStart
                    runStart = s
                    runEnd = e
                }
            }
            total += runEnd - runStart
            return total.toDouble()
        }

        fun isAsleep(instant: Long, windows: List<Pair<Long, Long>>): Boolean =
            windows.any { instant >= it.first && instant < it.second }

        fun approximatelyEqual(a: Double, b: Double, tolerance: Double = 1e-9): Boolean = abs(a - b) < tolerance
    }
}

// MARK: - Inputs

/**
 * One local day's daytime evidence: how many WAKING hours the day contained (day length minus every
 * sleep session overlapping it) and the daytime `heart.hrv` values recorded in them. Pure input to the
 * decision core, so both platforms feed the gate the same shape.
 */
data class StressDayBucket(
    val dayKey: String,
    val daytimeHours: Double,
    val daytimeHrv: List<Double>,
)

/**
 * The measured daytime sampling density — the evidence the gate rules on, carried into the read model
 * so power mode can show the numbers behind a hidden surface ("14 readings across 112 waking hours")
 * rather than an unexplained absence.
 */
data class StressDensity(
    val samplesPerHour: Double,
    val daytimeSamples: Int,
    val daytimeHours: Double,
    val daysWithSamples: Int,
    val windowDays: Int,
)

/**
 * The person's own recent daytime HRV reference, in the log domain (HRV is right-skewed). [nDays] is
 * how many daily values it was built from — the maturity term in the trend's confidence.
 */
data class StressReference(val logCenter: Double, val logMad: Double, val nDays: Int)

// MARK: - Surface states

/**
 * What the density detector concluded. Three values, matching the three surfaces — there is no
 * "partial" or "estimated" tier, because a tier that exists to soften a gate is a gate that does not
 * hold. Mirror of iOS `StressDensityState`.
 */
enum class StressDensityState(val code: String) {
    /**
     * Vendor-grade continuous daytime sampling. Would support an intraday index; this build does not
     * compute one ([StressEngine.INTRADAY_INDEX_IMPLEMENTED]).
     */
    DENSE("dense"),

    /** Enough daytime sampling for a DAILY trend and nothing finer. */
    MODERATE("moderate"),

    /** Not enough to say anything. The surface is hidden with an explanation. */
    INSUFFICIENT("insufficient"),
}

/**
 * Why nothing is shown. Every case is a statement about the DATA or the DEVICE — never about the user,
 * and never phrased as BADAN having failed. The bilingual copy lives on the reason itself (the pattern
 * `DeviationEngine` uses for its annotations) so an absence cannot ship unexplained: there is no code
 * path that produces a hidden surface without a rendered sentence attached.
 */
enum class StressAbsenceReason(val code: String) {
    /**
     * Daytime HRV exists but is too infrequent for any honest reading. **The default for watch-only
     * users**, and the reason this epic is a gate before it is a score.
     */
    DAYTIME_HRV_TOO_SPARSE("daytimeHrvTooSparse"),

    /** No daytime HRV at all in the window — no wearable, or none worn during waking hours. */
    NO_DAYTIME_HRV("noDaytimeHrv"),

    /** Readings exist but land on too few separate days to describe a week. */
    TOO_FEW_DAYS_COVERED("tooFewDaysCovered"),

    /**
     * The window barely contains any waking, recorded time, so a samples-per-hour rate would be
     * arithmetic rather than evidence.
     */
    NOT_ENOUGH_WAKING_COVERAGE("notEnoughWakingCoverage"),

    /**
     * Sampling is dense enough, but there is not yet enough daytime history to know what this person's
     * usual daytime pattern *is*. A calibration state, deliberately distinct from the device-sparsity
     * ones — telling an Oura user their device samples too rarely would be false.
     */
    STILL_LEARNING_DAYTIME_PATTERN("stillLearningDaytimePattern"),

    /** Too few days inside the trend window carried a usable value. */
    TOO_FEW_RECENT_DAYS("tooFewRecentDays"),

    /** The algorithm contract did not load, so the engine has no constants and computes nothing. */
    CONTRACT_UNAVAILABLE("contractUnavailable"),
    ;

    /** The explanation shown in place of the surface. Wellness-safe, device-factual, en + ar. */
    val explanation: LocalizedString
        get() = when (this) {
            DAYTIME_HRV_TOO_SPARSE -> LocalizedString(
                en = "Your device doesn't record daytime heart-rate variability often enough for this.",
                ar = "جهازك لا يسجّل تغيّر معدل ضربات القلب أثناء النهار بالتكرار الكافي لهذا المؤشر.",
            )
            NO_DAYTIME_HRV -> LocalizedString(
                en = "No daytime heart-rate variability readings arrived this week, so there's nothing to read here.",
                ar = "لم تصل أي قراءات لتغيّر معدل ضربات القلب أثناء النهار هذا الأسبوع، فلا شيء يمكن عرضه هنا.",
            )
            TOO_FEW_DAYS_COVERED -> LocalizedString(
                en = "Daytime readings arrived on too few days this week to describe a pattern.",
                ar = "وصلت قراءات نهارية في أيام قليلة جداً هذا الأسبوع لوصف نمط معيّن.",
            )
            NOT_ENOUGH_WAKING_COVERAGE -> LocalizedString(
                en = "There aren't enough recorded waking hours this week to judge how often your device samples.",
                ar = "لا توجد ساعات يقظة مسجّلة كافية هذا الأسبوع لتقدير مدى تكرار قياسات جهازك.",
            )
            STILL_LEARNING_DAYTIME_PATTERN -> LocalizedString(
                en = "Still learning your usual daytime pattern — this needs a few more weeks of readings.",
                ar = "ما زلنا نتعرّف على نمطك النهاري المعتاد — يحتاج هذا إلى أسابيع إضافية من القراءات.",
            )
            TOO_FEW_RECENT_DAYS -> LocalizedString(
                en = "Too few days with daytime readings in the last week to show a trend.",
                ar = "عدد الأيام التي تحتوي قراءات نهارية خلال الأسبوع الماضي أقل من أن يُظهر اتجاهاً.",
            )
            CONTRACT_UNAVAILABLE -> LocalizedString(
                en = "This measure isn't available in this version of the app.",
                ar = "هذا المؤشر غير متاح في هذه النسخة من التطبيق.",
            )
        }
}

/**
 * The direction band around the neutral 50 — the casual altitude's whole vocabulary. Never "high
 * stress"/"low stress": a direction relative to the person's own usual, nothing more.
 */
enum class StressTrendBand(val code: String) {
    LOWER_THAN_USUAL("lowerThanUsual"),
    ABOUT_USUAL("aboutUsual"),
    HIGHER_THAN_USUAL("higherThanUsual"),
}

/**
 * One day's line in the trend's anatomy: its daytime HRV median, the 0–100 load it mapped to, and the
 * recency weight it carried. Power mode renders the contribution bars straight off the manifest.
 */
data class StressDayContribution(
    val dayKey: String,
    val dayValue: Double,
    val load: Double,
    val weight: Double,
)

/**
 * A computed daily trend. It describes the **window ending on [dayKey]** — [windowDays] and
 * [daysPresent] travel with the value precisely so a surface cannot relabel it "now". There is no
 * timestamp field here, and that omission is deliberate: this type structurally cannot express a live
 * reading.
 */
data class StressTrend(
    val dayKey: String,
    /** 0–100, 50 = your own usual daytime pattern. Higher = more autonomic load than usual. */
    val value: Double,
    val band: StressTrendBand,
    /**
     * Capped by the contract for a moderate-density window (`moderateConfidenceCap`) — a sparse input
     * can never present as a confident reading.
     */
    val confidence: Double,
    val provisional: Boolean,
    val densityState: StressDensityState,
    val density: StressDensity,
    val daysPresent: Int,
    val windowDays: Int,
    val contributions: List<StressDayContribution>,
)

/**
 * **The three surfaces EPIC-34 may present, and no others.** A sealed type rather than a class with
 * optional fields, so a UI cannot assemble a fourth state (a "live" reading, or a trend without its
 * hidden-state explanation) out of the parts. Mirror of iOS `StressSurface`.
 */
sealed class StressSurface {
    /**
     * Vendor-grade density detected. The payload is still the DAILY trend: the intraday index is
     * Phase-4 work and [StressEngine.INTRADAY_INDEX_IMPLEMENTED] is false, so a surface in this state
     * renders the trend and says the intraday view is not available yet. Presenting this case as a
     * live number would be a defect.
     */
    data class Dense(val value: StressTrend) : StressSurface()

    /** A daily, explicitly low-confidence trend. The only state that renders a number today. */
    data class Moderate(val value: StressTrend) : StressSurface()

    /**
     * Nothing is shown, and `reason.explanation` says why. A first-class shipped state — the honest
     * default for phone-and-watch-only data, not an error and not an empty placeholder.
     */
    data class Hidden(val reason: StressAbsenceReason) : StressSurface()

    /**
     * The trend, when there is one. Null for [Hidden] — the only shape in which absence is
     * expressible, which is why nothing downstream can fabricate a value for a hidden day.
     */
    val trend: StressTrend?
        get() = when (this) {
            is Dense -> value
            is Moderate -> value
            is Hidden -> null
        }

    val absenceReason: StressAbsenceReason?
        get() = (this as? Hidden)?.reason
}

// MARK: - Spec (data-driven params, mirror of ReadinessSpec/EffortSpec)

/**
 * The numeric params the pure core needs. Resolved once from `stress.day_trend` in `algorithms.json`;
 * the pure functions take THIS, never the registry, so they stay I/O-free.
 */
data class StressParams(
    // Density gate
    val densityWindowDays: Int,
    val denseMinSamplesPerHour: Double,
    val moderateMinSamplesPerHour: Double,
    val minDaysWithDaytimeSamples: Int,
    val minDaytimeHoursInWindow: Double,
    val minDaytimeSamplesPerDay: Int,
    // Trend
    val referenceWindowDays: Int,
    val minReferenceDays: Int,
    val trendWindowDays: Int,
    val minTrendDays: Int,
    val trendHalfLifeDays: Double,
    val zClampSigmas: Double,
    val bandNeutralHalfWidth: Double,
    val moderateConfidenceCap: Double,
    val denseConfidenceCap: Double,
    /**
     * The MAD→sigma consistency constant, read from the BASELINE contract entry rather than
     * re-declared here. The baseline entry's own note calls it not-tunable ("changing it changes what
     * the band means"), so a second copy of it in this block would be exactly the hand-copied constant
     * table `algorithms.json` exists to prevent.
     */
    val madToSigma: Double,
    /** From the contract entry's `provisional` flag. */
    val algorithmProvisional: Boolean,
)

/**
 * The data-driven Stress spec. The ONLY place the gate thresholds and trend constants enter the engine
 * — never hardcoded — so the two platforms cannot drift and a change is a reviewable contract diff plus
 * a semver bump. A spec that failed to load ([isLoaded] == false) makes the engine hide with
 * CONTRACT_UNAVAILABLE rather than invent constants.
 */
data class StressSpec(
    val algorithm: AlgorithmVersion,
    val params: StressParams,
    val isLoaded: Boolean,
) {
    companion object {
        private const val CONTRACT_ID = "stress.day_trend"
        private const val BASELINE_CONTRACT_ID = "baseline.rolling_median_mad"

        fun load(registry: AlgorithmRegistry): StressSpec {
            val def = registry.definition(CONTRACT_ID) ?: return unavailable
            val madToSigma = registry.param(BASELINE_CONTRACT_ID, "madToSigma") ?: return unavailable
            val p = def.params
            val params = StressParams(
                densityWindowDays = (p["densityWindowDays"] ?: return unavailable).toInt(),
                denseMinSamplesPerHour = p["denseMinSamplesPerHour"] ?: return unavailable,
                moderateMinSamplesPerHour = p["moderateMinSamplesPerHour"] ?: return unavailable,
                minDaysWithDaytimeSamples = (p["minDaysWithDaytimeSamples"] ?: return unavailable).toInt(),
                minDaytimeHoursInWindow = p["minDaytimeHoursInWindow"] ?: return unavailable,
                minDaytimeSamplesPerDay = (p["minDaytimeSamplesPerDay"] ?: return unavailable).toInt(),
                referenceWindowDays = (p["referenceWindowDays"] ?: return unavailable).toInt(),
                minReferenceDays = (p["minReferenceDays"] ?: return unavailable).toInt(),
                trendWindowDays = (p["trendWindowDays"] ?: return unavailable).toInt(),
                minTrendDays = (p["minTrendDays"] ?: return unavailable).toInt(),
                trendHalfLifeDays = p["trendHalfLifeDays"] ?: return unavailable,
                zClampSigmas = p["zClampSigmas"] ?: return unavailable,
                bandNeutralHalfWidth = p["bandNeutralHalfWidth"] ?: return unavailable,
                moderateConfidenceCap = p["moderateConfidenceCap"] ?: return unavailable,
                denseConfidenceCap = p["denseConfidenceCap"] ?: return unavailable,
                madToSigma = madToSigma,
                algorithmProvisional = def.provisional,
            )
            return StressSpec(def.algorithmVersion, params, isLoaded = true)
        }

        /** The app-default spec, resolved once from the classpath contract mirror. */
        fun default(): StressSpec = cachedDefault

        private val cachedDefault: StressSpec by lazy { load(AlgorithmRegistry.fromClasspath()) }

        /**
         * The degenerate "the contract did not load" spec. The gate then answers Hidden for every
         * window — an engine with no thresholds must not guess where the thresholds are.
         */
        val unavailable = StressSpec(
            algorithm = AlgorithmVersion(algorithmId = CONTRACT_ID, semver = "0.0.0", introducedIn = "0.0.0"),
            params = StressParams(
                densityWindowDays = 0,
                denseMinSamplesPerHour = Double.POSITIVE_INFINITY,
                moderateMinSamplesPerHour = Double.POSITIVE_INFINITY,
                minDaysWithDaytimeSamples = Int.MAX_VALUE,
                minDaytimeHoursInWindow = Double.POSITIVE_INFINITY,
                minDaytimeSamplesPerDay = Int.MAX_VALUE,
                referenceWindowDays = 0,
                minReferenceDays = Int.MAX_VALUE,
                trendWindowDays = 0,
                minTrendDays = Int.MAX_VALUE,
                trendHalfLifeDays = 0.0,
                zClampSigmas = 0.0,
                bandNeutralHalfWidth = 0.0,
                moderateConfidenceCap = 0.0,
                denseConfidenceCap = 0.0,
                madToSigma = 0.0,
                algorithmProvisional = true,
            ),
            isLoaded = false,
        )
    }
}
