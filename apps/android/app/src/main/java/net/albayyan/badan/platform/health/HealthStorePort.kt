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
}
