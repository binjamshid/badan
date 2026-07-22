import Foundation

/// Storage for `ReferenceRange` — concepts 1+2 of the four-concept reference-range law ONLY (the
/// source-printed interval and the source-printed flag; `reference_ranges`, sensitive migration v5).
/// Personal baseline (concept 3) is `DerivedTrendRepository`'s table, entirely separate; a
/// user-defined threshold (concept 4) is not persisted at all this slice. Keeping this repository
/// scoped to exactly one table, with exactly the two source-only fields the type carries, is part of
/// what makes conflating the four concepts a compile-time impossibility rather than a discipline
/// someone has to remember.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `JournalRepository`/`LabReportRepository`/`LabResultRepository` use.
final class ReferenceRangeRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    private static let columns = """
        id, result_id, source_interval_low, source_interval_high, source_interval_text, \
        source_interval_unit, source_flag
        """
    private static let placeholders = "?, ?, ?, ?, ?, ?, ?"

    /// `INSERT OR REPLACE` idempotent on the ULID PK. A `ReferenceRange` has no revision chain of its
    /// own — it belongs 1:1 to one specific `LabResult` row (including a specific revision), so a
    /// correction to the printed range naturally arrives alongside a new `LabResult` revision with
    /// its own new range row, rather than an in-place edit of this one.
    func insertRange(_ range: ReferenceRange) throws {
        try sensitive.run("""
            INSERT OR REPLACE INTO reference_ranges (\(Self.columns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.convPlaceholders));
            """,
            [.text(range.id), .text(range.resultId), .double(range.sourceIntervalLow),
             .double(range.sourceIntervalHigh), .string(range.sourceIntervalText),
             .string(range.sourceIntervalUnit), .string(range.sourceFlag)]
            + Rows.convParams(updatedAt: range.updatedAt, originDeviceId: range.originDeviceId,
                              deletedAt: range.deletedAt))
    }

    /// The live range for one result — concepts 1+2 for `ReferenceRangeEngine.render`'s call site.
    /// `nil` when the source printed neither an interval nor a flag for this result (no row exists,
    /// or the row exists with every field absent — `render` treats both the same way: nothing to
    /// show for concepts 1/2).
    func range(resultId: String) throws -> ReferenceRange? {
        try sensitive.query("""
            SELECT * FROM reference_ranges WHERE result_id = ? AND deleted_at IS NULL
            ORDER BY updated_at DESC LIMIT 1;
            """, [.text(resultId)]).first.map(Self.readRange)
    }

    func deleteRange(id: String, at date: Date) throws {
        try sensitive.run("UPDATE reference_ranges SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                          [.date(date), .date(date), .text(id)])
    }

    static func readRange(_ r: SQLiteRow) -> ReferenceRange {
        ReferenceRange(
            id: r.requireString("id"),
            resultId: r.requireString("result_id"),
            sourceIntervalLow: r.double("source_interval_low"),
            sourceIntervalHigh: r.double("source_interval_high"),
            sourceIntervalText: r.string("source_interval_text"),
            sourceIntervalUnit: r.string("source_interval_unit"),
            sourceFlag: r.string("source_flag"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
