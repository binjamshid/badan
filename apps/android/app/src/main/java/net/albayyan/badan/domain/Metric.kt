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
 *
 * The `OTHER` fallback is a crash guard, not a shipping state. Registry v0.2.0 added seven
 * families at once (workout, readiness, effort, hydration, stress, cycle, lab) and, until they
 * were enumerated here, all 22 of their metrics collapsed into a single "Other" pillar with the
 * generic grid glyph — a third of the catalogue, indistinguishable in the Body browse surface.
 * `MetricFamilyParityTest` now fails if the registry names a family this enum doesn't, so the
 * next registry bump can't repeat that silently.
 *
 * Declaration order is load-bearing: `BodyScreen` sorts pillars by `entries.indexOf`, so this
 * reads top-to-bottom as the Body screen does, and must stay identical to the iOS `MetricFamily`
 * case order — the two are a mirrored pair, and a parity test on each side checks its own
 * platform only. New entries were *inserted* next to the family they relate to rather than
 * appended, preserving the relative order of the original ten; `MEDICATIONS` and `OTHER` stay
 * last because they are the non-registry and unknown buckets.
 */
enum class MetricFamily(val code: String) {
    SLEEP("sleep"),
    READINESS("readiness"),
    HEART("heart"),
    ACTIVITY("activity"),
    WORKOUT("workout"),
    EFFORT("effort"),
    BODY("body"),
    RESPIRATORY("respiratory"),
    NUTRITION("nutrition"),
    HYDRATION("hydration"),
    SUBJECTIVE("subjective"),
    JOURNAL("journal"),
    STRESS("stress"),
    CYCLE("cycle"),
    SYMPTOMS("symptoms"),
    LAB("lab"),
    MEDICATIONS("medications"),
    OTHER("other");

    val displayName: LocalizedString
        get() = when (this) {
            SLEEP -> LocalizedString(en = "Sleep", ar = "النوم")
            READINESS -> LocalizedString(en = "Readiness", ar = "الجاهزية")
            HEART -> LocalizedString(en = "Heart", ar = "القلب")
            ACTIVITY -> LocalizedString(en = "Activity", ar = "النشاط")
            WORKOUT -> LocalizedString(en = "Workouts", ar = "التمارين")
            EFFORT -> LocalizedString(en = "Effort", ar = "الجهد")
            BODY -> LocalizedString(en = "Body", ar = "الجسم")
            RESPIRATORY -> LocalizedString(en = "Respiratory", ar = "التنفّس")
            NUTRITION -> LocalizedString(en = "Nutrition", ar = "التغذية")
            HYDRATION -> LocalizedString(en = "Hydration", ar = "الترطيب")
            SUBJECTIVE -> LocalizedString(en = "How you feel", ar = "شعورك")
            // The journal family holds what you DID (behaviour tags) and what BADAN reads out of
            // it — deliberately distinct from SUBJECTIVE, which is how you FELT. Its one registry
            // row is the `journal.correlation` namespace (EPIC-29).
            JOURNAL -> LocalizedString(en = "Journal", ar = "المفكرة")
            // "Stress" names what the family tracks, not a state the reader is in — the metric is a
            // day-level trend (`stress.day_trend`), and the copy inside the family keeps it directional.
            STRESS -> LocalizedString(en = "Stress", ar = "التوتر")
            CYCLE -> LocalizedString(en = "Cycle", ar = "الدورة الشهرية")
            SYMPTOMS -> LocalizedString(en = "Symptoms", ar = "الأعراض")
            LAB -> LocalizedString(en = "Lab results", ar = "نتائج المختبر")
            MEDICATIONS -> LocalizedString(en = "Medications", ar = "الأدوية")
            OTHER -> LocalizedString(en = "Other", ar = "أخرى")
        }

    /** Material-style icon key for the family — kept here so both list and detail agree. */
    val symbolName: String
        get() = when (this) {
            SLEEP -> "bedtime"
            READINESS -> "bolt"
            HEART -> "favorite"
            ACTIVITY -> "directions_walk"
            // Shares the TimelineEventType key rather than minting a second one: same concept,
            // same glyph, and `iconForKey` would otherwise have two entries to keep in step.
            WORKOUT -> "directions_run"
            EFFORT -> "local_fire_department"
            BODY -> "accessibility"
            RESPIRATORY -> "air"
            NUTRITION -> "restaurant"
            HYDRATION -> "water_drop"
            SUBJECTIVE -> "mood"
            JOURNAL -> "edit_note"
            STRESS -> "psychology"
            CYCLE -> "calendar_month"
            SYMPTOMS -> "healing"
            LAB -> "science"
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
