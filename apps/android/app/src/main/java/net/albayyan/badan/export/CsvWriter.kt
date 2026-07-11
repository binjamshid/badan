package net.albayyan.badan.export

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.round

/**
 * One export row rendered as the 24-column, language-stable CSV contract
 * (`packages/export-schemas/csv_columns.json`). Fields are pre-formatted cell strings so the
 * writer's only job is RFC-4180 escaping — formatting (numbers, timestamps, booleans) is decided
 * by the caller that owns provenance and unit-profile context. Mirror of iOS `ExportRow`.
 */
data class ExportRow(
    val recordId: String,
    val recordKind: String,            // sample | interval | session | event | derived | baseline
    val metricId: String,
    val metricDisplay: String,
    val value: String,                 // in the active unit profile
    val unit: String,
    val canonicalValue: String,        // always canonical, independent of unit profile
    val canonicalUnit: String,
    val valueType: String,             // raw | derived | aggregate
    val isDerived: Boolean,
    val timestampStart: String,        // ISO-8601 w/ offset
    val timestampEnd: String? = null,  // ISO-8601 w/ offset, null for instants
    val timezone: String,              // IANA tz id
    val recordedAt: String,            // ISO-8601 w/ offset
    val sourceApp: String? = null,
    val sourceDevice: String? = null,
    val ingestionPath: String,
    val sourceExternalId: String? = null,
    val importBatchId: String? = null,
    val qualityFlags: String? = null,  // semicolon-delimited
    val confidence: String? = null,    // decimal 0–1
    val algorithmId: String? = null,
    val algorithmVersion: String? = null,
    val suppressedBy: String? = null,
)

/**
 * Renders [ExportRow]s to RFC-4180 CSV text. Column names and order are the frozen contract from
 * `csv_columns.json`; a single writer guarantees every file in an export shares them. Mirror of
 * iOS `CSVWriter`.
 */
class CsvWriter {

    /** The header line (column names, escaped defensively though none need it). */
    fun header(): String = columns.joinToString(",") { escape(it) }

    /** One data line, columns in contract order, each field RFC-4180 escaped. No trailing newline. */
    fun line(row: ExportRow): String {
        val cells: List<String> = listOf(
            row.recordId,
            row.recordKind,
            row.metricId,
            row.metricDisplay,
            row.value,
            row.unit,
            row.canonicalValue,
            row.canonicalUnit,
            row.valueType,
            if (row.isDerived) "true" else "false",
            row.timestampStart,
            row.timestampEnd ?: "",
            row.timezone,
            row.recordedAt,
            row.sourceApp ?: "",
            row.sourceDevice ?: "",
            row.ingestionPath,
            row.sourceExternalId ?: "",
            row.importBatchId ?: "",
            row.qualityFlags ?: "",
            row.confidence ?: "",
            row.algorithmId ?: "",
            row.algorithmVersion ?: "",
            row.suppressedBy ?: "",
        )
        return cells.joinToString(",") { escape(it) }
    }

    /**
     * Header + all rows + trailing newline. Always emits the header, even for zero rows, so an
     * empty file is still a valid, self-describing table.
     */
    fun render(rows: List<ExportRow>): String {
        val out = StringBuilder(header())
        for (row in rows) {
            out.append(NEWLINE)
            out.append(line(row))
        }
        out.append(NEWLINE)
        return out.toString()
    }

    companion object {
        /** The 24 columns, in contract order. Do not reorder — downstream joins are positional. */
        val columns: List<String> = listOf(
            "record_id", "record_kind", "metric_id", "metric_display", "value", "unit",
            "canonical_value", "canonical_unit", "value_type", "is_derived", "timestamp_start",
            "timestamp_end", "timezone", "recorded_at", "source_app", "source_device",
            "ingestion_path", "source_external_id", "import_batch_id", "quality_flags",
            "confidence", "algorithm_id", "algorithm_version", "suppressed_by",
        )

        /** RFC-4180 record separator (CRLF). */
        const val NEWLINE: String = "\r\n"

        /** RFC-4180: quote a field containing comma, quote, CR or LF; double any embedded quote. */
        fun escape(field: String): String {
            if (field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")) {
                return "\"" + field.replace("\"", "\"\"") + "\""
            }
            return field
        }

        /**
         * A stable, locale-independent decimal string. Integer-valued doubles render without a
         * fractional part so counts (steps) stay clean while measured values keep their precision.
         */
        fun decimal(value: Double): String {
            if (round(value) == value && abs(value) < 1e15) {
                return value.toLong().toString()
            }
            return value.toString()
        }

        /**
         * ISO-8601 with a numeric offset, formatted in the record's own timezone so the offset is
         * carried (never normalized to UTC). Unknown tz ids fall back to UTC ("Z"). [dateMillis]
         * is epoch-millis.
         */
        fun iso8601(dateMillis: Long, tzId: String): String = TimestampFormatting.string(dateMillis, tzId)
    }
}

/**
 * Thread-safe, per-timezone cache of ISO-8601 `SimpleDateFormat`s. Building a formatter per row
 * dominates a large export; keyed reuse keeps the offset-carrying format cheap. `SimpleDateFormat`
 * is not thread-safe, so the lock is held across the whole format call (mirror of iOS
 * `TimestampFormatting`).
 */
object TimestampFormatting {
    private val lock = Any()
    private val cache: HashMap<String, SimpleDateFormat> = HashMap()

    fun string(dateMillis: Long, tzId: String): String {
        synchronized(lock) {
            val formatter = cache.getOrPut(tzId) {
                // `XXX` mirrors iOS `ZZZZZ`: extended offset with a colon, "Z" for a zero offset.
                // Unknown ids resolve to GMT (offset 0) — the intended UTC fallback.
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone(tzId)
                }
            }
            return formatter.format(Date(dateMillis))
        }
    }
}
