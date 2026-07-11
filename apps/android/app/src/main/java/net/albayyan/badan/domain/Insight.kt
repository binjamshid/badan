package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString

/**
 * A deterministic, template-rendered interpretation. MVP generation is rules + templates (no
 * LLM); the entity exists so the explainability contract is proven before any engine. Every
 * insight ties back to the derived values and records that justify it.
 */
data class Insight(
    val id: String,
    val insightType: String,        // e.g. "statusExplanation"
    val templateId: String,
    val templateVersion: String,
    val metricIds: List<String>,
    val periodKey: String,
    val depthVariant: DepthPolicy,
    val renderedText: LocalizedString,
    val evidenceRefs: List<String>,      // derived-value + record ids
    val generatedAt: Long,
    val algorithmVersion: String? = null,
    val feedback: Int? = null,              // -1 / 0 / +1
)

/**
 * A wellness-safe sentence template loaded from `insight_templates.json`. `{metric}`, `{value}`,
 * `{baseline}` placeholders are filled in both languages simultaneously.
 */
@Serializable
data class InsightTemplate(
    @SerialName("id") val templateId: String,
    val metricFamily: String,
    val conditionEn: String,
    val textEn: String,
    val textAr: String,
) {
    val id: String get() = templateId

    val text: LocalizedString get() = LocalizedString(en = textEn, ar = textAr)
}
