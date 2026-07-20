package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.ExportAggregation
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportLayout
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.QuickExportPreset
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.Sql
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Why a template write was refused. These are user-facing conditions, not programming errors: the
 * export screen surfaces them as "that name is taken" / "presets can't be edited".
 */
sealed class ExportTemplateError(message: String) : Exception(message) {
    class NameTaken(val name: String) : ExportTemplateError("template name already in use")
    class PresetIsReadOnly(val id: String) : ExportTemplateError("preset templates are read-only")
    class NotFound(val id: String) : ExportTemplateError("no such template")
}

/**
 * `export_templates` (migration v4, plan §9.3) — saved export configurations. Mirror of the iOS
 * `ExportTemplateRepository`, same SQL and same refusals.
 *
 * Soft-delete only (`deleted_at`), like every other convention-column table: a deleted template
 * still has `ExportRun` rows pointing at it, and hard-deleting the row would leave the trust ledger
 * unable to say what those runs exported.
 */
class ExportTemplateRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    /**
     * Insert a new template.
     *
     * The name check and the insert run in one transaction because `idx_export_templates_name` is
     * the real enforcement and it raises a bare SQLite constraint error — accurate, but not
     * something a settings screen can turn into a sentence. Checking first lets the caller get
     * [ExportTemplateError.NameTaken]; doing both in a transaction stops the check from being
     * decorative.
     */
    fun insert(template: ExportTemplate) {
        db.transaction {
            if (!isNameAvailable(template.name, excludingId = null)) {
                throw ExportTemplateError.NameTaken(template.name)
            }
            write(template)
        }
    }

    /**
     * Update an existing template in place.
     *
     * Presets are refused here rather than in the UI: §12 EPIC-10 makes them read-only, and a rule
     * enforced only by a disabled button is a rule that a future screen or intent can walk around.
     */
    fun update(template: ExportTemplate) {
        if (template.isPreset) throw ExportTemplateError.PresetIsReadOnly(template.id)
        db.transaction {
            this.template(template.id) ?: throw ExportTemplateError.NotFound(template.id)
            if (!isNameAvailable(template.name, excludingId = template.id)) {
                throw ExportTemplateError.NameTaken(template.name)
            }
            write(template)
        }
    }

    /**
     * Tombstone a template. Its `ExportRun` history and `ExportCursor` rows are left alone — the run
     * log is a record of what happened, not a view over what currently exists.
     */
    fun softDelete(id: String, at: Long) {
        if (QuickExportPreset.presetIds.contains(id)) throw ExportTemplateError.PresetIsReadOnly(id)
        db.transaction {
            template(id) ?: throw ExportTemplateError.NotFound(id)
            db.run(
                "UPDATE export_templates SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                listOf(at, at, id),
            )
        }
    }

    /**
     * Seed the Quick Export presets, returning how many rows were actually inserted.
     *
     * `INSERT OR IGNORE` makes this idempotent across every launch: the fixed preset ids
     * ([QuickExportPreset.id]) collide with the primary key on the second call and nothing happens.
     * Returning the count rather than `Unit` is the honest part — `OR IGNORE` also swallows a
     * *name* collision with a user-created template called "Quick Export — Last 7 days (CSV)", in
     * which case that preset silently does not exist. A caller comparing the count against
     * `QuickExportPreset.entries.size` on a first run can notice.
     */
    fun seedPresets(now: Long, originDeviceId: String): Int = db.transaction {
        val before = seededPresetCount()
        for (preset in QuickExportPreset.entries) {
            write(preset.template(now, originDeviceId), conflictPolicy = "OR IGNORE")
        }
        seededPresetCount() - before
    }

    /**
     * How many presets currently exist as rows. Counted with a SELECT rather than by trusting the
     * write's changed-row count: an `INSERT OR IGNORE` that was ignored is not reliably
     * distinguishable by row count, and this is the number [seedPresets] reports to a caller
     * deciding whether a preset is missing.
     */
    private fun seededPresetCount(): Int {
        val placeholders = QuickExportPreset.entries.joinToString(", ") { "?" }
        return db.query(
            "SELECT COUNT(*) AS c FROM export_templates WHERE id IN ($placeholders);",
            QuickExportPreset.entries.map { it.id },
        ).firstOrNull()?.getInt("c") ?: 0
    }

    /**
     * The single INSERT. `OR REPLACE` for ordinary writes (id is the ULID the caller already holds,
     * so a replace is an update of the same row); `OR IGNORE` for seeding.
     */
    private fun write(t: ExportTemplate, conflictPolicy: String = "OR REPLACE") {
        db.run(
            """
            INSERT $conflictPolicy INTO export_templates
              (id, name, scope, range_rule, format, aggregation, aggregation_method, layout,
               include_schema_docs, destination_id, created_at, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                t.id, t.name, JsonCoding.encode(t.scope), t.rangeRule.storageValue, t.format.code,
                t.aggregation.storageGranularity, t.aggregation.storageMethod, t.layout.code,
                Sql.bool(t.includeSchemaDocs), t.destinationId, t.createdAt,
            ) + Rows.convParams(t.updatedAt, t.originDeviceId, t.deletedAt),
        )
    }

    // MARK: - Reads

    /**
     * Live templates, presets first then by name — Quick Export's row is the one a casual user is
     * looking for, and burying it under alphabetically-earlier user templates would defeat the
     * "≤3 taps" goal of §12 EPIC-10.
     */
    fun all(): List<ExportTemplate> =
        db.query("SELECT * FROM export_templates WHERE deleted_at IS NULL ORDER BY created_at ASC, name ASC;")
            .map { read(it) }

    fun template(id: String): ExportTemplate? =
        db.query("SELECT * FROM export_templates WHERE id = ? AND deleted_at IS NULL;", listOf(id))
            .firstOrNull()?.let { read(it) }

    fun templateNamed(name: String): ExportTemplate? =
        db.query(NAME_LOOKUP_SQL, listOf(name)).firstOrNull()?.let { read(it) }

    /**
     * Mirrors the partial unique index exactly — including `deleted_at IS NULL`, so a name freed by
     * deleting a template is offered back to the user rather than staying reserved by a row they
     * can no longer see.
     */
    fun isNameAvailable(name: String, excludingId: String?): Boolean {
        val existing = db.query(NAME_LOOKUP_SQL, listOf(name)).firstOrNull()?.getString("id")
            ?: return true
        return existing == excludingId
    }

    companion object {
        /**
         * Kept as a named constant so `ExportTemplateSystemTest` can assert the `deleted_at IS
         * NULL` predicate without a database — this module has no instrumented test source set, and
         * a name lookup that forgot the predicate would silently reserve deleted templates' names
         * forever, which is exactly the bug the partial index was built to avoid.
         */
        const val NAME_LOOKUP_SQL = "SELECT * FROM export_templates WHERE name = ? AND deleted_at IS NULL;"

        fun read(r: Row): ExportTemplate =
            ExportTemplate(
                id = r.requireString("id"),
                name = r.requireString("name"),
                // A scope that fails to decode falls back to `everything`, matching
                // `ExportJobRepository.read`. Note what "everything" does *not* include: its
                // `includeSensitive` and `includeSuppressed` are both false, so a corrupted row can
                // only ever widen toward raw+derived, never toward the sensitive namespace.
                scope = JsonCoding.decodeOrNull<ExportScope>(r.getString("scope")) ?: ExportScope.everything,
                rangeRule = ExportRangeRule.fromStorage(r.getString("range_rule")),
                format = ExportFormat.fromCode(r.getString("format")),
                aggregation = ExportAggregation.from(
                    r.getString("aggregation"), r.getString("aggregation_method"),
                ),
                layout = ExportLayout.fromCode(r.getString("layout")),
                includeSchemaDocs = r.getBool("include_schema_docs"),
                destinationId = r.getString("destination_id"),
                createdAt = r.requireDate("created_at"),
                updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )
    }
}
