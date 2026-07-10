package net.albayyan.badan.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString

/**
 * How a datum entered BADAN. Part of every record's provenance (INVARIANT I1).
 * Mirror of iOS `IngestionPath`. `code`/`@SerialName` both equal the iOS rawValue so the
 * value round-trips through JSON columns and DB columns identically.
 */
@Serializable
enum class IngestionPath(val code: String) {
    @SerialName("platformStore") PLATFORM_STORE("platformStore"),   // HealthKit / Health Connect
    @SerialName("manual") MANUAL("manual"),                          // typed by the user
    @SerialName("import") FILE_IMPORT("import"),
    @SerialName("derived") DERIVED("derived"),                       // computed by BADAN's own engines
    @SerialName("vendor") VENDOR("vendor");                          // reserved: direct vendor API / broker

    val displayLabel: LocalizedString
        get() = when (this) {
            PLATFORM_STORE -> LocalizedString(en = "Health app", ar = "تطبيق الصحة")
            MANUAL -> LocalizedString(en = "Entered by you", ar = "أدخلتها بنفسك")
            FILE_IMPORT -> LocalizedString(en = "Imported", ar = "مستورد")
            DERIVED -> LocalizedString(en = "Computed by BADAN", ar = "محسوب بواسطة بدن")
            VENDOR -> LocalizedString(en = "Connected service", ar = "خدمة متصلة")
        }

    companion object {
        fun fromCode(code: String?): IngestionPath = entries.firstOrNull { it.code == code } ?: MANUAL
    }
}

/** Honest quality annotations that travel with a datum and surface in power mode. */
@Serializable
enum class QualityFlag(val code: String) {
    @SerialName("gapFilled") GAP_FILLED("gapFilled"),
    @SerialName("artifactSuspected") ARTIFACT_SUSPECTED("artifactSuspected"),
    @SerialName("userCorrected") USER_CORRECTED("userCorrected"),
    @SerialName("provisionalBaseline") PROVISIONAL_BASELINE("provisionalBaseline"),
    @SerialName("estimate") ESTIMATE("estimate"),
    @SerialName("tzAssumed") TZ_ASSUMED("tzAssumed"),
    @SerialName("lowCoverage") LOW_COVERAGE("lowCoverage");

    companion object {
        fun fromCode(code: String?): QualityFlag = entries.firstOrNull { it.code == code } ?: ESTIMATE
    }
}

/**
 * Provenance is embedded, denormalized structure on every health datum's own row (D-3):
 * never a join, never optional. This is what makes BADAN's "where did this number come from"
 * promise mechanically true rather than aspirational. Stored as a JSON column.
 */
@Serializable
data class Provenance(
    val sourceId: String,
    val deviceId: String? = null,
    val ingestionPath: IngestionPath,
    /** Upstream system's own id — the idempotency key for re-ingest (I: no duplicates). */
    val externalId: String? = null,
    val importBatchId: String? = null,
    val measuredAt: Long,
    val measuredTimezone: String,   // IANA tz id, e.g. "Asia/Riyadh"
    val recordedAt: Long,
    val ingestedAt: Long,
    val algorithmVersionId: String? = null,
    val qualityFlags: List<QualityFlag> = emptyList(),
    /**
     * When set, this record was dedup-suppressed; points at the winning record's id.
     * Suppress, never delete (INVARIANT I3).
     */
    val suppressedBy: String? = null,
) {
    val isSuppressed: Boolean get() = suppressedBy != null
}
