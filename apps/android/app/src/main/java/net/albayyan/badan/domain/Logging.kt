package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString

// MARK: - Medications (sensitivePlus)

/**
 * A medication schedule. No dosing advice lives anywhere near this type — BADAN records, it
 * never prescribes. Mirror of the iOS enum-with-associated-values; modelled as a sealed class
 * so it round-trips through its JSON column via kotlinx polymorphic serialization.
 */
@Serializable
sealed class MedicationSchedule {
    abstract val isScheduled: Boolean

    /** Local "HH:mm" slots this regimen is due on a given weekday (1=Mon...7=Sun). */
    abstract fun dueTimes(onWeekday: Int): List<String>

    @Serializable
    @SerialName("asNeeded")
    data object AsNeeded : MedicationSchedule() {
        override val isScheduled: Boolean get() = false
        override fun dueTimes(onWeekday: Int): List<String> = emptyList()
    }

    @Serializable
    @SerialName("daily")
    data class Daily(val times: List<String>) : MedicationSchedule() {   // "HH:mm" local times
        override val isScheduled: Boolean get() = true
        override fun dueTimes(onWeekday: Int): List<String> = times
    }

    @Serializable
    @SerialName("weekly")
    data class Weekly(val days: List<Int>, val times: List<String>) : MedicationSchedule() {   // days 1=Mon ... 7=Sun
        override val isScheduled: Boolean get() = true
        override fun dueTimes(onWeekday: Int): List<String> = if (days.contains(onWeekday)) times else emptyList()
    }
}

data class MedicationRegimen(
    val id: String,
    val name: String,
    val strength: String? = null,
    val form: String? = null,          // tablet, capsule, ml...
    val schedule: MedicationSchedule,
    val startedAt: Long,
    val endedAt: Long? = null,
    val notes: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val isActive: Boolean get() = endedAt == null
}

enum class AdherenceKind(val code: String) {
    TAKEN("taken"),
    SKIPPED("skipped"),
    LATE("late");

    companion object {
        fun fromCode(code: String?): AdherenceKind = entries.firstOrNull { it.code == code } ?: TAKEN
    }
}

/** Skip-with-reason is a first-class equal of "taken" — non-punitive by design (no guilt). */
enum class SkipReason(val code: String) {
    FORGOT("forgot"),
    SIDE_EFFECTS("sideEffects"),
    RAN_OUT("ranOut"),
    DOCTOR_ADVICE("doctorAdvice"),
    NOT_NEEDED("notNeeded"),
    OTHER("other");

    val displayLabel: LocalizedString
        get() = when (this) {
            FORGOT -> LocalizedString(en = "Forgot", ar = "نسيت")
            SIDE_EFFECTS -> LocalizedString(en = "Side effects", ar = "آثار جانبية")
            RAN_OUT -> LocalizedString(en = "Ran out", ar = "نفد")
            DOCTOR_ADVICE -> LocalizedString(en = "Doctor's advice", ar = "بناءً على نصيحة الطبيب")
            NOT_NEEDED -> LocalizedString(en = "Not needed", ar = "غير ضروري")
            OTHER -> LocalizedString(en = "Other", ar = "أخرى")
        }

    companion object {
        fun fromCode(code: String?): SkipReason = entries.firstOrNull { it.code == code } ?: OTHER
    }
}

data class AdherenceEvent(
    val id: String,
    val regimenId: String,
    val kind: AdherenceKind,
    val scheduledFor: Long? = null,
    val occurredAt: Long,
    val tzId: String,
    val skipReason: SkipReason? = null,
    val skipNote: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

// MARK: - Symptoms (sensitivePlus)

data class SymptomEntry(
    val id: String,
    val symptomId: String? = null,      // canonical dictionary id
    val customLabel: String? = null,    // when not in the dictionary
    val severity: Int,           // 0...10 (scale origin preserved)
    val occurredAt: Long,
    val tzId: String,
    val durationSeconds: Double? = null,
    val bodyLocation: String? = null,
    val triggers: List<String> = emptyList(),
    val note: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

// MARK: - Workouts (normal sensitivity)

data class WorkoutEntry(
    val id: String,
    val activityType: String,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val energyKcal: Double? = null,
    val distanceM: Double? = null,
    val avgHr: Double? = null,
    val maxHr: Double? = null,
    val perceivedEffort: Int? = null,   // RPE 1...10
    val note: String? = null,
    val ingestionPath: IngestionPath = IngestionPath.MANUAL,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val durationSeconds: Double get() = (endAt - startAt) / 1000.0
}

// MARK: - Nutrition (normal sensitivity)

enum class MealType(val code: String) {
    BREAKFAST("breakfast"),
    LUNCH("lunch"),
    DINNER("dinner"),
    SNACK("snack"),
    DRINK("drink");

    val displayName: LocalizedString
        get() = when (this) {
            BREAKFAST -> LocalizedString(en = "Breakfast", ar = "الفطور")
            LUNCH -> LocalizedString(en = "Lunch", ar = "الغداء")
            DINNER -> LocalizedString(en = "Dinner", ar = "العشاء")
            SNACK -> LocalizedString(en = "Snack", ar = "وجبة خفيفة")
            DRINK -> LocalizedString(en = "Drink", ar = "مشروب")
        }

    val symbolName: String
        get() = when (this) {
            BREAKFAST -> "breakfast_dining"
            LUNCH -> "lunch_dining"
            DINNER -> "dinner_dining"
            SNACK -> "cookie"
            DRINK -> "local_cafe"
        }

    companion object {
        fun fromCode(code: String?): MealType = entries.firstOrNull { it.code == code } ?: SNACK
    }
}

data class NutritionEntry(
    val id: String,
    val description: String,
    val mealType: MealType,
    val energyKcal: Double? = null,
    val proteinG: Double? = null,
    val carbsG: Double? = null,
    val fatG: Double? = null,
    val fiberG: Double? = null,
    val waterMl: Double? = null,
    val caffeineMg: Double? = null,
    val lowDetail: Boolean = false,          // "quick calories" honestly flagged
    val occurredAt: Long,
    val tzId: String,
    val note: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

// MARK: - Conditions (sensitivePlus) & Notes (normal)

enum class ConditionStatus(val code: String) {
    ACTIVE("active"),
    RESOLVED("resolved"),
    EPISODIC("episodic");

    companion object {
        fun fromCode(code: String?): ConditionStatus = entries.firstOrNull { it.code == code } ?: ACTIVE
    }
}

/** User-declared only — BADAN never infers a condition. */
data class Condition(
    val id: String,
    val label: String,
    val status: ConditionStatus,
    val onsetAt: Long? = null,
    val linkedRegimenIds: List<String> = emptyList(),
    val linkedSymptomIds: List<String> = emptyList(),
    val notes: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

data class NoteEntry(
    val id: String,
    val text: String,
    val occurredAt: Long,
    val tzId: String,
    val tags: List<String> = emptyList(),
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)
