package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportJobStatus
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Export job history with manifests. Kept in the main DB; the export code path itself has
 * no networking or entitlement imports (D-8).
 */
class ExportJobRepository(private val db: SqliteConnection) {

    /** List-view projection of [ExportJob] — see [recentSummaries]. */
    data class ExportJobSummary(
        val id: String,
        val format: ExportFormat,
        val status: ExportJobStatus,
        val rowCount: Int?,
        val createdAt: Long,
    )

    fun insert(job: ExportJob) {
        db.run(
            """
            INSERT OR REPLACE INTO export_jobs
              (id, scope, format, status, manifest, output_path, row_count, started_at, finished_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                job.id, JsonCoding.encode(job.scope), job.format.code, job.status.code,
                job.manifest?.let { JsonCoding.encode(it) }, job.outputPath, job.rowCount?.toLong(),
                job.startedAt, job.finishedAt, job.createdAt,
            ),
        )
    }

    /**
     * [offset] supports a future "load more" affordance in the export history list (which today
     * always shows only the most recent [limit] jobs) without changing the default call shape —
     * existing positional callers (`recent(20)`) are unaffected.
     */
    fun recent(limit: Int = 30, offset: Int = 0): List<ExportJob> =
        db.query(
            "SELECT * FROM export_jobs ORDER BY created_at DESC LIMIT ? OFFSET ?;",
            listOf(limit.toLong(), offset.toLong()),
        ).map { read(it) }

    /**
     * A narrow projection for the history *list* view — skips decoding the `manifest` column
     * (per-metric row counts, file checksums) that only matters when inspecting one specific job,
     * not when rendering N rows of status/format/date.
     */
    fun recentSummaries(limit: Int = 30, offset: Int = 0): List<ExportJobSummary> =
        db.query(
            "SELECT id, format, status, row_count, created_at FROM export_jobs ORDER BY created_at DESC LIMIT ? OFFSET ?;",
            listOf(limit.toLong(), offset.toLong()),
        ).map { r ->
            ExportJobSummary(
                id = r.requireString("id"),
                format = ExportFormat.fromCode(r.requireString("format")),
                status = ExportJobStatus.fromCode(r.requireString("status")),
                rowCount = r.getInt("row_count"),
                createdAt = r.requireDate("created_at"),
            )
        }

    companion object {
        fun read(r: Row): ExportJob =
            ExportJob(
                id = r.requireString("id"),
                scope = JsonCoding.decodeOrNull<ExportScope>(r.getString("scope")) ?: ExportScope.everything,
                format = ExportFormat.fromCode(r.requireString("format")),
                status = ExportJobStatus.fromCode(r.requireString("status")),
                manifest = JsonCoding.decodeOrNull<ExportManifest>(r.getString("manifest")),
                outputPath = r.getString("output_path"), rowCount = r.getInt("row_count"),
                startedAt = r.getDate("started_at"), finishedAt = r.getDate("finished_at"),
                createdAt = r.requireDate("created_at"),
            )
    }
}
