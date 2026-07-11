package net.albayyan.badan.domain

import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString

enum class Aggregation(val code: String) {
    SUM("sum"),
    MEAN("mean"),
    MIN("min"),
    MAX("max"),
    DURATION("duration"),
    LATEST("latest");

    companion object {
        fun fromCode(code: String?): Aggregation = entries.firstOrNull { it.code == code } ?: LATEST
    }
}

/**
 * Instant / short-interval readings kept for lineage and the power explorer. `value` is always
 * in the metric's canonical unit; `originalValue`/`originalUnit` preserve what was received
 * (I: preserve provenance and source lineage).
 */
data class RawSample(
    val id: String,
    val metricId: String,
    val value: Double,          // canonical (SI) value
    val unit: String,           // canonical unit
    val originalValue: Double,
    val originalUnit: String,
    val startAt: Long,
    val endAt: Long? = null,
    val tzId: String,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

/**
 * Normalized aggregates treated as canonical facts (daily steps, nightly time-asleep). The
 * default read layer for charts.
 */
data class IntervalRecord(
    val id: String,
    val metricId: String,
    val value: Double,
    val unit: String,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val aggregation: Aggregation,
    val coverage: Double = 1.0,        // 0...1
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

enum class SessionKind(val code: String) {
    SLEEP_PRIMARY("sleepPrimary"),
    SLEEP_NAP("sleepNap"),
    WORKOUT("workout");

    val isSleep: Boolean get() = this == SLEEP_PRIMARY || this == SLEEP_NAP

    companion object {
        fun fromCode(code: String?): SessionKind = entries.firstOrNull { it.code == code } ?: WORKOUT
    }
}

enum class SleepStage(val code: String) {
    IN_BED("inBed"),
    AWAKE("awake"),
    LIGHT("light"),
    DEEP("deep"),
    REM("rem"),
    ASLEEP_UNSPECIFIED("asleepUnspecified");

    val displayName: LocalizedString
        get() = when (this) {
            IN_BED -> LocalizedString(en = "In bed", ar = "في السرير")
            AWAKE -> LocalizedString(en = "Awake", ar = "مستيقظ")
            LIGHT -> LocalizedString(en = "Light", ar = "خفيف")
            DEEP -> LocalizedString(en = "Deep", ar = "عميق")
            REM -> LocalizedString(en = "REM", ar = "حركة العين")
            ASLEEP_UNSPECIFIED -> LocalizedString(en = "Asleep", ar = "نائم")
        }

    companion object {
        fun fromCode(code: String?): SleepStage = entries.firstOrNull { it.code == code } ?: ASLEEP_UNSPECIFIED
    }
}

/**
 * Typed episode detail carried as a JSON column. `mergedFrom` records which raw session ids
 * were combined during dedup — the lineage the anatomy/provenance sheets render.
 */
@Serializable
data class SessionDetail(
    val mergedFrom: List<String> = emptyList(),
    val timeAsleepSeconds: Double? = null,
    val timeInBedSeconds: Double? = null,
    val stageSummarySeconds: Map<String, Double> = emptyMap(),   // stage rawValue -> seconds
)

/**
 * Sleep / workout episodes. `localNight` (YYYY-MM-DD) is the sleep-attribution key that powers
 * the "last night" query even across DST and post-midnight bedtimes.
 */
data class Session(
    val id: String,
    val kind: SessionKind,
    val subtype: String? = null,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val localNight: String? = null,
    val detail: SessionDetail = SessionDetail(),
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
) {
    val durationSeconds: Double get() = (endAt - startAt) / 1000.0
}

data class SessionStage(
    val sessionId: String,
    val seq: Int,
    val stage: SleepStage,
    val startAt: Long,
    val endAt: Long,
) {
    val id: String get() = "$sessionId:$seq"
    val durationSeconds: Double get() = (endAt - startAt) / 1000.0
}
