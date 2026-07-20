package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportErrorDetail
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRowCounts
import net.albayyan.badan.domain.ExportRun
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.domain.ManifestDigest
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * `export_runs` (migration v4, plan §9.5) — the trust ledger.
 *
 * One row per **attempted** export. This table is the anti-HAE thesis in storage form: the failure
 * mode it exists to prevent is an export that quietly does not happen, so the write here is
 * unconditional and the reads below are what the Export Health dashboard (EPIC-16) is built on.
 *
 * Append-only and device-local, like `background_runs` and for the same reasons the v4 comment
 * gives: no `deleted_at` (a ledger whose rows can be removed cannot answer the one question it
 * exists for) and no `updated_at`/`origin_device_id` (a run is an event that happened on *this*
 * device; merging another phone's run log in would produce a history the user never observed).
 */
class ExportRunRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    /**
     * Append one finished run.
     *
     * Written once, at the end, because [ExportOutcome] has no in-flight case — every outcome in
     * §9.5 is terminal. The gap that leaves is real and worth stating plainly: a run whose process
     * is killed mid-export (the Samsung/Xiaomi OEM-killer case, or low memory) writes no row at all.
     * That case is not invisible, but it is not visible *here* — it shows up as an `export_jobs` row
     * left in `running`, and as a job with no run, which [jobIdsWithoutRun] surfaces for exactly
     * this reason.
     *
     * Plain `INSERT`, not `INSERT OR REPLACE`: run ids are fresh ULIDs, so a collision is an
     * id-generation bug that should fail the write rather than overwrite an earlier run's record.
     */
    fun insert(run: ExportRun) {
        db.run(
            """
            INSERT INTO export_runs
              (id, template_id, job_id, trigger_kind, started_at, finished_at, outcome, error_code,
               error_detail, bytes_written, row_counts, destination_id, delivered_at,
               cursor_before, cursor_after, manifest_sha256)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                run.id, run.templateId, run.jobId,
                // Column is `trigger_kind`, not `trigger`: TRIGGER is a SQL reserved word (v4
                // comment). The domain field keeps §9.5's name.
                run.trigger.code, run.startedAt, run.finishedAt, run.outcome.code,
                run.errorCode?.code,
                run.errorDetail?.let { JsonCoding.encode(it) },
                run.bytesWritten,
                run.rowCounts?.let { JsonCoding.encode(it) },
                run.destinationId, run.deliveredAt, run.cursorBefore, run.cursorAfter,
                run.manifestSha256?.hex,
            ),
        )
    }

    // MARK: - Reads

    /** Uses `idx_export_runs_started`. */
    fun recent(limit: Int = 50): List<ExportRun> =
        db.query("SELECT * FROM export_runs ORDER BY started_at DESC LIMIT ?;", listOf(limit.toLong()))
            .map { read(it) }

    /** Uses `idx_export_runs_template_started`. */
    fun recent(templateId: String, limit: Int = 50): List<ExportRun> =
        db.query(
            "SELECT * FROM export_runs WHERE template_id = ? ORDER BY started_at DESC LIMIT ?;",
            listOf(templateId, limit.toLong()),
        ).map { read(it) }

    /**
     * The last run of a template regardless of outcome — what a template row shows ("last run
     * yesterday, didn't finish"). Distinct from [lastSuccess], which is what a *cursor* decision is
     * allowed to trust.
     */
    fun lastRun(templateId: String): ExportRun? =
        db.query(
            "SELECT * FROM export_runs WHERE template_id = ? ORDER BY started_at DESC LIMIT 1;",
            listOf(templateId),
        ).firstOrNull()?.let { read(it) }

    /**
     * The last run that actually delivered everything it claimed to.
     *
     * [ExportOutcome.PARTIAL] is deliberately excluded: resuming a delta export from a partial run's
     * watermark would treat the rows it failed to write as already exported, and they would never
     * appear in any later file. That is the silent-loss failure this whole subsystem is designed
     * against, so the query has to be `= 'success'` and not `NOT IN (failures)`.
     */
    fun lastSuccess(templateId: String, destinationId: String): ExportRun? =
        db.query(
            """
            SELECT * FROM export_runs
            WHERE template_id = ? AND destination_id = ? AND outcome = ?
            ORDER BY started_at DESC LIMIT 1;
            """,
            listOf(templateId, destinationId, ExportOutcome.SUCCESS.code),
        ).firstOrNull()?.let { read(it) }

    /**
     * Runs per outcome since [since], in `ExportOutcome.entries` order, omitting outcomes with no
     * runs. Same shape and ordering rule as `BackgroundRunRepository.cadence`'s summary so the two
     * health surfaces read alike.
     */
    fun outcomeCounts(since: Long): List<Pair<ExportOutcome, Int>> {
        val counts = HashMap<ExportOutcome, Int>()
        for (row in db.query(
            "SELECT outcome, COUNT(*) AS c FROM export_runs WHERE started_at >= ? GROUP BY outcome;",
            listOf(since),
        )) {
            val code = row.getString("outcome") ?: continue
            val outcome = ExportOutcome.entries.firstOrNull { it.code == code } ?: continue
            counts[outcome] = row.getInt("c") ?: 0
        }
        return ExportOutcome.entries.mapNotNull { outcome -> counts[outcome]?.let { outcome to it } }
    }

    /**
     * Export jobs that have no run row — i.e. exports that started and left no ledger entry.
     *
     * This is the completeness check on the ledger itself. §12's rule is that every run writes an
     * `ExportRun`; a job without one means the process died between creating the job and recording
     * its outcome, and without this query that gap is precisely the "it just never happened and
     * nothing said so" behavior the table exists to make impossible.
     */
    fun jobIdsWithoutRun(limit: Int = 50): List<String> =
        db.query(
            """
            SELECT j.id AS id FROM export_jobs j
            LEFT JOIN export_runs r ON r.job_id = j.id
            WHERE r.id IS NULL
            ORDER BY j.created_at DESC LIMIT ?;
            """,
            listOf(limit.toLong()),
        ).mapNotNull { it.getString("id") }

    companion object {
        fun read(r: Row): ExportRun =
            ExportRun(
                id = r.requireString("id"),
                templateId = r.getString("template_id"),
                jobId = r.getString("job_id"),
                trigger = ExportTrigger.fromCode(r.getString("trigger_kind")),
                startedAt = r.requireDate("started_at"),
                finishedAt = r.getDate("finished_at"),
                outcome = ExportOutcome.fromCode(r.getString("outcome")),
                errorCode = ExportErrorCode.fromCode(r.getString("error_code")),
                errorDetail = JsonCoding.decodeOrNull<ExportErrorDetail>(r.getString("error_detail")),
                bytesWritten = r.getLong("bytes_written"),
                rowCounts = JsonCoding.decodeOrNull<ExportRowCounts>(r.getString("row_counts")),
                destinationId = r.getString("destination_id"),
                deliveredAt = r.getDate("delivered_at"),
                cursorBefore = r.getDate("cursor_before"),
                cursorAfter = r.getDate("cursor_after"),
                manifestSha256 = ManifestDigest.of(r.getString("manifest_sha256")),
            )
    }
}
