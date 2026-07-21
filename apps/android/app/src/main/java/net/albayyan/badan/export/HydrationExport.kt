package net.albayyan.badan.export

import net.albayyan.badan.domain.hydration.BeverageDefinition
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoal

/**
 * The hydration slice of an export: the live ledger, the day summaries, the goals, and the beverage
 * catalog the entries reference. Assembled by a caller and handed to [JsonBundleWriter] (as
 * `logs.hydration`) and [HydrationCsvWriter] (as its own CSV set). The writers do not re-derive
 * liveness — they serialize what they are given. Mirror of iOS `HydrationExportPayload`.
 */
data class HydrationExportPayload(
    val entries: List<HydrationEntry> = emptyList(),
    val summaries: List<HydrationDailySummary> = emptyList(),
    val goals: List<HydrationGoal> = emptyList(),
    val beverages: List<BeverageDefinition> = emptyList(),
) {
    val isEmpty: Boolean get() = entries.isEmpty() && summaries.isEmpty() && goals.isEmpty() && beverages.isEmpty()
}

/**
 * What the hydration export withholds by default. §7A.1 makes the default export a **privacy default,
 * structural**: notes, and any fasting / cycle / pregnancy context, location, and reminder history,
 * are excluded unless the user explicitly opts each back in. Everything except [includeNotes] is a
 * fixed exclusion this phase because the module does not yet store those contexts — they are listed
 * so the redaction manifest tells the reader exactly what a default file leaves out. Mirror of iOS
 * `HydrationRedactionPolicy`.
 */
data class HydrationRedactionPolicy(
    /** The one stored field redacted by default. Off = the `note` column/key is absent entirely. */
    val includeNotes: Boolean = false,
) {
    /** The fields a default export excludes, for the redaction manifest. */
    val excludedFields: List<String>
        get() = buildList {
            if (!includeNotes) add("note")
            addAll(listOf("fasting_context", "cycle_context", "pregnancy_context", "location", "reminder_history"))
        }

    companion object {
        val DEFAULT = HydrationRedactionPolicy()
    }
}

/**
 * The redaction manifest, as a [CanonicalJson] value. Shared by [JsonBundleWriter] (embedded in
 * `logs.hydration.redaction`) and [HydrationCsvWriter] (written standalone) so both emit identical
 * bytes. Mirror of iOS `HydrationExportJSON.redaction`.
 */
object HydrationExportJson {
    fun redaction(policy: HydrationRedactionPolicy): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "notes_included" to CanonicalJson.Bool(policy.includeNotes),
            "excluded_by_default" to CanonicalJson.Arr(policy.excludedFields.map { CanonicalJson.Str(it) }),
        ),
    )
}

/**
 * Renders the hydration export's CSV set — one small, self-describing table per aspect (entries,
 * summaries, goals, sources), separate from the 26-column main contract. Escaping and number/timestamp
 * formatting are borrowed from [CsvWriter] so hydration cells format identically to every other cell.
 *
 * The default set **excludes notes structurally**: the `note` column exists only when the policy opts
 * it in. Mirror of iOS `HydrationCSVWriter`.
 */
class HydrationCsvWriter(private val policy: HydrationRedactionPolicy = HydrationRedactionPolicy.DEFAULT) {

    /** The named CSV files for one export (plus the redaction manifest). */
    fun files(payload: HydrationExportPayload): Map<String, String> = mapOf(
        "hydration_entries.csv" to entriesCsv(payload.entries),
        "hydration_summaries.csv" to summariesCsv(payload.summaries),
        "hydration_goals.csv" to goalsCsv(payload.goals),
        "hydration_sources.csv" to sourcesCsv(payload.entries),
        "hydration_redaction.json" to redactionManifest(),
    )

    fun entriesCsv(entries: List<HydrationEntry>): String {
        val columns = buildList {
            addAll(
                listOf(
                    "record_id", "original_id", "supersedes", "revision", "volume_ml", "canonical_unit",
                    "fluid_type", "beverage_id", "container_id", "occurred_at", "timezone",
                    "ingestion_path", "source_app", "updated_at", "deleted_at",
                ),
            )
            if (policy.includeNotes) add("note")
        }
        val sb = StringBuilder(row(columns))
        for (e in entries) {
            val cells = buildList {
                addAll(
                    listOf(
                        e.id, e.originalId, e.supersedes ?: "", e.revision.toString(),
                        CsvWriter.decimal(e.volumeMl), "mL", e.fluidType, e.beverageId ?: "", e.containerId ?: "",
                        CsvWriter.iso8601(e.occurredAt, e.tzId), e.tzId,
                        e.provenance.ingestionPath.code, e.provenance.sourceId,
                        CsvWriter.iso8601(e.updatedAt, e.tzId),
                        e.deletedAt?.let { CsvWriter.iso8601(it, e.tzId) } ?: "",
                    ),
                )
                if (policy.includeNotes) add(e.note ?: "")
            }
            sb.append(CsvWriter.NEWLINE).append(row(cells))
        }
        return sb.append(CsvWriter.NEWLINE).toString()
    }

    fun summariesCsv(summaries: List<HydrationDailySummary>): String {
        val sb = StringBuilder(
            row(listOf("day_key", "timezone", "manual_ml", "imported_ml", "estimated_ml", "total_ml", "entry_count", "goal_kind", "goal_target_ml", "goal_progress_pct")),
        )
        for (s in summaries) {
            sb.append(CsvWriter.NEWLINE).append(
                row(
                    listOf(
                        s.dayKey, s.tzId, CsvWriter.decimal(s.manualMl), CsvWriter.decimal(s.importedMl),
                        CsvWriter.decimal(s.estimatedMl), CsvWriter.decimal(s.totalMl), s.entryCount.toString(),
                        s.goalKind.code, s.goalTargetMl?.let { CsvWriter.decimal(it) } ?: "",
                        s.goalProgressPct?.let { CsvWriter.decimal(it) } ?: "",
                    ),
                ),
            )
        }
        return sb.append(CsvWriter.NEWLINE).toString()
    }

    fun goalsCsv(goals: List<HydrationGoal>): String {
        val sb = StringBuilder(row(listOf("goal_id", "kind", "target_ml", "day_type", "active", "created_at")))
        for (g in goals) {
            sb.append(CsvWriter.NEWLINE).append(
                row(
                    listOf(
                        g.id, g.kind.code, g.targetMl?.let { CsvWriter.decimal(it) } ?: "", g.dayType ?: "",
                        if (g.active) "true" else "false", CsvWriter.iso8601(g.createdAt, "UTC"),
                    ),
                ),
            )
        }
        return sb.append(CsvWriter.NEWLINE).toString()
    }

    fun sourcesCsv(entries: List<HydrationEntry>): String {
        val paths = HashMap<String, MutableSet<String>>()
        val counts = HashMap<String, Int>()
        for (e in entries) {
            paths.getOrPut(e.provenance.sourceId) { mutableSetOf() }.add(e.provenance.ingestionPath.code)
            counts[e.provenance.sourceId] = (counts[e.provenance.sourceId] ?: 0) + 1
        }
        val sb = StringBuilder(row(listOf("source_app", "ingestion_paths", "entry_count")))
        for (sourceId in paths.keys.sorted()) {
            sb.append(CsvWriter.NEWLINE).append(
                row(listOf(sourceId, paths[sourceId]!!.sorted().joinToString(";"), (counts[sourceId] ?: 0).toString())),
            )
        }
        return sb.append(CsvWriter.NEWLINE).toString()
    }

    /** Byte-matches the JSON bundle's embedded `logs.hydration.redaction`. */
    fun redactionManifest(): String = HydrationExportJson.redaction(policy).render()

    private fun row(cells: List<String>): String = cells.joinToString(",") { CsvWriter.escape(it) }
}
