package net.albayyan.badan.export

/**
 * EPIC-13 / §22.3: the wide CSV layout, as a **projection over the tidy rows** — never a second
 * query path. Mirror of iOS `WideCSVProjector`.
 *
 * This is the most important sentence in the file and the easiest one to erode: tidy-long (one row
 * per observation, the [AggregateRecord] list) is the one source of truth, and wide is a pivot of
 * exactly those records. The tempting alternative — a `GROUP BY metric, date` that selects straight
 * into columns — is a second way to compute the same numbers, and the day it exists is the day the
 * wide file and the tidy file can disagree while both look right. So the input here is the tidy
 * records themselves and the only operation is transposition. If a value is wrong in wide it is
 * wrong in tidy; they cannot drift.
 *
 * ## Layout
 *
 * ```
 * # BADAN wide layout · schema 1.0.0 · layout wide-v1 · granularity day
 * date,activity.steps|sum,heart.hr|max,heart.hr|mean,heart.hr|min
 * 2026-03-08,8421,142,71.5,53
 * 2026-03-09,,148,73.2,55
 * ```
 *
 * - **One comment row first**, carrying schema version and layout id (§22.3). It starts with `#`,
 *   which RFC 4180 does not define — a spreadsheet imports it as a one-cell first row and a script
 *   skips it with `comment='#'`. A deliberate departure: wide is the spreadsheet-facing convenience
 *   format, and a consumer that needs the strict contract reads tidy, which has no comment row.
 * - **`date`** is the bucket key — a local calendar label, not an instant. Wide drops the interval
 *   boundaries, timezone and sample count tidy carries per row: it trades provenance for
 *   legibility, which is why it is a separate layout and not the default.
 * - **Columns** are `metric_id|stat`, sorted, one per distinct pair present, so a min/mean/max
 *   export lands as three adjacent columns in that reading order.
 * - **Empty cell** = no record for that pair in that bucket. Not zero: a day with no steps recorded
 *   and a day with zero steps recorded are different facts, and a spreadsheet `SUM` skips the blank
 *   while counting the zero.
 */
class WideCsvProjector {

    /**
     * Projects tidy [records] into the wide layout. All records must share one granularity — a wide
     * file mixing daily and weekly columns has no coherent `date` axis — and that is the caller's
     * contract; the granularity of the first record labels the comment row. Returns the full
     * document, CRLF-terminated including a trailing newline, matching [CsvWriter]'s RFC-4180 line
     * discipline.
     */
    fun render(records: List<AggregateRecord>): String {
        val newline = CsvWriter.NEWLINE
        val granularity = (records.firstOrNull()?.granularity ?: AggregateGranularity.DAY)
            .csvGranularity.code

        val out = StringBuilder(comment(granularity))

        // Columns: every (metric, stat) pair that occurs, sorted so the file is stable and
        // min/mean/max read left-to-right within a metric (AggregateStat declaration order).
        val columns = columnsOf(records)
        out.append(newline)
        out.append((listOf("date") + columns.map { CsvWriter.escape(it.header) }).joinToString(","))

        // Index the tidy records by (row key, column) so the pivot is a lookup, not a scan per
        // cell. A (bucketKey, metric, stat) triple is unique by construction — the aggregator emits
        // one record per bucket per stat — so a later value never silently overwrites an earlier one.
        val cell = HashMap<CellKey, String>()
        val rowKeys = LinkedHashSet<String>()
        for (record in records) {
            rowKeys.add(record.bucketKey)
            cell[CellKey(record.bucketKey, Column(record.metricId, record.stat))] =
                CsvWriter.decimal(record.value)
        }

        for (rowKey in rowKeys.sorted()) {
            val cells = mutableListOf(CsvWriter.escape(rowKey))
            for (column in columns) {
                cells.add(cell[CellKey(rowKey, column)] ?: "")
            }
            out.append(newline)
            out.append(cells.joinToString(","))
        }

        out.append(newline)
        return out.toString()
    }

    private data class Column(val metricId: String, val stat: AggregateStat) : Comparable<Column> {
        /** `metric_id|stat` — `|` cannot occur in a registry metric id or a stat token, so the
         *  header parses back into its two parts unambiguously. */
        val header: String get() = "$metricId|${stat.csvMethod.code}"

        override fun compareTo(other: Column): Int {
            if (metricId != other.metricId) return metricId.compareTo(other.metricId)
            // Within a metric, order by the stat's declaration order (min, mean, max, …) rather
            // than alphabetically, so a range reads correctly.
            return stat.ordinal.compareTo(other.stat.ordinal)
        }
    }

    private data class CellKey(val row: String, val column: Column)

    private fun columnsOf(records: List<AggregateRecord>): List<Column> =
        records.map { Column(it.metricId, it.stat) }.toSortedSet().toList()

    /** The `#`-prefixed metadata row. Separators are ` · ` rather than commas so the whole thing
     *  stays one cell when a spreadsheet imports it, instead of scattering the version across
     *  columns. */
    private fun comment(granularity: String): String =
        "# BADAN wide layout · schema ${ExportSchema.VERSION} · layout $LAYOUT_ID · granularity $granularity"

    companion object {
        /** The layout identifier stamped into the comment row. Bumped only if the wide shape
         *  changes in a way a pinned consumer would notice; moves independently of the export schema
         *  version, since wide is a presentation of the same 1.0.0 data. */
        const val LAYOUT_ID = "wide-v1"
    }
}
