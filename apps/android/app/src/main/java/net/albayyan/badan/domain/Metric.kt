package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString

/**
 * The shape of a metric's storage, which drives which table it lives in and how it renders.
 * Mirrors the ontology `kind` field. Decoded from the ontology JSON.
 */
@Serializable
enum class MetricKind(val code: String) {
    @SerialName("rawSample") RAW_SAMPLE("rawSample"),
    @SerialName("intervalAggregate") INTERVAL_AGGREGATE("intervalAggregate"),
    @SerialName("session") SESSION("session"),
    @SerialName("event") EVENT("event"),
    @SerialName("derived") DERIVED("derived");

    companion object {
        fun fromCode(code: String?): MetricKind = entries.firstOrNull { it.code == code } ?: RAW_SAMPLE
    }
}

@Serializable
enum class ChartHint(val code: String) {
    @SerialName("line") LINE("line"),
    @SerialName("bar") BAR("bar"),
    @SerialName("range") RANGE("range"),
    @SerialName("stacked") STACKED("stacked"),
    @SerialName("scatter") SCATTER("scatter");

    companion object {
        fun fromCode(code: String?): ChartHint = entries.firstOrNull { it.code == code } ?: LINE
    }
}

@Serializable
enum class SensitiveClass(val code: String) {
    @SerialName("normal") NORMAL("normal"),
    @SerialName("sensitivePlus") SENSITIVE_PLUS("sensitivePlus");   // meds, symptoms, conditions, mood, stress — separate DB file

    companion object {
        fun fromCode(code: String?): SensitiveClass = entries.firstOrNull { it.code == code } ?: NORMAL
    }
}

/**
 * High-level grouping used for pillars, icons, and colour families in the UI. Backed by the
 * free-form `family` string on a MetricDefinition so the registry can add families without a
 * code change; unknown families fall back to `OTHER`.
 */
enum class MetricFamily(val code: String) {
    SLEEP("sleep"),
    HEART("heart"),
    ACTIVITY("activity"),
    BODY("body"),
    RESPIRATORY("respiratory"),
    NUTRITION("nutrition"),
    SUBJECTIVE("subjective"),
    SYMPTOMS("symptoms"),
    MEDICATIONS("medications"),
    OTHER("other");

    val displayName: LocalizedString
        get() = when (this) {
            SLEEP -> LocalizedString(en = "Sleep", ar = "النوم")
            HEART -> LocalizedString(en = "Heart", ar = "القلب")
            ACTIVITY -> LocalizedString(en = "Activity", ar = "النشاط")
            BODY -> LocalizedString(en = "Body", ar = "الجسم")
            RESPIRATORY -> LocalizedString(en = "Respiratory", ar = "التنفّس")
            NUTRITION -> LocalizedString(en = "Nutrition", ar = "التغذية")
            SUBJECTIVE -> LocalizedString(en = "How you feel", ar = "شعورك")
            SYMPTOMS -> LocalizedString(en = "Symptoms", ar = "الأعراض")
            MEDICATIONS -> LocalizedString(en = "Medications", ar = "الأدوية")
            OTHER -> LocalizedString(en = "Other", ar = "أخرى")
        }

    /** Material-style icon key for the family — kept here so both list and detail agree. */
    val symbolName: String
        get() = when (this) {
            SLEEP -> "bedtime"
            HEART -> "favorite"
            ACTIVITY -> "directions_walk"
            BODY -> "accessibility"
            RESPIRATORY -> "air"
            NUTRITION -> "restaurant"
            SUBJECTIVE -> "mood"
            SYMPTOMS -> "healing"
            MEDICATIONS -> "medication"
            OTHER -> "grid_view"
        }

    companion object {
        fun fromRawOrOther(raw: String): MetricFamily = entries.firstOrNull { it.code == raw } ?: OTHER
        fun fromCode(code: String?): MetricFamily = entries.firstOrNull { it.code == code } ?: OTHER
    }
}

/**
 * Compiled from `packages/metric-ontology/registry.json`. Apps never hardcode metric-id
 * strings outside `MetricId` constants; this is the single description of every metric.
 * Tolerant defaults mirror the iOS custom decoder (unknown kind -> rawSample, chartHint ->
 * line, missing labels fall back to the English name).
 */
@Serializable
data class MetricDefinition(
    val metricId: String,
    val family: String,
    val kind: MetricKind = MetricKind.RAW_SAMPLE,
    val canonicalUnit: String,
    val displayUnits: List<String> = emptyList(),
    val nameEn: String,
    val nameAr: String,
    val casualLabel: String = "",
    val preciseLabel: String = "",
    val chartHint: ChartHint = ChartHint.LINE,
    val baselineEligible: Boolean = false,
    val sensitiveClass: SensitiveClass = SensitiveClass.NORMAL,
    val explainerEn: String? = null,
) {
    val id: String get() = metricId

    val familyGroup: MetricFamily get() = MetricFamily.fromRawOrOther(family)

    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)

    /**
     * The user-facing label at a given depth: casual shows the friendly label, power shows the
     * precise term. Both localise to Arabic via `displayName` fallback. Blank labels fall back
     * to the English name (mirrors the iOS decoder default).
     */
    fun label(depth: DepthPolicy, language: AppLanguage): String = when {
        depth == DepthPolicy.POWER -> if (language == AppLanguage.AR) nameAr else preciseLabel.ifBlank { nameEn }
        language == AppLanguage.AR -> nameAr
        else -> casualLabel.ifBlank { nameEn }
    }

    /** The default display unit for this metric (first of `displayUnits`, else canonical). */
    val primaryDisplayUnit: String get() = displayUnits.firstOrNull() ?: canonicalUnit
}
