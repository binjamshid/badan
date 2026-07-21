package net.albayyan.badan.domain.reports

import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone

/**
 * Resolves a report period (an ISO week or a calendar month) into the concrete set of local day keys
 * it spans, plus its start/end instants — in one place so [ReportBuilder], the trigger, and the
 * screen all agree on where a week begins and which days a month contains. Mirror of iOS
 * `ReportPeriod.swift`.
 *
 * Weeks are ISO-8601 (Monday-first, the week containing Jan 4 is week 1), matching the
 * `week:2026-W29` form the schema and `reports.period_key` use. Months are calendar months
 * (`month:2026-07`). Boundaries are computed in a single [Resolved.timezone] (the device's zone at
 * generation), which each model records so a later re-resolution can reproduce it.
 */
object ReportPeriod {

    /**
     * A period key is a MACHINE key — stored in `reports.period_key`, matched against the shared
     * contract's `^(week:\d{4}-W\d{2}|month:\d{4}-\d{2})$`, sorted lexicographically, and compared
     * across devices. It must therefore be formatted with Western digits regardless of the device's
     * locale.
     *
     * This is not hypothetical: `String.format` without an explicit locale uses
     * `Locale.getDefault(FORMAT)`, and on a device set to Arabic (`ar`, `ar-SA`, `ar-EG` — the JVM's
     * `DecimalFormatSymbols` zero digit for those is `٠`) `%04d` renders `٢٠٢٦`, which would store
     * `week:٢٠٢٦-W٢٩`, fail the contract's pattern, break the DESC ordering against any
     * Western-digit key, and let the same week be generated twice if the user ever changed locale.
     * The Arabic-digit *presentation* of a period lives in `ReportPresentation`, where it belongs.
     */
    private val KEY_LOCALE: Locale = Locale.ROOT

    data class Resolved(
        val periodKey: String,
        val kind: ReportPeriodKind,
        /** "YYYY-MM-DD" day keys, ascending. 7 for a week; 28–31 for a month. */
        val dayKeys: List<String>,
        /** Start of the first local day (inclusive). */
        val start: Long,
        /** Start of the local day AFTER the last day (exclusive) — the period is [start, end). */
        val end: Long,
        val timezone: String,
    ) {
        /** The `day:<key>` period keys the derived store uses, ascending. */
        val dayPeriodKeys: List<String> get() = dayKeys.map { "day:$it" }
    }

    // ISO-8601 semantics: Monday-first, ≥4 days in the first week. `DayAttribution`'s plain
    // GregorianCalendar is locale-default-first, so week numbering needs its own calendar; day-key
    // formatting and startOfDay still delegate to `DayAttribution` for a single source of truth.
    private fun isoCalendar(tz: String): GregorianCalendar {
        val c = GregorianCalendar(TimeZone.getTimeZone(tz))
        c.firstDayOfWeek = Calendar.MONDAY
        c.minimalDaysInFirstWeek = 4
        return c
    }

    // MARK: - Week

    /** The ISO week containing [containing] (epoch millis). */
    fun week(containing: Long, tz: String): Resolved {
        val c = isoCalendar(tz)
        c.timeInMillis = containing
        val weekOfYear = c.get(Calendar.WEEK_OF_YEAR)
        val weekYear = c.weekYear
        val periodKey = String.format(KEY_LOCALE, "week:%04d-W%02d", weekYear, weekOfYear)

        val monday = isoCalendar(tz)
        monday.clear()
        monday.setWeekDate(weekYear, weekOfYear, Calendar.MONDAY)
        val start = DayAttribution.startOfDay(monday.timeInMillis, tz)
        val dayKeys = (0 until 7).map { DayAttribution.localDayKey(DayAttribution.addingDays(it, start, tz), tz) }
        val end = DayAttribution.startOfDay(DayAttribution.addingDays(7, start, tz), tz)
        return Resolved(periodKey, ReportPeriodKind.WEEK, dayKeys, start, end, tz)
    }

    // MARK: - Month

    /** The calendar month containing [containing] (epoch millis). */
    fun month(containing: Long, tz: String): Resolved {
        val zone = TimeZone.getTimeZone(tz)
        val c = GregorianCalendar(zone)
        c.timeInMillis = containing
        val year = c.get(Calendar.YEAR)
        val month = c.get(Calendar.MONTH) + 1
        val periodKey = String.format(KEY_LOCALE, "month:%04d-%02d", year, month)

        val first = GregorianCalendar(zone)
        first.clear()
        first.set(year, month - 1, 1)
        val start = DayAttribution.startOfDay(first.timeInMillis, tz)
        val dayCount = first.getActualMaximum(Calendar.DAY_OF_MONTH)
        val dayKeys = (0 until dayCount).map { DayAttribution.localDayKey(DayAttribution.addingDays(it, start, tz), tz) }
        val end = DayAttribution.startOfDay(DayAttribution.addingDays(dayCount, start, tz), tz)
        return Resolved(periodKey, ReportPeriodKind.MONTH, dayKeys, start, end, tz)
    }

    // MARK: - Parse / navigate

    /**
     * Reconstruct a period from its key (`week:YYYY-Www` | `month:YYYY-MM`). Returns null for a
     * malformed key rather than guessing.
     */
    fun resolve(periodKey: String, tz: String): Resolved? {
        if (periodKey.startsWith("week:")) {
            val parts = periodKey.removePrefix("week:").split("-")
            if (parts.size != 2 || !parts[1].startsWith("W")) return null
            val year = parts[0].toIntOrNull() ?: return null
            val weekNumber = parts[1].drop(1).toIntOrNull() ?: return null
            val cal = isoCalendar(tz)
            cal.clear()
            // Lenient would silently roll week 54 into the next year; strict makes it throw so a
            // malformed key is rejected rather than resolved to a plausible-looking wrong week.
            cal.isLenient = false
            val anchor = runCatching {
                cal.setWeekDate(year, weekNumber, Calendar.MONDAY)
                cal.timeInMillis
            }.getOrNull() ?: return null
            val resolved = week(anchor, tz)
            return if (resolved.periodKey == periodKey) resolved else null
        }
        if (periodKey.startsWith("month:")) {
            val parts = periodKey.removePrefix("month:").split("-")
            if (parts.size != 2) return null
            val year = parts[0].toIntOrNull() ?: return null
            val monthNumber = parts[1].toIntOrNull() ?: return null
            if (monthNumber !in 1..12) return null
            val cal = GregorianCalendar(TimeZone.getTimeZone(tz))
            cal.clear()
            cal.set(year, monthNumber - 1, 1)
            val resolved = month(cal.timeInMillis, tz)
            return if (resolved.periodKey == periodKey) resolved else null
        }
        return null
    }

    /**
     * The period immediately before the given one (prior week / prior month), used to compute
     * period-over-period deltas.
     */
    fun prior(resolved: Resolved, tz: String): Resolved {
        val dayBefore = DayAttribution.addingDays(-1, resolved.start, tz)
        return when (resolved.kind) {
            ReportPeriodKind.WEEK -> week(dayBefore, tz)
            ReportPeriodKind.MONTH -> month(dayBefore, tz)
        }
    }
}
