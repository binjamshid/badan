package net.albayyan.badan.features.export

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.automation.AutomationCadence
import net.albayyan.badan.domain.automation.AutomationSchedule
import net.albayyan.badan.domain.automation.AutomationTier

/**
 * EPIC-15 — the one place a raw [AutomationTier]/[AutomationCadence]/schedule state becomes something
 * a person reads. Kotlin mirror of iOS `AutomationPresentation`, held to the same three rules:
 *
 *  1. **Never a raw token.** `OPPORTUNISTIC_BACKGROUND` / `SHORTCUT_DRIVEN` must never reach the user
 *     — every enum resolves to a calm bilingual sentence here (asserted total in the pure test).
 *  2. **Scheduling honesty (§13.7 / plan §4.10 / §14).** The tier labels are Android's honest
 *     wording — WorkManager genuinely IS more reliable than iOS's best-effort, so the background
 *     tier says "usually within an hour of the target" rather than flattening to "best-effort"; and
 *     it still discloses OEM battery throttling. No label promises a wall-clock time, says "cron", or
 *     says "guaranteed" un-caveated. The next run is always ESTIMATE language.
 *  3. **Status is never colour-only (§16 a11y).** The status/tier map to a closed kind here; the
 *     screen pairs each kind with an icon AND text, never a bare hue.
 *
 * Deliberately PURE — no Compose types (icons are chosen in the composable, exactly as
 * `ExportOutcomeCopy` does), so the JVM test source set can exhaust the mapping without a database or
 * an Android runtime.
 */
object AutomationPresentation {

    // -- Tier --

    /**
     * The full, honest reliability promise — the mandatory expectation-setting the wizard shows
     * BEFORE the user enables anything, and the detail line on a schedule row.
     */
    fun tierLabel(tier: AutomationTier): LocalizedString = when (tier) {
        AutomationTier.OPPORTUNISTIC_BACKGROUND -> LocalizedString(
            en = "Scheduled — usually within an hour of the target. Some phones delay background " +
                "work to save battery, so it can be later on those.",
            ar = "مجدول — عادةً خلال ساعة من الوقت المستهدف. تؤخّر بعض الهواتف عمل الخلفية لتوفير " +
                "البطارية، فقد يتأخّر عليها.",
        )
        AutomationTier.SHORTCUT_DRIVEN -> LocalizedString(
            en = "Runs when you start it — Android has no timed shortcut, so this one only runs on tap.",
            ar = "يعمل عند بدئه — لا يوجد اختصار مؤقّت في أندرويد، لذا يعمل هذا عند الضغط فقط.",
        )
        AutomationTier.MANUAL_ONLY -> LocalizedString(
            en = "Runs only when you tap Run now. Nothing happens on its own — you are always the trigger.",
            ar = "يعمل فقط عند ضغطك «شغّل الآن». لا يحدث شيء من تلقاء نفسه — أنت المُشغِّل دائماً.",
        )
    }

    /** A one-word title for the tier, for the wizard's option list and card headers. */
    fun tierTitle(tier: AutomationTier): LocalizedString = when (tier) {
        AutomationTier.OPPORTUNISTIC_BACKGROUND -> LocalizedString(en = "Scheduled (best-effort)", ar = "مجدول (أفضل جهد)")
        AutomationTier.SHORTCUT_DRIVEN -> LocalizedString(en = "On tap", ar = "عند الضغط")
        AutomationTier.MANUAL_ONLY -> LocalizedString(en = "Only when I tap", ar = "فقط عند ضغطي")
    }

    /** The compact chip label on a schedule row. */
    fun tierChip(tier: AutomationTier): LocalizedString = when (tier) {
        AutomationTier.OPPORTUNISTIC_BACKGROUND -> LocalizedString(en = "Scheduled", ar = "مجدول")
        AutomationTier.SHORTCUT_DRIVEN -> LocalizedString(en = "On tap", ar = "عند الضغط")
        AutomationTier.MANUAL_ONLY -> LocalizedString(en = "Manual", ar = "يدوي")
    }

    // -- Cadence --

    /**
     * How often, in ESTIMATE language. "About every…" / "when new data arrives" — never a wall-clock
     * claim; the tier already carries the truth about whether a wake happens at all.
     */
    fun cadenceLabel(cadence: AutomationCadence): LocalizedString = when (cadence) {
        AutomationCadence.ON_NEW_DATA -> LocalizedString(en = "When new data arrives", ar = "عند وصول بيانات جديدة")
        AutomationCadence.HOURLY_BEST_EFFORT -> LocalizedString(en = "About every hour", ar = "كل ساعة تقريباً")
        AutomationCadence.DAILY_BEST_EFFORT -> LocalizedString(en = "About every day", ar = "كل يوم تقريباً")
        AutomationCadence.WEEKLY_BEST_EFFORT -> LocalizedString(en = "About every week", ar = "كل أسبوع تقريباً")
    }

    /** A short helper sentence for each cadence in the wizard's picker. */
    fun cadenceHint(cadence: AutomationCadence): LocalizedString = when (cadence) {
        AutomationCadence.ON_NEW_DATA -> LocalizedString(
            en = "Runs after your sources bring in something new to export.",
            ar = "يعمل بعد أن تجلب مصادرك شيئاً جديداً للتصدير.",
        )
        AutomationCadence.HOURLY_BEST_EFFORT -> LocalizedString(
            en = "At most once an hour, on the next scheduled background run.",
            ar = "مرة كل ساعة على الأكثر، في تشغيل الخلفية المجدول التالي.",
        )
        AutomationCadence.DAILY_BEST_EFFORT -> LocalizedString(
            en = "At most once a day, on the next scheduled background run.",
            ar = "مرة كل يوم على الأكثر، في تشغيل الخلفية المجدول التالي.",
        )
        AutomationCadence.WEEKLY_BEST_EFFORT -> LocalizedString(
            en = "At most once a week, on the next scheduled background run.",
            ar = "مرة كل أسبوع على الأكثر، في تشغيل الخلفية المجدول التالي.",
        )
    }

    // -- Schedule status (active / paused / off) --

    /**
     * The three states a schedule can be in on the dashboard. Deliberately distinct: [PAUSED] is the
     * failure-budget stop (the anti-HAE visible-failure state), [OFF] is the user's own disable —
     * conflating them would hide which one the user is looking at.
     */
    enum class StatusKind { ACTIVE, PAUSED, OFF }

    fun status(schedule: AutomationSchedule): StatusKind = when {
        schedule.isPaused -> StatusKind.PAUSED
        schedule.enabled -> StatusKind.ACTIVE
        else -> StatusKind.OFF
    }

    fun statusLabel(status: StatusKind): LocalizedString = when (status) {
        StatusKind.ACTIVE -> LocalizedString(en = "On", ar = "مُفعّل")
        StatusKind.PAUSED -> LocalizedString(en = "Paused", ar = "متوقّف مؤقتاً")
        StatusKind.OFF -> LocalizedString(en = "Off", ar = "متوقّف")
    }

    /**
     * The VISIBLE reason a schedule paused itself — the exact never-silent-failure sentence EPIC-15
     * exists to guarantee. [count] is the already-formatted strike count (so the digit follows the
     * Arabic-Indic numeral rule); the value is [AutomationSchedule.FAILURE_BUDGET].
     */
    fun pausedReason(count: String): LocalizedString = LocalizedString(
        en = "Paused after $count exports failed in a row. It won't try again on its own — resume it to let it retry.",
        ar = "توقّف بعد فشل $count تصديرات متتالية. لن يحاول مجدداً من تلقاء نفسه — استأنفه ليعيد المحاولة.",
    )

    // -- Next expected window (always an ESTIMATE) --

    /**
     * What "next run" reads as. A closed vocabulary so the screen formats a date only in the one case
     * that has one, and so the mapping is testable without a clock. NONE of these is a promise:
     * [AROUND_ESTIMATE] is the EARLIEST the schedule becomes eligible (a floor), not an appointment.
     */
    enum class NextWindow { ON_TAP, WHEN_NEW_DATA, AROUND_ESTIMATE, AS_BACKGROUND_ALLOWS }

    fun nextWindow(schedule: AutomationSchedule): NextWindow = when (schedule.tier) {
        // Android has no timed shortcut, so a shortcut-tier row (only reachable via a config import)
        // reads as on-tap, the honest truth about when it can actually run here.
        AutomationTier.MANUAL_ONLY, AutomationTier.SHORTCUT_DRIVEN -> NextWindow.ON_TAP
        AutomationTier.OPPORTUNISTIC_BACKGROUND -> when (schedule.desiredCadence) {
            AutomationCadence.ON_NEW_DATA -> NextWindow.WHEN_NEW_DATA
            AutomationCadence.HOURLY_BEST_EFFORT,
            AutomationCadence.DAILY_BEST_EFFORT,
            AutomationCadence.WEEKLY_BEST_EFFORT ->
                if (schedule.nextExpectedWindow != null) NextWindow.AROUND_ESTIMATE else NextWindow.AS_BACKGROUND_ALLOWS
        }
    }

    /**
     * The label for a [NextWindow]. [dateText] is the pre-formatted, localized estimate and is used
     * ONLY by [NextWindow.AROUND_ESTIMATE]; passing `null` there falls back to the un-anchored
     * phrasing rather than printing an empty date.
     */
    fun nextWindowLabel(kind: NextWindow, dateText: String?): LocalizedString = when (kind) {
        NextWindow.ON_TAP -> LocalizedString(en = "Runs when you tap Run now", ar = "يعمل عند ضغطك «شغّل الآن»")
        NextWindow.WHEN_NEW_DATA -> LocalizedString(en = "Soon after new data arrives", ar = "بُعيد وصول بيانات جديدة")
        NextWindow.AS_BACKGROUND_ALLOWS -> LocalizedString(
            en = "On the next scheduled background run",
            ar = "في تشغيل الخلفية المجدول التالي",
        )
        NextWindow.AROUND_ESTIMATE ->
            if (dateText == null) {
                LocalizedString(en = "On the next scheduled background run", ar = "في تشغيل الخلفية المجدول التالي")
            } else {
                LocalizedString(en = "No earlier than around $dateText", ar = "ليس قبل نحو $dateText")
            }
    }
}
