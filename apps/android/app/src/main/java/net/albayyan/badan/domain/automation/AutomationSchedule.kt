package net.albayyan.badan.domain.automation

import net.albayyan.badan.domain.ExportOutcome
import java.time.Instant
import java.time.ZoneId

// §9.7 AutomationSchedule — the user's declared automation intent, with an honest tier.
//
// EPIC-15. Kotlin mirror of iOS `AutomationSchedule.swift`, decision-for-decision. This file is the
// *domain* of scheduling honesty: the entity, its enums, and the two PURE decision functions the
// engine turns into runs. It touches no database, no WorkManager — those live in the engine and the
// worker — so every rule below is a plain JVM unit test (the split `ExportRunnerTemplateTest`
// documents: this module's test source set cannot open a database, so the shared decisions are the
// part tested here).
//
// The anti-HAE thesis (plan §4.10 / §13.7) is enforced structurally:
//   • [tier] is a stored PROMISE, never inferred, so the UI can label reliability honestly.
//   • [nextExpectedWindow] is a DISPLAY-ONLY estimate — never read back as a due-time to fire on.
//   • "paused after repeated failure" is DERIVED from [consecutiveFailures], not a second stored
//     flag — see [isPaused]. The schema (§9.7 / migration v4) deliberately carries no `paused`
//     column so the pause and the count that caused it can never disagree.

/**
 * §9.7 `tier` — the reliability promise BADAN makes, labeled honestly at every surface (§13.7). The
 * background wake only auto-runs [OPPORTUNISTIC_BACKGROUND]; the others fire from a Shortcut/tap.
 * The [code] is the STORED string and matches iOS's `rawValue` byte-for-byte so a config backup is
 * portable across platforms.
 */
enum class AutomationTier(val code: String) {
    OPPORTUNISTIC_BACKGROUND("opportunisticBackground"),
    SHORTCUT_DRIVEN("shortcutDriven"),
    MANUAL_ONLY("manualOnly");

    companion object {
        /**
         * Falls back to [MANUAL_ONLY] — the tier that makes NO promise and is never auto-run — so a
         * corrupt row can only ever become MORE conservative, never silently start firing in the
         * background.
         */
        fun fromCode(code: String?): AutomationTier = entries.firstOrNull { it.code == code } ?: MANUAL_ONLY
    }
}

/**
 * §9.7 `desiredCadence`. `ON_NEW_DATA` is data-driven; the best-effort tiers are elapsed-time-driven.
 * None is a wall-clock promise — the tier carries the truth about *whether* a wake happens.
 */
enum class AutomationCadence(val code: String) {
    ON_NEW_DATA("onNewData"),
    HOURLY_BEST_EFFORT("hourlyBestEffort"),
    DAILY_BEST_EFFORT("dailyBestEffort"),
    WEEKLY_BEST_EFFORT("weeklyBestEffort");

    /** Minimum elapsed time before a time-driven cadence is eligible again; 0 for [ON_NEW_DATA]. */
    val minimumIntervalMillis: Long
        get() = when (this) {
            ON_NEW_DATA -> 0L
            HOURLY_BEST_EFFORT -> 3_600_000L
            DAILY_BEST_EFFORT -> 86_400_000L
            WEEKLY_BEST_EFFORT -> 604_800_000L
        }

    /**
     * DISPLAY-ONLY estimate of the next eligible instant after [lastSuccess]; `null` for
     * [ON_NEW_DATA] or when there is no prior success. Never consulted when deciding to fire (§9.7).
     */
    fun estimatedNextWindow(lastSuccess: Long?): Long? =
        if (this == ON_NEW_DATA || lastSuccess == null) null else lastSuccess + minimumIntervalMillis

    companion object {
        fun fromCode(code: String?): AutomationCadence = entries.firstOrNull { it.code == code } ?: ON_NEW_DATA
    }
}

/**
 * §9.7 `quietHours` — a local wall-clock window during which the schedule must not fire. Stored as a
 * compact canonical `"HH:mm-HH:mm"` string (mirror of iOS) so the two platforms' stored values are
 * byte-identical. A window whose start is after its end wraps midnight (e.g. `22:00-07:00`).
 */
data class QuietHours(val startMinute: Int, val endMinute: Int) {

    /**
     * Whether [instantMillis], read in [zoneId] (device-local), falls inside the window. A
     * zero-length window (`start == end`) is inert — the honest reading of a window collapsed to a
     * point, and it keeps a mis-saved `00:00-00:00` from silently suppressing the schedule forever.
     */
    fun contains(instantMillis: Long, zoneId: ZoneId): Boolean {
        if (startMinute == endMinute) return false
        val time = Instant.ofEpochMilli(instantMillis).atZone(zoneId).toLocalTime()
        val m = time.hour * 60 + time.minute
        return if (startMinute < endMinute) m in startMinute until endMinute
        else m >= startMinute || m < endMinute
    }

    /** `"HH:mm-HH:mm"` — the persisted form and the parity token. */
    val storageString: String
        get() = "%02d:%02d-%02d:%02d".format(startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60)

    companion object {
        fun of(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int): QuietHours =
            QuietHours(wrap(startHour * 60 + startMinute), wrap(endHour * 60 + endMinute))

        private fun wrap(minute: Int): Int = ((minute % 1440) + 1440) % 1440

        /**
         * Parse `"HH:mm-HH:mm"`, returning `null` for any malformed or out-of-range value rather
         * than guessing — a corrupt string must not silently become a real suppressing window.
         */
        fun fromStorage(value: String?): QuietHours? {
            if (value == null) return null
            val halves = value.split("-", limit = 2)
            if (halves.size != 2) return null
            val start = parseMinute(halves[0]) ?: return null
            val end = parseMinute(halves[1]) ?: return null
            return QuietHours(start, end)
        }

        private fun parseMinute(s: String): Int? {
            val parts = s.split(":")
            if (parts.size != 2) return null
            val h = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            if (h !in 0..23 || m !in 0..59) return null
            return h * 60 + m
        }
    }
}

/**
 * §9.7 `AutomationSchedule`. Configuration plus the small mutable bookkeeping the failure budget
 * needs. Unlike a derived value (I2), the bookkeeping is legitimately mutated in place — it is
 * scheduler state, not a health datum; the append-only audit of what an automation *did* lives in
 * `export_runs`. Timestamps are epoch-millis `Long` (the Android storage convention).
 */
data class AutomationSchedule(
    val id: String,
    val templateId: String,
    val tier: AutomationTier,
    val desiredCadence: AutomationCadence,
    val quietHours: QuietHours? = null,
    val enabled: Boolean = true,
    val consecutiveFailures: Int = 0,
    val lastSuccessAt: Long? = null,
    val nextExpectedWindow: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /**
     * Whether repeated failures have paused this schedule. DERIVED, not stored (see the file
     * header): the pause and the count that caused it can never disagree, and "resume" is simply
     * resetting the count to 0.
     */
    val isPaused: Boolean get() = consecutiveFailures >= FAILURE_BUDGET

    companion object {
        /**
         * Three consecutive failures pause the schedule (§12 EPIC-15 / §13.7). A constant, not a
         * per-install knob: the number is part of the promise the design makes to the user.
         */
        const val FAILURE_BUDGET = 3
    }
}

// -- Pure decision 1: is this schedule due? --

/** Why a schedule was not run this wake. A closed vocabulary a diagnostics surface and a test read. */
enum class AutomationSkipReason { DISABLED, PAUSED, NOT_BACKGROUND_TIER, QUIET_HOURS, CADENCE_NOT_ELAPSED, NO_NEW_DATA }

/** The verdict for one schedule at one instant. */
sealed interface AutomationDueVerdict {
    object Due : AutomationDueVerdict
    data class Skip(val reason: AutomationSkipReason) : AutomationDueVerdict
}

/**
 * The pure "is it due?" gate. All inputs are values; no I/O. [hasNewData] is only consulted for the
 * [AutomationCadence.ON_NEW_DATA] cadence — the engine passes `false` for the time-driven cadences,
 * where it is unused, rather than paying a database read it will not look at.
 *
 * The gates mirror the plan's phrasing ("cadence satisfied? outside quiet hours? data new since the
 * cursor?"): candidacy (enabled/tier/paused) → quiet hours (a hard gate for every cadence) →
 * cadence (`onNewData` on data, best-effort on elapsed time).
 */
object AutomationDueEvaluator {
    /**
     * Slack on the elapsed-time gate so a periodic wake landing a few minutes short of the interval
     * (WorkManager's hourly flex can fire anywhere in the hour) still counts as due, rather than
     * skipping and drifting the effective cadence out to two wake intervals. Deliberately small so
     * it cannot collapse a daily into an hourly; the tier label already discloses approximate timing.
     */
    const val CADENCE_SLACK_MILLIS = 5 * 60 * 1000L

    fun verdict(schedule: AutomationSchedule, now: Long, hasNewData: Boolean, zoneId: ZoneId): AutomationDueVerdict {
        if (!schedule.enabled) return AutomationDueVerdict.Skip(AutomationSkipReason.DISABLED)
        if (schedule.tier != AutomationTier.OPPORTUNISTIC_BACKGROUND) {
            return AutomationDueVerdict.Skip(AutomationSkipReason.NOT_BACKGROUND_TIER)
        }
        if (schedule.isPaused) return AutomationDueVerdict.Skip(AutomationSkipReason.PAUSED)
        val quiet = schedule.quietHours
        if (quiet != null && quiet.contains(now, zoneId)) {
            return AutomationDueVerdict.Skip(AutomationSkipReason.QUIET_HOURS)
        }
        return when (schedule.desiredCadence) {
            AutomationCadence.ON_NEW_DATA ->
                if (hasNewData) AutomationDueVerdict.Due else AutomationDueVerdict.Skip(AutomationSkipReason.NO_NEW_DATA)
            AutomationCadence.HOURLY_BEST_EFFORT,
            AutomationCadence.DAILY_BEST_EFFORT,
            AutomationCadence.WEEKLY_BEST_EFFORT -> {
                // No prior success ⇒ infinitely overdue ⇒ due.
                val last = schedule.lastSuccessAt ?: return AutomationDueVerdict.Due
                val elapsed = now - last
                if (elapsed >= schedule.desiredCadence.minimumIntervalMillis - CADENCE_SLACK_MILLIS) {
                    AutomationDueVerdict.Due
                } else {
                    AutomationDueVerdict.Skip(AutomationSkipReason.CADENCE_NOT_ELAPSED)
                }
            }
        }
    }
}

// -- Pure decision 2: the failure budget --

/**
 * What one run's outcome does to the schedule's bookkeeping. Success and `skippedNoData` are both
 * clean terminal states (including the honest "nothing to export"), so both reset the counter and
 * stamp `lastSuccessAt`. `isFailure` outcomes spend a strike. Everything else — locked, throttled,
 * cancelled — is neutral: the run never really happened.
 */
enum class AutomationOutcomeKind { SUCCESS, FAILURE, NEUTRAL }

/**
 * The computed bookkeeping change. [didJustPause] is true only on the transition INTO the paused
 * state (the count crossing the budget), so the notification fires exactly once — a paused schedule
 * is skipped on subsequent wakes and cannot re-notify without a resume.
 */
data class AutomationOutcomeUpdate(
    val kind: AutomationOutcomeKind,
    val consecutiveFailures: Int,
    val lastSuccessAt: Long?,
    val didJustPause: Boolean,
)

object AutomationBudget {
    fun applyOutcome(outcome: ExportOutcome, schedule: AutomationSchedule, now: Long): AutomationOutcomeUpdate {
        if (outcome.isFailure) {
            val newCount = schedule.consecutiveFailures + 1
            val wasPaused = schedule.consecutiveFailures >= AutomationSchedule.FAILURE_BUDGET
            val nowPaused = newCount >= AutomationSchedule.FAILURE_BUDGET
            return AutomationOutcomeUpdate(
                kind = AutomationOutcomeKind.FAILURE,
                consecutiveFailures = newCount,
                lastSuccessAt = schedule.lastSuccessAt,
                didJustPause = nowPaused && !wasPaused,
            )
        }
        return when (outcome) {
            ExportOutcome.SUCCESS, ExportOutcome.SKIPPED_NO_DATA -> AutomationOutcomeUpdate(
                kind = AutomationOutcomeKind.SUCCESS,
                consecutiveFailures = 0,
                lastSuccessAt = now,
                didJustPause = false,
            )
            // SKIPPED_LOCKED / THROTTLED / CANCELLED — neutral, nothing changes.
            else -> AutomationOutcomeUpdate(
                kind = AutomationOutcomeKind.NEUTRAL,
                consecutiveFailures = schedule.consecutiveFailures,
                lastSuccessAt = schedule.lastSuccessAt,
                didJustPause = false,
            )
        }
    }
}
