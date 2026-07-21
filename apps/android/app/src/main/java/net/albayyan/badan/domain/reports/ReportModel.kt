package net.albayyan.badan.domain.reports

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The typed, language-neutral model a periodic report is built from (EPIC-31) — the shared shape
 * described by `packages/contracts/report_model.schema.json` and mirrored on iOS as
 * `ReportModel.swift`.
 *
 * WHOOP's Performance Assessment, transparent edition: every *claim* in a report (a
 * [MetricSummary], a [ChangeItem], or the [AdherenceSummary]) carries the ids of the rows it rests
 * on ([EvidenceRef]), so the report can always answer "where did this number come from" by
 * resolving those ids back to real derived-value / adherence rows. The model is **numeric and
 * evidence-bearing, never prose** — the localized, wellness-safe sentences live in
 * [ReportPresentation], which is what lets a model snapshot fixture pin the numbers and refs rather
 * than any wording, and what makes the Arabic report the same report as the English one.
 *
 * Instants are epoch millis (the Android convention), matching every other entity here.
 */
@Serializable
data class ReportModel(
    val schemaVersion: String = SCHEMA_VERSION,
    val periodKey: String,
    val periodKind: ReportPeriodKind,
    val periodStart: Long,
    /** Exclusive: the period is [periodStart, periodEnd). */
    val periodEnd: Long,
    val timezone: String,
    /** EXCLUDED from [sha256]. */
    val generatedAt: Long,
    val algorithmVersionId: String,
    val hasSufficientData: Boolean,
    val sections: List<ReportSection>,
    val sha256: String,
) {
    /** The ids of the sections present — exactly what `reports.sections_included` stores. */
    val sectionsIncluded: List<String> get() = sections.map { it.kind.code }

    fun section(kind: ReportSectionKind): ReportSection? = sections.firstOrNull { it.kind == kind }

    companion object { const val SCHEMA_VERSION = "1.0" }
}

@Serializable
enum class ReportPeriodKind(val code: String) {
    @SerialName("week") WEEK("week"),
    @SerialName("month") MONTH("month"),
}

@Serializable
enum class ReportSectionKind(val code: String) {
    @SerialName("sleep") SLEEP("sleep"),
    @SerialName("effort") EFFORT("effort"),
    @SerialName("readiness") READINESS("readiness"),
    @SerialName("adherence") ADHERENCE("adherence"),
    @SerialName("changes") CHANGES("changes"),
}

/**
 * The direction of a period-over-period shift — never a value judgement. `INSUFFICIENT` when either
 * period lacked enough days to compare; the renderer maps every case to neutral, wellness-safe copy.
 */
@Serializable
enum class TrendDirection(val code: String) {
    @SerialName("up") UP("up"),
    @SerialName("down") DOWN("down"),
    @SerialName("flat") FLAT("flat"),
    @SerialName("insufficient") INSUFFICIENT("insufficient"),
}

@Serializable
enum class EvidenceKind(val code: String) {
    @SerialName("derivedValue") DERIVED_VALUE("derivedValue"),
    @SerialName("adherenceEvent") ADHERENCE_EVENT("adherenceEvent"),
    @SerialName("baseline") BASELINE("baseline"),
}

/**
 * A pointer to a real row a report claim rests on — the transparency contract. [id] resolves in the
 * store named by [kind]; nothing about the row's content is copied here.
 */
@Serializable
data class EvidenceRef(
    val kind: EvidenceKind,
    val id: String,
    val periodKey: String? = null,
)

/**
 * One report section. A uniform shape across kinds so the set can grow without a schema break: a
 * score section (sleep/effort/readiness) populates [metrics]; `CHANGES` populates [changes];
 * `ADHERENCE` populates [adherence]. Fields not relevant to a kind stay empty/null.
 */
@Serializable
data class ReportSection(
    val kind: ReportSectionKind,
    val metrics: List<MetricSummary> = emptyList(),
    val changes: List<ChangeItem> = emptyList(),
    val adherence: AdherenceSummary? = null,
)

/**
 * A claim about one metric over the period: how many days had a value, the central/extreme values,
 * and the shift versus the prior period. Every questionable field is backed by [evidence].
 */
@Serializable
data class MetricSummary(
    val metricId: String,
    val unit: String,
    val count: Int,
    val mean: Double? = null,
    val min: Double? = null,
    val max: Double? = null,
    val latest: Double? = null,
    val deltaVsPrior: Double? = null,
    val direction: TrendDirection,
    val evidence: List<EvidenceRef>,
)

/**
 * A notable period-over-period change for one metric. Present only when the shift crossed the
 * published threshold, so the changes section is the "what changed" highlight, not a repeat of every
 * metric.
 */
@Serializable
data class ChangeItem(
    val metricId: String,
    val currentMean: Double,
    val priorMean: Double,
    val deltaAbs: Double,
    val deltaPct: Double? = null,
    val direction: TrendDirection,
    val evidence: List<EvidenceRef>,
)

/**
 * Medication-adherence roll-up. COUNTS ONLY — no medication names, dosages, or any sensitive
 * content, so this aggregate never carries the sensitive-plus namespace's contents into the report
 * artifact (I7). Skip-with-reason counts equally to taken (non-punitive by design).
 */
@Serializable
data class AdherenceSummary(
    val taken: Int,
    val late: Int,
    val skipped: Int,
    val logged: Int,
    val adherenceRate: Double? = null,
    val evidence: List<EvidenceRef>,
)
