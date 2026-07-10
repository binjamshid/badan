package net.albayyan.badan.domain

import net.albayyan.badan.core.LocalizedString

/**
 * Where data comes from — a platform store, a manual entry channel, an import, or (later) a
 * vendor. Hidden ≠ deleted: a hidden source stops contributing but its history stays.
 */
enum class SourceType(val code: String) {
    HEALTHKIT("healthkit"),
    HEALTH_CONNECT("healthConnect"),
    MANUAL("manual"),
    FILE_IMPORT("import"),
    VENDOR("vendor");

    companion object {
        fun fromCode(code: String?): SourceType = entries.firstOrNull { it.code == code } ?: MANUAL
    }
}

enum class SourceStatus(val code: String) {
    ACTIVE("active"),
    REVOKED("revoked"),
    HIDDEN("hidden");

    companion object {
        fun fromCode(code: String?): SourceStatus = entries.firstOrNull { it.code == code } ?: ACTIVE
    }
}

data class Source(
    val id: String,
    val type: SourceType,
    val displayName: String,
    val platformBundleId: String? = null,
    val status: SourceStatus = SourceStatus.ACTIVE,
    val connectedAt: Long? = null,
    val lastDeliveryAt: Long? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

data class Device(
    val id: String,
    val sourceId: String,
    val name: String,
    val model: String? = null,
    val firstSeen: Long,
    val lastSeen: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

/**
 * Permission is a first-class UI state, not an error. This drives honest granted / denied /
 * partial matrices in Settings and Onboarding.
 */
enum class PermissionStatus(val code: String) {
    NOT_REQUESTED("notRequested"),
    GRANTED("granted"),
    DENIED("denied"),
    PARTIAL("partial"),
    REVOKED("revoked");

    val displayLabel: LocalizedString
        get() = when (this) {
            NOT_REQUESTED -> LocalizedString(en = "Not requested", ar = "لم يُطلب")
            GRANTED -> LocalizedString(en = "Connected", ar = "متصل")
            DENIED -> LocalizedString(en = "Not allowed", ar = "غير مسموح")
            PARTIAL -> LocalizedString(en = "Partly allowed", ar = "مسموح جزئياً")
            REVOKED -> LocalizedString(en = "Turned off", ar = "متوقف")
        }

    companion object {
        fun fromCode(code: String?): PermissionStatus = entries.firstOrNull { it.code == code } ?: NOT_REQUESTED
    }
}

data class PermissionState(
    val store: String,        // "healthkit" | "healthConnect"
    val platformType: String, // e.g. "sleepAnalysis"
    val status: PermissionStatus,
    val lastCheckedAt: Long,
    val lastReadAt: Long? = null,
) {
    val id: String get() = "$store:$platformType"
}

/**
 * The single local user. BADAN MVP has no accounts; the profile is device-local and exists to
 * hold demographics used only for on-device derivations (e.g. BMI needs height).
 */
data class UserProfile(
    val id: String,
    val displayName: String? = null,
    val heightMeters: Double? = null,
    val birthYear: Int? = null,
    val biologicalContextNote: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
)
