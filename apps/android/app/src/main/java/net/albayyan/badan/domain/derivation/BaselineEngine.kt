package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import kotlin.math.abs

/**
 * Recomputes personal "normal" bands (rolling median + MAD over a 14-day window) and the
 * two MVP composites (sleep efficiency, readiness score). Everything is append-only and
 * driven by an injected [Clock], so recompute is deterministic and auditable (INVARIANT I2).
 */
class BaselineEngine(
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
) {
    companion object {
        /** Frozen identity of the baseline method — carried on every baseline row for traceability. */
        val baselineAlgorithm = AlgorithmVersion(
            algorithmId = "baseline.rolling_median_mad", semver = "1.0.0",
            params = mapOf("windowDays" to 14.0), introducedIn = "1.0.0",
        )
        val efficiencyAlgorithm = AlgorithmVersion(
            algorithmId = "composite.sleep_efficiency", semver = "1.0.0", introducedIn = "1.0.0",
        )
        val readinessAlgorithm = AlgorithmVersion(
            algorithmId = "composite.readiness_score", semver = "1.0.0", introducedIn = "1.0.0",
        )

        /**
         * Rolling window length in days and the "enough to be honest" threshold below which a
         * baseline stays provisional (wellness-safe honesty about thin data).
         */
        const val windowDays = 14
        const val minPointsForConfident = 7

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
     * Rebuild the baseline band for one metric as of [asOf]. Gathers up to the last 14 daily
     * values (latest record per local day) and materializes a fresh baseline row. No-op when
     * the metric has no interval data in the window.
     */
    fun recompute(metricId: String, asOf: Long) {
        val from = asOf - windowDays * 86_400_000L
        val byDay = latestPerDay(metricId, from, asOf)
        if (byDay.isEmpty()) return

        // Most recent `windowDays` distinct days, in day order.
        val days = byDay.keys.sorted().takeLast(windowDays)
        val values = days.mapNotNull { byDay[it]?.value }
        if (values.isEmpty()) return

        val center = median(values)
        val spread = mad(values, center)
        val scaled = 1.4826 * spread
        val unit = registry.definitionOrFallback(metricId).canonicalUnit
        val n = values.size

        val baseline = Baseline(
            id = Ulid.newId(), metricId = metricId, windowDays = windowDays,
            center = center, spread = spread, bandLow = center - scaled, bandHigh = center + scaled,
            nPoints = n, provisional = n < minPointsForConfident,
            algorithmVersion = baselineAlgorithm.id, validFrom = asOf,
            computedAt = clock.now(), unit = unit,
        )
        derivation.upsertBaseline(baseline)
    }

    // MARK: - Full recompute + composites

    /**
     * Rebuild every baseline-eligible metric that has interval data, then append the two
     * per-day composites (sleep efficiency and readiness score) as derived values.
     */
    fun recomputeAll(asOf: Long) {
        for (def in registry.baselineEligible) {
            recompute(def.metricId, asOf)
        }
        appendSleepEfficiency(asOf)
        appendReadinessScore(asOf)
    }

    /**
     * sleep.efficiency = time_asleep / time_in_bed * 100, per local day, for every day that
     * has both inputs. Each row carries an InputManifest referencing the two interval ids.
     */
    private fun appendSleepEfficiency(asOf: Long) {
        val from = asOf - windowDays * 86_400_000L
        val asleepByDay = latestPerDay(MetricId.timeAsleep, from, asOf)
        val inBedByDay = latestPerDay(MetricId.timeInBed, from, asOf)

        for (day in asleepByDay.keys.sorted()) {
            val asleep = asleepByDay[day] ?: continue
            val inBed = inBedByDay[day] ?: continue
            if (inBed.value <= 0) continue
            val efficiency = minOf(100.0, maxOf(0.0, asleep.value / inBed.value * 100.0))
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
     */
    private fun appendReadinessScore(asOf: Long) {
        val from = asOf - windowDays * 86_400_000L
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

    // MARK: - Helpers

    /**
     * Latest interval record per local day (attributed in the record's own timezone) for a
     * metric over a window. Records arrive ascending by start, so the last one per day wins.
     */
    private fun latestPerDay(metricId: String, from: Long, to: Long): Map<String, IntervalRecord> {
        val records = measurements.intervalRecords(metricId, from, to)
        val byDay = mutableMapOf<String, IntervalRecord>()
        for (r in records) {
            val day = DayAttribution.localDayKey(r.startAt, r.tzId)
            val existing = byDay[day]
            if (existing != null && existing.startAt >= r.startAt) continue
            byDay[day] = r
        }
        return byDay
    }
}
