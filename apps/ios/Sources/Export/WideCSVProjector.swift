import Foundation

/// EPIC-13 / §22.3: the wide CSV layout, as a **projection over the tidy rows** — never a second
/// query path.
///
/// This is the single most important sentence in the file and the easiest one to erode: tidy-long
/// (one row per observation, the `AggregateRecord` list) is the one source of truth, and wide is a
/// pivot of exactly those records. The tempting alternative — a `GROUP BY metric, date` that
/// selects straight into columns — is a second way to compute the same numbers, and the day it
/// exists is the day the wide file and the tidy file can disagree while both look right. So the
/// input here is the tidy records themselves, and the only operation is transposition. If a value
/// is wrong in wide, it is wrong in tidy; they cannot drift.
///
/// ## Layout
///
/// ```
/// # BADAN wide layout · schema 1.1.0 · layout wide-v1 · granularity day
/// date,activity.steps|sum,heart.hr|max,heart.hr|mean,heart.hr|min
/// 2026-03-08,8421,142,71.5,53
/// 2026-03-09,,148,73.2,55
/// ```
///
/// - **One comment row first**, carrying the schema version and the layout id (§22.3). It starts
///   with `#`, which RFC 4180 does not define — a spreadsheet imports it as a one-cell first row
///   and a script skips it with `comment='#'`. That is an accepted, deliberate departure: the wide
///   layout is the spreadsheet-facing convenience format, and a consumer that needs the strict
///   contract reads tidy, where there is no comment row.
/// - **`date`** is the bucket key — a local calendar label (`2026-03-08`, `2026-03-08T14`,
///   `2026-W11`, `2026-03`), not an instant. The wide layout drops the interval boundaries,
///   timezone and sample count that tidy carries per row: it trades provenance for legibility,
///   which is the whole reason it is a separate layout and not the default.
/// - **Columns** are `metric_id|stat`, sorted, one per distinct pair present. A `min`/`mean`/`max`
///   export therefore lands as three adjacent columns for one metric, in that reading order.
/// - **Empty cell** = no record for that pair in that bucket. Not zero: a day with no steps
///   recorded and a day with zero steps recorded are different facts, and a spreadsheet `SUM`
///   skips the blank while counting the zero.
struct WideCSVProjector {
    /// The layout identifier stamped into the comment row. Bumped only if the wide shape changes
    /// in a way a pinned consumer would notice — a new column-ordering rule, a different key
    /// format. The export *schema* version and this move independently: wide is a presentation of
    /// the same 1.0.0 data.
    static let layoutId = "wide-v1"

    init() {}

    /// Projects tidy `records` into the wide layout. All records must share one granularity — a
    /// wide file mixing daily and weekly columns has no coherent `date` axis — and that is the
    /// caller's contract; the granularity of the first record labels the comment row.
    ///
    /// Returns the full document, CRLF-terminated including a trailing newline, matching
    /// `CSVWriter`'s RFC-4180 line discipline so the two CSV outputs of one export are consistent.
    func render(_ records: [AggregateRecord]) -> String {
        let newline = CSVWriter.newline
        let granularity = records.first?.granularity.rawValue ?? AggregateGranularity.day.rawValue

        var out = comment(granularity: granularity)

        // Columns: every (metric, stat) pair that actually occurs, sorted so the file is stable
        // and min/mean/max read left-to-right within a metric (AggregateStat's case order).
        let columns = Self.columns(of: records)
        out += newline
        out += (["date"] + columns.map { CSVWriter.escape($0.header) }).joined(separator: ",")

        // Index the tidy records by (row key, column) so the pivot is a lookup, not a scan per
        // cell. A (bucketKey, metric, stat) triple is unique by construction — the aggregator
        // emits one record per bucket per stat — so a later value never silently overwrites an
        // earlier one here.
        var cell: [CellKey: String] = [:]
        var rowKeys: [String] = []
        var seenRow = Set<String>()
        for record in records {
            if seenRow.insert(record.bucketKey).inserted { rowKeys.append(record.bucketKey) }
            cell[CellKey(row: record.bucketKey, column: Column(metricId: record.metricId, stat: record.stat))]
                = CSVWriter.decimal(record.value)
        }

        for rowKey in rowKeys.sorted() {
            var cells = [CSVWriter.escape(rowKey)]
            for column in columns {
                cells.append(cell[CellKey(row: rowKey, column: column)] ?? "")
            }
            out += newline
            out += cells.joined(separator: ",")
        }

        out += newline
        return out
    }

    // MARK: - Internals

    private struct Column: Hashable, Comparable {
        let metricId: String
        let stat: AggregateStat

        /// `metric_id|stat` — `|` because it cannot occur in a registry metric id (dotted
        /// lower-snake) or a stat token, so the header parses back into its two parts unambiguously.
        var header: String { "\(metricId)|\(stat.rawValue)" }

        static func < (lhs: Column, rhs: Column) -> Bool {
            if lhs.metricId != rhs.metricId { return lhs.metricId < rhs.metricId }
            // Within a metric, order by the stat's declaration order (min, mean, max, …) rather
            // than alphabetically, so a range reads correctly.
            return statOrder(lhs.stat) < statOrder(rhs.stat)
        }

        private static func statOrder(_ stat: AggregateStat) -> Int {
            AggregateStat.allCases.firstIndex(of: stat) ?? 0
        }
    }

    private struct CellKey: Hashable {
        let row: String
        let column: Column
    }

    private static func columns(of records: [AggregateRecord]) -> [Column] {
        var seen = Set<Column>()
        for record in records { seen.insert(Column(metricId: record.metricId, stat: record.stat)) }
        return seen.sorted()
    }

    /// The `#`-prefixed metadata row. The separators are ` · ` rather than commas so the whole
    /// thing stays one cell when a spreadsheet does import it, instead of scattering the version
    /// across columns.
    private func comment(granularity: String) -> String {
        "# BADAN wide layout · schema \(ExportSchema.version) · layout \(Self.layoutId) · granularity \(granularity)"
    }
}
