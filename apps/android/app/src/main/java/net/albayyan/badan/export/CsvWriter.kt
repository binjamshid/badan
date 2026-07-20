package net.albayyan.badan.export

import java.io.OutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.round

/**
 * The version of the export contract this build writes, shared by every format (CSV, JSON
 * bundle, manifest) so a single constant moves them together. Mirror of iOS `ExportSchema`.
 *
 * Lives here rather than in `domain/Export.kt` because the *shape* of an artifact is the
 * writers' contract, not the domain's: `ExportManifest.schemaVersion` is a stored field that a
 * persisted job carries forward from whenever it ran, while this is what the code in front of
 * you actually emits. EPIC-08 widened it 0.1.0 -> 1.0.0 under approval A1
 * (`docs/adr/ADR-0009-approvals-a1-a2-a3.md`); migration notes in
 * `packages/export-schemas/CHANGELOG.md`.
 */
object ExportSchema {
    const val VERSION: String = "1.0.0"

    /**
     * The time resolution a row's value describes (`granularity`, CSV column 25, added
     * 1.0.0/A1). Enum rather than a raw string for the same reason [RecordKind]/[ValueType] are
     * (OPT-269): a typo'd granularity is not a crash, it is a silently wrong claim about what a
     * number means.
     */
    enum class Granularity(val code: String) {
        RAW("raw"),
        SECOND("second"),
        MINUTE("minute"),
        HOUR("hour"),
        DAY("day"),
        WEEK("week"),
        MONTH("month"),
        YEAR("year"),
    }

    /**
     * How multiple underlying readings were combined into one value (`aggregation_method`, CSV
     * column 26, added 1.0.0/A1).
     *
     * [NONE] is an answer — "this is a single reading" — and is distinct from the column being
     * empty, which means the emitting path has not declared one. [MIN_AVG_MAX] is reserved for
     * the triple-valued rollups the registry defines but no writer produces yet.
     *
     * Nested here, rather than sitting at file scope, to mirror iOS: `Domain/Export.kt` owns a
     * same-named aggregation vocabulary for EPIC-09's template bucketing, and the two are
     * deliberately different — that one is a choice the user made about how to bucket an export
     * and has no `none`; this one reports what a row already is.
     */
    enum class AggregationMethod(val code: String) {
        NONE("none"),
        SUM("sum"),
        MEAN("mean"),
        MIN("min"),
        MAX("max"),
        MIN_AVG_MAX("min_avg_max"),
        DURATION("duration"),
        LATEST("latest"),
    }
}

/**
 * Record shape: sample | interval | session | event | derived | baseline (instant vs aggregate
 * vs typed-event vs computed). Backs the `record_kind` CSV column with a real enum — mirroring
 * `IngestionPath`'s enum-not-raw-string discipline — so a typo'd kind string is a compile error
 * rather than a silent export-content bug (OPT-269).
 */
enum class RecordKind(val code: String) {
    SAMPLE("sample"),
    INTERVAL("interval"),
    SESSION("session"),
    EVENT("event"),
    DERIVED("derived"),
    BASELINE("baseline"),
}

/**
 * raw | derived | aggregate — separates measured rows from computed/rolled-up rows. Backs the
 * `value_type` CSV column with a real enum, same rationale as [RecordKind] (OPT-269).
 */
enum class ValueType(val code: String) {
    RAW("raw"),
    DERIVED("derived"),
    AGGREGATE("aggregate"),
}

/**
 * One export row rendered as the 26-column, language-stable CSV contract
 * (`packages/export-schemas/csv_columns.json`). Fields are pre-formatted cell strings so the
 * writer's only job is RFC-4180 escaping — formatting (numbers, timestamps, booleans) is decided
 * by the caller that owns provenance and unit-profile context. Mirror of iOS `ExportRow`.
 */
data class ExportRow(
    val recordId: String,
    val recordKind: RecordKind,
    val metricId: String,
    val metricDisplay: String,
    val value: String,                 // in the active unit profile
    val unit: String,
    val canonicalValue: String,        // always canonical, independent of unit profile
    val canonicalUnit: String,
    val valueType: ValueType,
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
    /**
     * Columns 25 and 26 (schema 1.0.0, approval A1).
     *
     * Optional, and defaulted to null, for two reasons. First, a row whose window is not a whole
     * calendar unit has no honest granularity, and rounding one off would put a wrong claim in a
     * column whose entire purpose is to stop consumers guessing. Second, the callers that build
     * these rows are not all migrated yet — [ExportRunner] still emits both as empty (it is owned
     * by a later stage of EPIC-08), so today a shipped export carries the columns with blank
     * cells rather than fabricated ones. Empty means "not stated"; it never means "raw"/"none".
     */
    val granularity: ExportSchema.Granularity? = null,
    val aggregationMethod: ExportSchema.AggregationMethod? = null,
)

/**
 * Renders [ExportRow]s to RFC-4180 CSV text. Column names and order are the frozen contract from
 * `csv_columns.json`; a single writer guarantees every file in an export shares them. Mirror of
 * iOS `CSVWriter`.
 */
class CsvWriter {

    /** The header line (column names, escaped defensively though none need it). */
    fun header(): String = columns.joinToString(",") { escape(it) }

    /**
     * One data line, columns in contract order, each field RFC-4180 escaped. No trailing newline.
     * Free-text columns that can carry externally-supplied or user-entered strings are also
     * formula-injection-sanitized (`metric_display`, `source_app`, `source_device`,
     * `source_external_id`) — see [sanitizeText] (DATA-13). Numeric/enum/timestamp columns are
     * left untouched.
     */
    fun line(row: ExportRow): String {
        val cells: List<String> = listOf(
            row.recordId,
            row.recordKind.code,
            row.metricId,
            sanitizeText(row.metricDisplay),
            row.value,
            row.unit,
            row.canonicalValue,
            row.canonicalUnit,
            row.valueType.code,
            if (row.isDerived) "true" else "false",
            row.timestampStart,
            row.timestampEnd ?: "",
            row.timezone,
            row.recordedAt,
            row.sourceApp?.let { sanitizeText(it) } ?: "",
            row.sourceDevice?.let { sanitizeText(it) } ?: "",
            row.ingestionPath,
            row.sourceExternalId?.let { sanitizeText(it) } ?: "",
            row.importBatchId ?: "",
            row.qualityFlags ?: "",
            row.confidence ?: "",
            row.algorithmId ?: "",
            row.algorithmVersion ?: "",
            row.suppressedBy ?: "",
            row.granularity?.code ?: "",
            row.aggregationMethod?.code ?: "",
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

    /**
     * Streams header + rows directly to [outputStream] (wrapped so [digest] is updated
     * incrementally in the same pass, rather than as a second pass over an already
     * fully-materialized byte array) instead of building the whole file as one in-memory string
     * first. Takes ownership of [outputStream] and closes it; call `digest.digest()` afterward to
     * read the finished checksum (PERF-252/PERF-254 — memory pressure and double-pass checksum on
     * large exports).
     */
    fun writeTo(rows: List<ExportRow>, outputStream: OutputStream, digest: MessageDigest) {
        DigestOutputStream(outputStream, digest).bufferedWriter(Charsets.UTF_8).use { w ->
            w.write(header())
            for (row in rows) {
                w.write(NEWLINE)
                w.write(line(row))
            }
            w.write(NEWLINE)
        }
    }

    companion object {
        /**
         * The 26 columns, in contract order.
         *
         * Do not reorder — downstream joins are positional. The first 24 are the set frozen at
         * 0.1.0 and are byte-for-byte where they always were; `granularity` and
         * `aggregation_method` were APPENDED at 25/26 by A1 precisely so a consumer pinned to the
         * 24-column read keeps parsing correctly by name.
         */
        val columns: List<String> = listOf(
            "record_id", "record_kind", "metric_id", "metric_display", "value", "unit",
            "canonical_value", "canonical_unit", "value_type", "is_derived", "timestamp_start",
            "timestamp_end", "timezone", "recorded_at", "source_app", "source_device",
            "ingestion_path", "source_external_id", "import_batch_id", "quality_flags",
            "confidence", "algorithm_id", "algorithm_version", "suppressed_by",
            "granularity", "aggregation_method",
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
         * Neutralizes CSV formula injection, mirroring iOS `CSVWriter.sanitizeText` (DATA-13).
         *
         * Spreadsheet apps treat a cell starting with `=`, `+`, `-`, `@`, a tab or a CR as the
         * start of a formula/command, so a nameable free-text value (a paired device's Bluetooth
         * name, an imported source app name, an upstream external id) could otherwise execute
         * when the file is opened. Prefixing a single quote forces the cell to read back as
         * literal text.
         *
         * This existed on iOS only until EPIC-08. The two platforms' CSV output is now asserted
         * byte-identical against a shared golden (`packages/fixtures/export/`), which is what
         * surfaced the gap: the mitigation was described in the contract as if it applied to
         * "the writer", and Android's writer did not have it — so the same store exported from
         * an Android device produced a file iOS considered unsafe to open.
         */
        fun sanitizeText(field: String): String {
            val first = field.firstOrNull() ?: return field
            return if (first in charArrayOf('=', '+', '-', '@', '\t', '\r')) "'$field" else field
        }

        /**
         * A stable, locale-independent decimal string. Integer-valued doubles render without a
         * fractional part so counts (steps) stay clean while measured values keep their precision.
         *
         * Values are first rounded to 6 decimal places so floating-point noise from unit
         * conversion (`4.999999999999998` for what should be a clean `5`) doesn't leak into the
         * column as spurious precision; the rounding pass is skipped above 1e9 to keep the 1e6
         * scaling inside Double's exact-integer range. Above that, and for any non-integer, the
         * value is rendered with `%.6f` and trimmed rather than via `Double.toString()`, which
         * switches to scientific notation past certain magnitudes (`1.0E-9`) — not valid
         * CSV-numeric input for many spreadsheet importers (DATA-14).
         *
         * Every clause above is iOS `CSVWriter.decimal`'s algorithm, restated here deliberately.
         * Before EPIC-08 this function was three lines (`round`, `toLong`, else `toString()`) and
         * diverged from iOS for exactly the values that matter most — conversion residue and
         * sub-microsecond magnitudes — which no test could see while each platform only ever
         * compared against itself.
         */
        fun decimal(value: Double): String {
            val rounded = if (abs(value) < 1e9) round(value * 1e6) / 1e6 else value
            if (round(rounded) == rounded && abs(rounded) < 1e15) {
                return rounded.toLong().toString()
            }
            return nonExponentialString(rounded)
        }

        /**
         * `%.6f` never emits an exponent, at the cost of fixed-width zero padding this trims back
         * off. [Locale.US] is explicit: the default locale would otherwise decide the decimal
         * separator (a comma on an `fr-FR` device), silently corrupting the CSV contract.
         */
        private fun nonExponentialString(value: Double): String {
            var text = String.format(Locale.US, "%.6f", value)
            while (text.contains(".") && text.endsWith("0")) text = text.dropLast(1)
            if (text.endsWith(".")) text = text.dropLast(1)
            return if (text == "-0") "0" else text
        }

        /**
         * ISO-8601 with a numeric offset, formatted in the record's own timezone so the offset is
         * carried (never normalized to UTC). Unknown tz ids fall back to UTC ("+00:00").
         * [dateMillis] is epoch-millis.
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

    /**
     * Renders [dateMillis] as `yyyy-MM-ddTHH:mm:ss±HH:MM` in [tzId].
     *
     * The offset is always NUMERIC — a zero offset renders `+00:00`, never `Z`. Schema 1.0.0
     * (§22.1: "all public timestamps ISO-8601 with numeric offset") makes this the contract for
     * every format, and one renderer serving CSV, the JSON bundle and the manifest is what keeps
     * them from drifting apart. `XXX` (like iOS `ZZZZZ`) emits `Z` for a zero offset on its own,
     * so the substitution below is load-bearing rather than cosmetic: without it a UTC-recorded
     * row and an `Asia/Dubai`-recorded row come out in two different shapes, and the schema's
     * timestamp pattern rejects one of them.
     *
     * Unknown tz ids resolve to GMT (offset 0) — the intended UTC fallback.
     */
    fun string(dateMillis: Long, tzId: String): String {
        synchronized(lock) {
            val formatter = cache.getOrPut(tzId) {
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone(tzId)
                }
            }
            val rendered = formatter.format(Date(dateMillis))
            return if (rendered.endsWith("Z")) rendered.dropLast(1) + "+00:00" else rendered
        }
    }
}
