import Foundation
import os

/// Moves already-ingested sensitive-plus measurement rows out of `badan.db` and into
/// `badan_sensitive.db` (A21/D-26 scope-gap closure).
///
/// `MeasurementRouting` fixes where NEW rows land. It does nothing for an install that already
/// ingested glucose under the old placement — those rows keep sitting unencrypted in `badan.db`,
/// outside `purgeSensitiveNamespace()`'s reach, which is the exact defect D-26 left open. Schema
/// migrations cannot do this: a `Migration` runs against one connection, and this is a cross-file
/// move between two separately-opened databases (one of them SQLCipher-encrypted). So it runs once
/// at startup instead, in the same spirit as `SensitiveDatabaseMigrator`'s in-place conversion.
///
/// **Copy-then-delete ordering, and why the delete is a HARD delete.** Rows are inserted into the
/// sensitive file and only then removed from main, so a crash mid-run leaves a duplicate (healed by
/// the next run's `INSERT OR IGNORE` + re-delete) rather than a hole. The removal is a real
/// `DELETE`, not the soft-delete INVARIANT I3 mandates everywhere else, and that is deliberate: I3
/// exists so a row the USER removed still leaves a tombstone the export delta can carry. Nothing is
/// being removed from the user's record here — the same row continues to exist, with the same id,
/// one file over. A tombstone would be a lie (the reading was not deleted), and leaving the row
/// soft-deleted in `badan.db` would preserve the value, the timestamp, and the provenance of a
/// sensitive-plus reading in the unencrypted file that the whole change exists to get it out of.
enum SensitiveMeasurementRelocator {
    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "Storage")

    /// What one run moved, for logging and for tests to assert on.
    struct Outcome: Equatable {
        var rawSamples = 0
        var intervalRecords = 0
        var isEmpty: Bool { rawSamples == 0 && intervalRecords == 0 }
    }

    /// Relocates every sensitive-plus row found in `main`'s measurement tables. Idempotent: a
    /// second run finds nothing to move and reports an empty `Outcome`. Cheap on the overwhelmingly
    /// common path — two indexed `SELECT ... WHERE metric_id IN (...)` probes that return no rows —
    /// so calling it on every launch costs a pair of index lookups, not a scan.
    @discardableResult
    static func run(main: SQLiteConnection, sensitive: SQLiteConnection,
                    registry: MetricRegistry = .shared) throws -> Outcome {
        let ids = MeasurementRouting.sensitiveMetricIds(registry: registry)
        guard !ids.isEmpty else { return Outcome() }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let params = ids.map { SQLValue.text($0) }

        var outcome = Outcome()
        outcome.rawSamples = try relocate(
            table: "raw_samples", main: main, sensitive: sensitive,
            placeholders: placeholders, params: params)
        outcome.intervalRecords = try relocate(
            table: "interval_records", main: main, sensitive: sensitive,
            placeholders: placeholders, params: params)

        if !outcome.isEmpty {
            logger.notice("Relocated \(outcome.rawSamples) raw samples and \(outcome.intervalRecords) interval records to the sensitive database (D-26)")
        }
        return outcome
    }

    /// The column list is read from the table itself rather than hardcoded. An earlier draft of this
    /// file spelled the columns out and got them wrong — it omitted `ingestion_path`, `device_id`,
    /// and `algorithm_version_id`, so every INSERT violated `ingestion_path`'s NOT NULL constraint.
    /// Nothing reported that, because the `OR IGNORE` it used treats a constraint violation as a row
    /// to skip; the rows were then deleted from main. A hand-written column list plus a conflict
    /// clause that swallows errors is a data-loss bug wearing the costume of a safe idempotent
    /// write. Both halves are gone: columns come from `PRAGMA table_info`, and the INSERT is loud.
    /// (Caught by `SensitiveMeasurementRoutingTests` only because it asserts on the destination file
    /// directly rather than trusting the relocator's own return value.)
    private static func columnNames(_ connection: SQLiteConnection, table: String) throws -> [String] {
        try connection.query("PRAGMA table_info(\(table));").compactMap { $0.string("name") }
    }

    private static func relocate(table: String,
                                 main: SQLiteConnection, sensitive: SQLiteConnection,
                                 placeholders: String, params: [SQLValue]) throws -> Int {
        let names = try columnNames(main, table: table)
        // The two tables are meant to be identical (sensitive migration 9 mirrors main migration 1).
        // If they ever diverge, refuse rather than move rows through a column mapping nobody has
        // checked — the alternative is silently dropping whichever column is missing.
        guard try Set(names) == Set(columnNames(sensitive, table: table)), !names.isEmpty else {
            logger.fault("Refusing to relocate \(table): main and sensitive schemas differ")
            return 0
        }

        let columns = names.joined(separator: ", ")
        // Deliberately NOT filtered on `deleted_at IS NULL`: a soft-deleted sensitive-plus row still
        // holds the value and provenance of a real reading, and its tombstone still has to reach a
        // delta export — both belong in the sensitive file with the rest of that metric's history.
        let rows = try main.query("SELECT \(columns) FROM \(table) WHERE metric_id IN (\(placeholders));", params)
        guard !rows.isEmpty else { return 0 }

        let valuePlaceholders = names.map { _ in "?" }.joined(separator: ", ")
        try sensitive.transaction {
            for row in rows {
                // `OR REPLACE`, not `OR IGNORE`. Both make a resumed run (one that copied rows then
                // died before deleting them from main) idempotent, but only `OR REPLACE` still fails
                // loudly on a NOT NULL or datatype violation instead of skipping the row — see
                // `columnNames` above for what that difference already cost once. Overwriting is
                // safe precisely because the only way a row exists at this id is that this same
                // relocator put an identical copy there.
                //
                // Values pass straight through as the `SQLValue`s SQLite handed back, never via a
                // typed accessor — a relocation must reproduce the row exactly, including NULLs and
                // any column whose stored type differs from what a typed getter would coerce it to.
                try sensitive.run("INSERT OR REPLACE INTO \(table) (\(columns)) VALUES (\(valuePlaceholders));",
                                  names.map { row.values[$0] ?? .null })
            }
        }
        // Only after every INSERT above has committed. A crash before this point leaves duplicates,
        // which the next run resolves; a crash after it leaves nothing in the unencrypted file.
        try main.transaction {
            try main.run("DELETE FROM \(table) WHERE metric_id IN (\(placeholders));", params)
        }
        return rows.count
    }
}
