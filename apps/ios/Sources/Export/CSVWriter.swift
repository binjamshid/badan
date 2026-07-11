import Foundation

/// One export row rendered as the 24-column, language-stable CSV contract
/// (`packages/export-schemas/csv_columns.json`). Fields are pre-formatted cell strings so the
/// writer's only job is RFC-4180 escaping — formatting (numbers, timestamps, booleans) is
/// decided by the caller that owns provenance and unit-profile context.
struct ExportRow {
    var recordId: String
    var recordKind: String            // sample | interval | session | event | derived | baseline
    var metricId: String
    var metricDisplay: String
    var value: String                 // in the active unit profile
    var unit: String
    var canonicalValue: String        // always canonical, independent of unit profile
    var canonicalUnit: String
    var valueType: String             // raw | derived | aggregate
    var isDerived: Bool
    var timestampStart: String        // ISO-8601 w/ offset
    var timestampEnd: String? = nil   // ISO-8601 w/ offset, null for instants
    var timezone: String              // IANA tz id
    var recordedAt: String            // ISO-8601 w/ offset
    var sourceApp: String? = nil
    var sourceDevice: String? = nil
    var ingestionPath: String
    var sourceExternalId: String? = nil
    var importBatchId: String? = nil
    var qualityFlags: String? = nil   // semicolon-delimited
    var confidence: String? = nil     // decimal 0–1
    var algorithmId: String? = nil
    var algorithmVersion: String? = nil
    var suppressedBy: String? = nil
}

/// Renders `ExportRow`s to RFC-4180 CSV text. Column names and order are the frozen contract
/// from `csv_columns.json`; a single writer guarantees every file in an export shares them.
struct CSVWriter {
    /// The 24 columns, in contract order. Do not reorder — downstream joins are positional.
    static let columns: [String] = [
        "record_id", "record_kind", "metric_id", "metric_display", "value", "unit",
        "canonical_value", "canonical_unit", "value_type", "is_derived", "timestamp_start",
        "timestamp_end", "timezone", "recorded_at", "source_app", "source_device",
        "ingestion_path", "source_external_id", "import_batch_id", "quality_flags",
        "confidence", "algorithm_id", "algorithm_version", "suppressed_by"
    ]

    /// RFC-4180 record separator (CRLF).
    static let newline = "\r\n"

    init() {}

    /// The header line (column names, escaped defensively though none need it).
    func header() -> String {
        Self.columns.map(Self.escape).joined(separator: ",")
    }

    /// One data line, columns in contract order, each field RFC-4180 escaped. No trailing newline.
    func line(_ row: ExportRow) -> String {
        let cells: [String] = [
            row.recordId,
            row.recordKind,
            row.metricId,
            row.metricDisplay,
            row.value,
            row.unit,
            row.canonicalValue,
            row.canonicalUnit,
            row.valueType,
            row.isDerived ? "true" : "false",
            row.timestampStart,
            row.timestampEnd ?? "",
            row.timezone,
            row.recordedAt,
            row.sourceApp ?? "",
            row.sourceDevice ?? "",
            row.ingestionPath,
            row.sourceExternalId ?? "",
            row.importBatchId ?? "",
            row.qualityFlags ?? "",
            row.confidence ?? "",
            row.algorithmId ?? "",
            row.algorithmVersion ?? "",
            row.suppressedBy ?? ""
        ]
        return cells.map(Self.escape).joined(separator: ",")
    }

    /// Header + all rows + trailing newline. Always emits the header, even for zero rows, so an
    /// empty file is still a valid, self-describing table.
    func render(_ rows: [ExportRow]) -> String {
        var out = header()
        for row in rows {
            out += Self.newline
            out += line(row)
        }
        out += Self.newline
        return out
    }

    // MARK: - Field formatting helpers

    /// RFC-4180: quote a field containing comma, quote, CR or LF; double any embedded quote.
    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// A stable, locale-independent decimal string. Integer-valued doubles render without a
    /// fractional part so counts (steps) stay clean while measured values keep their precision.
    static func decimal(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// ISO-8601 with a numeric offset, formatted in the record's own timezone so the offset is
    /// carried (never normalized to UTC). Unknown tz ids fall back to UTC ("+00:00").
    static func iso8601(_ date: Date, tzId: String) -> String {
        TimestampFormatting.string(date, tzId: tzId)
    }
}

/// Thread-safe, per-timezone cache of ISO-8601 `DateFormatter`s. Building a formatter per row
/// dominates a large export; keyed reuse keeps the offset-carrying format cheap.
enum TimestampFormatting {
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, tzId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = cache[tzId] {
            formatter = cached
        } else {
            let made = DateFormatter()
            made.locale = Locale(identifier: "en_US_POSIX")
            made.timeZone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
            made.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            cache[tzId] = made
            formatter = made
        }
        return formatter.string(from: date)
    }
}
