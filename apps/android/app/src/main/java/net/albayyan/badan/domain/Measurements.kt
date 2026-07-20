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
 * Ingested-workout totals, in canonical units (energy kJ, distance m, HR bpm, elevation m) so a
 * reader never has to consult a unit column to compare two workouts. Every field is nullable
 * because a source that did not measure something must not be made to say zero.
 */
@Serializable
data class WorkoutTotals(
    val energyKj: Double? = null,
    val distanceM: Double? = null,
    val avgHrBpm: Double? = null,
    val maxHrBpm: Double? = null,
    val elevationGainM: Double? = null,
)

/**
 * The typed workout payload inside [SessionDetail] (plan §9.1).
 *
 * Versioned by [version] rather than by the enclosing schema: `sessions.detail` is a JSON column
 * precisely so its shape can move without a migration, and a reader five versions from now needs
 * to know which shape it is holding. The version travels with the payload, not with the table.
 *
 * [routeRef] is a *reference*, never the route itself. Embedding coordinates here would put
 * location data inside a column that every non-route reader already loads — the sessions list,
 * the export writer, the widget snapshot — and quietly defeat the separate route consent gate
 * (plan §4 rule 11). The route lives in `workout_routes`/`route_points` where its own toggle
 * governs it; this is only the pointer.
 */
@Serializable
data class WorkoutDetail(
    val version: String = "workout.detail.v1",
    /** Health Connect exercise type / HealthKit activity type, normalized to a shared vocabulary. */
    val activityType: String? = null,
    val totals: WorkoutTotals = WorkoutTotals(),
    /** The upstream session id, kept so a workout can be traced back to the writing app's record. */
    val sourceWorkoutId: String? = null,
    val routeRef: String? = null,
)

/**
 * Typed episode detail carried as a JSON column. `mergedFrom` records which raw session ids
 * were combined during dedup — the lineage the anatomy/provenance sheets render.
 *
 * Sleep fields and [workout] are mutually exclusive in practice but not by type: one nullable
 * sub-object is cheaper to evolve than a sealed hierarchy that every JSON reader on two platforms
 * would have to agree on the discriminator for. `JsonCoding` runs with `explicitNulls = false`,
 * so a sleep session's stored JSON is byte-identical to what it was before [workout] existed —
 * which is what keeps this an additive change rather than a silent rewrite of every stored row.
 */
@Serializable
data class SessionDetail(
    val mergedFrom: List<String> = emptyList(),
    val timeAsleepSeconds: Double? = null,
    val timeInBedSeconds: Double? = null,
    val stageSummarySeconds: Map<String, Double> = emptyMap(),   // stage rawValue -> seconds
    val workout: WorkoutDetail? = null,
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

/**
 * A workout's GPS trace (plan §9.2). The route — not the point — is the unit of consent, the unit
 * of provenance (I1), and the unit of replacement: points are deleted and re-inserted wholesale
 * when a route is re-read, so there is never a half-updated trace.
 *
 * [consentSnapshot] is the route-consent state at ingest, not now. A later toggle-off must not
 * retroactively relabel rows captured while consent was genuinely granted; export gating reads
 * the *current* toggle. See the `workout_routes` comment in Schema.kt.
 *
 * [pointCount] is stored rather than counted on read so a list of workouts can show "1,284 points"
 * without loading a single coordinate — which is also what lets a route summary render on a
 * surface that has no right to the points themselves.
 */
data class WorkoutRoute(
    val id: String,
    val sessionId: String,
    val pointCount: Int,
    val startAt: Long,
    val endAt: Long,
    val consentSnapshot: String,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

/**
 * One GPS fix. Deliberately carries no provenance and no convention columns — it inherits both
 * from its [WorkoutRoute]. See the `route_points` comment in Schema.kt for why that is load-
 * bearing in both directions rather than an omission.
 */
data class RoutePoint(
    val routeId: String,
    val seq: Int,
    val lat: Double,
    val lon: Double,
    val altitudeM: Double? = null,
    val horizontalAccuracyM: Double? = null,
    val timestamp: Long,
)
