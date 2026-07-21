import Foundation
import CryptoKit

/// The version of the export contract this build writes, shared by every format (CSV, JSON
/// bundle, manifest) so a single constant moves them together.
///
/// Lives here rather than in `Domain/Export.swift` because the *shape* of an artifact is the
/// writers' contract, not the domain's: `ExportManifest.schemaVersion` is a stored field that a
/// persisted job carries forward from whenever it ran, while this is what the code in front of
/// you actually emits. EPIC-08 widened it 0.1.0 -> 1.0.0 under approval A1
/// (`docs/adr/ADR-0009-approvals-a1-a2-a3.md`); the migration notes are in
/// `packages/export-schemas/CHANGELOG.md`.
enum ExportSchema {
    static let version = "1.0.0"

    /// The time resolution a row's value describes (`granularity`, CSV column 25, added
    /// 1.0.0/A1).
    ///
    /// An enum rather than a raw string for the same reason Android's `RecordKind`/`ValueType`
    /// are (OPT-269): a typo'd granularity is not a crash, it is a silently wrong claim about
    /// what a number means, which is the failure mode a versioned contract exists to prevent.
    enum Granularity: String {
        case raw, second, minute, hour, day, week, month, year
    }

    /// How multiple underlying readings were combined into one value (`aggregation_method`, CSV
    /// column 26, added 1.0.0/A1).
    ///
    /// `none` is an answer — "this is a single reading" — and is distinct from the column being
    /// empty, which means the emitting path has not declared one. `minAvgMax` is reserved for
    /// the triple-valued rollups the registry defines but no writer produces yet.
    ///
    /// Nested here, rather than sitting at file scope, because `Domain/Export.swift` owns a
    /// same-named `ExportAggregationMethod` for EPIC-09's template bucketing. The two are
    /// deliberately different vocabularies — that one is a choice the user made about how to
    /// bucket an export and has no `none`; this one reports what a row already is — and giving
    /// each its own namespace keeps them from being silently interchanged at a call site.
    enum AggregationMethod: String {
        case none, sum, mean, min, max
        case minAvgMax = "min_avg_max"
        case duration, latest
    }
}

/// One export row rendered as the 26-column, language-stable CSV contract
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
    /// Columns 25 and 26 (schema 1.0.0, approval A1).
    ///
    /// Optional, and defaulted to `nil`, for two reasons. First, a row whose window is not a
    /// whole calendar unit has no honest granularity, and rounding one off would put a wrong
    /// claim in a column whose entire purpose is to stop consumers guessing. Second, the callers
    /// that build these rows are not all migrated yet — `ExportRunner` still emits both as empty
    /// (it is owned by a later stage of EPIC-08), so today a shipped export carries the columns
    /// with blank cells rather than fabricated ones. Empty means "not stated"; it never means
    /// "raw" or "none".
    ///
    /// One Swift trap worth knowing before you write a call site: `aggregationMethod: .none`
    /// resolves to `Optional.none` — nil — and NOT to `AggregationMethod.none`, because the
    /// property is optional and `Optional` wins the shorthand. The two mean opposite things here
    /// ("not stated" versus "this is a single reading"), so spell the enum case out:
    /// `aggregationMethod: ExportSchema.AggregationMethod.none`.
    var granularity: ExportSchema.Granularity? = nil
    var aggregationMethod: ExportSchema.AggregationMethod? = nil
}

/// Renders `ExportRow`s to RFC-4180 CSV text. Column names and order are the frozen contract
/// from `csv_columns.json`; a single writer guarantees every file in an export shares them.
struct CSVWriter {
    /// The 26 columns, in contract order.
    ///
    /// Do not reorder — downstream joins are positional. The first 24 are the set frozen at
    /// 0.1.0 and are byte-for-byte where they always were; `granularity` and
    /// `aggregation_method` were APPENDED at 25/26 by A1 precisely so a consumer pinned to the
    /// 24-column read keeps parsing correctly by name.
    static let columns: [String] = [
        "record_id", "record_kind", "metric_id", "metric_display", "value", "unit",
        "canonical_value", "canonical_unit", "value_type", "is_derived", "timestamp_start",
        "timestamp_end", "timezone", "recorded_at", "source_app", "source_device",
        "ingestion_path", "source_external_id", "import_batch_id", "quality_flags",
        "confidence", "algorithm_id", "algorithm_version", "suppressed_by",
        "granularity", "aggregation_method"
    ]

    /// RFC-4180 record separator (CRLF).
    static let newline = "\r\n"

    init() {}

    /// The header line (column names, escaped defensively though none need it).
    func header() -> String {
        Self.columns.map(Self.escape).joined(separator: ",")
    }

    /// One data line, columns in contract order, each field RFC-4180 escaped. No trailing newline.
    /// Free-text columns that can carry externally-supplied or user-entered strings are also
    /// formula-injection-sanitized (`metric_display`, `source_app`, `source_device`,
    /// `source_external_id`) — see `sanitizeText` (DATA-13). Numeric/enum/timestamp columns are
    /// left untouched.
    func line(_ row: ExportRow) -> String {
        let cells: [String] = [
            row.recordId,
            row.recordKind,
            row.metricId,
            Self.sanitizeText(row.metricDisplay),
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
            row.sourceApp.map(Self.sanitizeText) ?? "",
            row.sourceDevice.map(Self.sanitizeText) ?? "",
            row.ingestionPath,
            row.sourceExternalId.map(Self.sanitizeText) ?? "",
            row.importBatchId ?? "",
            row.qualityFlags ?? "",
            row.confidence ?? "",
            row.algorithmId ?? "",
            row.algorithmVersion ?? "",
            row.suppressedBy ?? "",
            row.granularity?.rawValue ?? "",
            row.aggregationMethod?.rawValue ?? ""
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

    /// Writes the same bytes `render(_:)` would produce directly to `handle`, one chunk at a
    /// time, and returns their SHA-256 hex digest computed incrementally as each chunk is
    /// written. This avoids ever holding the full CSV simultaneously as a `String` and a second
    /// `Data` copy (PERF-168), and avoids a separate full-buffer hashing pass afterward
    /// (PERF-170) — the returned digest is byte-identical to `sha256(Data(render(rows).utf8))`.
    func write(_ rows: [ExportRow], to handle: FileHandle) throws -> String {
        var hasher = SHA256()
        func emit(_ s: String) throws {
            let chunk = Data(s.utf8)
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
        }
        try emit(header())
        for row in rows {
            try emit(Self.newline)
            try emit(line(row))
        }
        try emit(Self.newline)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Field formatting helpers

    /// RFC-4180: quote a field containing comma, quote, CR or LF; double any embedded quote.
    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Neutralizes CSV formula injection: spreadsheet apps (Excel/Numbers/Sheets) treat a cell
    /// starting with `=`, `+`, `-`, `@`, a tab, or a CR as the start of a formula/command, so a
    /// nameable free-text value (a paired device's Bluetooth name, an imported source app name,
    /// an upstream external id) could otherwise execute as a formula when the file is opened.
    /// Prefixing a single quote forces the cell to be read back as literal text — applied only
    /// to the free-text columns that can carry such strings, never to numeric/enum/timestamp
    /// columns (DATA-13).
    static func sanitizeText(_ field: String) -> String {
        guard let first = field.unicodeScalars.first else { return field }
        let triggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
        return triggers.contains(first) ? "'" + field : field
    }

    /// A stable, locale-independent decimal string. Integer-valued doubles render without a
    /// fractional part so counts (steps) stay clean while measured values keep their precision.
    /// Values are first rounded to 6 decimal places so floating-point noise from unit conversion
    /// (e.g. `4.999999999999998` for what should be a clean `5`) doesn't leak into the exported
    /// column as spurious precision, while still preserving any real sub-integer precision. The
    /// rounding pass is skipped above 1e9 to keep the 1e6 scaling within Double's exact-integer
    /// range (already far outside the integer fast path's own 1e15 bound).
    static func decimal(_ value: Double) -> String {
        let rounded = abs(value) < 1e9 ? (value * 1e6).rounded() / 1e6 : value
        if rounded.rounded() == rounded && abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        return nonExponentialString(rounded)
    }

    /// Renders `value` without scientific notation regardless of magnitude — plain `String(
    /// Double)` (and `%g`-style formatting) switches to exponential form past certain
    /// magnitudes/precisions (≥1e15, or non-integer values ≥1e9), which is not valid CSV-numeric
    /// input for many spreadsheet importers (DATA-14). `%f` never emits an exponent, at the cost
    /// of fixed-width zero padding this trims back off. Uses the POSIX locale explicitly — `%f`
    /// via `String(format:)` otherwise follows the current locale's decimal separator (e.g. a
    /// comma on a French-locale device), which would silently corrupt the CSV contract.
    private static func nonExponentialString(_ value: Double) -> String {
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// ISO-8601 with a numeric offset, formatted in the record's own timezone so the offset is
    /// carried (never normalized to UTC). Unknown tz ids fall back to UTC ("+00:00").
    static func iso8601(_ date: Date, tzId: String) -> String {
        TimestampFormatting.string(date, tzId: tzId)
    }
}

/// The two reconciliation tables a CSV **delta** export carries (§22.6 / EPIC-17), alongside
/// `raw.csv` / `derived.csv` / `events.csv`.
///
/// They exist because the desync a delta creates is format-independent. A delta gathers only LIVE
/// rows, so a removal or a dedup flip since the cursor is invisible to a consumer that only ever
/// receives additions — and a CSV consumer is no less entitled to reconcile than a JSON one. The
/// JSON bundle carries the same two facts as its `deletions[]` and `corrections[]` arrays; these are
/// the CSV projection of exactly those records, one row per record, same field names, same ordering
/// (`ExportTombstone.exportSorted` / `ExportSuppressionCorrection.exportSorted` — the single shared
/// comparators, so the two formats cannot drift apart).
///
/// They ride their own small tables rather than the 26-column contract for the same reason the
/// hydration set does: a tombstone is not a measurement, and forcing "this record is gone" onto a
/// row shape built for "this record has value V in unit U" would produce a row a consumer has to
/// guess at. `record_kind` has no `tombstone` case and inventing one would break the frozen
/// vocabulary.
///
/// **Presence is the delta signal.** Unlike the JSON bundle, a CSV export's `manifest.json` carries
/// no `is_delta` flag (`ExportManifest` has no delta fields), so `ExportRunner` writes BOTH files —
/// header-only when nothing was removed or flipped — on every delta run, and neither on any other
/// run. A consumer that receives them therefore knows the artifact is a delta AND is told
/// affirmatively that nothing went away, instead of having to distinguish "no removals" from "this
/// exporter never reports removals". A non-delta CSV export is byte-identical to before.
struct ExportDeltaCSVWriter {
    static let deletionsFileName = "deletions.csv"
    static let correctionsFileName = "corrections.csv"

    init() {}

    /// The named CSV files for one delta run. Both are always present (see the type doc) so the
    /// caller writes and checksums them unconditionally on a delta.
    func files(deletions: [ExportTombstone],
               corrections: [ExportSuppressionCorrection]) -> [String: String] {
        [
            Self.deletionsFileName: deletionsCSV(deletions),
            Self.correctionsFileName: correctionsCSV(corrections)
        ]
    }

    /// Rows removed since the cursor. Columns mirror the JSON `deletions[]` object exactly
    /// (`record_id`, `entity`, `deleted_at`), and `deleted_at` is rendered in the row's OWN
    /// timezone — the same offset-carrying instant the bundle writes, never normalized to UTC.
    func deletionsCSV(_ deletions: [ExportTombstone]) -> String {
        var out = row(["record_id", "entity", "deleted_at"])
        for t in ExportTombstone.exportSorted(deletions) {
            out += CSVWriter.newline
            out += row([t.recordId, t.entity, CSVWriter.iso8601(t.deletedAt, tzId: t.tzId)])
        }
        return out + CSVWriter.newline
    }

    /// Suppression flips since the cursor. Columns mirror the JSON `corrections[]` object
    /// (`record_id`, `suppressed_by`, `changed_at`); `changed_at` is UTC, matching the bundle,
    /// because a dedup decision is an engine event with no measurement timezone of its own.
    ///
    /// A cleared suppression writes an EMPTY `suppressed_by` cell — CSV has no null, and the
    /// column is a record id, so empty can only mean "no longer suppressed". That is the same
    /// convention every other nullable id column in the export uses.
    func correctionsCSV(_ corrections: [ExportSuppressionCorrection]) -> String {
        var out = row(["record_id", "suppressed_by", "changed_at"])
        for c in ExportSuppressionCorrection.exportSorted(corrections) {
            out += CSVWriter.newline
            out += row([c.recordId, c.suppressedBy ?? "", CSVWriter.iso8601(c.changedAt, tzId: "UTC")])
        }
        return out + CSVWriter.newline
    }

    /// One RFC-4180 line, borrowed from `CSVWriter` so these cells escape identically to every
    /// other exported cell. No `sanitizeText` pass: every column here is a ULID or a timestamp,
    /// never free text, so there is nothing a spreadsheet could read as a formula.
    private func row(_ cells: [String]) -> String {
        cells.map(CSVWriter.escape).joined(separator: ",")
    }
}

/// Thread-safe, per-timezone cache of ISO-8601 `DateFormatter`s. Building a formatter per row
/// dominates a large export; keyed reuse keeps the offset-carrying format cheap.
enum TimestampFormatting {
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    /// Renders `date` as `yyyy-MM-ddTHH:mm:ss±HH:MM` in `tzId`.
    ///
    /// The offset is always NUMERIC — a zero offset renders `+00:00`, never `Z`. Schema 1.0.0
    /// (§22.1: "all public timestamps ISO-8601 with numeric offset") makes this the contract for
    /// every format, and one renderer serving CSV, the JSON bundle and the manifest is what
    /// keeps them from drifting apart. `ZZZZZ` emits `Z` for a zero offset on its own, so the
    /// substitution below is load-bearing rather than cosmetic: without it a UTC-recorded row
    /// and an `Asia/Dubai`-recorded row come out in two different shapes, and the schema's
    /// timestamp pattern rejects one of them.
    ///
    /// Note for anyone diffing a 0.1.0 artifact against a 1.0.0 one: this is a real output
    /// change for zero-offset records. It is listed in `packages/export-schemas/CHANGELOG.md`;
    /// both spellings parse as the same instant under any conformant ISO-8601 reader.
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
        let rendered = formatter.string(from: date)
        return rendered.hasSuffix("Z") ? rendered.dropLast() + "+00:00" : rendered
    }
}
