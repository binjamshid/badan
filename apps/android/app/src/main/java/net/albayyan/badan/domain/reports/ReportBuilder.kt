package net.albayyan.badan.domain.reports

import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.AlgorithmVersion
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.LoggingRepository
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.roundToLong

/** Why a report could not be generated. */
class InvalidPeriodKeyException(val periodKey: String) :
    IllegalArgumentException("not a report period key: $periodKey")

/**
 * Builds a periodic report (EPIC-31) — WHOOP's Performance Assessment, transparent edition. Mirror of
 * iOS `ReportBuilder.swift`.
 *
 * The heart of it is [build], a **pure** function from already-loaded rows to a [ReportModel]: given
 * the same period and the same derived-value / adherence rows, it produces an identical model
 * (identical `sha256`), which is what lets a rendered artifact be verified against a re-derivation and
 * never be a source of truth (migration v8). Purity is also why the report is testable with fixtures
 * alone — no database in the loop — and why the acceptance test can assert that *every claim resolves
 * to a real evidence ref*: the refs come straight from the input rows' ids, so they cannot point at
 * anything that was not there.
 *
 * [generate] is the thin loading shell around it: it resolves a period, reads the latest derived value
 * per day per score metric plus the period's adherence events, and calls [build]. Adherence is
 * aggregated to **counts only** (never medication names/dosages), so the report artifact never carries
 * the sensitive-plus namespace's contents across (I7); `includeAdherence` lets the composition root
 * omit it entirely.
 */
class ReportBuilder(
    private val derivation: DerivationRepository,
    private val logging: LoggingRepository,
) {

    /**
     * Everything [build] needs, pre-loaded — the seam that keeps the builder pure and the tests
     * database-free. Each `List<DerivedValue>` holds at most one row per day (the latest per day per
     * metric), carrying its own `id` and `periodKey` for evidence.
     */
    data class Inputs(
        val period: ReportPeriod.Resolved,
        val prior: ReportPeriod.Resolved,
        val currentByMetric: Map<String, List<DerivedValue>>,
        val priorByMetric: Map<String, List<DerivedValue>>,
        val adherence: List<AdherenceEvent>?,
        val generatedAt: Long,
    )

    /**
     * Resolve [periodKey] in [tz] and generate the report from the derived store (+ adherence).
     * Throws [InvalidPeriodKeyException] for a key that is not a well-formed week/month key.
     */
    fun generate(periodKey: String, tz: String, now: Long, includeAdherence: Boolean = true): ReportModel {
        val period = ReportPeriod.resolve(periodKey, tz) ?: throw InvalidPeriodKeyException(periodKey)
        return generate(period, tz, now, includeAdherence)
    }

    /** Generate from an already-resolved period. */
    fun generate(
        period: ReportPeriod.Resolved,
        tz: String,
        now: Long,
        includeAdherence: Boolean = true,
    ): ReportModel {
        val prior = ReportPeriod.prior(period, tz)
        val currentByMetric = mutableMapOf<String, List<DerivedValue>>()
        val priorByMetric = mutableMapOf<String, List<DerivedValue>>()
        for (metric in allScoreMetrics) {
            currentByMetric[metric] = load(metric, period.dayKeys)
            priorByMetric[metric] = load(metric, prior.dayKeys)
        }
        val adherence = if (includeAdherence) {
            // `to` is inclusive in the repository; the period end is exclusive (start of the next
            // day), so step back one millisecond to avoid counting an event at exactly midnight.
            logging.adherence(period.start, period.end - 1)
        } else {
            null
        }
        return build(
            Inputs(
                period = period, prior = prior, currentByMetric = currentByMetric,
                priorByMetric = priorByMetric, adherence = adherence, generatedAt = now,
            ),
        )
    }

    private fun load(metricId: String, dayKeys: List<String>): List<DerivedValue> =
        dayKeys.mapNotNull { derivation.latestDerived(metricId, "day:$it") }

    companion object {

        // MARK: - Published algorithm identity + constants

        /**
         * A period-over-period delta is only computed when BOTH periods have at least this many days
         * with a value — comparing a 2-day week against a full one would manufacture a "change".
         */
        const val MIN_COMPARABLE_DAYS = 3

        /**
         * Relative shift (|Δmean| / priorMean) at or above which a change is "notable" enough for the
         * changes section. 10%.
         */
        const val CHANGE_REL_THRESHOLD = 0.10

        /** Absolute shift used only when priorMean is 0 (no relative change is defined). */
        const val CHANGE_ABS_FLOOR = 5.0

        /** Relative band inside which a direction reads as `flat` rather than up/down. */
        const val FLAT_REL_THRESHOLD = 0.02

        /**
         * The report-building algorithm identity. Written to `reports.algorithm_version_id` and
         * [ReportModel.algorithmVersionId]; part of a report's identity, so a change here makes the
         * next generation a genuinely new report rather than a replacement (v8 unique index).
         */
        val algorithm = AlgorithmVersion(
            algorithmId = "report.periodic",
            semver = "1.0.0",
            params = mapOf(
                "minComparableDays" to MIN_COMPARABLE_DAYS.toDouble(),
                "changeRelThreshold" to CHANGE_REL_THRESHOLD,
                "changeAbsFloor" to CHANGE_ABS_FLOOR,
                "flatRelThreshold" to FLAT_REL_THRESHOLD,
            ),
            introducedIn = "0.1.0",
        )

        /**
         * Score metrics per section (only those present with a value appear). Sleep leads with
         * performance and, when present, its debt/consistency companions.
         */
        val sleepMetrics = listOf(MetricId.sleepPerformance, MetricId.sleepDebt, MetricId.sleepConsistency)
        val effortMetrics = listOf(MetricId.effortDay)
        val readinessMetrics = listOf(MetricId.readinessScore)

        /** The primary metrics the changes section is computed over (one headline per score family). */
        val changeMetrics = listOf(MetricId.sleepPerformance, MetricId.effortDay, MetricId.readinessScore)

        val allScoreMetrics: List<String> get() = sleepMetrics + effortMetrics + readinessMetrics

        // MARK: - Pure build

        /**
         * The pure core: rows in, model out, deterministic. No I/O, no clock beyond the supplied
         * `generatedAt` (which is deliberately excluded from the content hash).
         */
        fun build(inputs: Inputs): ReportModel {
            val sections = mutableListOf<ReportSection>()

            // Score sections, in the fixed order sleep → effort → readiness.
            scoreSection(ReportSectionKind.SLEEP, sleepMetrics, inputs)?.let { sections += it }
            scoreSection(ReportSectionKind.EFFORT, effortMetrics, inputs)?.let { sections += it }
            scoreSection(ReportSectionKind.READINESS, readinessMetrics, inputs)?.let { sections += it }

            // Adherence, when supplied and non-empty.
            val adherence = inputs.adherence?.let { adherenceSummary(it) }
            if (adherence != null && adherence.logged > 0) {
                sections += ReportSection(kind = ReportSectionKind.ADHERENCE, adherence = adherence)
            }

            // Notable changes, computed over the primary metrics; present only if any crossed threshold.
            val changes = changeItems(inputs)
            if (changes.isNotEmpty()) {
                sections += ReportSection(kind = ReportSectionKind.CHANGES, changes = changes)
            }

            val model = ReportModel(
                periodKey = inputs.period.periodKey,
                periodKind = inputs.period.kind,
                periodStart = inputs.period.start,
                periodEnd = inputs.period.end,
                timezone = inputs.period.timezone,
                generatedAt = inputs.generatedAt,
                algorithmVersionId = algorithm.id,
                hasSufficientData = sections.isNotEmpty(),
                sections = sections,
                sha256 = "",
            )
            return model.copy(sha256 = contentHash(model))
        }

        // MARK: - Sections

        private fun scoreSection(
            kind: ReportSectionKind,
            metrics: List<String>,
            inputs: Inputs,
        ): ReportSection? {
            val summaries = mutableListOf<MetricSummary>()
            for (metricId in metrics) {
                val current = (inputs.currentByMetric[metricId] ?: emptyList()).sortedBy { it.periodKey }
                if (current.isEmpty()) continue
                val prior = inputs.priorByMetric[metricId] ?: emptyList()
                summaries += metricSummary(metricId, current, prior)
            }
            if (summaries.isEmpty()) return null
            return ReportSection(kind = kind, metrics = summaries)
        }

        private fun metricSummary(
            metricId: String,
            current: List<DerivedValue>,
            prior: List<DerivedValue>,
        ): MetricSummary {
            val values = current.map { it.value }
            val count = values.size
            val mean = round4(values.sum() / count)
            val minV = round4(values.min())
            val maxV = round4(values.max())
            val latest = round4(current.last().value)   // current is sorted ascending by day key

            var deltaVsPrior: Double? = null
            if (count >= MIN_COMPARABLE_DAYS && prior.size >= MIN_COMPARABLE_DAYS) {
                deltaVsPrior = round4(mean - prior.map { it.value }.sum() / prior.size)
            }
            val priorMean = if (prior.isEmpty()) null else round4(prior.map { it.value }.sum() / prior.size)
            val direction = trend(deltaVsPrior, priorMean)

            val unit = current.first().unit
            val evidence = current.map {
                EvidenceRef(kind = EvidenceKind.DERIVED_VALUE, id = it.id, periodKey = it.periodKey)
            }
            return MetricSummary(
                metricId = metricId, unit = unit, count = count, mean = mean, min = minV, max = maxV,
                latest = latest, deltaVsPrior = deltaVsPrior, direction = direction, evidence = evidence,
            )
        }

        private fun changeItems(inputs: Inputs): List<ChangeItem> {
            val items = mutableListOf<ChangeItem>()
            for (metricId in changeMetrics) {
                val current = inputs.currentByMetric[metricId] ?: emptyList()
                val prior = inputs.priorByMetric[metricId] ?: emptyList()
                if (current.size < MIN_COMPARABLE_DAYS || prior.size < MIN_COMPARABLE_DAYS) continue
                val currentMean = round4(current.map { it.value }.sum() / current.size)
                val priorMean = round4(prior.map { it.value }.sum() / prior.size)
                val deltaAbs = round4(currentMean - priorMean)
                val notable: Boolean
                val deltaPct: Double?
                if (priorMean != 0.0) {
                    val pct = deltaAbs / priorMean
                    deltaPct = round4(pct)
                    notable = abs(pct) >= CHANGE_REL_THRESHOLD
                } else {
                    deltaPct = null
                    notable = abs(deltaAbs) >= CHANGE_ABS_FLOOR
                }
                if (!notable) continue
                val evidence = current.sortedBy { it.periodKey }.map {
                    EvidenceRef(kind = EvidenceKind.DERIVED_VALUE, id = it.id, periodKey = it.periodKey)
                } + prior.sortedBy { it.periodKey }.map {
                    EvidenceRef(kind = EvidenceKind.DERIVED_VALUE, id = it.id, periodKey = it.periodKey)
                }
                items += ChangeItem(
                    metricId = metricId, currentMean = currentMean, priorMean = priorMean,
                    deltaAbs = deltaAbs, deltaPct = deltaPct,
                    direction = when {
                        deltaAbs > 0 -> TrendDirection.UP
                        deltaAbs < 0 -> TrendDirection.DOWN
                        else -> TrendDirection.FLAT
                    },
                    evidence = evidence,
                )
            }
            return items
        }

        private fun adherenceSummary(events: List<AdherenceEvent>): AdherenceSummary? {
            if (events.isEmpty()) return null
            var taken = 0
            var late = 0
            var skipped = 0
            for (e in events) {
                when (e.kind) {
                    AdherenceKind.TAKEN -> taken++
                    AdherenceKind.LATE -> late++
                    AdherenceKind.SKIPPED -> skipped++
                }
            }
            val logged = taken + late + skipped
            val rate = if (logged > 0) round4((taken + late).toDouble() / logged) else null
            // Evidence: ids only, never event content (I7). Sorted by id for a stable model.
            val evidence = events.map { it.id }.sorted().map {
                EvidenceRef(kind = EvidenceKind.ADHERENCE_EVENT, id = it)
            }
            return AdherenceSummary(
                taken = taken, late = late, skipped = skipped, logged = logged,
                adherenceRate = rate, evidence = evidence,
            )
        }

        // MARK: - Helpers

        private fun trend(deltaAbs: Double?, priorMean: Double?): TrendDirection {
            if (deltaAbs == null || priorMean == null) return TrendDirection.INSUFFICIENT
            val rel = if (priorMean != 0.0) deltaAbs / abs(priorMean) else deltaAbs
            if (abs(rel) < FLAT_REL_THRESHOLD) return TrendDirection.FLAT
            return if (rel > 0) TrendDirection.UP else TrendDirection.DOWN
        }

        fun round4(x: Double): Double = (x * 10000).roundToLong() / 10000.0

        /**
         * Lowercase-hex SHA-256 of the model's content — everything except `generatedAt` (zeroed) and
         * `sha256` (blanked). Deterministic within a platform: kotlinx-serialization emits fields in
         * declaration order and all doubles are pre-rounded, so the same content hashes the same
         * across runs regardless of when it was generated. Not required to match iOS byte-for-byte —
         * each device stores its own report rows and re-derives its own hash.
         */
        fun contentHash(model: ReportModel): String {
            val canonical = model.copy(generatedAt = 0L, sha256 = "")
            val bytes = JsonCoding.encode(canonical).toByteArray(Charsets.UTF_8)
            return MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
        }
    }
}
