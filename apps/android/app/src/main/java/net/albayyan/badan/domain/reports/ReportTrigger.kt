package net.albayyan.badan.domain.reports

import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone

/**
 * Decides *which* weekly reports are due — a pure function so the background substrate can ask "is
 * anything to generate?" without owning report logic, and so the rule is testable without a clock or
 * a database. Mirror of iOS `ReportTrigger.swift`.
 *
 * **Why "last completed week", not "is it Sunday?"** (plan §13.7 scheduling honesty): background
 * work is best-effort — the OS decides if and when a wake happens, and no wall-clock time is
 * promised. Gating strictly on the local weekday would silently drop a week whenever no wake landed
 * on its Sunday. Instead this targets the most recently *completed* ISO week, so the first wake at
 * or after the week's end generates it (around the Sunday/Monday boundary in practice). Dedup is
 * structural: an already-generated period is filtered out by `existingPeriodKeys`, so repeated
 * opportunistic wakes in the same week produce at most one report.
 *
 * **Why a backfill, and why it is bounded.** Targeting only the last completed week self-heals a
 * missed Sunday but NOT a missed week: three weeks with no wake used to leave two weeks with no
 * report and nothing that would ever produce them, because by the time a wake landed those weeks
 * were no longer "last". [dueWeeklyPeriodKeys] therefore also returns the completed weeks inside a
 * bounded horizon that sit in a GAP between reports BADAN has already produced. The horizon is
 * deliberately short ([DEFAULT_BACKFILL_WEEKS]) because this runs on a background wake that may be
 * cut off at any moment — see that constant for what a longer outage does and does not heal.
 */
object ReportTrigger {

    /**
     * The most recently completed ISO week as of [asOf]: the ISO week whose Sunday is the most
     * recent one strictly before today's local start, so every one of its seven days is in the past
     * (no partial current-day data). Generated automatically; the current in-progress week is
     * reachable only by manual regeneration from the screen.
     */
    fun lastCompletedWeek(asOf: Long, tz: String): ReportPeriod.Resolved {
        val startToday = DayAttribution.startOfDay(asOf, tz)
        val cal = GregorianCalendar(TimeZone.getTimeZone(tz))
        var sunday = DayAttribution.addingDays(-1, startToday, tz)
        var guard = 0
        while (guard < 7) {
            cal.timeInMillis = sunday
            if (cal.get(Calendar.DAY_OF_WEEK) == Calendar.SUNDAY) break
            sunday = DayAttribution.addingDays(-1, sunday, tz)
            guard++
        }
        return ReportPeriod.week(sunday, tz)
    }

    /**
     * How many completed weeks back a single wake will look. Four ≈ a month: enough that a phone
     * left in a drawer over a holiday comes back to a complete run of reports, small enough that the
     * worst case is four report builds on one opportunistic wake.
     *
     * Said plainly rather than implied: a gap **longer** than this horizon does not fully heal. The
     * oldest weeks of a months-long outage will never be generated, because nothing offers to
     * generate an arbitrary past week (the Reports screen offers last week, this week and last month
     * only). That is a bounded, known hole, not a promise this function is quietly failing.
     */
    const val DEFAULT_BACKFILL_WEEKS: Int = 4

    /**
     * The period keys of the weekly reports due now, **newest first** — the most recent completed
     * week is generated before the backfill, since that is the one the Reports screen shows and the
     * one a user is waiting for if the wake is cut short.
     *
     * [existingPeriodKeys] is the set of period keys that currently have a (non-deleted) report row
     * for the current algorithm version. It may contain `month:` keys as well as `week:` ones (it
     * comes straight from the reports table), which is why the gap floor below filters.
     *
     * Two different rules, on purpose:
     *  - the most recently completed week is due whenever it has no report — the weekly trigger
     *    itself, unchanged;
     *  - an **older** week inside the horizon is due only when it falls after the oldest weekly
     *    report that already exists. Backfill fills gaps in a run of reports; it does not invent
     *    pre-history. Without that floor a fresh install would manufacture four empty reports for
     *    weeks before BADAN was ever installed, and "no data for that week" would look like a
     *    finding rather than the absence of one.
     */
    fun dueWeeklyPeriodKeys(
        asOf: Long,
        tz: String,
        existingPeriodKeys: Set<String>,
        maxBackfillWeeks: Int = DEFAULT_BACKFILL_WEEKS,
    ): List<String> {
        val target = lastCompletedWeek(asOf, tz)

        val horizon = mutableListOf<String>()
        var week = target
        repeat(maxOf(1, maxBackfillWeeks)) {
            horizon.add(week.periodKey)
            week = ReportPeriod.prior(week, tz)
        }

        // `week:%04d-W%02d` is zero-padded and year-first, so lexicographic order IS chronological
        // order for these keys — no date parsing needed to find the run's floor.
        val oldestExistingWeek = existingPeriodKeys.filter { it.startsWith("week:") }.minOrNull()

        return horizon.filter { key ->
            when {
                existingPeriodKeys.contains(key) -> false
                key == target.periodKey -> true
                oldestExistingWeek == null -> false
                else -> key > oldestExistingWeek
            }
        }
    }
}
