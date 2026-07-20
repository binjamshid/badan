import Foundation

/// `export_runs` (migration v4, plan §9.5) — the trust ledger.
///
/// One row per **attempted** export. This table is the anti-HAE thesis in storage form: the
/// failure mode it exists to prevent is an export that quietly does not happen, so the write here
/// is unconditional and the reads below are what the Export Health dashboard (EPIC-16) is built
/// on.
///
/// Append-only and device-local, like `background_runs` and for the same reasons the v4 comment
/// gives: no `deleted_at` (a ledger whose rows can be removed cannot answer the one question it
/// exists for) and no `updated_at`/`origin_device_id` (a run is an event that happened on *this*
/// device; merging another phone's run log in would produce a history the user never observed).
final class ExportRunRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Writes

    /// Append one finished run.
    ///
    /// Written once, at the end, because `ExportOutcome` has no in-flight case — every outcome
    /// in §9.5 is terminal. The gap that leaves is real and worth stating plainly: a run whose
    /// process is killed mid-export (memory pressure, force-quit, an OS reclaim) writes no row
    /// at all. That case is not invisible, but it is not visible *here* — it shows up as an
    /// `export_jobs` row stuck in `running` (reconciled by
    /// `ExportJobRepository.markStaleRunningAsFailed`) and as a job with no run, which
    /// `jobIdsWithoutRun` surfaces for exactly this reason.
    ///
    /// Plain `INSERT`, not `INSERT OR REPLACE`: run ids are fresh ULIDs, so a collision is an
    /// id-generation bug that should fail the write rather than overwrite an earlier run's record.
    func insert(_ run: ExportRun) throws {
        try db.run("""
            INSERT INTO export_runs
              (id, template_id, job_id, trigger_kind, started_at, finished_at, outcome, error_code,
               error_detail, bytes_written, row_counts, destination_id, delivered_at,
               cursor_before, cursor_after, manifest_sha256)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(run.id), .string(run.templateId), .string(run.jobId),
             // Column is `trigger_kind`, not `trigger`: TRIGGER is a SQL reserved word (v4
             // comment). The domain field keeps §9.5's name.
             .text(run.trigger.rawValue), .date(run.startedAt), .date(run.finishedAt),
             .text(run.outcome.rawValue), .string(run.errorCode?.rawValue),
             .string(run.errorDetail.map { JSONCoding.encode($0) }),
             .int(run.bytesWritten),
             .string(run.rowCounts.map { JSONCoding.encode($0) }),
             .string(run.destinationId), .date(run.deliveredAt),
             .date(run.cursorBefore), .date(run.cursorAfter),
             .string(run.manifestSha256?.hex)])
    }

    // MARK: - Reads

    /// Uses `idx_export_runs_started`.
    func recent(limit: Int = 50) throws -> [ExportRun] {
        try db.query("SELECT * FROM export_runs ORDER BY started_at DESC LIMIT ?;", [.int(limit)])
            .map(Self.read)
    }

    /// Uses `idx_export_runs_template_started`.
    func recent(templateId: String, limit: Int = 50) throws -> [ExportRun] {
        try db.query("""
            SELECT * FROM export_runs WHERE template_id = ? ORDER BY started_at DESC LIMIT ?;
            """, [.text(templateId), .int(limit)]).map(Self.read)
    }

    /// The last run of a template regardless of outcome — what a template row shows ("last run
    /// yesterday, didn't finish"). Distinct from `lastSuccess`, which is what a *cursor* decision
    /// is allowed to trust.
    func lastRun(templateId: String) throws -> ExportRun? {
        try db.query("""
            SELECT * FROM export_runs WHERE template_id = ? ORDER BY started_at DESC LIMIT 1;
            """, [.text(templateId)]).first.map(Self.read)
    }

    /// The last run that actually delivered everything it claimed to.
    ///
    /// `partial` is deliberately excluded: resuming a delta export from a partial run's watermark
    /// would treat the rows it failed to write as already exported, and they would never appear
    /// in any later file. That is the silent-loss failure this whole subsystem is designed
    /// against, so the query has to be `= 'success'` and not `NOT IN (failures)`.
    func lastSuccess(templateId: String, destinationId: String) throws -> ExportRun? {
        try db.query("""
            SELECT * FROM export_runs
            WHERE template_id = ? AND destination_id = ? AND outcome = ?
            ORDER BY started_at DESC LIMIT 1;
            """, [.text(templateId), .text(destinationId), .text(ExportOutcome.success.rawValue)])
            .first.map(Self.read)
    }

    /// Runs per outcome since `since`, in `ExportOutcome.allCases` order, omitting outcomes with
    /// no runs. Same shape and ordering rule as `BackgroundRunRepository.summary` so the two
    /// health surfaces read alike.
    func outcomeCounts(since: Date) throws -> [(outcome: ExportOutcome, count: Int)] {
        var counts: [ExportOutcome: Int] = [:]
        for row in try db.query("""
            SELECT outcome, COUNT(*) AS c FROM export_runs WHERE started_at >= ? GROUP BY outcome;
            """, [.date(since)]) {
            guard let outcome = ExportOutcome(rawValue: row.requireString("outcome")) else { continue }
            counts[outcome] = row.intValue("c") ?? 0
        }
        return ExportOutcome.allCases.compactMap { outcome in
            counts[outcome].map { (outcome: outcome, count: $0) }
        }
    }

    /// Export jobs that have no run row — i.e. exports that started and left no ledger entry.
    ///
    /// This is the completeness check on the ledger itself. §12's rule is that every run writes an
    /// `ExportRun`; a job without one means the process died between creating the job and
    /// recording its outcome, and without this query that gap is precisely the "it just never
    /// happened and nothing said so" behavior the table exists to make impossible.
    func jobIdsWithoutRun(limit: Int = 50) throws -> [String] {
        try db.query("""
            SELECT j.id AS id FROM export_jobs j
            LEFT JOIN export_runs r ON r.job_id = j.id
            WHERE r.id IS NULL
            ORDER BY j.created_at DESC LIMIT ?;
            """, [.int(limit)]).compactMap { $0.string("id") }
    }

    static func read(_ r: SQLiteRow) -> ExportRun {
        ExportRun(
            id: r.requireString("id"),
            templateId: r.string("template_id"),
            jobId: r.string("job_id"),
            // Falls back to `manual`, the trigger that makes the fewest claims: reading an
            // unparseable row as a *scheduled* run would invent evidence that an automation fired.
            trigger: ExportTrigger(rawValue: r.requireString("trigger_kind")) ?? .manual,
            startedAt: r.requireDate("started_at"),
            finishedAt: r.date("finished_at"),
            // An unreadable outcome falls back to `failedGeneration` rather than `success` — a
            // ledger must never round an unknown up into a claim that the export worked.
            outcome: ExportOutcome(rawValue: r.requireString("outcome")) ?? .failedGeneration,
            errorCode: r.string("error_code").flatMap { ExportErrorCode(rawValue: $0) },
            errorDetail: JSONCoding.decode(ExportErrorDetail.self, from: r.string("error_detail")),
            bytesWritten: r.intValue("bytes_written"),
            rowCounts: JSONCoding.decode(ExportRowCounts.self, from: r.string("row_counts")),
            destinationId: r.string("destination_id"),
            deliveredAt: r.date("delivered_at"),
            cursorBefore: r.date("cursor_before"),
            cursorAfter: r.date("cursor_after"),
            manifestSha256: r.string("manifest_sha256").flatMap { ManifestDigest(hex: $0) })
    }
}
