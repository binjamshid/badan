package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.ExportCursor
import net.albayyan.badan.domain.ManifestDigest
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * `export_cursors` (migration v4, plan §9.6) — the incremental-export checkpoint per
 * (template, destination).
 *
 * The watermark is a max **`ingested_at`**, never a max `measured_at`. [ExportCursor]'s doc carries
 * the full reasoning; the short version is that a watch syncing Saturday's workout on Monday
 * produces a row whose `measured_at` is behind an existing Sunday watermark, so a `measured_at`
 * cursor drops every late-arriving and backfilled row without any file looking wrong. Anyone tempted
 * to "fix" the column to `measured_at` should read that comment first.
 */
class ExportCursorRepository(private val db: SqliteConnection) {

    // MARK: - Reads

    fun cursor(templateId: String, destinationId: String): ExportCursor? =
        db.query(
            "SELECT * FROM export_cursors WHERE template_id = ? AND destination_id = ?;",
            listOf(templateId, destinationId),
        ).firstOrNull()?.let { read(it) }

    fun all(): List<ExportCursor> =
        db.query("SELECT * FROM export_cursors ORDER BY updated_at DESC;").map { read(it) }

    // MARK: - Writes

    /**
     * Move a cursor forward after a successful delta run. Returns false — and writes nothing — if
     * [watermark] is not ahead of the stored one.
     *
     * Forward-only on purpose. A cursor that can move backwards silently re-exports a window the
     * user already has, which is merely wasteful; but the same unguarded write is how a cursor moves
     * *forward past* data during an out-of-order retry, and that loses rows permanently. So the only
     * unconditional writes here are the two explicit ones below, both named for what they do.
     * Callers wanting to re-export deliberately call [rewind] or [reset].
     */
    fun advance(
        templateId: String,
        destinationId: String,
        watermark: Long,
        lastRunId: String?,
        manifestSha: ManifestDigest?,
        now: Long,
    ): Boolean = db.transaction {
        val existing = cursor(templateId, destinationId)
        if (existing != null && existing.highWatermark >= watermark) {
            false
        } else {
            write(
                ExportCursor(
                    templateId = templateId, destinationId = destinationId,
                    highWatermark = watermark, lastManifestSha = manifestSha,
                    lastRunId = lastRunId, updatedAt = now,
                ),
            )
            true
        }
    }

    /**
     * Deliberately move a cursor backwards, so the next run re-exports from [watermark].
     *
     * Separate from [advance] rather than a flag on it: re-exporting is a legitimate user action
     * ("send last month again"), but it is never something a run should be able to do as a side
     * effect of a retry. Splitting them means a rewind is always an explicit call someone wrote.
     */
    fun rewind(templateId: String, destinationId: String, watermark: Long, now: Long) {
        write(
            ExportCursor(
                templateId = templateId, destinationId = destinationId,
                highWatermark = watermark, lastManifestSha = null, lastRunId = null, updatedAt = now,
            ),
        )
    }

    /**
     * Drop the checkpoint entirely; the next `sinceLastRun` run has no cursor.
     *
     * Note what that means downstream (§12 EPIC-09's input rule): a `sinceLastRun` template with no
     * cursor falls back to `lastNDays` **with a notice**, rather than silently exporting all of
     * history. Hard delete, not a tombstone — a soft-deleted watermark that could be resurrected
     * would resume from a stale position (the v4 comment's reasoning for this table having no
     * convention columns).
     */
    fun reset(templateId: String, destinationId: String) {
        db.run(RESET_SQL, listOf(templateId, destinationId))
    }

    /**
     * Drop every checkpoint for a template — used when a template's scope changes materially, where
     * resuming from the old watermark would mean the newly-added metrics are never backfilled into
     * an export at all.
     */
    fun resetAll(templateId: String) {
        db.run(RESET_ALL_SQL, listOf(templateId))
    }

    private fun write(c: ExportCursor) {
        db.run(
            """
            INSERT OR REPLACE INTO export_cursors
              (template_id, destination_id, high_watermark, last_manifest_sha, last_run_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            listOf(
                c.templateId, c.destinationId, c.highWatermark,
                c.lastManifestSha?.hex, c.lastRunId, c.updatedAt,
            ),
        )
    }

    companion object {
        /**
         * Both deletes are kept as named constants so `ExportTemplateSystemTest` can assert they
         * are bounded without a database — this module has no instrumented test source set, and an
         * unbounded `DELETE FROM export_cursors` would silently reset every template's incremental
         * progress, which no user-visible symptom would distinguish from a normal re-export. Same
         * rationale as `BackgroundRunRepository.PRUNE_SQL`.
         */
        const val RESET_SQL = "DELETE FROM export_cursors WHERE template_id = ? AND destination_id = ?;"
        const val RESET_ALL_SQL = "DELETE FROM export_cursors WHERE template_id = ?;"

        fun read(r: Row): ExportCursor =
            ExportCursor(
                templateId = r.requireString("template_id"),
                destinationId = r.requireString("destination_id"),
                highWatermark = r.requireDate("high_watermark"),
                lastManifestSha = ManifestDigest.of(r.getString("last_manifest_sha")),
                lastRunId = r.getString("last_run_id"),
                updatedAt = r.requireDate("updated_at"),
            )
    }
}
