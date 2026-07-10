package net.albayyan.badan.domain.ingestion

import java.util.Calendar
import java.util.GregorianCalendar
import java.util.TimeZone

/**
 * Timezone-aware day and "local night" attribution. Days are computed in the timezone at
 * measurement (never the device's current tz), so a night recorded in Riyadh stays a Riyadh
 * night even if you fly to London — and DST 23/25-hour days resolve correctly via Calendar.
 */
object DayAttribution {
    private fun calendar(tz: String): Calendar {
        val zone = TimeZone.getTimeZone(tz)
        return GregorianCalendar(zone)
    }

    /** "YYYY-MM-DD" for the calendar day containing [millis] in [tz]. */
    fun localDayKey(millis: Long, tz: String): String {
        val c = calendar(tz)
        c.timeInMillis = millis
        return String.format(
            "%04d-%02d-%02d",
            c.get(Calendar.YEAR),
            c.get(Calendar.MONTH) + 1,
            c.get(Calendar.DAY_OF_MONTH),
        )
    }

    /** A sleep session is attributed to the morning it ends (the "last night" label). */
    fun localNight(sessionEndMillis: Long, tz: String): String =
        localDayKey(sessionEndMillis, tz)

    /** Period key used by derived values / baselines for a daily metric. */
    fun dayPeriodKey(millis: Long, tz: String): String =
        "day:" + localDayKey(millis, tz)

    fun startOfDay(millis: Long, tz: String): Long {
        val c = calendar(tz)
        c.timeInMillis = millis
        c.set(Calendar.HOUR_OF_DAY, 0)
        c.set(Calendar.MINUTE, 0)
        c.set(Calendar.SECOND, 0)
        c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }

    fun addingDays(days: Int, toMillis: Long, tz: String): Long {
        val c = calendar(tz)
        c.timeInMillis = toMillis
        c.add(Calendar.DAY_OF_MONTH, days)
        return c.timeInMillis
    }

    /** Parse a "YYYY-MM-DD" day key back to that day's start instant in [tz]. */
    fun dateFromDayKey(key: String, tz: String): Long? {
        val parts = key.split("-").mapNotNull { it.toIntOrNull() }
        if (parts.size != 3) return null
        val c = calendar(tz)
        c.clear()
        c.set(Calendar.YEAR, parts[0])
        c.set(Calendar.MONTH, parts[1] - 1)
        c.set(Calendar.DAY_OF_MONTH, parts[2])
        return c.timeInMillis
    }
}
