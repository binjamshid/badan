package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.storage.sqlite.Row

/**
 * Shared column lists and (de)serialization for the embedded provenance + convention
 * columns that recur across measurement tables. Keeping these in one place is what stops
 * the 12 provenance columns from drifting between INSERTs.
 */
object Rows {
    const val provColumns =
        "source_id, device_id, ingestion_path, external_id, batch_id, measured_at, measured_tz, recorded_at, ingested_at, algorithm_version_id, quality_flags, suppressed_by"
    const val provPlaceholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"
    const val convColumns = "updated_at, origin_device_id, deleted_at"
    const val convPlaceholders = "?, ?, ?"

    fun provParams(p: Provenance): List<Any?> {
        val flags = if (p.qualityFlags.isEmpty()) null else p.qualityFlags.joinToString(";") { it.code }
        return listOf(
            p.sourceId,
            p.deviceId,
            p.ingestionPath.code,
            p.externalId,
            p.importBatchId,
            p.measuredAt,
            p.measuredTimezone,
            p.recordedAt,
            p.ingestedAt,
            p.algorithmVersionId,
            flags,
            p.suppressedBy,
        )
    }

    /** Precomputed once instead of a linear `QualityFlag.entries` scan per flag per row. */
    private val qualityFlagsByCode: Map<String, QualityFlag> = QualityFlag.entries.associateBy { it.code }

    fun readProvenance(row: Row): Provenance {
        val flags = (row.getString("quality_flags") ?: "")
            .split(";")
            .filter { it.isNotEmpty() }
            .mapNotNull { code -> qualityFlagsByCode[code] }
        return Provenance(
            sourceId = row.requireString("source_id"),
            deviceId = row.getString("device_id"),
            ingestionPath = IngestionPath.fromCode(row.requireString("ingestion_path")),
            externalId = row.getString("external_id"),
            importBatchId = row.getString("batch_id"),
            measuredAt = row.requireDate("measured_at"),
            measuredTimezone = row.requireString("measured_tz"),
            recordedAt = row.requireDate("recorded_at"),
            ingestedAt = row.requireDate("ingested_at"),
            algorithmVersionId = row.getString("algorithm_version_id"),
            qualityFlags = flags,
            suppressedBy = row.getString("suppressed_by"),
        )
    }

    fun convParams(updatedAt: Long, originDeviceId: String, deletedAt: Long?): List<Any?> =
        listOf(updatedAt, originDeviceId, deletedAt)
}
