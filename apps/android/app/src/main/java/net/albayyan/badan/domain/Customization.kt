package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString

/**
 * The dual-altitude mechanism (D-5). Casual and power are presentation policies over a single
 * component library and identical queries — never separate products.
 */
@Serializable
enum class DepthPolicy(val code: String) {
    @SerialName("casual") CASUAL("casual"),
    @SerialName("balanced") BALANCED("balanced"),
    @SerialName("power") POWER("power");

    val displayName: LocalizedString
        get() = when (this) {
            CASUAL -> LocalizedString(en = "Simple", ar = "مبسّط")
            BALANCED -> LocalizedString(en = "Balanced", ar = "متوازن")
            POWER -> LocalizedString(en = "Detailed", ar = "مفصّل")
        }

    /** Whether power-only affordances (raw values, lineage, tables, algorithm strings) show. */
    val showsPowerDetail: Boolean get() = this == POWER

    /** The most compact number of home modules this depth prefers to show. */
    val maxHomeModules: Int get() = if (this == CASUAL) 5 else 12

    companion object {
        fun fromCode(code: String?): DepthPolicy = entries.firstOrNull { it.code == code } ?: BALANCED
    }
}

@Serializable
enum class AppTheme(val code: String) {
    @SerialName("system") SYSTEM("system"),
    @SerialName("light") LIGHT("light"),
    @SerialName("dark") DARK("dark");

    val displayName: LocalizedString
        get() = when (this) {
            SYSTEM -> LocalizedString(en = "Match device", ar = "حسب الجهاز")
            LIGHT -> LocalizedString(en = "Light", ar = "فاتح")
            DARK -> LocalizedString(en = "Dark", ar = "داكن")
        }

    companion object {
        fun fromCode(code: String?): AppTheme = entries.firstOrNull { it.code == code } ?: SYSTEM
    }
}

@Serializable
enum class UnitProfileMode(val code: String) {
    @SerialName("canonical") CANONICAL("canonical"),   // SI units, provenance-faithful
    @SerialName("display") DISPLAY("display");          // the user's chosen display units

    companion object {
        fun fromCode(code: String?): UnitProfileMode = entries.firstOrNull { it.code == code } ?: CANONICAL
    }
}

/** An orderable, hideable home surface. This is the DashboardCard/DashboardLayout concept. */
@Serializable
data class HomeModule(
    val id: String,            // "sleep" | "readiness" | "activity" | "meds" | ...
    val visible: Boolean,
    val order: Int,
)

/**
 * A notification quiet-hours window, in local wall-clock hours. [startHour] is inclusive,
 * [endHour] exclusive; a window may wrap past midnight (e.g. 22→07). EPIC-32's decision engine
 * consults it per notification class so a calm nudge never lands in the middle of the night.
 * Stored as two ints rather than instants because it is a recurring wall-clock rule, not a moment.
 *
 * Deliberately distinct from `domain.automation`'s minute-based `QuietHours` (EPIC-15): that one
 * carries an export schedule's `"HH:mm-HH:mm"` storage-string parity contract, this one is an
 * hour-granularity user preference. Coupling the two would tie a notification-prefs change to the
 * automation-schedule storage format for no shared benefit. Mirror of iOS `NotificationQuietHours`.
 */
@Serializable
data class NotificationQuietHours(
    val startHour: Int = DEFAULT_START,   // 0…23, inclusive
    val endHour: Int = DEFAULT_END,       // 0…23, exclusive (may be < startHour to wrap midnight)
) {
    companion object {
        /** The default night window applied to non-med classes: 22:00 → 07:00 local. */
        const val DEFAULT_START = 22
        const val DEFAULT_END = 7
        val defaultNight = NotificationQuietHours(DEFAULT_START, DEFAULT_END)
    }
}

@Serializable
data class NotificationPreference(
    // These three carry no delivery on either platform. iOS (STUB-12) already defaults them off
    // rather than pre-consenting every user to categories nothing sends; Android matches, so the
    // two profiles decode to the same state and neither ships a silent "yes" the app cannot honour.
    val morningNarrative: Boolean = false,
    val weeklyDigest: Boolean = false,
    val medicationReminders: Boolean = false,
    val dataPausedAlerts: Boolean = false,
    /**
     * EPIC-32 per-class opt-in for the decision-engine classes, keyed by `NotificationClass`'s
     * storage code (`readiness`, `windDown`, `deviation`, `exportHealth`, `hydration`). A missing
     * key means OFF — every class is opt-in and ships OFF (the existing convention), so an empty
     * map is "nothing enabled". `meds` is deliberately NOT keyed here: it keeps using
     * [medicationReminders] above, so the shape stays identical to iOS.
     */
    val classOptIn: Map<String, Boolean> = emptyMap(),
    /**
     * EPIC-32 quiet-hours window honoured by every non-med decision class. Modeled as one window
     * (what a user means by "don't notify me at night"); the engine takes it PER class, so a future
     * per-class override slots in without a schema change.
     */
    val quietHours: NotificationQuietHours = NotificationQuietHours.defaultNight,
)

enum class GoalDirection(val code: String) {
    AT_LEAST("atLeast"),
    AT_MOST("atMost"),
    AROUND("around");

    companion object {
        fun fromCode(code: String?): GoalDirection = entries.firstOrNull { it.code == code } ?: AROUND
    }
}

@Serializable
data class Goal(
    val id: String,
    val metricId: String,
    val target: Double,
    val unit: String,
    val direction: GoalDirection,
    val active: Boolean = true,
    val createdAt: Long,
)

/**
 * The single presentation/preferences record. This IS the "one model, two altitudes" switch
 * plus units, language, theme and dashboard layout — a UserPreference aggregate.
 */
@Serializable
data class CustomizationProfile(
    val depthPolicy: DepthPolicy = DepthPolicy.BALANCED,
    val homeModules: List<HomeModule> = defaultModules,
    val unitOverrides: Map<String, String> = emptyMap(),   // metricId -> preferred display unit
    val unitProfile: UnitProfileMode = UnitProfileMode.DISPLAY,
    val language: AppLanguage = AppLanguage.EN,
    val arabicDigits: Boolean = false,
    val theme: AppTheme = AppTheme.SYSTEM,
    val notifications: NotificationPreference = NotificationPreference(),
    val sensitiveModulesEnabled: Boolean = true,
    val nutritionEnabled: Boolean = true,
    // EPIC-38: whether the hydration surface is shown in the Log tab. A presentation flag exactly
    // like [nutritionEnabled] — hiding it is non-destructive (§7A.1 "hideable without deletion"):
    // the ledger, goals and summaries stay in the DB and re-enabling brings them straight back.
    // Defaults on; a persisted profile without the field decodes to true (ignoreUnknownKeys + default).
    val hydrationEnabled: Boolean = true,
) {
    fun module(id: String): HomeModule? = homeModules.firstOrNull { it.id == id }

    val visibleModulesOrdered: List<HomeModule>
        get() = homeModules.filter { it.visible }.sortedBy { it.order }

    companion object {
        val defaultModules: List<HomeModule> = listOf(
            HomeModule(id = "readiness", visible = true, order = 0),
            HomeModule(id = "sleep", visible = true, order = 1),
            HomeModule(id = "activity", visible = true, order = 2),
            HomeModule(id = "heart", visible = true, order = 3),
            HomeModule(id = "meds", visible = true, order = 4),
            HomeModule(id = "nutrition", visible = true, order = 5),
            HomeModule(id = "timeline", visible = true, order = 6),
        )
    }
}
