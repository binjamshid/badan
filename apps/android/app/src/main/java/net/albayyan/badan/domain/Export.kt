package net.albayyan.badan.domain

import kotlinx.serialization.Serializable
import net.albayyan.badan.core.AppLanguage

enum class ExportFormat(val code: String) {
    CSV("csv"),
    JSON("json");

    val fileExtension: String get() = code

    companion object {
        fun fromCode(code: String?): ExportFormat = entries.firstOrNull { it.code == code } ?: JSON
    }
}

enum class ExportJobStatus(val code: String) {
    PENDING("pending"),
    RUNNING("running"),
    COMPLETED("completed"),
    FAILED("failed");

    companion object {
        fun fromCode(code: String?): ExportJobStatus = entries.firstOrNull { it.code == code } ?: PENDING
    }
}

/**
 * The four-part scope picker as data. `null` list = "all". Raw / derived / suppressed /
 * sensitive are explicitly separable so the export never leaks what the user didn't ask for.
 * Stored as a JSON column.
 */
@Serializable
data class ExportScope(
    val metricIds: List<String>? = null,
    val families: List<String>? = null,
    val startDate: Long? = null,
    val endDate: Long? = null,
    val sourceIds: List<String>? = null,
    val includeRaw: Boolean = true,
    val includeDerived: Boolean = true,
    val includeSuppressed: Boolean = false,
    val includeSensitive: Boolean = false,
    val unitProfile: UnitProfileMode = UnitProfileMode.CANONICAL,
    val language: AppLanguage = AppLanguage.EN,
) {
    companion object {
        val everything = ExportScope(
            includeRaw = true, includeDerived = true,
            includeSuppressed = false, includeSensitive = false,
        )
    }
}

/**
 * Published, versioned manifest. Makes truncation and tampering detectable and the export
 * reproducible from its own description (D-8). Stored as a JSON column.
 */
@Serializable
data class ExportManifest(
    val exportId: String,
    val schemaVersion: String,
    val appVersion: String,
    val platform: String,
    val generatedAt: Long,
    val scope: ExportScope,
    val dateRange: String,
    val displayLanguage: String,
    val unitProfile: String,
    val timezonePolicy: String,
    val dedupPolicy: String,
    val perMetricRowCounts: Map<String, Int>,
    val checksums: Map<String, String>,
    val dataQualityNote: String,
    /**
     * True when the files this manifest describes were wrapped into one `ExportEncryptor`
     * container (always true for an `includeSensitive` export — see ADR-0008) rather than written
     * as plain CSV/JSON. [checksums] above still describe the real plaintext content either way;
     * only how it reached disk changes. Defaulted `false` so manifests persisted before EPIC-06
     * decode unchanged.
     */
    val encrypted: Boolean = false,
    /**
     * The container's filename inside the job's `outputPath` folder (always
     * `ExportEncryptor.CONTAINER_FILE_NAME` today; kept as a manifest field rather than a
     * hardcoded constant lookup so export UI doesn't need to import the encryptor just to know
     * what to look for). `null` when [encrypted] is false.
     */
    val encryptedContainerName: String? = null,
)

data class ExportJob(
    val id: String,
    val scope: ExportScope,
    val format: ExportFormat,
    val status: ExportJobStatus = ExportJobStatus.PENDING,
    val manifest: ExportManifest? = null,
    val outputPath: String? = null,
    val rowCount: Int? = null,
    val startedAt: Long? = null,
    val finishedAt: Long? = null,
    val createdAt: Long,
)
