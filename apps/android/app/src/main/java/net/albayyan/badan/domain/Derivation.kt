package net.albayyan.badan.domain

import kotlinx.serialization.Serializable

/**
 * A frozen algorithm identity. Derived values carry their algorithm+version so a number can
 * always be traced to the exact method that produced it, and recompute is auditable.
 */
data class AlgorithmVersion(
    val algorithmId: String,     // e.g. "baseline.rolling_median_mad"
    val semver: String,          // e.g. "1.0.0"
    val params: Map<String, Double> = emptyMap(),
    val introducedIn: String,    // app version
) {
    val id: String get() = "$algorithmId@$semver"
}

/**
 * The records that fed a derived value — renders the "anatomy" sheet that answers "why is it
 * saying that?" (VS-4). Append-only alongside the DerivedValue. Stored as a JSON column.
 */
@Serializable
data class InputManifest(
    val id: String,
    val inputs: List<Input>,
) {
    @Serializable
    data class Input(
        val recordId: String,
        val metricId: String,
        val value: Double,
        val weight: Double? = null,
    )
}

/**
 * An append-only interpretation of raw facts (D-2). Recompute appends a new row and the latest
 * `computedAt` wins on read; older rows are never overwritten (INVARIANT I2).
 */
data class DerivedValue(
    val id: String,
    val metricId: String,
    val value: Double,
    val unit: String,
    val periodKey: String,          // "day:2026-07-10" | "session:<ulid>" | "week:2026-W28"
    val confidence: Double? = null,
    val provisional: Boolean = false,
    val algorithmId: String,
    val algorithmVersion: String,
    val inputManifestId: String? = null,
    val computedAt: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

enum class BaselineMethod(val code: String) {
    MEDIAN_MAD("medianMAD");

    companion object {
        fun fromCode(code: String?): BaselineMethod = entries.firstOrNull { it.code == code } ?: MEDIAN_MAD
    }
}

/**
 * A materialized "personal normal" band. Center ± spread define the band; `provisional` stays
 * true until there are enough points to be honest about (I: wellness-safe honesty).
 */
data class Baseline(
    val id: String,
    val metricId: String,
    val covariateContext: String = "default",   // MVP always "default"
    val windowDays: Int,
    val method: BaselineMethod = BaselineMethod.MEDIAN_MAD,
    val center: Double,
    val spread: Double,              // MAD
    val bandLow: Double,
    val bandHigh: Double,
    val nPoints: Int,
    val provisional: Boolean,
    val algorithmVersion: String,
    val validFrom: Long,
    val computedAt: Long,
    val unit: String,
) {
    /** Where a value sits relative to the personal band — never "good/bad", only position. */
    enum class Position(val code: String) {
        BELOW("below"),
        WITHIN("within"),
        ABOVE("above");
    }

    fun position(of: Double): Position {
        if (of < bandLow) return Position.BELOW
        if (of > bandHigh) return Position.ABOVE
        return Position.WITHIN
    }

    /**
     * Standardized deviation from center (robust z). Used by the insight engine and to scale
     * confidence to data quality.
     */
    fun z(of: Double): Double {
        if (spread <= 0) return 0.0
        // 1.4826 makes MAD a consistent estimator of sigma for normal data.
        return (of - center) / (1.4826 * spread)
    }
}
