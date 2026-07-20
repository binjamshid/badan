package net.albayyan.badan.export

import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.ExportAggregationMethod
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricKind
import java.util.TimeZone

/**
 * EPIC-13: rolls BADAN's canonical rows up into hourly/daily/weekly/monthly buckets for export
 * (plan §12 EPIC-13). Mirror of iOS `MetricAggregator`.
 *
 * ## Why this does not call Health Connect's aggregation APIs
 *
 * Health Connect will happily hand back a daily step total, and it is tempting: one query, no
 * bucketing code, no timezone arithmetic. It is also the wrong number. The platform aggregates
 * *its* view of the store — every contributing record from every app, with its own de-duplication.
 * BADAN's export exists to publish **BADAN's reconciled store**: rows that went through this app's
 * ingestion, source-priority reconciliation (I4) and dedup journal (I3), with losers marked
 * `suppressed_by` and excluded unless the user asked for them. Those two totals differ whenever a
 * phone and a watch both recorded a walk, which is most days for most users.
 *
 * Exporting the platform's number under BADAN's manifest — which states a `dedup_policy` and
 * per-metric row counts — would make the manifest a false description of the file. If someone later
 * "optimizes" this into a platform aggregation query because it is faster, the export stops being
 * an export of BADAN and becomes an export of Health Connect that BADAN happened to write.
 *
 * ## Why the GROUP BY is here and not in SQL
 *
 * §12 EPIC-13 specifies "SQL `GROUP BY` aggregation over canonical tables", and the *selection*
 * half of that is what happens: the caller pulls the in-scope rows out of `raw_samples` /
 * `interval_records` through the repositories. The **bucketing** cannot be a
 * `GROUP BY strftime('%Y-%m-%d', start_at, ...)` because day boundaries have to be computed in
 * each row's own `tz_id`, and SQLite carries no timezone database — `strftime` knows UTC and the
 * device's current local time and nothing else. A SQL `GROUP BY` would silently bucket a trip to
 * Dubai by the phone's timezone today, or by UTC, and would get DST-transition days wrong by an
 * hour at both ends of the year. So this is a pure function over already-selected canonical rows,
 * testable against a fixture without a database.
 *
 * ## Day boundaries
 *
 * Every row is assigned to the calendar unit that contains it **in the row's own `tz_id`**, not in
 * the device's current zone and not in UTC. A run at 23:30 in Dubai belongs to that Dubai day even
 * if the phone is now in New York. The consequences are deliberate and fixture-tested: a
 * spring-forward day is 23 hours long and a fall-back day 25, both one bucket; when the user
 * changes timezone mid-range, rows on both sides of the change that share a local date land in the
 * *same* bucket (one calendar day, as lived), and [AggregateRecord.contributingTimezones] lists
 * every zone that fed it so the anomaly is visible in the data.
 */

/** Aggregation window. [csvGranularity] is the CSV column-25 stamp every produced record carries. */
enum class AggregateGranularity(val csvGranularity: ExportSchema.Granularity) {
    HOUR(ExportSchema.Granularity.HOUR),
    DAY(ExportSchema.Granularity.DAY),
    WEEK(ExportSchema.Granularity.WEEK),
    MONTH(ExportSchema.Granularity.MONTH),
}

/**
 * The concrete statistic a produced record carries — distinct from [ExportAggregationMethod], which
 * is what the user *asked for*. They differ in exactly one place and that place is the point of this
 * type: `minAvgMax` is a request for three numbers and a CSV row has one value column, so it expands
 * into three records stamped `min`, `mean`, `max` rather than three mutually indistinguishable rows.
 *
 * Declaration order is the emission order for a metric's records and the wide layout's columns: min,
 * mean, max reads as a range where the alphabetical order (max, mean, min) does not.
 */
enum class AggregateStat(val csvMethod: ExportSchema.AggregationMethod) {
    MIN(ExportSchema.AggregationMethod.MIN),
    MEAN(ExportSchema.AggregationMethod.MEAN),
    MAX(ExportSchema.AggregationMethod.MAX),
    SUM(ExportSchema.AggregationMethod.SUM),
    DURATION(ExportSchema.AggregationMethod.DURATION),
    LATEST(ExportSchema.AggregationMethod.LATEST),
}

/**
 * One canonical row on its way into a bucket — the subset of `RawSample` / `IntervalRecord` the
 * aggregation reads. A projection rather than the domain types themselves so a fixture can express
 * both tables in one list and so a caller cannot feed in a row it has not decided is in-scope
 * (suppressed, soft-deleted and sensitive-namespace rows are the caller's filter, applied upstream).
 *
 * All times are epoch millis. Aggregation happens in canonical [unit] only — mixing a display-profile
 * value into a sum is a unit error no column would reveal.
 */
data class AggregateInputRow(
    val metricId: String,
    val value: Double,
    val unit: String,
    val startAt: Long,
    /** Present on intervals/sessions, null on instant samples. Only `duration` reads it. */
    val endAt: Long? = null,
    /** IANA zone at measurement. The bucket boundary is computed in *this*, per row. */
    val tzId: String,
    /** `interval_records.aggregation`; null for `raw_samples`. See [MetricAggregator.defaultStat]. */
    val storedAggregation: Aggregation? = null,
)

/**
 * One aggregated number, fully self-describing. The stamps are the deliverable: HAE leaves a
 * consumer to infer from a timestamp span whether a number is a daily total, an hourly total or a
 * single reading; every record here states its granularity and method.
 */
data class AggregateRecord(
    val metricId: String,
    /** Local calendar key: `2026-03-08` (day), `2026-03-08T14` (hour), `2026-W11` (week),
     *  `2026-03` (month). Locale-stable; the wide layout's `date` cell. */
    val bucketKey: String,
    /** First instant of the bucket and of the *next* one (closed-open), epoch millis, computed in
     *  [tzId] — so a DST day really is 23 or 25 hours wide here. */
    val bucketStartMillis: Long,
    val bucketEndMillis: Long,
    /** The zone the boundaries were computed in: the zone of the earliest contributing row. */
    val tzId: String,
    /** Every distinct zone that fed this bucket, sorted. More than one means a mid-day zone change. */
    val contributingTimezones: List<String>,
    val granularity: AggregateGranularity,
    val stat: AggregateStat,
    val value: Double,
    val unit: String,
    /** How many canonical rows fed this number — a mean over two readings and one over two hundred
     *  read identically without it. */
    val sampleCount: Int,
) {
    val spansMultipleTimezones: Boolean get() = contributingTimezones.size > 1
}

/** Buckets canonical rows and computes the statistics. Stateless. */
class MetricAggregator {

    /**
     * Aggregates [rows] into [granularity] buckets. [method] is the user's template choice; pass
     * null to fall back per metric to [defaultStat]. Output is sorted by (metric id, bucket key,
     * stat order) so two runs over the same data produce the same file; nothing downstream re-sorts.
     */
    fun aggregate(
        rows: List<AggregateInputRow>,
        granularity: AggregateGranularity,
        method: ExportAggregationMethod?,
        definitions: Map<String, MetricDefinition>,
    ): List<AggregateRecord> {
        // Bucket first, statistics second. Grouping by (metric, local key) rather than
        // (metric, key, tz) is the deliberate choice: the unit is the calendar day the person
        // lived, not the calendar day of a particular zone.
        val buckets = LinkedHashMap<BucketKey, MutableList<AggregateInputRow>>()
        for (row in rows) {
            val key = BucketKey(row.metricId, bucketKey(row.startAt, row.tzId, granularity))
            buckets.getOrPut(key) { mutableListOf() }.add(row)
        }

        val records = mutableListOf<AggregateRecord>()
        for (key in buckets.keys.sortedWith(compareBy({ it.metricId }, { it.bucket }))) {
            val members = buckets.getValue(key)
            if (members.isEmpty()) continue
            val sorted = members.sortedBy { it.startAt }
            // Boundaries come from the earliest contributing row's zone: on a mixed-zone day some
            // zone has to define the interval, and "the one the day started in" is the only choice
            // that does not depend on row ordering out of the database.
            val primaryTz = sorted[0].tzId
            val interval = bucketInterval(key.bucket, primaryTz, granularity)
            val zones = sorted.map { it.tzId }.toSortedSet().toList()

            val stats = statsFor(method, key.metricId, sorted, definitions)
            for (stat in AggregateStat.entries) {
                if (stat !in stats) continue
                val value = compute(stat, sorted) ?: continue
                records.add(
                    AggregateRecord(
                        metricId = key.metricId, bucketKey = key.bucket,
                        bucketStartMillis = interval.first, bucketEndMillis = interval.second,
                        tzId = primaryTz, contributingTimezones = zones,
                        granularity = granularity, stat = stat,
                        // `duration` is seconds regardless of what the metric measures; any other
                        // unit label on it would be a lie about the number.
                        value = value, unit = if (stat == AggregateStat.DURATION) "s" else sorted[0].unit,
                        sampleCount = sorted.size,
                    ),
                )
            }
        }
        return records
    }

    private data class BucketKey(val metricId: String, val bucket: String)

    // MARK: - Which statistic

    private fun statsFor(
        method: ExportAggregationMethod?,
        metricId: String,
        rows: List<AggregateInputRow>,
        definitions: Map<String, MetricDefinition>,
    ): Set<AggregateStat> = when (method) {
        null -> setOf(defaultStat(metricId, rows, definitions))
        ExportAggregationMethod.MIN_AVG_MAX -> setOf(AggregateStat.MIN, AggregateStat.MEAN, AggregateStat.MAX)
        ExportAggregationMethod.SUM -> setOf(AggregateStat.SUM)
        ExportAggregationMethod.MEAN -> setOf(AggregateStat.MEAN)
        ExportAggregationMethod.MIN -> setOf(AggregateStat.MIN)
        ExportAggregationMethod.MAX -> setOf(AggregateStat.MAX)
        ExportAggregationMethod.DURATION -> setOf(AggregateStat.DURATION)
        ExportAggregationMethod.LATEST -> setOf(AggregateStat.LATEST)
    }

    /**
     * The default statistic for a metric when the caller did not choose one.
     *
     * **The registry does not carry an aggregation field.** `packages/metric-ontology/registry.json`
     * at v0.2.0 has `kind`, `canonicalUnit`, units and labels — no `aggregation`/`aggregationHint`
     * key — so this hint is *derived*, not read, and the derivation is stated here rather than
     * implied by whichever call site needed it first. When the registry gains the field this becomes
     * a lookup with this rule as its seed data; nothing else changes.
     *
     * In priority order:
     *  1. **The rows' own `interval_records.aggregation`**, when every contributing interval row
     *     agrees — real recorded data, not a guess. Rows that disagree fall through, because
     *     combining a `sum` row and a `max` row under either label is wrong under both.
     *  2. **Cumulative unit + `intervalAggregate` kind → `sum`** (steps, distance, energy, sleep
     *     seconds, grams of protein — quantities that accumulate over a window).
     *  3. **Everything else → `mean`.** Levels and rates do not add up; `respiratory.rate`
     *     (breaths/min) and `body.wrist_temp_deviation` (degC) are `intervalAggregate` rows whose
     *     sum has no meaning, which is why the rule keys on the unit, not on `kind` alone.
     *
     * Only ever a default: a named method overrides it, and the produced record states which
     * statistic it actually is, so a wrong default is visible in the file rather than baked in.
     */
    fun defaultStat(
        metricId: String,
        rows: List<AggregateInputRow>,
        definitions: Map<String, MetricDefinition>,
    ): AggregateStat {
        val stored = rows.mapNotNull { it.storedAggregation }.toSet()
        if (stored.size == 1) {
            map(stored.first())?.let { return it }
        }
        val definition = definitions[metricId] ?: return AggregateStat.MEAN
        return if (definition.kind == MetricKind.INTERVAL_AGGREGATE &&
            definition.canonicalUnit in CUMULATIVE_UNITS
        ) {
            AggregateStat.SUM
        } else {
            AggregateStat.MEAN
        }
    }

    // MARK: - The statistics

    /** `nil` when the statistic is undefined for this data — currently only `duration` over rows
     *  with no `endAt`, where emitting 0 would claim the activity took no time. */
    private fun compute(stat: AggregateStat, rows: List<AggregateInputRow>): Double? = when (stat) {
        AggregateStat.SUM -> rows.sumOf { it.value }
        AggregateStat.MEAN -> rows.sumOf { it.value } / rows.size
        AggregateStat.MIN -> rows.minOf { it.value }
        AggregateStat.MAX -> rows.maxOf { it.value }
        AggregateStat.LATEST -> rows.last().value
        AggregateStat.DURATION -> {
            val spans = rows.mapNotNull { row -> row.endAt?.let { (it - row.startAt) / 1000.0 } }
            if (spans.isEmpty()) null else spans.sum()
        }
    }

    companion object {
        /**
         * Canonical units whose values accumulate. Listed explicitly rather than inferred from a
         * dimension analysis: the set is small, closed by the registry, and a wrong entry turns a
         * daily average heart rate into a meaningless total. Anything rate- or level-shaped is
         * deliberately absent: `bpm`, `mmHg`, `percent`, `m/s`, `breaths/min`, `degC`, `kg`.
         */
        private val CUMULATIVE_UNITS = setOf("count", "m", "km", "kJ", "kcal", "s", "min", "h", "g", "mg", "L", "mL")

        private fun map(aggregation: Aggregation): AggregateStat? = when (aggregation) {
            Aggregation.SUM -> AggregateStat.SUM
            Aggregation.MEAN -> AggregateStat.MEAN
            Aggregation.MIN -> AggregateStat.MIN
            Aggregation.MAX -> AggregateStat.MAX
            Aggregation.DURATION -> AggregateStat.DURATION
            Aggregation.LATEST -> AggregateStat.LATEST
        }

        // MARK: - Bucketing

        /**
         * The local calendar key for an instant in a zone.
         *
         * Week keys are ISO-8601 (`2026-W11`, Monday-start, week 1 contains the first Thursday) and
         * computed arithmetically from the local date rather than through `Calendar`'s week fields —
         * not distrust of the platform, but that iOS has to produce the same string and "both
         * platforms' calendar libraries agree on ISO week numbering at every year boundary" is an
         * assumption with no cheap way to hold it true. The Thursday rule is four lines and provably
         * identical.
         */
        fun bucketKey(instantMillis: Long, tzId: String, granularity: AggregateGranularity): String {
            val zone = TimeZone.getTimeZone(tzId)
            val offsetSeconds = zone.getOffset(instantMillis) / 1000L
            val local = CivilTime.fromEpochSeconds(Math.floorDiv(instantMillis, 1000L) + offsetSeconds)
            return when (granularity) {
                AggregateGranularity.HOUR ->
                    "${pad(local.year, 4)}-${pad(local.month, 2)}-${pad(local.day, 2)}T${pad(local.hour, 2)}"
                AggregateGranularity.DAY ->
                    "${pad(local.year, 4)}-${pad(local.month, 2)}-${pad(local.day, 2)}"
                AggregateGranularity.MONTH ->
                    "${pad(local.year, 4)}-${pad(local.month, 2)}"
                AggregateGranularity.WEEK -> {
                    // The ISO week-year is the year of that week's Thursday and the week number is
                    // that Thursday's ordinal position in it; both fall out of one date shift.
                    val days = CivilTime.daysFromCivil(local.year, local.month, local.day)
                    val thursday = CivilTime.civilFromDays(days - isoWeekdayIndex(days) + 3)
                    val weekOfYear = (thursday.dayOfYear - 1) / 7 + 1
                    "${pad(thursday.year, 4)}-W${pad(weekOfYear, 2)}"
                }
            }
        }

        /**
         * The bucket's half-open instant interval (epoch millis), in [tzId]. Derived from the *key*
         * rather than the instant that produced it, so every row in a bucket yields the same
         * boundaries — deriving from the instant would make a fall-back day's start depend on which
         * side of the transition the first row sat on.
         */
        fun bucketInterval(key: String, tzId: String, granularity: AggregateGranularity): Pair<Long, Long> {
            val zone = TimeZone.getTimeZone(tzId)
            val start = parseKey(key, granularity)
            val end = advance(start, granularity)
            return Pair(
                instant(CivilTime.epochSeconds(start), zone),
                instant(CivilTime.epochSeconds(end), zone),
            )
        }

        private fun parseKey(key: String, granularity: AggregateGranularity): CivilTime = when (granularity) {
            AggregateGranularity.HOUR -> {
                val parts = key.split("T")
                val date = parts[0].split("-")
                CivilTime(date[0].toLong(), date[1].toLong(), date[2].toLong(), parts[1].toLong(), 0, 0)
            }
            AggregateGranularity.DAY -> {
                val date = key.split("-")
                CivilTime(date[0].toLong(), date[1].toLong(), date[2].toLong(), 0, 0, 0)
            }
            AggregateGranularity.MONTH -> {
                val date = key.split("-")
                CivilTime(date[0].toLong(), date[1].toLong(), 1, 0, 0, 0)
            }
            AggregateGranularity.WEEK -> {
                // Invert the Thursday rule: week N's Monday is Jan-4's week's Monday plus (N-1)
                // weeks, and Jan 4 is in week 1 by definition.
                val parts = key.split("W")
                val year = parts[0].dropLast(1).toLong() // trailing '-'
                val week = parts[1].toLong()
                val jan4 = CivilTime.daysFromCivil(year, 1, 4)
                val firstMonday = jan4 - isoWeekdayIndex(jan4)
                CivilTime.civilFromDays(firstMonday + (week - 1) * 7)
            }
        }

        private fun advance(time: CivilTime, granularity: AggregateGranularity): CivilTime = when (granularity) {
            AggregateGranularity.HOUR -> CivilTime.fromEpochSeconds(CivilTime.epochSeconds(time) + 3_600)
            AggregateGranularity.DAY ->
                CivilTime.civilFromDays(CivilTime.daysFromCivil(time.year, time.month, time.day) + 1)
            AggregateGranularity.WEEK ->
                CivilTime.civilFromDays(CivilTime.daysFromCivil(time.year, time.month, time.day) + 7)
            AggregateGranularity.MONTH -> {
                val rolled = time.month == 12L
                CivilTime(if (rolled) time.year + 1 else time.year, if (rolled) 1 else time.month + 1, 1, 0, 0, 0)
            }
        }

        /** 0 for Monday … 6 for Sunday. 1970-01-01 was a Thursday, so day 0 is index 3. */
        private fun isoWeekdayIndex(days: Long): Long = ((days + 3) % 7 + 7) % 7

        /**
         * The instant whose local representation in [zone] is [localSeconds]. The inverse of
         * "instant + offset = local" needs the offset, and the offset depends on the instant, so it
         * is solved by iteration. Two candidates cover every case: ordinary time (first candidate
         * matches), a fall-back overlap (first candidate is the earlier of the two, as
         * `ZonedDateTime.of` also picks), and a spring-forward gap (neither matches; the first
         * candidate is the local time shifted forward by the gap, as `java.time` returns). Only
         * [TimeZone.getOffset] is taken from the platform, and it reads the same IANA database on
         * both sides.
         */
        private fun instant(localSeconds: Long, zone: TimeZone): Long {
            fun offset(atSeconds: Long): Long = zone.getOffset(atSeconds * 1000L) / 1000L
            fun matches(candidate: Long): Boolean = candidate + offset(candidate) == localSeconds
            val first = localSeconds - offset(localSeconds)
            if (matches(first)) return first * 1000L
            val second = localSeconds - offset(first)
            return (if (matches(second)) second else first) * 1000L
        }

        private fun pad(value: Long, width: Int): String {
            var text = value.toString()
            while (text.length < width) text = "0$text"
            return text
        }
    }
}

/**
 * Proleptic-Gregorian civil time and the two conversions between it and a second count. Mirror of
 * iOS `CivilTime`.
 *
 * Hand-rolled rather than taken from `java.time` because this arithmetic has to be **bit-identical
 * on both platforms**, and it is the half of timezone handling that needs no timezone database:
 * shifting an instant by an offset and reading off the calendar fields is pure integer arithmetic.
 * What genuinely requires the IANA database — what the offset *is* at a given instant — still goes
 * through the platform. `MetricAggregator` and `GpxWriter` both use this, hence its package scope.
 *
 * The date conversions are Howard Hinnant's `days_from_civil` / `civil_from_days`, correct across
 * the proleptic Gregorian range rather than the "divide by 365.25" approximation that drifts a day
 * around March in leap years.
 */
data class CivilTime(
    val year: Long,
    val month: Long,
    val day: Long,
    val hour: Long,
    val minute: Long,
    val second: Long,
) {
    /** 1-based ordinal day within [year]. */
    val dayOfYear: Long
        get() = daysFromCivil(year, month, day) - daysFromCivil(year, 1, 1) + 1

    companion object {
        fun fromEpochSeconds(epochSeconds: Long): CivilTime {
            var secondsOfDay = epochSeconds % 86_400
            if (secondsOfDay < 0) secondsOfDay += 86_400
            val date = civilFromDays((epochSeconds - secondsOfDay) / 86_400)
            return date.copy(
                hour = secondsOfDay / 3_600,
                minute = (secondsOfDay % 3_600) / 60,
                second = secondsOfDay % 60,
            )
        }

        fun epochSeconds(time: CivilTime): Long =
            daysFromCivil(time.year, time.month, time.day) * 86_400 +
                time.hour * 3_600 + time.minute * 60 + time.second

        /** Days since 1970-01-01 for a proleptic-Gregorian date. */
        fun daysFromCivil(year: Long, month: Long, day: Long): Long {
            val y = if (month <= 2) year - 1 else year
            val era = (if (y >= 0) y else y - 399) / 400
            val yearOfEra = y - era * 400
            val dayOfYear = (153 * (if (month > 2) month - 3 else month + 9) + 2) / 5 + day - 1
            val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return era * 146_097 + dayOfEra - 719_468
        }

        /** The inverse of [daysFromCivil]. Time fields come back zeroed. */
        fun civilFromDays(days: Long): CivilTime {
            val z = days + 719_468
            val era = (if (z >= 0) z else z - 146_096) / 146_097
            val dayOfEra = z - era * 146_097
            val yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            val year = yearOfEra + era * 400
            val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            val mp = (5 * dayOfYear + 2) / 153
            val day = dayOfYear - (153 * mp + 2) / 5 + 1
            val month = if (mp < 10) mp + 3 else mp - 9
            return CivilTime(if (month <= 2) year + 1 else year, month, day, 0, 0, 0)
        }
    }
}
