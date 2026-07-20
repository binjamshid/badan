package net.albayyan.badan.platform.health

import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.SourceType

/**
 * Platform-neutral DTOs and the port BADAN reads health data through. The real
 * HealthKit/Health Connect adapters and the FakeHealthStore all conform to this, so the
 * ingestion pipeline is identical regardless of source (the seam that keeps UI decoupled
 * from any vendor schema). This is an MVP subset of blueprint §51.1.
 *
 * Timestamps are epoch milliseconds (Long); durations stay in seconds (Double).
 */
data class HealthDateRange(val start: Long, val end: Long)

enum class HealthAvailability { available, notInstalled, unsupported }

data class SourceDescriptor(
    val id: String,
    val displayName: String,
    val type: SourceType,
    val bundleId: String? = null,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val deviceModel: String? = null,
    /** Higher wins dedup ties (I4: device wins by source priority for non-manual metrics). */
    val priority: Int,
)

data class SampleDto(
    val metricId: String,
    val value: Double,
    val unit: String,
    val start: Long,
    val end: Long? = null,
    val tz: String,
    val sourceId: String,
    val deviceId: String? = null,
    val externalId: String,
    /**
     * Honest annotations travelling with this reading — notably [QualityFlag.SAMPLE_DATA], which
     * marks a row nobody measured. Mirrors iOS's DTO `qualityFlags`; Android's DTOs carried no
     * flags field at all, so a fabricated row had no way to say so between the store that
     * invented it and the database it landed in.
     */
    val qualityFlags: List<QualityFlag> = emptyList(),
)

data class IntervalDto(
    val metricId: String,
    val value: Double,
    val unit: String,
    val start: Long,
    val end: Long,
    val tz: String,
    val aggregation: Aggregation,
    val sourceId: String,
    val deviceId: String? = null,
    val externalId: String,
    /**
     * Honest annotations travelling with this reading — notably [QualityFlag.SAMPLE_DATA], which
     * marks a row nobody measured. Mirrors iOS's DTO `qualityFlags`; Android's DTOs carried no
     * flags field at all, so a fabricated row had no way to say so between the store that
     * invented it and the database it landed in.
     */
    val qualityFlags: List<QualityFlag> = emptyList(),
)

data class StageDto(
    val stage: SleepStage,
    val start: Long,
    val end: Long,
)

/**
 * Workout totals as the source reported them, in the source's own units (canonicalized by
 * `IngestionPipeline` before they reach `SessionDetail`). Every field is optional because every
 * field genuinely is: a pool swim has no distance from GPS, an indoor bike may report energy but
 * no heart rate, and a manually-started session may report nothing but its duration. A zero here
 * would be a claim ("you burned 0 kJ"); null is the truth ("the source did not say").
 */
data class WorkoutTotalsDto(
    val energyKj: Double? = null,
    val distanceM: Double? = null,
    val avgHrBpm: Double? = null,
    val maxHrBpm: Double? = null,
    val elevationGainM: Double? = null,
)

/**
 * One GPS fix inside a workout route. Carries no provenance of its own — it inherits the parent
 * [RouteDto]'s, which is the shape `route_points` is built for (see Schema.kt v4).
 */
data class RoutePointDto(
    val seq: Int,
    val lat: Double,
    val lon: Double,
    val altitudeM: Double? = null,
    val horizontalAccuracyM: Double? = null,
    val timestamp: Long,
)

/**
 * A workout's GPS trace, read only when route consent is granted.
 *
 * [sessionExternalId] rather than a session *row* id: routes are read from the platform in the
 * same pass as the workouts they belong to, before any BADAN ULID exists for the session, so the
 * link is resolved against the upstream identity at write time (`RouteRepository.upsertRoute`).
 *
 * [consentSnapshot] is the route-consent state as it stood when these points were read, recorded
 * on the row per plan §9.2. It answers "was this row allowed to exist when it was written", which
 * stays a real question after the user later toggles consent off — export gating reads the
 * *current* toggle, never this.
 */
data class RouteDto(
    val sessionExternalId: String,
    val externalId: String,
    val sourceId: String,
    val deviceId: String? = null,
    val start: Long,
    val end: Long,
    val tz: String,
    val consentSnapshot: String,
    val points: List<RoutePointDto>,
    val qualityFlags: List<QualityFlag> = emptyList(),
)

/**
 * What a source can honestly deliver for one platform type, surfaced to the backfill banner.
 *
 * A stated Phase-0 exit criterion (plan §14): Health Connect serves 30 days by default and BADAN
 * asks for 90, so without this the app shows a 90-day chart that is two-thirds empty and lets the
 * user conclude their watch was not recording. [achievableStart] is what the platform will
 * actually serve; [requestedStart] is what BADAN asked for. When they differ the UI says so.
 *
 * [incremental] distinguishes "this sync only fetched what changed since last time" from "this
 * sync re-read the whole window" — the difference between a fast steady-state sync and a
 * token-expiry recovery, and the honest answer to "why did that take so long this once".
 */
data class BackfillWindow(
    val platformType: String,
    val requestedStart: Long,
    val achievableStart: Long,
    val end: Long,
    val incremental: Boolean,
) {
    /** True when the source cannot serve everything the caller asked for. */
    val isTruncated: Boolean get() = achievableStart > requestedStart
}

data class SessionDto(
    val kind: SessionKind,
    val subtype: String? = null,
    val start: Long,
    val end: Long,
    val tz: String,
    val sourceId: String,
    val deviceId: String? = null,
    val externalId: String,
    val stages: List<StageDto> = emptyList(),
    val timeAsleepSeconds: Double? = null,
    val timeInBedSeconds: Double? = null,
    /** Set for [SessionKind.WORKOUT] only; null for sleep. See [WorkoutTotalsDto]. */
    val activityType: String? = null,
    val totals: WorkoutTotalsDto? = null,
    /**
     * Honest annotations travelling with this reading — notably [QualityFlag.SAMPLE_DATA], which
     * marks a row nobody measured. Mirrors iOS's DTO `qualityFlags`; Android's DTOs carried no
     * flags field at all, so a fabricated row had no way to say so between the store that
     * invented it and the database it landed in.
     */
    val qualityFlags: List<QualityFlag> = emptyList(),
)

interface HealthStorePort {
    fun availability(): HealthAvailability
    fun sourceDescriptors(): List<SourceDescriptor>
    fun readSamples(range: HealthDateRange): List<SampleDto>
    fun readIntervals(range: HealthDateRange): List<IntervalDto>
    fun readSessions(range: HealthDateRange): List<SessionDto>

    /**
     * GPS traces for the workouts [readSessions] returned in the same pass.
     *
     * Defaulted to empty rather than abstract so that a store with no location data (the seed
     * store, any future import path) is not forced to write a stub that says "no" — the honest
     * default for a source that has no routes to give.
     *
     * Consent is the *implementation's* responsibility, not the pipeline's: a store that has not
     * been granted route access returns empty here, and the pipeline never learns there was
     * anything to ask about. That keeps the location gate at the one boundary that can actually
     * enforce it (plan §4 rule 11, §9.2).
     */
    fun readRoutes(range: HealthDateRange): List<RouteDto> = emptyList()

    /**
     * Persist whatever incremental-read cursor this store advanced during the reads above
     * (Health Connect changes tokens; `HKQueryAnchor`s on iOS).
     *
     * Split from the reads themselves so a cursor can never advance past data whose write has not
     * committed — the DATA-08 discipline iOS arrived at the hard way. See
     * `HealthConnectAdapter.commitPendingReadState` for the transaction reasoning on this
     * platform, and `IngestionPipeline.ingest` for where it is called.
     *
     * A no-op default: a store that reads a fixed generated history (the seed store) has no
     * cursor to advance, and forcing it to declare that would be ceremony, not clarity.
     */
    fun commitPendingReadState() {}

    /**
     * What the reads above could honestly cover, per platform type — see [BackfillWindow].
     *
     * Populated by the read calls for the range they were given, so it is a report on the sync
     * that just happened rather than a prediction. Empty by default: a store that can serve any
     * range it is asked for has nothing to disclose.
     */
    fun backfillWindows(): List<BackfillWindow> = emptyList()
}
