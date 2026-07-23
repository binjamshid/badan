import Foundation

/// Parses a small, EXPLICIT CSV contract into `SampleDTO`s (EPIC-43 ACC-005) — a line-splitting
/// parser over BADAN's own documented header, never a general-purpose spreadsheet reader, and
/// never guessing an ambiguous column's meaning.
///
/// **Required header columns** (case-insensitive names, any order): `metric_id, value, unit,
/// measured_at, tz`.
///   - `metric_id` — a BADAN metric id (e.g. `activity.steps`, `body.weight`, `heart.rhr`). An id
///     the registry doesn't recognize is not rejected here — this parser has no registry access,
///     matching every other parser in this feature — it reaches `IngestionPipeline.writeSamples`,
///     which skips unknown ids with a bare `continue`, exactly as it already does for a live-sync
///     or Apple-Health row naming an id BADAN doesn't carry.
///   - `value` — a decimal number, in `unit`.
///   - `unit` — one of `Units.table`'s symbols (`kg`, `bpm`, `km`, `percent`, …). An unconvertible
///     unit is likewise not rejected here: `IngestionPipeline.canonicalValue` already has an
///     honest fallback for it (stores the raw number, flags `.estimate`).
///   - `measured_at` — an ISO-8601 date-time (`2024-03-01T08:00:00+03:00` or `...Z`).
///   - `tz` — an IANA timezone id (e.g. `Asia/Riyadh`). Required and never defaulted or guessed —
///     the entire point of a named column is that nobody has to infer a timezone from context.
///
/// **Optional columns**: `external_id` (a caller-supplied idempotency key — without one, an id is
/// derived from the row's own content, so re-importing the identical file lands back on the same
/// rows instead of duplicating them) and `source` (a free-text label; rows sharing a label share
/// one `SourceDescriptor`, rows with no `source` column share a single default one).
///
/// **Scope, stated plainly rather than silently narrowed**: every row becomes an instantaneous
/// `SampleDTO`. This contract does NOT support interval/aggregate rows (a daily total, a nightly
/// duration) — that would need an `end` column and real aggregation semantics
/// (`Aggregation.sum`/`.mean`/…), which is genuine additional surface this slice does not take on.
/// A later slice can extend the header contract additively, the same way `csv_columns.json`
/// itself only ever grows by appending columns (see `CSVWriter`).
enum CSVFileParser {
    static let requiredColumns = ["metric_id", "value", "unit", "measured_at", "tz"]

    static func parse(fileURL: URL) throws -> ParsedFileImport {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw FileImportError.cannotReadFile
        }
        return try parse(text: text)
    }

    /// The pure half: takes the file's already-decoded text directly, so tests build fixtures
    /// inline without touching the filesystem.
    static func parse(text: String) throws -> ParsedFileImport {
        let lines = Self.splitLines(text)
        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw FileImportError.emptyFile
        }
        let header = Self.splitFields(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var columnIndex: [String: Int] = [:]
        for (i, name) in header.enumerated() where columnIndex[name] == nil { columnIndex[name] = i }

        let missing = requiredColumns.filter { columnIndex[$0] == nil }
        guard missing.isEmpty else {
            throw FileImportError.missingColumns("missing required column(s): \(missing.joined(separator: ", "))")
        }

        var parsed = ParsedFileImport()
        var descriptorsBySource: [String: SourceDescriptor] = [:]
        var descriptorOrder: [String] = []
        // Row numbers are reported 1-based INCLUDING the header, matching how a person would count
        // lines while looking at the file in a text editor.
        var rowNumber = 1

        for rawLine in lines.dropFirst() {
            rowNumber += 1
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty else { continue }   // tolerate blank lines
            let fields = Self.splitFields(rawLine)
            guard fields.count == header.count else {
                throw FileImportError.malformed("row \(rowNumber): expected \(header.count) columns, found \(fields.count)")
            }
            func field(_ name: String) -> String? {
                guard let idx = columnIndex[name], idx < fields.count else { return nil }
                let v = fields[idx].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }

            guard let metricId = field("metric_id") else {
                throw FileImportError.malformed("row \(rowNumber): metric_id is required")
            }
            // AUDIT FIX: `Double.init?(String)` is far more permissive than "a decimal number" —
            // it happily parses "nan"/"inf"/"infinity"/hex floats ("0x1p3")/overflow-to-infinity
            // literals ("1e400") without failing. An `.isFinite` check is required IN ADDITION to
            // the parse succeeding, or a garbage token silently becomes a fully-provenanced,
            // fully-trusted reading: `Units.convert` does pure arithmetic with no finiteness
            // guard, `IngestionPipeline.canonicalValue` returns it with zero quality flags (not
            // even `.estimate`), and SQLite's `sqlite3_bind_double` persists it verbatim —
            // corrupting every downstream average/baseline/sort touching that metric.
            guard let valueStr = field("value"), let value = Double(valueStr), value.isFinite else {
                throw FileImportError.malformed("row \(rowNumber): value must be a finite number")
            }
            guard let unit = field("unit") else {
                throw FileImportError.malformed("row \(rowNumber): unit is required")
            }
            guard let measuredAtStr = field("measured_at"), let measuredAt = Self.parseDate(measuredAtStr) else {
                throw FileImportError.malformed("row \(rowNumber): measured_at must be ISO-8601")
            }
            guard let tz = field("tz"), TimeZone(identifier: tz) != nil else {
                throw FileImportError.malformed("row \(rowNumber): tz must be a valid IANA timezone id")
            }

            let sourceLabel = field("source") ?? "CSV file import"
            let sourceId = "csv:" + Self.slugify(sourceLabel)
            if descriptorsBySource[sourceId] == nil {
                descriptorsBySource[sourceId] = SourceDescriptor(id: sourceId, displayName: sourceLabel,
                                                                 type: .fileImport, priority: 0)
                descriptorOrder.append(sourceId)
            }

            // Deterministic from the row's own content when the file doesn't supply one, so
            // re-importing the identical file re-derives the identical id and upserts in place
            // (I: no duplicates) rather than minting a fresh, colliding-free id every run.
            let externalId = field("external_id")
                ?? "csv-\(metricId)-\(sourceId)-\(measuredAt.epochMillis)-\(valueStr)"

            parsed.samples.append(SampleDTO(metricId: metricId, value: value, unit: unit, start: measuredAt,
                                            tz: tz, sourceId: sourceId, externalId: externalId))
        }

        parsed.descriptors = descriptorOrder.compactMap { descriptorsBySource[$0] }
        parsed.recordsProcessed = parsed.samples.count
        return parsed
    }

    // MARK: - Minimal RFC-4180-aware line/field splitting.
    //
    // The task's own words are "a simple line-splitting parser" — this is that, extended just far
    // enough to survive a quoted field containing a comma (the single most common way a hand-built
    // or spreadsheet-exported CSV breaks a naive `line.split(separator: ",")`). It intentionally
    // does not handle a quoted field spanning multiple physical lines (an embedded newline) — a
    // small, documented limitation rather than a full RFC-4180 engine.

    private static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "source" : collapsed
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? iso.date(from: s)
    }
}
