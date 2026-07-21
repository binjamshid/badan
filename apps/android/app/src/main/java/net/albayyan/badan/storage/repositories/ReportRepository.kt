package net.albayyan.badan.storage.repositories

import net.albayyan.badan.core.Ulid
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * One generated periodic report's METADATA (migration v8, plan §9.12). The rendered artifact (a PDF)
 * lives as a file and is regenerable, so this row is DERIVED and never a source of truth:
 * `ReportBuilder` is deterministic, so re-running it reproduces the same model and the same [sha256].
 * The row exists so the Reports surface can list and open reports without re-deriving, and so a
 * rendered file can be checked against what the store would regenerate. Mirror of iOS `ReportRecord`.
 */
data class ReportRecord(
    val id: String,
    val periodKey: String,
    val generatedAt: Long,
    val algorithmVersionId: String,
    /**
     * The section ids present (`ReportModel.sectionsIncluded`), stored whole so the section set can
     * evolve without a migration. An empty period legitimately has fewer (or zero) sections.
     */
    val sectionsIncluded: List<String>,
    /**
     * The rendered PDF's path, or null — the file may not have been rendered yet, or may have been
     * pruned. A report row is valid without a file: the file is regenerable from the model.
     */
    val artifactPath: String?,
    /**
     * Content hash of the deterministic model (`ReportBuilder.contentHash`). The integrity anchor: a
     * rendered artifact is trustworthy iff re-deriving the model reproduces this hash. Always present
     * even when [artifactPath] is null.
     */
    val sha256: String,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    /**
     * Whether the report's on-disk artifact is stale relative to a freshly-derived model: the content
     * hash the store would regenerate now differs from what this row was rendered against. A stale
     * report must be obviously regenerable — never silently shown as current.
     */
    fun isStale(freshHash: String): Boolean = sha256 != freshHash
}

/**
 * `reports` (migration v8, plan §9.12) — periodic-report metadata.
 *
 * Soft-delete only (`deleted_at`), like every other convention-column table, and — deliberately
 * unlike `derived_values`/`baselines` — NOT append-only: a report is a disposable, regenerable
 * rollup, so regenerating for the same (period, algorithm version) REPLACES the row in place rather
 * than appending (I2 governs BADAN's beliefs over time, not a rendered artifact). The
 * (period_key, algorithm_version_id) identity is enforced by the partial unique index
 * `idx_reports_period_algorithm` (WHERE deleted_at IS NULL). Mirror of iOS `ReportRepository.swift`.
 */
class ReportRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    /**
     * Persist a report's metadata, replacing any existing (non-deleted) row for the same
     * (period, algorithm version) in place so the row's id is stable across regenerations. Returns
     * the persisted record (its id is the existing row's id on a replace, a fresh ULID otherwise).
     */
    fun save(
        periodKey: String,
        algorithmVersionId: String,
        generatedAt: Long,
        sectionsIncluded: List<String>,
        artifactPath: String?,
        sha256: String,
        now: Long,
        originDeviceId: String,
    ): ReportRecord = db.transaction {
        val sectionsJson = JsonCoding.encode(sectionsIncluded)
        val existing = current(periodKey, algorithmVersionId)
        if (existing != null) {
            db.run(
                """
                UPDATE reports SET generated_at = ?, sections_included = ?, artifact_path = ?,
                  sha256 = ?, updated_at = ? WHERE id = ?;
                """,
                listOf(generatedAt, sectionsJson, artifactPath, sha256, now, existing.id),
            )
            ReportRecord(
                id = existing.id, periodKey = periodKey, generatedAt = generatedAt,
                algorithmVersionId = algorithmVersionId, sectionsIncluded = sectionsIncluded,
                artifactPath = artifactPath, sha256 = sha256, updatedAt = now,
                originDeviceId = existing.originDeviceId, deletedAt = null,
            )
        } else {
            val id = Ulid.newId()
            db.run(
                """
                INSERT INTO reports
                  (id, period_key, generated_at, algorithm_version_id, sections_included, artifact_path,
                   sha256, ${Rows.convColumns})
                VALUES (?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
                """,
                listOf(id, periodKey, generatedAt, algorithmVersionId, sectionsJson, artifactPath, sha256) +
                    Rows.convParams(updatedAt = now, originDeviceId = originDeviceId, deletedAt = null),
            )
            ReportRecord(
                id = id, periodKey = periodKey, generatedAt = generatedAt,
                algorithmVersionId = algorithmVersionId, sectionsIncluded = sectionsIncluded,
                artifactPath = artifactPath, sha256 = sha256, updatedAt = now,
                originDeviceId = originDeviceId, deletedAt = null,
            )
        }
    }

    /**
     * Record (or clear) the rendered artifact's path for an existing report row. Kept separate from
     * [save] because the artifact is rendered after the metadata is written and may be pruned later —
     * the row outlives its file.
     */
    fun setArtifactPath(id: String, path: String?, at: Long) {
        db.run(
            "UPDATE reports SET artifact_path = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(path, at, id),
        )
    }

    /**
     * Tombstone a report. The file, if any, is the caller's to remove; a soft-deleted row frees its
     * (period, version) identity so the user can regenerate a report they just deleted.
     */
    fun softDelete(id: String, at: Long) {
        db.run(
            "UPDATE reports SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(at, at, id),
        )
    }

    // MARK: - Reads

    /**
     * The current report for a (period, algorithm version), or null. Matches the partial unique
     * index's predicate exactly (WHERE deleted_at IS NULL).
     */
    fun current(periodKey: String, algorithmVersionId: String): ReportRecord? =
        db.query(
            "SELECT * FROM reports WHERE period_key = ? AND algorithm_version_id = ? AND deleted_at IS NULL;",
            listOf(periodKey, algorithmVersionId),
        ).firstOrNull()?.let { read(it) }

    fun report(id: String): ReportRecord? =
        db.query("SELECT * FROM reports WHERE id = ? AND deleted_at IS NULL;", listOf(id))
            .firstOrNull()?.let { read(it) }

    /** Live reports, most recent period first (period keys are lexicographically sortable). */
    fun all(): List<ReportRecord> =
        db.query("SELECT * FROM reports WHERE deleted_at IS NULL ORDER BY period_key DESC, generated_at DESC;")
            .map { read(it) }

    /**
     * The set of period keys that currently have a (non-deleted) report for [algorithmVersionId] —
     * what `ReportTrigger.dueWeeklyPeriodKey` needs to avoid regenerating an existing week.
     */
    fun periodKeys(algorithmVersionId: String): Set<String> =
        db.query(
            "SELECT period_key FROM reports WHERE algorithm_version_id = ? AND deleted_at IS NULL;",
            listOf(algorithmVersionId),
        ).mapNotNull { it.getString("period_key") }.toSet()

    companion object {
        fun read(r: Row): ReportRecord = ReportRecord(
            id = r.requireString("id"),
            periodKey = r.requireString("period_key"),
            generatedAt = r.requireDate("generated_at"),
            algorithmVersionId = r.requireString("algorithm_version_id"),
            sectionsIncluded = JsonCoding.decodeOrNull<List<String>>(r.getString("sections_included")) ?: emptyList(),
            artifactPath = r.getString("artifact_path"),
            sha256 = r.requireString("sha256"),
            updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )
    }
}
