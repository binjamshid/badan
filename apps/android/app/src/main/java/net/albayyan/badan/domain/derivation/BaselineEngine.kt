package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.BaselineMethod
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.min

/**
 * Recomputes personal "normal" bands and the two MVP composites (sleep efficiency, readiness
 * score). Bands are robust median + MAD over a PER-METRIC trailing window and transform, driven
 * entirely by [BaselineSpec] (the algorithm contract) rather than by constants baked in here: HRV is
 * banded in the log domain over 60 days, RHR/RR/temp over 14, sleep-need inputs over 28, everything
 * else over the default window (plan §18). MAD-based outlier rejection removes single wild readings
 * before the band is drawn, and a band stays `provisional` until it has enough points to be honest
 * about. Everything is append-only and driven by an injected [Clock], so recompute is deterministic
 * and auditable (INVARIANT I2). Mirror of iOS `BaselineEngine`.
 *
 * The heavy math ([computeBaseline], [classifyTier]) is pure and static so it produces numbers
 * byte-identical to iOS from the same inputs — that cross-platform identity is the acceptance golden.
 */
class BaselineEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
    private val spec: BaselineSpec = BaselineSpec.default(),
) {
    companion object {
        /**
         * Frozen algorithm identity, resolved from the contract (never hand-written here — a change
         * is a contract diff + semver bump, and old baseline rows keep their old id under I2).
         */
        val baselineAlgorithm: AlgorithmVersion get() = BaselineSpec.default().algorithm

        /**
         * The two legacy MVP composites keep their own frozen identities: they are pre-EPIC-24/25
         * scaffolding (a real SleepIntelligenceEngine/ReadinessEngine supersede them), carry no
         * tuning constants, and must not be rewired onto the Phase-2 contract entries here.
         */
        val efficiencyAlgorithm = AlgorithmVersion(
            algorithmId = "composite.sleep_efficiency", semver = "1.0.0", introducedIn = "1.0.0",
        )
        val readinessAlgorithm = AlgorithmVersion(
            algorithmId = "composite.readiness_score", semver = "1.0.0", introducedIn = "1.0.0",
        )

        /**
         * The "enough to be honest" point count below which a baseline stays provisional. Sourced
         * from the contract, not a literal; it is the floor of the per-metric provisional gate, which
         * also requires filling half the window (see [classifyTier]).
         */
        val minPointsForConfident: Int get() = BaselineSpec.default().minPoints

        // MARK: - Pure baseline math (identical on both platforms — golden-tested)

        /**
         * Compute the robust band for a metric's windowed per-day values. Pure and deterministic:
         * transform → MAD-based outlier rejection → robust centre/spread → band → confidence tier.
         * Returns null when nothing usable survives (e.g. a log metric whose only values are <= 0).
         *
         * For a `log` transform the median and MAD are taken on `ln(value)` and the centre/band are
         * exponentiated back, giving an ASYMMETRIC linear band (correct for a right-skewed vital). The
         * stored `spread` is the linear-equivalent upper half-width divided by `madToSigma*bandSigmas`
         * — for an identity metric that is exactly the MAD, and for a log metric it keeps
         * `(bandHigh - centre)/spread == madToSigma*bandSigmas` so the anatomy sheet's derived
         * multiplier and `Baseline.z(of)` stay meaningful without the band having to be symmetric.
         */
        fun computeBaseline(values: List<Double>, resolution: BaselineWindowResolution, spec: BaselineSpec): BaselineComputation? {
            val isLog = resolution.transform == BaselineTransform.LOG
            // A log-normal vital cannot take a non-positive value; drop rather than clamp so a sensor
            // zero is treated as missing, not as ln(0) = -inf dragging the whole band down.
            val usable = if (isLog) values.filter { it > 0.0 } else values
            if (usable.isEmpty()) return null
            val working = if (isLog) usable.map { ln(it) } else usable

            // MAD-based outlier rejection in the working (post-transform) domain. Skipped when MAD is
            // exactly 0: a zero spread cannot define an outlier, and a lone differing value in an
            // otherwise-flat window is data, not noise (keeps the FIX-07 "steady then spike" case whole).
            val med0 = median(working)
            val mad0 = mad(working, med0)
            val kept: List<Double> = if (mad0 > 0.0) {
                val threshold = spec.outlierMadThreshold * mad0
                working.filter { abs(it - med0) <= threshold }
            } else {
                working
            }
            if (kept.isEmpty()) return null

            val center = median(kept)
            val spread = mad(kept, center)
            val half = spec.madToSigma * spec.bandSigmas * spread

            val outCenter = if (isLog) exp(center) else center
            val outLow = if (isLog) exp(center - half) else center - half
            val outHigh = if (isLog) exp(center + half) else center + half
            val denom = spec.madToSigma * spec.bandSigmas
            val outSpread = if (denom > 0.0) (outHigh - outCenter) / denom else 0.0

            val n = kept.size
            val tier = classifyTier(n, resolution.windowDays, spec)
            return BaselineComputation(outCenter, outSpread, outLow, outHigh, n, tier)
        }

        /**
         * Confidence tier from point count and window (plan §18): `provisional` until there are at
         * least `minPoints` points AND at least `establishingFraction` of the window filled;
         * `established` once the window is full; `establishing` in between. Nothing renders as a score
         * while a contributing baseline is provisional.
         */
        fun classifyTier(nPoints: Int, windowDays: Int, spec: BaselineSpec): BaselineTier {
            val halfWindow = ceil(windowDays.toDouble() * spec.establishingFraction).toInt()
            val clearThreshold = maxOf(spec.minPoints, halfWindow)
            if (nPoints < clearThreshold) return BaselineTier.PROVISIONAL
            if (nPoints < windowDays) return BaselineTier.ESTABLISHING
            return BaselineTier.ESTABLISHED
        }

        /**
         * Whether a per-day derived value was "computed later from history": its `computedAt` day is
         * more than `retroactiveGraceDays` after the day it describes (e.g. a readiness day recomputed
         * once an import backfilled that week). Derived from the two stored fields rather than a stored
         * column — the fact is answerable directly from the row (I1), needs no migration, and the
         * `QualityFlag.RETROACTIVE` label is attached at read/export time exactly as
         * `provisionalBaseline` is derived from `provisional`. See `docs/algorithms/baselines.md`.
         */
        fun isRetroactive(periodDayKey: String, computedAt: Long, tz: String, spec: BaselineSpec): Boolean {
            val periodDay = DayAttribution.dateFromDayKey(periodDayKey, tz) ?: return false
            val computedDayStart = DayAttribution.startOfDay(computedAt, tz)
            val graceEnd = DayAttribution.addingDays(spec.retroactiveGraceDays, periodDay, tz)
            return computedDayStart > graceEnd
        }

        fun median(xs: List<Double>): Double {
            if (xs.isEmpty()) return 0.0
            val s = xs.sorted()
            val n = s.size
            return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2
        }

        /** Median absolute deviation about [center] — the robust spread the band is built from. */
        fun mad(xs: List<Double>, center: Double): Double =
            median(xs.map { abs(it - center) })

        fun clamp(x: Double, lo: Double, hi: Double): Double = minOf(hi, maxOf(lo, x))
    }

    // MARK: - Single-metric baseline

    /**
     * Rebuild the baseline band for one metric as of [asOf], under a covariate [context] (EPIC-39
     * prep — `"default"` is the unconditioned baseline; a cycle phase or other context stores a
     * PARALLEL band additively, never overwriting the default). Gathers the metric's per-day values
     * over ITS OWN window and materializes a fresh baseline row. No-op when the metric has no data in
     * the window, or when the spec did not load (a missing contract computes nothing rather than
     * inventing a band).
     *
     * [tz] is used only for calendar day-stepping (DATA-11), not to re-attribute any record's own day
     * (each record is still keyed by its own `tzId` in `latestPerDay`). This DST-safe windowing (via
     * [DayAttribution]) and the today-excluding window match iOS exactly — the Android port previously
     * used raw millisecond arithmetic and included the evaluation day, which this replaces.
     */
    fun recompute(metricId: String, asOf: Long, tz: String = TimeZone.getDefault().id, context: String = "default") {
        if (!spec.isLoaded) return
        val resolution = spec.resolve(metricId)

        // (DATA-10) Exclude the evaluation day itself; (DATA-11) Calendar-based day-stepping.
        val (from, to) = baselineWindow(asOf, resolution.windowDays, tz)
        val byDay = latestPerDay(metricId, from, to)
        if (byDay.isEmpty()) return

        val days = byDay.keys.sorted().takeLast(resolution.windowDays)
        val values = days.mapNotNull { byDay[it]?.value }
        val comp = computeBaseline(values, resolution, spec) ?: return

        val unit = registry.definitionOrFallback(metricId).canonicalUnit
        val baseline = Baseline(
            id = Ulid.newId(), metricId = metricId, covariateContext = context,
            windowDays = resolution.windowDays, method = BaselineMethod.MEDIAN_MAD,
            center = comp.center, spread = comp.spread, bandLow = comp.bandLow, bandHigh = comp.bandHigh,
            nPoints = comp.nPoints, provisional = comp.provisional,
            algorithmVersion = spec.algorithm.id, validFrom = asOf,
            computedAt = clock.now(), unit = unit,
        )

        // Append-only should still mean "append only when something actually changed": skip the write
        // when the latest existing baseline FOR THIS CONTEXT is numerically identical. The algorithm
        // version is part of "identical": a version bump that reproduces the same band must still
        // append, or this metric's latest baseline would keep the OLD version id and the recompute
        // would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        val existing = derivation.latestBaseline(metricId, context)
        if (existing != null && existing.algorithmVersion == baseline.algorithmVersion &&
            existing.nPoints == comp.nPoints &&
            approximatelyEqual(existing.center, comp.center) &&
            approximatelyEqual(existing.bandLow, comp.bandLow) &&
            approximatelyEqual(existing.bandHigh, comp.bandHigh)
        ) {
            return
        }
        derivation.upsertBaseline(baseline)
    }

    // MARK: - Full recompute + composites (backfill entry point)

    /**
     * Rebuild every baseline-eligible metric that has data, then append the two per-day composites.
     * This is the clean recompute API the background lane (WorkManager) calls for both the nightly
     * pass and a post-import backfill: it is idempotent (a repeat run over unchanged data writes
     * nothing) and append-only (a run over NEW history appends fresh rows, never mutating prior ones —
     * I2), so a backfill job needs no special path. When [metricIds] is given, only those
     * baseline-eligible metrics are recomputed; null recomputes everything.
     */
    /**
     * [includeInterimReadinessComposite] gates ONLY the pre-EPIC-25 `readiness.score` composite this
     * engine appends. Once the real [ReadinessEngine] (v2) is wired into the pipeline, BOTH would
     * write `readiness.score` every recompute with different values, and — since each one's
     * skip-if-identical check reads the LATEST row regardless of version — they would ping-pong a
     * fresh row apiece per run (an I2/idempotency break). The composition root passes `false` so the
     * v2 engine owns `readiness.score` outright; the flag defaults to `true` so every existing direct
     * caller (and the headless seed path with no v2 engine) keeps the interim composite.
     * `sleep.efficiency` is unaffected: a distinct metric with no other writer, always emitted.
     */
    fun recomputeAll(asOf: Long, metricIds: List<String>? = null, tz: String = TimeZone.getDefault().id, context: String = "default", includeInterimReadinessComposite: Boolean = true) {
        if (!spec.isLoaded) return
        val eligible = if (metricIds != null) {
            registry.baselineEligible.filter { metricIds.contains(it.metricId) }
        } else {
            registry.baselineEligible
        }
        for (def in eligible) {
            recompute(def.metricId, asOf, tz, context)
        }
        // Interim MVP composites (superseded by EPIC-24/25). Their lookback is the sleep-input window
        // — they are sleep/RHR-anchored — read from the spec rather than a literal. Unlike the
        // single-metric baseline window this INCLUDES the evaluation day: the composites need TODAY's
        // own values to score today against the (today-excluding) baselines just computed.
        val lookback = spec.resolve(MetricId.timeAsleep).windowDays
        appendSleepEfficiency(lookback, asOf, tz)
        if (includeInterimReadinessComposite) {
            appendReadinessScore(lookback, asOf, tz)
        }
    }

    /**
     * sleep.efficiency = time_asleep / time_in_bed * 100, per local day, for every day that has both
     * inputs. Each row carries an InputManifest referencing the two interval ids.
     */
    private fun appendSleepEfficiency(lookback: Int, asOf: Long, tz: String) {
        val from = DayAttribution.addingDays(-lookback, asOf, tz)
        val asleepByDay = latestPerDay(MetricId.timeAsleep, from, asOf)
        val inBedByDay = latestPerDay(MetricId.timeInBed, from, asOf)

        for (day in asleepByDay.keys.sorted()) {
            val asleep = asleepByDay[day] ?: continue
            val inBed = inBedByDay[day] ?: continue
            if (inBed.value <= 0) continue
            val efficiency = minOf(100.0, maxOf(0.0, asleep.value / inBed.value * 100.0))
            val periodKey = "day:$day"
            // Version-aware skip (mirrors ReadinessEngine.persist and the iOS BaselineEngine): an
            // unchanged value across an algorithm-version bump must still append, or this period's
            // latest row keeps the old version id and the change goes unrecorded. sleep.efficiency is
            // a live surfaced score, so the guard checks the version, not just the value.
            val existing = derivation.latestDerived(MetricId.sleepEfficiency, periodKey)
            if (existing != null && existing.algorithmId == efficiencyAlgorithm.algorithmId &&
                existing.algorithmVersion == efficiencyAlgorithm.semver &&
                approximatelyEqual(existing.value, efficiency)) continue
            val manifest = InputManifest(
                id = Ulid.newId(),
                inputs = listOf(
                    InputManifest.Input(recordId = asleep.id, metricId = MetricId.timeAsleep, value = asleep.value),
                    InputManifest.Input(recordId = inBed.id, metricId = MetricId.timeInBed, value = inBed.value),
                ),
            )
            derivation.insertManifest(manifest)
            derivation.appendDerived(
                makeDerived(
                    metricId = MetricId.sleepEfficiency, value = efficiency, unit = "percent",
                    day = day, provisional = false, algorithm = efficiencyAlgorithm, manifestId = manifest.id,
                ),
            )
        }
    }

    /**
     * readiness.score (0–100), per local day, from how time_asleep and rhr sit against their
     * baselines: more sleep within/above band lifts it, higher rhr above band lowers it.
     *
     * Every day in the window is scored against the SAME latest (today-anchored) baseline — a
     * historical day earlier in the window doesn't get its own contemporaneous band. That's an
     * accepted approximation for now (the same simplification `InsightEngine.generate` makes).
     */
    private fun appendReadinessScore(lookback: Int, asOf: Long, tz: String) {
        val from = DayAttribution.addingDays(-lookback, asOf, tz)
        val sleepByDay = latestPerDay(MetricId.timeAsleep, from, asOf)
        val rhrByDay = latestPerDay(MetricId.restingHeartRate, from, asOf)

        val sleepBaseline = derivation.latestBaseline(MetricId.timeAsleep)
        val rhrBaseline = derivation.latestBaseline(MetricId.restingHeartRate)

        for (day in sleepByDay.keys.sorted()) {
            val sleep = sleepByDay[day] ?: continue
            val rhr = rhrByDay[day] ?: continue

            var score = 50.0
            if (sleepBaseline != null) score += clamp(sleepBaseline.z(sleep.value), -2.0, 2.0) * 12.5
            if (rhrBaseline != null) score -= clamp(rhrBaseline.z(rhr.value), -2.0, 2.0) * 12.5
            score = minOf(100.0, maxOf(0.0, score))
            val provisional = (sleepBaseline?.provisional ?: true) || (rhrBaseline?.provisional ?: true)

            val periodKey = "day:$day"
            // Version-aware skip, same reasoning as appendSleepEfficiency above.
            val existing = derivation.latestDerived("readiness.score", periodKey)
            if (existing != null && existing.algorithmId == readinessAlgorithm.algorithmId &&
                existing.algorithmVersion == readinessAlgorithm.semver &&
                approximatelyEqual(existing.value, score) && existing.provisional == provisional) continue
            val manifest = InputManifest(
                id = Ulid.newId(),
                inputs = listOf(
                    InputManifest.Input(recordId = sleep.id, metricId = MetricId.timeAsleep, value = sleep.value),
                    InputManifest.Input(recordId = rhr.id, metricId = MetricId.restingHeartRate, value = rhr.value),
                ),
            )
            derivation.insertManifest(manifest)
            derivation.appendDerived(
                makeDerived(
                    metricId = "readiness.score", value = score, unit = "score_0_100",
                    day = day, provisional = provisional, algorithm = readinessAlgorithm, manifestId = manifest.id,
                ),
            )
        }
    }

    private fun makeDerived(
        metricId: String,
        value: Double,
        unit: String,
        day: String,
        provisional: Boolean,
        algorithm: AlgorithmVersion,
        manifestId: String,
    ): DerivedValue {
        val now = clock.now()
        return DerivedValue(
            id = Ulid.newId(), metricId = metricId, value = value, unit = unit,
            periodKey = "day:$day", provisional = provisional,
            algorithmId = algorithm.algorithmId, algorithmVersion = algorithm.semver,
            inputManifestId = manifestId, computedAt = now, updatedAt = now, originDeviceId = deviceId,
        )
    }

    // MARK: - Calibration read model

    /**
     * The calibration state of a metric's current baseline (for the given [context]), for the score
     * cards and anatomy sheet — "day 9 of 14", tier, window, transform. Null when no baseline exists
     * yet. Pure read; the UI lane owns the bilingual strings.
     */
    fun calibration(metricId: String, context: String = "default"): BaselineCalibration? {
        val baseline = derivation.latestBaseline(metricId, context) ?: return null
        return BaselineCalibration.from(baseline, spec)
    }

    // MARK: - Helpers

    /**
     * (DATA-10 + DATA-11) The window a single metric's baseline band is built from: the [windowDays]
     * calendar days strictly BEFORE [asOf]'s own day, stepped via [DayAttribution.addingDays] rather
     * than fixed 86,400s multiples so it survives DST. `to` sits one second before local midnight of
     * [asOf]'s day — excluding the evaluation day itself.
     */
    private fun baselineWindow(asOf: Long, windowDays: Int, tz: String): Pair<Long, Long> {
        val dayStart = DayAttribution.startOfDay(asOf, tz)
        val to = dayStart - 1
        val from = DayAttribution.addingDays(-windowDays, dayStart, tz)
        return from to to
    }

    /**
     * Latest interval record per local day (attributed in the record's own timezone) for a metric
     * over a window. "Latest" means most recently written (`updatedAt`), not latest start time — a
     * corrected aggregate that supersedes an earlier-starting one must win even if its own `startAt`
     * is earlier than the value it corrects. Same-day ties (identical `updatedAt`) fall back to the
     * record's own `provenance.sourceId` so the choice is deterministic, not query-order-dependent
     * (DATA-09). This matches iOS `latestPerDay`.
     */
    private fun latestPerDay(metricId: String, from: Long, to: Long): Map<String, IntervalRecord> {
        val records = measurements.intervalRecords(metricId, from, to)
        val byDay = mutableMapOf<String, IntervalRecord>()
        for (r in records) {
            val day = DayAttribution.localDayKey(r.startAt, r.tzId)
            val existing = byDay[day]
            if (existing != null && !isPreferred(r, existing)) continue
            byDay[day] = r
        }
        return byDay
    }

    private fun isPreferred(candidate: IntervalRecord, incumbent: IntervalRecord): Boolean {
        if (candidate.updatedAt != incumbent.updatedAt) return candidate.updatedAt > incumbent.updatedAt
        return candidate.provenance.sourceId < incumbent.provenance.sourceId
    }

    private fun approximatelyEqual(a: Double, b: Double, tolerance: Double = 1e-9): Boolean = abs(a - b) < tolerance
}
