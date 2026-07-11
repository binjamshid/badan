package net.albayyan.badan.domain.derivation

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.Insight
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.DerivationRepository
import net.albayyan.badan.storage.repositories.InsightRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository

/**
 * Deterministic, template-rendered insight generation (no LLM). For a handful of key metrics
 * it compares the day's value to the personal baseline and picks a wellness-safe template,
 * filling `{metric}`/`{value}`/`{baseline}` in both languages. Regeneration is idempotent:
 * the day's insights are cleared and rebuilt so evidence always ties back to live derivations.
 */
class InsightEngine(
    private val insights: InsightRepository,
    private val derivation: DerivationRepository,
    private val measurements: MeasurementRepository,
    private val templates: InsightTemplateStore,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
) {
    companion object {
        /** The metrics that carry a daily status explanation on the home surface. */
        val keyMetrics = listOf(MetricId.timeAsleep, MetricId.restingHeartRate, MetricId.hrv)

        // MARK: - Template selection

        /**
         * Map a metric's position against its baseline to a template id, or null to skip when no
         * safe template fits the direction (never fabricate a template that isn't authored).
         */
        fun templateId(metricId: String, baseline: Baseline, value: Double): String? {
            if (baseline.provisional) return "baseline_provisional"
            return when (baseline.position(value)) {
                Baseline.Position.WITHIN -> "vitals_within_band"
                Baseline.Position.BELOW -> when {
                    metricId == MetricId.hrv -> "hrv_below_band"
                    metricId == MetricId.timeAsleep -> "sleep_debt_rising"
                    else -> null // e.g. RHR below band is a good sign; no authored template
                }
                Baseline.Position.ABOVE ->
                    if (metricId == MetricId.restingHeartRate) "rhr_above_band" else null
                // HRV/sleep above band is a good sign; no authored template
            }
        }

        // MARK: - Formatting

        /**
         * Durations (canonical seconds) render as "Xh Ym"; everything else is a rounded number
         * plus its unit. Digits stay plain — the UI localises numerals separately.
         */
        fun formatValue(value: Double, unit: String): String {
            if (unit == "s") {
                val total = Math.round(value).toInt()
                val hours = total / 3600
                val minutes = (total % 3600) / 60
                return "${hours}h ${minutes}m"
            }
            val rounded = Math.round(value).toInt()
            return if (unit.isEmpty()) "$rounded" else "$rounded $unit"
        }

        fun fill(template: String, values: Map<String, String>): String {
            var out = template
            for ((key, value) in values) {
                out = out.replace("{$key}", value)
            }
            return out
        }
    }

    /** Rebuild the day's status-explanation insights for the key metrics in timezone [tz]. */
    fun generate(forDayMillis: Long, tz: String) {
        val dayKey = DayAttribution.localDayKey(forDayMillis, tz)
        val periodKey = "day:$dayKey"
        val dayStart = DayAttribution.startOfDay(forDayMillis, tz)
        val dayEnd = DayAttribution.addingDays(1, dayStart, tz)

        // Idempotent regeneration.
        insights.deleteForPeriod(periodKey)

        for (metricId in keyMetrics) {
            val records = measurements.intervalRecords(metricId, dayStart, dayEnd)
            val record = records.filter { it.startAt < dayEnd }.lastOrNull() ?: continue
            val baseline = derivation.latestBaseline(metricId) ?: continue

            val templateId = templateId(metricId, baseline, record.value) ?: continue
            val template = templates.template(templateId) ?: continue

            val def = registry.definitionOrFallback(metricId)
            val valueStr = formatValue(record.value, record.unit)
            val baselineStr = formatValue(baseline.center, baseline.unit)

            val rendered = LocalizedString(
                en = fill(template.textEn, mapOf("metric" to def.nameEn, "value" to valueStr, "baseline" to baselineStr)),
                ar = fill(template.textAr, mapOf("metric" to def.nameAr, "value" to valueStr, "baseline" to baselineStr)),
            )

            val insight = Insight(
                id = Ulid.newId(), insightType = "statusExplanation", templateId = template.templateId,
                templateVersion = "1", metricIds = listOf(metricId), periodKey = periodKey,
                depthVariant = DepthPolicy.BALANCED, renderedText = rendered,
                evidenceRefs = listOf(record.id, baseline.id), generatedAt = clock.now(),
            )
            insights.insert(insight)
        }
    }
}
