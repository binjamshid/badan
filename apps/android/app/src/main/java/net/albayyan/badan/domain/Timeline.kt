package net.albayyan.badan.domain

import net.albayyan.badan.core.LocalizedString

enum class TimelineEventType(val code: String) {
    SLEEP("sleep"),
    WORKOUT("workout"),
    MEAL("meal"),
    MEDICATION("medication"),
    SYMPTOM("symptom"),
    MEASUREMENT("measurement"),
    NOTE("note"),
    INSIGHT("insight");

    val symbolName: String
        get() = when (this) {
            SLEEP -> "bedtime"
            WORKOUT -> "directions_run"
            MEAL -> "restaurant"
            MEDICATION -> "medication"
            SYMPTOM -> "healing"
            MEASUREMENT -> "straighten"
            NOTE -> "notes"
            INSIGHT -> "auto_awesome"
        }

    val displayName: LocalizedString
        get() = when (this) {
            SLEEP -> LocalizedString(en = "Sleep", ar = "نوم")
            WORKOUT -> LocalizedString(en = "Workout", ar = "تمرين")
            MEAL -> LocalizedString(en = "Meal", ar = "وجبة")
            MEDICATION -> LocalizedString(en = "Medication", ar = "دواء")
            SYMPTOM -> LocalizedString(en = "Symptom", ar = "عرض")
            MEASUREMENT -> LocalizedString(en = "Measurement", ar = "قياس")
            NOTE -> LocalizedString(en = "Note", ar = "ملاحظة")
            INSIGHT -> LocalizedString(en = "Insight", ar = "ملاحظة تحليلية")
        }

    companion object {
        fun fromCode(code: String?): TimelineEventType = entries.firstOrNull { it.code == code } ?: NOTE
    }
}

/**
 * A unified, chronological read-model row assembled at query time from sessions, logs and
 * notable samples — BADAN's anti-fragmentation spine (the Timeline screen). Not persisted.
 */
data class TimelineEvent(
    val id: String,
    val type: TimelineEventType,
    val occurredAt: Long,
    val tzId: String,
    val title: LocalizedString,
    val subtitle: LocalizedString? = null,
    val valueText: String? = null,
    val sourceRecordId: String? = null,
    val ingestionPath: IngestionPath? = null,
    val sensitive: Boolean = false,
    /** Auto-ingested rows are provenance-locked and not user-deletable. */
    val deletable: Boolean = true,
) {
    val symbolName: String get() = type.symbolName
}
