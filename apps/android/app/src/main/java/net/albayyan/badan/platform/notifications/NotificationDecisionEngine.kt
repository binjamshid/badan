package net.albayyan.badan.platform.notifications

import java.time.Instant
import java.time.ZoneId
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.NotificationQuietHours
import net.albayyan.badan.domain.reports.ReportPresentation

// MARK: - Class registry (EPIC-32)

/**
 * The notification classes BADAN can raise. This is the registry the whole decision layer is built
 * around: budget, opt-in, quiet hours and the shared pending ceiling all reason in terms of a
 * [NotificationClass], and the storage ledger (`notification_deliveries`) records one row per class
 * per delivery.
 *
 * [code] is the STORAGE CODE — byte-identical to the strings migration v8 documents
 * (`readiness|windDown|deviation|exportHealth|hydration|meds`) and to the iOS `NotificationClass`
 * raw values. They are the ledger's `notification_class` values, so renaming one is a
 * schema-visible change, not a refactor.
 *
 * `MEDS` is a first-class member of the registry so the budget/ledger accounting has one vocabulary
 * covering every notification BADAN sends. Note the platform difference stated plainly: iOS has a
 * medication-reminder scheduler (`NotificationScheduler` + `MedicationReminderPlan`) and this engine
 * EXTENDS it; **Android has no medication-reminder delivery at all** — that is standing parity debt,
 * not something EPIC-32 built — so on Android no `meds` row is ever written and the Notifications
 * settings surface offers no medication toggle. See [AndroidNotificationScheduler].
 */
enum class NotificationClass(val code: String) {
    MORNING_READINESS_SUMMARY("readiness"),
    EVENING_WIND_DOWN("windDown"),
    DEVIATION_NOTICE("deviation"),
    EXPORT_HEALTH_ALERT("exportHealth"),
    HYDRATION("hydration"),
    MEDS("meds"),
    ;

    /**
     * Medication reminders are exempt from the ≤2/day non-med budget AND are never evicted to make
     * room for a score/hydration notice. A med reminder is a safety-relevant thing the user
     * explicitly set up, not an ambient nudge — the whole point of the budget is to protect the
     * user from ambient-nudge fatigue, which meds are not.
     */
    val isMedication: Boolean get() = this == MEDS

    /**
     * Whether a delivery of this class consumes one unit of the daily non-med budget. Everything
     * except meds does; this is the single predicate the ≤2/day invariant is stated against, so a
     * future class is budgeted by default the moment it is added.
     */
    val countsAgainstDailyBudget: Boolean get() = !isMedication

    /**
     * The notification channel this class posts through. One channel per class (not one for the
     * whole app) so a user who finds the water reminders chatty can silence exactly those in system
     * settings without losing the export-health alert they actually want. Ids are stable strings —
     * a channel's id is user-visible state (its importance and sound survive under that id), so
     * renaming one silently resets the user's per-channel choices.
     */
    val channelId: String get() = "badan.notif.$code"

    /**
     * The work/tag name for this class's scheduled (time-based) notification. Shared prefix
     * [DECISION_PREFIX] so the engine can cancel its own work by class without ever touching the
     * EPIC-15 automation-pause notice or anything else.
     */
    val workTag: String get() = "$DECISION_PREFIX$code"

    /** The evidence surface a tap opens (plan §12 EPIC-32 task 4: deep links to evidence screens). */
    val deepLink: NotificationDeepLink
        get() = when (this) {
            MORNING_READINESS_SUMMARY -> NotificationDeepLink.READINESS
            EVENING_WIND_DOWN -> NotificationDeepLink.SLEEP
            DEVIATION_NOTICE -> NotificationDeepLink.HEALTH_MONITOR
            EXPORT_HEALTH_ALERT -> NotificationDeepLink.EXPORT_HEALTH
            HYDRATION -> NotificationDeepLink.HYDRATION
            MEDS -> NotificationDeepLink.MEDS
        }

    companion object {
        /** Shared prefix for every non-med decision-engine work tag. */
        const val DECISION_PREFIX = "decision."

        fun fromCode(code: String?): NotificationClass? = entries.firstOrNull { it.code == code }

        /**
         * The classes the Notifications settings surface offers, in display order — exactly those a
         * producer in the app can actually schedule. A toggle is a promise, so a class earns a row
         * here only once something raises it.
         *
         * Three classes are registered but deliberately NOT offered:
         * - `MEDS` — Android delivers no medication reminders at all (see the class doc); standing
         *   parity debt, not something this engine can honour.
         * - `DEVIATION_NOTICE` and `EXPORT_HEALTH_ALERT` — registered for the ledger/budget
         *   vocabulary and for their deep links, but no code path raises either yet. They are
         *   event-driven by design and [raiseDecisionNotification] is the seam waiting for a
         *   producer; until a detector calls it, a toggle would promise a notice that never arrives.
         *   The automation-pause notice is NOT that producer — it is unbudgeted and ungated, and
         *   merely borrows `EXPORT_HEALTH_ALERT`'s deep link (see `AndroidAutomationPauseNotifier`).
         *
         * Add a class here in the same change that gives it a producer, never before.
         */
        val userFacing: List<NotificationClass> =
            listOf(MORNING_READINESS_SUMMARY, EVENING_WIND_DOWN, HYDRATION)

        /**
         * The classes that schedule ahead of time, at a fixed local hour each day. The remaining
         * budgeted classes (deviation, export-health) are event-driven by design — they would be
         * raised at the moment they occur — but no producer calls that seam yet, which is why they
         * are absent from [userFacing] too.
         */
        val timeBased: List<NotificationClass> =
            listOf(MORNING_READINESS_SUMMARY, EVENING_WIND_DOWN, HYDRATION)

        /** The default local fire hour for a time-based class — a constant, not a call-site literal. */
        fun defaultHour(cls: NotificationClass): Int = when (cls) {
            MORNING_READINESS_SUMMARY -> 8
            EVENING_WIND_DOWN -> 21
            HYDRATION -> 15
            else -> 9
        }
    }
}

// MARK: - Deep links

/**
 * Where tapping a notification takes the user. Kept deliberately coarse — a destination the app can
 * always honour — and carried as an intent extra so `MainActivity` can route without parsing copy.
 * [code] is a stable token (it rides in the intent, so it is a small contract with the activity,
 * not free text). Mirror of iOS `NotificationDeepLink`.
 */
enum class NotificationDeepLink(val code: String) {
    READINESS("readiness"),
    SLEEP("sleep"),
    HEALTH_MONITOR("healthMonitor"),
    EXPORT_HEALTH("exportHealth"),
    HYDRATION("hydration"),
    MEDS("meds"),
    ;

    companion object {
        /** The intent-extra key the notification carries and `MainActivity` reads. */
        const val EXTRA = "badan.deeplink"

        fun fromCode(code: String?): NotificationDeepLink? = entries.firstOrNull { it.code == code }
    }
}

// MARK: - Quiet hours evaluation

/**
 * Whether [instant]'s local hour in [zone] falls inside this quiet window. A window where
 * `startHour == endHour` is empty (never quiet); a window that wraps midnight
 * (`startHour > endHour`, e.g. 22→07) is handled explicitly. Byte-equivalent behaviour to the iOS
 * `NotificationQuietHours.contains(_:calendar:)` extension.
 */
fun NotificationQuietHours.contains(instant: Long, zone: ZoneId): Boolean {
    if (startHour == endHour) return false
    val hour = Instant.ofEpochMilli(instant).atZone(zone).hour
    return if (startHour < endHour) hour >= startHour && hour < endHour
    else hour >= startHour || hour < endHour   // wraps past midnight
}

// MARK: - Budget constants

/**
 * The hard limits the decision engine enforces. [DAILY_NON_MED_LIMIT] is the anti-fatigue budget
 * (plan §12 EPIC-32: "Default ≤2/day … budget is a hard invariant, not a preference");
 * [SYSTEM_PENDING_LIMIT] is the shared pending ceiling.
 */
object NotificationBudget {
    /**
     * At most this many NON-medication notifications may be scheduled/delivered per local day,
     * across ALL non-med classes combined. Not a preference — the user can turn classes off, but
     * cannot raise this ceiling.
     */
    const val DAILY_NON_MED_LIMIT = 2

    /**
     * The pending-request ceiling meds and decision notices share. 64 is *iOS's* limit — the number
     * of pending `UNNotificationRequest`s the OS keeps per app before silently dropping the rest —
     * and it is mirrored here because both platforms run the same decision algorithm and the same
     * fixtures. Android has no equivalent per-app queue ceiling, so on Android this check does not
     * bind in practice; [AndroidNotificationScheduler] still feeds it real counts (scheduled,
     * not-yet-fired ledger rows) rather than zeros, so the arithmetic is honest rather than faked.
     */
    const val SYSTEM_PENDING_LIMIT = 64
}

// MARK: - The pure decision engine

/**
 * The side-effect-free core of EPIC-32: given a candidate notification and a snapshot of the current
 * state (opt-in, quiet hours, today's non-med ledger count, pending med/non-med counts), it decides
 * whether the candidate may be scheduled and, if not, WHY. It touches no `NotificationManager`, no
 * database and no clock — everything it needs is passed in — so the budget, the opt-in matrix and
 * the shared-ceiling interplay are all unit-testable on the JVM.
 *
 * Byte-equivalent decision behaviour to the iOS `NotificationDecisionEngine`; the scheduler adapter
 * ([AndroidNotificationScheduler]) is the thin I/O shell that gathers the inputs, asks this engine,
 * and turns a [Decision.SCHEDULED] verdict into a real notification plus a ledger row.
 */
object NotificationDecisionEngine {

    /**
     * The verdict for one candidate. Every non-[SCHEDULED] case names the specific reason so the
     * scheduler can record it and tests can assert the *why*, not just the *whether*.
     */
    enum class Decision {
        SCHEDULED,

        /** The user has not opted this class in (all classes default OFF). */
        SUPPRESSED_OPTED_OUT,

        /** The candidate's fire time falls inside this class's quiet-hours window. */
        SUPPRESSED_QUIET_HOURS,

        /** The ≤2/day non-med budget for the candidate's day is already spent. */
        SUPPRESSED_DAILY_BUDGET,

        /** Scheduling would exceed the pending ceiling shared with med reminders. Meds win. */
        SUPPRESSED_SYSTEM_CAP,

        /**
         * Notifications are not permitted (`POST_NOTIFICATIONS` denied, or notifications switched
         * off for BADAN), so nothing would arrive. Raised by the SCHEDULER ADAPTER, never by
         * [decide] — permission is an I/O fact the pure engine cannot see, and reporting it as
         * "opted out" would name the wrong reason for a caller or a test.
         */
        SUPPRESSED_NOT_AUTHORIZED,

        /**
         * The budget ledger could not reserve a slot (the `notification_deliveries` insert failed),
         * so nothing was handed to WorkManager or posted. Also an ADAPTER verdict, for the same
         * reason as [SUPPRESSED_NOT_AUTHORIZED]: storage is an I/O fact [decide] is never handed.
         *
         * This exists because the ≤2/day ceiling is a HARD invariant (plan §12 EPIC-32) and the
         * ledger is the only thing that remembers it across process death. A notification that went
         * out without a ledger row would let the next evaluation read a lower count and push the day
         * past 2 — so the adapter reserves the slot FIRST and, if it cannot, declines to send rather
         * than degrading the budget open. Failing closed loses at most one wellness nudge; failing
         * open breaks the invariant the user cannot see being broken.
         */
        SUPPRESSED_LEDGER_UNAVAILABLE,
        ;

        val didSchedule: Boolean get() = this == SCHEDULED
    }

    /**
     * One notification the engine is asked to consider. [fireAt] is epoch millis: both the
     * quiet-hours check and the day the daily budget is measured over are taken from it.
     */
    data class Candidate(val notificationClass: NotificationClass, val fireAt: Long)

    /**
     * The state the decision is made against. The three count fields are what the scheduler reads
     * from the ledger immediately before deciding; [decideBatch] advances them as it accepts
     * candidates so a single evaluation cannot blow the budget.
     */
    data class Context(
        val zone: ZoneId,
        /**
         * Whether the user has enabled a given class. Meds map to the existing
         * `medicationReminders` preference; the rest to the per-class opt-in map.
         */
        val optedIn: (NotificationClass) -> Boolean,
        /** The quiet-hours window for a given class, or `null` for "no quiet hours". */
        val quietHours: (NotificationClass) -> NotificationQuietHours?,
        /**
         * How many budgeted (non-med) notifications are already scheduled/delivered for the
         * candidate day, read from the `notification_deliveries` ledger.
         */
        val nonMedScheduledToday: Int,
        /**
         * Pending med reminders right now. Meds are never evicted for a non-med notice, so a
         * non-med candidate only takes a slot the meds are not using.
         */
        val pendingMedCount: Int,
        /** Pending non-med (decision-engine) notifications right now. */
        val pendingNonMedCount: Int,
        val dailyNonMedLimit: Int = NotificationBudget.DAILY_NON_MED_LIMIT,
        val systemPendingLimit: Int = NotificationBudget.SYSTEM_PENDING_LIMIT,
    )

    /**
     * Decide a single candidate. Order matters: opt-in first (a class the user turned off is never
     * even considered), then quiet hours, then the daily budget, then the shared system cap.
     */
    fun decide(candidate: Candidate, context: Context): Decision {
        val cls = candidate.notificationClass

        if (!context.optedIn(cls)) return Decision.SUPPRESSED_OPTED_OUT

        val window = context.quietHours(cls)
        if (window != null && window.contains(candidate.fireAt, context.zone)) {
            return Decision.SUPPRESSED_QUIET_HOURS
        }

        // The ≤2/day invariant applies only to budgeted (non-med) classes.
        if (cls.countsAgainstDailyBudget && context.nonMedScheduledToday >= context.dailyNonMedLimit) {
            return Decision.SUPPRESSED_DAILY_BUDGET
        }

        // Shared-ceiling interplay. A non-med notice may only take a slot the meds are not already
        // using: meds + non-med together must never exceed the ceiling, and meds are never pushed
        // out to fit a non-med one. Meds themselves never fail this check (they are scheduled by the
        // med path, which caps ITSELF against the same ceiling — see [medPendingLimit]).
        if (cls.countsAgainstDailyBudget &&
            context.pendingMedCount + context.pendingNonMedCount >= context.systemPendingLimit
        ) {
            return Decision.SUPPRESSED_SYSTEM_CAP
        }

        return Decision.SCHEDULED
    }

    /**
     * Decide a batch in one pass, advancing the running counts as candidates are accepted so the
     * budget holds even when many candidates arrive at once (the "≤2/day under load" acceptance
     * case). Candidates are assumed to target the SAME budget day — the caller builds one batch per
     * day/evaluation — so [Context.nonMedScheduledToday] is a single counter.
     */
    fun decideBatch(candidates: List<Candidate>, context: Context): List<Pair<Candidate, Decision>> {
        var nonMedToday = context.nonMedScheduledToday
        var pendingNonMed = context.pendingNonMedCount
        val results = ArrayList<Pair<Candidate, Decision>>(candidates.size)
        for (candidate in candidates) {
            val ctx = context.copy(nonMedScheduledToday = nonMedToday, pendingNonMedCount = pendingNonMed)
            val decision = decide(candidate, ctx)
            if (decision == Decision.SCHEDULED && candidate.notificationClass.countsAgainstDailyBudget) {
                nonMedToday += 1
                pendingNonMed += 1
            }
            results.add(candidate to decision)
        }
        return results
    }

    // MARK: - Shared-ceiling interplay (the med side)

    /**
     * The number of pending slots medication reminders may claim, after reserving room for the
     * non-med notices currently pending. On iOS this is what
     * `NotificationScheduler.rescheduleMedicationReminders` caps its plan to, so meds + decision
     * notices together never exceed the ceiling.
     *
     * Because non-med notices are capped at ≤2/day and are one-shots that clear as they fire, this
     * reservation is at most a couple of slots — meds keep ≥62 of 64 in the worst case, and the full
     * 64 whenever no non-med notice is pending (the default, since every non-med class ships OFF).
     * So this is NOT starvation: the med cap keeps the SOONEST reminders and rolls the window
     * forward on every reschedule, and losing at most two of the furthest-out repeating slots to a
     * notice the user explicitly opted into is the correct trade — the alternative is the OS
     * silently dropping meds when the total crosses the ceiling.
     *
     * Mirrored here (rather than left iOS-only) so both platforms carry one algorithm and one set of
     * fixtures; Android has no med-reminder scheduler to call it yet.
     */
    fun medPendingLimit(nonMedPending: Int, systemLimit: Int = NotificationBudget.SYSTEM_PENDING_LIMIT): Int =
        maxOf(0, systemLimit - nonMedPending)
}

// MARK: - Copy (bilingual, wellness-safe, privacy-first)

/**
 * Every string a decision-engine notification, its channel, or its settings row shows. Two rules
 * govern all of it: the delivered BODY names no health value (nothing legible on a lock screen —
 * the same discipline [AutomationPausedCopy] follows), and the register is calm and never alarmist
 * (D-11 wellness language) — a shifted reading is "a little different", never "abnormal". Copy is
 * hand-written in both languages, not machine-literal, and is byte-identical to iOS
 * `NotificationClassCopy`.
 */
object NotificationClassCopy {

    /** The notification content (title + body) for a delivered notification of [cls]. */
    fun content(cls: NotificationClass): Pair<LocalizedString, LocalizedString> {
        val title = LocalizedString(en = "BADAN", ar = "بدن")
        val body = when (cls) {
            NotificationClass.MORNING_READINESS_SUMMARY -> LocalizedString(
                en = "Your morning check-in is ready whenever you are.",
                ar = "ملخّص صباحك جاهز متى شئت.",
            )
            NotificationClass.EVENING_WIND_DOWN -> LocalizedString(
                en = "A calm moment to start winding down for the night.",
                ar = "لحظة هادئة لتبدأ الاستعداد للنوم.",
            )
            NotificationClass.DEVIATION_NOTICE -> LocalizedString(
                en = "A recent reading looks a little different from your usual. Open BADAN when it suits you.",
                ar = "بدت إحدى قراءاتك الأخيرة مختلفة قليلاً عن معتادك. افتح «بدن» متى ناسبك.",
            )
            NotificationClass.EXPORT_HEALTH_ALERT -> LocalizedString(
                en = "One of your automatic exports could use a quick look.",
                ar = "يحتاج أحد تصديراتك التلقائية إلى نظرة سريعة.",
            )
            NotificationClass.HYDRATION -> LocalizedString(
                en = "A gentle reminder to have some water.",
                ar = "تذكير لطيف لشرب بعض الماء.",
            )
            NotificationClass.MEDS -> LocalizedString(
                en = "It's about the time you usually take a medication.",
                ar = "اقترب وقتك المعتاد لأحد أدويتك.",
            )
        }
        return title to body
    }

    /** The system notification-channel name shown in Android settings for [cls]. */
    fun channelName(cls: NotificationClass): LocalizedString = when (cls) {
        NotificationClass.MORNING_READINESS_SUMMARY -> LocalizedString(en = "Morning summary", ar = "ملخّص الصباح")
        NotificationClass.EVENING_WIND_DOWN -> LocalizedString(en = "Evening wind-down", ar = "استرخاء المساء")
        NotificationClass.DEVIATION_NOTICE -> LocalizedString(en = "Gentle change notices", ar = "تنبيهات لطيفة للتغيّرات")
        NotificationClass.EXPORT_HEALTH_ALERT -> LocalizedString(en = "Export health alerts", ar = "تنبيهات حالة التصدير")
        NotificationClass.HYDRATION -> LocalizedString(en = "Water reminders", ar = "تذكيرات شرب الماء")
        NotificationClass.MEDS -> LocalizedString(en = "Medication reminders", ar = "تذكيرات الأدوية")
    }

    /** The Settings row (label + hint) for [cls]. The label doubles as the channel name above. */
    fun settingsRow(cls: NotificationClass): Pair<LocalizedString, LocalizedString> {
        val hint = when (cls) {
            NotificationClass.MORNING_READINESS_SUMMARY -> LocalizedString(
                en = "A short check-in each morning. No readings shown on the lock screen.",
                ar = "ملخّص قصير كل صباح. لا تظهر أي قراءات على شاشة القفل.",
            )
            NotificationClass.EVENING_WIND_DOWN -> LocalizedString(
                en = "A calm nudge to ease into the evening.",
                ar = "تذكير هادئ للاستعداد لأمسيتك.",
            )
            NotificationClass.DEVIATION_NOTICE -> LocalizedString(
                en = "An occasional heads-up when a reading drifts from your usual.",
                ar = "تنبيه من حين لآخر عندما تبتعد قراءة عن معتادك.",
            )
            NotificationClass.EXPORT_HEALTH_ALERT -> LocalizedString(
                en = "A heads-up if an automatic export needs your attention.",
                ar = "تنبيه إذا احتاج تصدير تلقائي إلى انتباهك.",
            )
            NotificationClass.HYDRATION -> LocalizedString(
                en = "A gentle, occasional nudge to drink some water.",
                ar = "تذكير لطيف من حين لآخر لشرب بعض الماء.",
            )
            NotificationClass.MEDS -> LocalizedString(
                en = "A gentle nudge at your usual times. No names appear on the lock screen.",
                ar = "تذكير لطيف في أوقاتك المعتادة. لا تظهر أي أسماء على شاشة القفل.",
            )
        }
        return channelName(cls) to hint
    }

    /**
     * The daily-budget explanation shown in Settings when any budgeted class is on. Wellness-safe: a
     * budget is a kindness, not a failure.
     *
     * The count goes through [ReportPresentation.countedNoun] rather than being interpolated straight
     * into the sentence, because Arabic does not simply pluralise: at the current limit of 2 the noun
     * takes the DUAL ("إشعارين", which carries the two by itself and wants no numeral in front of
     * it), and a bare "$n إشعارات" is wrong at every count below 3. That is the same agreement rule
     * the reports surface already applies, so it is reused rather than re-derived — and
     * [arabicDigits] is threaded through for the same reason every other number in the app is: the
     * digit shapes follow the user's preference, not this call site. Mirror of iOS
     * `NotificationClassCopy.dailyBudgetNote`.
     */
    fun dailyBudgetNote(arabicDigits: Boolean): LocalizedString {
        fun notices(language: AppLanguage) = ReportPresentation.countedNoun(
            NotificationBudget.DAILY_NON_MED_LIMIT, language, arabicDigits,
            enSingular = "notification", enPlural = "notifications",
            arOne = "إشعاراً واحداً", arTwo = "إشعارين", arFew = "إشعارات", arMany = "إشعاراً",
        )
        return LocalizedString(
            en = "BADAN sends at most ${notices(AppLanguage.EN)} of this kind a day, " +
                "so it never crowds your lock screen.",
            ar = "يرسل «بدن» ${notices(AppLanguage.AR)} من هذا النوع في اليوم كحدّ أقصى، " +
                "حتى لا يزدحم قفل شاشتك.",
        )
    }

    /**
     * Shown under the toggles once any class is on: WorkManager schedules the time-based classes,
     * and its delays are best-effort (doze can defer one). Plan §4 rule 10 — every automation
     * surface states its reliability tier rather than implying a wall-clock promise.
     */
    val schedulingHonestyNote = LocalizedString(
        en = "Timed reminders run in the background, so they arrive around the time you'd expect rather than exactly on it.",
        ar = "تُرسَل التذكيرات المجدولة في الخلفية، لذا تصل قرب الوقت المتوقّع لا في لحظته تماماً.",
    )

    /** Shown when notifications are switched off for BADAN at the system level. */
    val systemOffNote = LocalizedString(
        en = "Notifications are turned off for BADAN in system settings, so nothing will arrive until you turn them on there.",
        ar = "الإشعارات معطّلة لتطبيق «بدن» في إعدادات النظام، لذا لن يصل أي تنبيه حتى تفعّلها هناك.",
    )

    /** Shown when the user declines the POST_NOTIFICATIONS prompt — honest, never nagging. */
    val permissionDeniedNote = LocalizedString(
        en = "BADAN needs notification permission to send these. You can grant it any time in system settings.",
        ar = "يحتاج «بدن» إلى إذن الإشعارات لإرسال هذه التنبيهات. يمكنك منحه في أي وقت من إعدادات النظام.",
    )

    /** Section header for the budgeted classes. */
    val sectionHeader = LocalizedString(en = "Summaries & reminders", ar = "الملخّصات والتذكيرات")

    /**
     * The one honest line about medication reminders on Android: they are not built here yet. Stated
     * rather than omitted, because a user coming from the iOS app would otherwise be left guessing
     * why the toggle they know is missing.
     */
    val medsNotOnAndroidNote = LocalizedString(
        en = "Medication reminders are not available on Android yet.",
        ar = "تذكيرات الأدوية غير متوفّرة على أندرويد بعد.",
    )
}
