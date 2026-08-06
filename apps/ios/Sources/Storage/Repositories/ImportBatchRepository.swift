import Foundation

/// The `import_batches` table (reserved by migration v1, wired for real here for the Apple Health
/// archive importer — plan §19). One row per file import: it is the lineage record that makes an
/// import (a) resumable after an interruption and (b) undoable in one tap.
///
/// Every measurement row an import writes carries this row's `id` in its provenance `batch_id`
/// column (`Provenance.importBatchId`, `idx_raw_batch`), stamped by `IngestionPipeline` when the
/// importer routes its DTOs through `ingest(from:range:origin: .fileImport(batchId:))`. That is
/// what lets `undo(id:)` below find and tombstone exactly the rows one import added — nothing is
/// touched that the import did not create, and any live-sync row an imported row had dedup-
/// suppressed is un-suppressed so undoing an import never hides the user's own device data.
///
/// The importer's resume model mirrors `SeedController`'s (re-run, don't diff): ingestion is
/// idempotent by upstream identity, so resuming a `running` batch re-parses from the start and
/// every upsert is a no-op for rows already written — `state == completed` is the only signal
/// that the whole archive landed. `chunkCursor` is an honest progress record (records processed),
/// not a correctness dependency.
struct ImportBatch: Equatable {
    let id: String
    let sourceKind: String
    let fileName: String?
    var state: String
    /// Records processed at the last checkpoint (a decimal string). Progress + resume telemetry,
    /// not a correctness gate — see the type doc.
    var chunkCursor: String?
    /// Per-family import counts as JSON (`{"samples": N, "sessions": M, ...}`), for the result UI.
    var counts: String?
    let createdAt: Date

    /// Freshly staged, records not yet written. Matches `BackupBundle.previewedState`.
    static let statePreviewed = "previewed"
    /// Actively writing rows (or interrupted mid-write — resumable).
    static let stateRunning = "running"
    /// Every record landed and derivations were backfilled.
    static let stateCompleted = "completed"
    /// The import threw and left partial rows; still fully undoable by `id`.
    static let stateFailed = "failed"
    /// `undo(id:)` has run: the batch's rows are tombstoned (`deleted_at` set), not gone.
    ///
    /// The batch ROW survives an undo, and that is load-bearing rather than tidy bookkeeping. Undo
    /// soft-deletes so a delta export can carry the removal (see `undo`), and a re-import of the
    /// same archive must land back on those exact rows — the upserts are keyed by upstream identity
    /// and `MeasurementRepository`'s `ON CONFLICT` clauses never rewrite an existing row's
    /// `batch_id`. If the batch row vanished, `existingBatch` would mint a fresh id, the revived
    /// rows would keep pointing at the dead one, and the new batch's "undo" would silently do
    /// nothing — the exact failure `existingBatch`'s own doc warns about.
    static let stateUndone = "undone"

    /// The Apple Health export archive `source_kind`. A stable token (never localized) so
    /// `resumable(...)` and any later importer agree on the vocabulary.
    static let appleHealthSourceKind = "apple_health"

    /// EPIC-43 ACC-005. One `source_kind` per file-import format (`FileImporter`/`FileImportFormat`),
    /// each a distinct token from `appleHealthSourceKind` and from each other — mirroring that
    /// constant's own naming convention — so `existingBatch(sourceKind:fileName:)`'s per-file-per-
    /// format dedup can never conflate a `route.gpx` picked for the GPX importer with a same-named
    /// file picked for a different format. FIT (Garmin's binary format) deliberately has no constant
    /// here: it is out of scope for this slice, not merely unimplemented — see `FileImportFormat`.
    static let gpxSourceKind = "gpx_file"
    static let tcxSourceKind = "tcx_file"
    static let csvSourceKind = "csv_file"

    var isTerminal: Bool { state == Self.stateCompleted }

    /// The batch's rows have been tombstoned by `ImportBatchRepository.undo`. Distinct from
    /// `isTerminal` on purpose: an undone batch must NOT offer "undo" again (there is nothing left
    /// to take back), and any surface listing it has to say its data is gone, or the row's own
    /// record counts read as data still present.
    var isUndone: Bool { state == Self.stateUndone }

    /// Decoded per-family counts, empty when absent/unparseable.
    var decodedCounts: [String: Int] {
        guard let counts, let data = counts.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
    }
}

/// Reads/writes `import_batches` and performs the batch-scoped undo. Owns no parsing or ingest
/// logic — it is purely the lineage/undo layer the importer and Settings surface consult.
final class ImportBatchRepository {
    private let db: SQLiteConnection
    /// The sensitive connection, when this repository is routing (A21/D-26). `nil` means
    /// single-connection mode: undo looks only at `db`, exactly as before routing existed — which
    /// is what the ~20 test call sites constructing `ImportBatchRepository(db.main)` and
    /// `Database.inMemoryFallback()`'s degraded path get. Mirrors `MeasurementRepository`'s own
    /// optional-`sensitive` seam deliberately: undo has to reach wherever that repository put the
    /// rows, so the two must be wired from the same pair of connections.
    private let sensitiveDb: SQLiteConnection?

    /// - Parameter sensitive: the `badan_sensitive.db` connection. Supply it (as `AppEnvironment`
    ///   does) and `undo(id:now:)` spans both files.
    ///
    /// STORAGE-2: this parameter did not exist, and its absence made undo silently partial. Since
    /// A21/D-26, `MeasurementRepository` routes any metric whose registry `sensitiveClass` is
    /// `sensitivePlus` — today `body.glucose` — into `badan_sensitive.db`, and the Apple Health
    /// archive importer writes its DTOs through that same repository. So a CGM user's imported
    /// glucose landed in `raw_samples` in the SENSITIVE file, carrying the batch id, while every
    /// statement in `undo` ran against `main` alone: `liveIds` found none of it, `removedSamples`
    /// under-reported, `measuredRange` returned a window that excluded the glucose span (so the
    /// caller re-derived the wrong range), and `softDeleteBatch` tombstoned nothing — yet the batch
    /// was still marked `undone`, which `ImportBatch.isUndone` treats as "nothing left to take
    /// back" and so permanently blocked a second attempt. The user was told the import was reversed
    /// while forty thousand glucose readings stayed live in the app and in every export.
    init(_ db: SQLiteConnection, sensitive: SQLiteConnection? = nil) {
        self.db = db
        self.sensitiveDb = sensitive
    }

    /// The tables sensitive migration 9 actually mirrors — the same set, for the same reason, as
    /// `MeasurementRepository.sensitiveMirroredTables`: aiming a statement at a file where the
    /// table does not exist throws "no such table" rather than harmlessly matching zero rows.
    /// `sessions`, `session_stages` and `workout_routes` exist only in `badan.db` (no session or
    /// route is a sensitive-plus metric), and `import_batches` itself is main-only — the lineage
    /// row is bookkeeping about a file the user picked, not a health datum.
    private static let sensitiveMirroredTables: Set<String> = ["raw_samples", "interval_records"]

    /// The connections a statement naming `table` must run against, main first. Row ids are unique
    /// across the pair and `batch_id` is stamped identically in both files, so running the same
    /// statement on both is correct rather than merely convenient: it matches nothing on whichever
    /// file does not hold the rows.
    private func connections(forTable table: String) -> [SQLiteConnection] {
        guard let sensitiveDb, Self.sensitiveMirroredTables.contains(table) else { return [db] }
        return [db, sensitiveDb]
    }

    /// Bracket `body` in a transaction on every connection undo can write to.
    ///
    /// Mirrors `MeasurementRepository.transaction` exactly — same nesting, same lock order (main
    /// then sensitive, so the two types can never deadlock against each other) — including what it
    /// refuses to claim: two separate SQLite files cannot two-phase-commit.
    ///
    /// The nesting decides which way a torn commit can fall, and it falls the safe way. Sensitive
    /// COMMITs first, so the only interruption window leaves the sensitive tombstones durable while
    /// main rolls back — the batch row is still `completed` (it is `setState`d inside the same
    /// body), so the user can undo again, and re-running finishes the main half while
    /// `softDeleteBatch`'s `deleted_at IS NULL` guard makes the already-tombstoned sensitive half a
    /// no-op rather than a second `deleted_at` pushed past an export cursor. An undo that reported
    /// itself complete with half the rows still live is exactly the failure STORAGE-2 was.
    private func bothConnections<T>(_ body: () throws -> T) throws -> T {
        guard let sensitiveDb else { return try db.transaction(body) }
        return try db.transaction { try sensitiveDb.transaction(body) }
    }

    // MARK: - Lifecycle

    /// Insert a new batch row. `id` is a ULID minted by the caller so it can stamp rows with it
    /// before the row exists (the batch id must be known at the first `ingest` call).
    func create(id: String, sourceKind: String, fileName: String?, state: String, createdAt: Date) throws {
        try db.run("""
            INSERT INTO import_batches (id, source_kind, file_name, state, chunk_cursor, counts, created_at)
            VALUES (?, ?, ?, ?, NULL, NULL, ?);
            """,
            [.text(id), .text(sourceKind), .string(fileName), .text(state), .date(createdAt)])
    }

    func find(id: String) throws -> ImportBatch? {
        try db.query("SELECT * FROM import_batches WHERE id = ?;", [.text(id)]).first.map(Self.read)
    }

    /// The batch already associated with this archive file, if any — one batch per source file,
    /// regardless of state.
    ///
    /// Deliberately NOT restricted to unfinished batches. Three cases need the same answer:
    /// *resuming* an interrupted import must keep writing under the original id (or half the rows
    /// would end up under a second batch and undo would only reach one of them); *re-importing* a
    /// file already imported must too — the upserts are idempotent and never rewrite an existing
    /// row's `batch_id`, so minting a new batch there would produce a second history entry that
    /// owns zero rows and whose "undo" would silently do nothing; and *re-importing after an undo*
    /// needs it most of all, because `undo` tombstones rows rather than deleting them, so the
    /// re-import's upserts land on those same rows (reviving them via `deleted_at=excluded
    /// .deleted_at`) and they keep the batch_id they already carry. Hence `stateUndone` batches are
    /// returned here like any other.
    func existingBatch(sourceKind: String, fileName: String?) throws -> ImportBatch? {
        guard let fileName else { return nil }
        return try db.query("""
            SELECT * FROM import_batches
            WHERE source_kind = ? AND file_name = ?
            ORDER BY created_at DESC LIMIT 1;
            """,
            [.text(sourceKind), .text(fileName)])
            .first.map(Self.read)
    }

    /// All batches, newest first (for the Settings "recent imports" list).
    func all() throws -> [ImportBatch] {
        try db.query("SELECT * FROM import_batches ORDER BY created_at DESC;").map(Self.read)
    }

    /// The most recent batch overall, newest first — what a one-tap "Undo last import" acts on.
    func latest() throws -> ImportBatch? {
        try db.query("SELECT * FROM import_batches ORDER BY created_at DESC LIMIT 1;").first.map(Self.read)
    }

    /// Advance the honest progress record after a flush. `counts` is the running per-family total
    /// so the result screen can show live numbers on a long import.
    func checkpoint(id: String, recordsProcessed: Int, counts: [String: Int]) throws {
        try db.run("UPDATE import_batches SET chunk_cursor = ?, counts = ? WHERE id = ?;",
                   [.text(String(recordsProcessed)), .text(Self.encodeCounts(counts)), .text(id)])
    }

    func setState(id: String, _ state: String) throws {
        try db.run("UPDATE import_batches SET state = ? WHERE id = ?;", [.text(state), .text(id)])
    }

    // MARK: - Undo

    /// The window an undo removed, so the caller can re-derive scores over exactly that span
    /// (imported history feeds baselines; removing it must un-feed them). `nil` when the batch had
    /// no LIVE measurement rows left (e.g. undone twice, or a `previewed` batch that never wrote).
    ///
    /// The `removed*` counts are rows this call actually tombstoned, so a second undo of the same
    /// batch reports zeros rather than re-counting rows it left alone.
    struct UndoResult: Equatable {
        let removedSamples: Int
        let removedIntervals: Int
        let removedSessions: Int
        let affectedRange: (from: Date, to: Date)?

        static func == (l: UndoResult, r: UndoResult) -> Bool {
            l.removedSamples == r.removedSamples && l.removedIntervals == r.removedIntervals
                && l.removedSessions == r.removedSessions
                && l.affectedRange?.from == r.affectedRange?.from
                && l.affectedRange?.to == r.affectedRange?.to
        }
    }

    /// Tombstone every row an import wrote, un-suppress anything those rows had out-ranked, and
    /// mark the batch `undone` — all in one transaction.
    ///
    /// **Soft-delete, not hard delete, and the reason is downstream.** An undo is a removal a
    /// downstream store has to hear about: a `sinceLastRun` delta gathers only live rows, so the
    /// only way it can report "this record went away" is `MeasurementRepository.tombstones(since:)`,
    /// which selects on `deleted_at > watermark`. A hard-deleted row leaves no tombstone, so a store
    /// fed by deltas kept rows BADAN had removed, forever, with nothing saying so. Setting
    /// `deleted_at` — the same soft-delete every upstream deletion already uses — is what puts the
    /// removal in the next delta's `deletions[]` / `deletions.csv`.
    ///
    /// That used to be impossible for a different reason, now fixed rather than worked around: the
    /// upsert's `ON CONFLICT` clauses did not clear `deleted_at`, so a re-import after a soft-delete
    /// undo would have stayed invisible. They now carry `deleted_at` across (see
    /// `MeasurementRepository.upsertRawSample`), so re-importing the same archive revives exactly
    /// the rows this call tombstoned. The batch row survives for the same reason — see
    /// `ImportBatch.stateUndone`.
    ///
    /// I3 is not the governing invariant here (it governs *reconciliation* of competing readings,
    /// not a user-initiated import reversal), but its discipline is: nothing is destroyed, and the
    /// reversal is journaled.
    ///
    /// Before tombstoning, any row (in any measurement table) whose dedup winner was one of this
    /// batch's rows is un-suppressed — so undoing an import that out-ranked a live-sync session for
    /// a night restores the live session rather than leaving that night with nothing visible — and
    /// each un-suppression is written to `dedup_decisions` as a reversal, so it reaches a delta
    /// export as a `corrections[]` record instead of flipping a row's authority silently
    /// (`unsuppress` below). A later live sync re-runs dedup and settles any night that ends up
    /// with more than one candidate, exactly as it does after any other change.
    ///
    /// Derived values are append-only (I2) and are NOT touched here; the caller recomputes over
    /// `affectedRange` so the latest-wins read model reflects the removal.
    ///
    /// Every statement below spans both physical databases where the table it names exists in both
    /// — see `connections(forTable:)` and STORAGE-2 on `init`. Undo has to reach wherever
    /// `MeasurementRepository` put the rows, and since A21/D-26 that is not always `badan.db`.
    @discardableResult
    func undo(id: String, now: Date) throws -> UndoResult {
        try bothConnections {
            // LIVE rows only: a second undo of the same batch must tombstone nothing, report zeros,
            // and above all must not re-stamp `deleted_at` — that would push an already-reported
            // removal past the cursor again on every call.
            let sampleIds = try liveIds(in: "raw_samples", batchId: id)
            let intervalIds = try liveIds(in: "interval_records", batchId: id)
            let sessionIds = try liveIds(in: "sessions", batchId: id)
            let range = try measuredRange(batchId: id)

            // Un-suppress any live row this batch's rows had won a dedup over (across tables),
            // journaling each flip as a reversal.
            let winnerIds = sampleIds + intervalIds + sessionIds
            for table in ["raw_samples", "interval_records", "sessions"] {
                try unsuppress(table: table, byWinners: winnerIds, now: now)
            }

            // `workout_routes` carries the full provenance struct (migration v4) and therefore a
            // `batch_id` of its own, so routes are tombstoned by batch. `route_points` inherits
            // through `route_id` and is deliberately left alone: a route's geometry belongs to the
            // route, and deleting the points would make the tombstone irreversible while the route
            // row itself stays revivable. The Apple Health archive format exposes no route geometry,
            // so today this touches nothing; it is here because the alternative is a table that
            // silently accumulates live routes the first time an importer does produce one.
            //
            // `session_stages` is likewise left in place — the stages belong to the session row,
            // which is now tombstoned, and every read path reaches stages through a live session.
            try softDeleteBatch(table: "workout_routes", batchId: id, now: now)
            try softDeleteBatch(table: "raw_samples", batchId: id, now: now)
            try softDeleteBatch(table: "interval_records", batchId: id, now: now)
            try softDeleteBatch(table: "sessions", batchId: id, now: now)
            try setState(id: id, ImportBatch.stateUndone)

            return UndoResult(removedSamples: sampleIds.count, removedIntervals: intervalIds.count,
                              removedSessions: sessionIds.count, affectedRange: range)
        }
    }

    // MARK: - Helpers

    /// The ids of this batch's rows that are still LIVE, across every file that holds `table`.
    /// Everything undo does — counting, tombstoning, un-suppressing what they beat — is about rows
    /// that currently exist, so a repeat undo is a no-op rather than a second round of writes.
    private func liveIds(in table: String, batchId: String) throws -> [String] {
        try connections(forTable: table).flatMap { connection in
            try connection.query("SELECT id FROM \(table) WHERE batch_id = ? AND deleted_at IS NULL;", [.text(batchId)])
                .compactMap { $0.string("id") }
        }
    }

    /// The earliest/latest `measured_at` across the LIVE rows this batch wrote — the span derivations
    /// must be re-run over after removal. Live-only for the same reason `liveIds` is: after a
    /// completed undo there is nothing left to re-derive over, and reporting a span anyway would make
    /// the caller backfill a window it already backfilled.
    private func measuredRange(batchId: String) throws -> (from: Date, to: Date)? {
        var earliest: Date?
        var latest: Date?
        for table in ["raw_samples", "interval_records", "sessions"] {
            // Both files, min/max folded across them: a range computed from `main` alone would end
            // where the non-sensitive rows end, and the caller would re-derive over a window that
            // excludes the glucose span it was called precisely to un-feed (STORAGE-2).
            for connection in connections(forTable: table) {
                let row = try connection.query("""
                    SELECT MIN(measured_at) AS lo, MAX(measured_at) AS hi FROM \(table)
                    WHERE batch_id = ? AND deleted_at IS NULL;
                    """, [.text(batchId)]).first
                if let lo = row?.date("lo") { earliest = earliest.map { min($0, lo) } ?? lo }
                if let hi = row?.date("hi") { latest = latest.map { max($0, hi) } ?? hi }
            }
        }
        guard let from = earliest, let to = latest else { return nil }
        return (from, to)
    }

    /// Tombstone every live row this batch wrote in `table`. `deleted_at IS NULL` in the WHERE clause
    /// makes it idempotent in exactly the shape `MeasurementRepository.softDelete` uses: re-running
    /// an undo cannot re-stamp `deleted_at` and push an already-exported removal past the cursor a
    /// second time.
    private func softDeleteBatch(table: String, batchId: String, now: Date) throws {
        for connection in connections(forTable: table) {
            try connection.run("""
                UPDATE \(table) SET deleted_at = ?, updated_at = ? WHERE batch_id = ? AND deleted_at IS NULL;
                """, [.date(now), .date(now), .text(batchId)])
        }
    }

    /// Clear `suppressed_by` on every row whose dedup winner was one of `winnerIds`, and JOURNAL each
    /// clearing as a reversal in `dedup_decisions`.
    ///
    /// The journal half is not bookkeeping. A delta export builds its `corrections[]` from the
    /// journal (`ReconciliationRepository.decisionsChangedSince`), so a `suppressed_by` cleared
    /// without a journal row changes which record is authoritative on this device while every
    /// downstream store keeps believing the old verdict — the add-only desync EPIC-17 exists to
    /// close, arriving through the back door. I3's two words for a dedup decision are *reversible*
    /// and *inspectable*; an un-journaled un-suppression is neither.
    ///
    /// Two cases, because both occur:
    ///  • A live decision exists (the ordinary one — the import's own sleep dedup journaled it):
    ///    `markReversed` stamps `reversed_at`, and the delta reports `suppressed_by: null` at that
    ///    instant.
    ///  • No live decision exists — the suppression was written without one (today only reachable
    ///    from `IngestionPipeline`'s un-journaled compensation paths). A decision row is written
    ///    *and* immediately marked reversed, so the flip is still reported. `decided_at` is the
    ///    row's own `updated_at`, which is the instant `setSuppressed` last stamped it: a grounded
    ///    best effort, not an invented one, and it is never later than `reversed_at`.
    ///
    /// The journal shares this repository's MAIN `SQLiteConnection`, so it joins the caller's
    /// transaction rather than opening a second one — the same-thread nesting
    /// `MeasurementRepository.transaction` documents. It stays on `main` even when the suppressed
    /// row being cleared lives in `badan_sensitive.db`: `dedup_decisions` exists only in `badan.db`
    /// (main migration v1; sensitive migration 9 mirrors the two measurement tables and nothing
    /// else), and a decision row names two record ids and a rule — no metric, no value — so it
    /// discloses nothing a sensitive purge is meant to take with it.
    private func unsuppress(table: String, byWinners winnerIds: [String], now: Date) throws {
        guard !winnerIds.isEmpty else { return }
        let journal = ReconciliationRepository(db)
        // Both files (STORAGE-2): an imported glucose row that out-ranked a live CGM reading did
        // the suppressing inside `badan_sensitive.db`, so an un-suppression aimed only at `main`
        // would leave that night's own reading hidden behind a winner that no longer exists.
        for connection in connections(forTable: table) {
            // Chunk the IN list so a very large batch can't build an oversized statement.
            for chunk in winnerIds.badanChunked(500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let params = chunk.map { SQLValue.text($0) }
                let losers = try connection.query("""
                    SELECT id, suppressed_by, updated_at FROM \(table) WHERE suppressed_by IN (\(placeholders));
                    """, params)
                for row in losers {
                    guard let recordId = row.string("id"), let winnerId = row.string("suppressed_by") else { continue }
                    if let decision = try journal.forSuppressed(recordId) {
                        try journal.markReversed(id: decision.id, at: now)
                    } else {
                        try journal.insert(ReconciliationDecision(
                            id: ULID.newID(), rule: Self.undoUnsuppressRule, ruleVersion: "1.0.0",
                            keptRecordId: winnerId, suppressedRecordId: recordId,
                            reversible: true, reversedAt: now,
                            decidedAt: row.date("updated_at") ?? now,
                            detail: ["reason": "import_undo", "table": table]))
                    }
                }
                try connection.run("UPDATE \(table) SET suppressed_by = NULL, updated_at = ? WHERE suppressed_by IN (\(placeholders));",
                                   [.date(now)] + params)
            }
        }
    }

    /// The rule id on a decision this repository writes itself, for the un-journaled-suppression
    /// case above. Distinct from `DedupLite`'s rule ids on purpose: nothing here *decided* anything
    /// — it recorded that an import undo cleared a suppression whose original decision was never
    /// journaled, and a reader of `dedup_decisions` must be able to tell those apart.
    static let undoUnsuppressRule = "import.undo.unsuppress.v1"

    private static func encodeCounts(_ counts: [String: Int]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func read(_ r: SQLiteRow) -> ImportBatch {
        ImportBatch(id: r.requireString("id"), sourceKind: r.requireString("source_kind"),
                    fileName: r.string("file_name"), state: r.requireString("state"),
                    chunkCursor: r.string("chunk_cursor"), counts: r.string("counts"),
                    createdAt: r.requireDate("created_at"))
    }
}
