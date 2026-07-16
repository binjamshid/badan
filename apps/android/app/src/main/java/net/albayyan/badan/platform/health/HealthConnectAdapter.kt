package net.albayyan.badan.platform.health

import android.content.Context
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.response.ReadRecordsResponse
import androidx.health.connect.client.time.TimeRangeFilter
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.SourceType
import java.time.Instant
import java.util.TimeZone
import kotlin.reflect.KClass

/**
 * Real Health Connect integration. Conforms to the same [HealthStorePort] the FakeHealthStore
 * does, so the ingestion pipeline is identical regardless of source. Reads map Health Connect
 * records to BADAN's canonical DTOs (steps, active energy, distance, heart rate, resting HR, HRV,
 * respiratory rate, SpO2, sleep sessions with stages).
 *
 * It is entitlement-safe: the client is created lazily and guarded, so with no provider installed
 * (or no permissions granted) reads simply return empty rather than crashing. Timezone attribution
 * uses the device's current zone (Health Connect stores offsets, not IANA names) — a pragmatic
 * approximation documented in `docs/android-parity-status.md`.
 */
class HealthConnectAdapter(private val context: Context) : HealthStorePort {

    private val client: HealthConnectClient? by lazy {
        runCatching { HealthConnectClient.getOrCreate(context) }.getOrNull()
    }

    private val tz: String get() = TimeZone.getDefault().id

    /**
     * Map Health Connect's SDK status onto BADAN's three states.
     *
     * `SDK_UNAVAILABLE` used to fall into `else -> unsupported`, which told a large share of real
     * users their phone couldn't do this at all. It usually means the opposite: below Android 14
     * Health Connect is a separate Play app, so "unavailable" is simply "not installed yet" — one
     * install away, and the UI already has a `notInstalled` branch that offers exactly that. Only
     * on Android 14+, where Health Connect ships as part of the platform, does `SDK_UNAVAILABLE`
     * genuinely mean this device cannot support it (e.g. an Android Go or otherwise stripped
     * build), and there is nothing to install.
     */
    override fun availability(): HealthAvailability =
        when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_AVAILABLE -> HealthAvailability.available
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthAvailability.notInstalled
            HealthConnectClient.SDK_UNAVAILABLE ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    HealthAvailability.notInstalled
                } else {
                    HealthAvailability.unsupported
                }
            else -> HealthAvailability.unsupported
        }

    override fun sourceDescriptors(): List<SourceDescriptor> = listOf(
        SourceDescriptor(
            id = "healthConnect", displayName = "Health Connect", type = SourceType.HEALTH_CONNECT,
            bundleId = "com.google.android.apps.healthdata", priority = 80,
        ),
    )

    /** Permissions granted so far (empty if HC unavailable). Denial is first-class state, not error. */
    suspend fun grantedPermissions(): Set<String> =
        client?.permissionController?.getGrantedPermissions() ?: emptySet()

    suspend fun hasAllPermissions(): Boolean = grantedPermissions().containsAll(permissions)

    // MARK: - Reads (synchronous port; the suspend HC calls are bridged with runBlocking, which is
    // safe because ingestion runs off the main thread).

    override fun readSamples(range: HealthDateRange): List<SampleDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        coroutineScope {
            val heartRate = async { readHeartRate(range) }
            val spo2 = async { readSpo2(range) }
            heartRate.await() + spo2.await()
        }
    }

    override fun readIntervals(range: HealthDateRange): List<IntervalDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        coroutineScope {
            val steps = async { readSteps(range) }
            val activeEnergy = async { readActiveEnergy(range) }
            val distance = async { readDistance(range) }
            val restingHeartRate = async { readRestingHeartRate(range) }
            val hrv = async { readHrv(range) }
            val respiratoryRate = async { readRespiratoryRate(range) }
            steps.await() + activeEnergy.await() + distance.await() + restingHeartRate.await() +
                hrv.await() + respiratoryRate.await()
        }
    }

    override fun readSessions(range: HealthDateRange): List<SessionDto> = runBlocking {
        if (client == null) return@runBlocking emptyList()
        readSleep(range)
    }

    // MARK: - Paged record reader

    private suspend fun <T : Record> readAll(type: KClass<T>, range: HealthDateRange): List<T> {
        val c = client ?: return emptyList()
        val out = ArrayList<T>()
        var token: String? = null
        do {
            val response = readPageWithRetry(c, type, range, token) ?: break
            out.addAll(response.records)
            token = response.pageToken
        } while (token != null)
        return out
    }

    /**
     * Reads one page, retrying transient failures (provider hiccups/IO) with a short backoff
     * before giving up. A [SecurityException] means the permission was denied/revoked — that's
     * not transient, so it's not retried and the page loop is terminated immediately.
     */
    private suspend fun <T : Record> readPageWithRetry(
        c: HealthConnectClient,
        type: KClass<T>,
        range: HealthDateRange,
        token: String?,
    ): ReadRecordsResponse<T>? {
        var attempt = 0
        while (true) {
            val result = runCatching {
                c.readRecords(
                    ReadRecordsRequest(
                        recordType = type,
                        timeRangeFilter = TimeRangeFilter.between(
                            Instant.ofEpochMilli(range.start), Instant.ofEpochMilli(range.end)
                        ),
                        pageToken = token,
                    )
                )
            }
            result.getOrNull()?.let { return it }
            val error = result.exceptionOrNull() ?: return null
            if (error is SecurityException || attempt >= maxPageReadRetries) return null
            attempt += 1
            delay(pageReadRetryBaseDelayMs * (1L shl (attempt - 1)))
        }
    }

    // MARK: - Mappers

    private fun source(meta: Metadata) = meta.dataOrigin.packageName
    private fun device(meta: Metadata) = meta.device?.model

    private suspend fun readSteps(range: HealthDateRange) = readAll(StepsRecord::class, range).map {
        IntervalDto(MetricId.steps, it.count.toDouble(), "count", it.startTime.toEpochMilli(),
            it.endTime.toEpochMilli(), tz, Aggregation.SUM, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readActiveEnergy(range: HealthDateRange) = readAll(ActiveCaloriesBurnedRecord::class, range).map {
        IntervalDto(MetricId.activeEnergy, it.energy.inKilocalories, "kcal", it.startTime.toEpochMilli(),
            it.endTime.toEpochMilli(), tz, Aggregation.SUM, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readDistance(range: HealthDateRange) = readAll(DistanceRecord::class, range).map {
        IntervalDto(MetricId.distance, it.distance.inMeters, "m", it.startTime.toEpochMilli(),
            it.endTime.toEpochMilli(), tz, Aggregation.SUM, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readRestingHeartRate(range: HealthDateRange) = readAll(RestingHeartRateRecord::class, range).map {
        val t = it.time.toEpochMilli()
        IntervalDto(MetricId.restingHeartRate, it.beatsPerMinute.toDouble(), "bpm", t, t, tz,
            Aggregation.LATEST, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readHrv(range: HealthDateRange) = readAll(HeartRateVariabilityRmssdRecord::class, range).map {
        val t = it.time.toEpochMilli()
        IntervalDto(MetricId.hrv, it.heartRateVariabilityMillis, "ms", t, t, tz,
            Aggregation.LATEST, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readRespiratoryRate(range: HealthDateRange) = readAll(RespiratoryRateRecord::class, range).map {
        val t = it.time.toEpochMilli()
        IntervalDto(MetricId.respiratoryRate, it.rate, "breaths/min", t, t, tz,
            Aggregation.LATEST, source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readHeartRate(range: HealthDateRange): List<SampleDto> =
        readAll(HeartRateRecord::class, range).flatMap { record ->
            record.samples.map { sample ->
                val t = sample.time.toEpochMilli()
                SampleDto(MetricId.heartRate, sample.beatsPerMinute.toDouble(), "bpm", t, t, tz,
                    source(record.metadata), device(record.metadata), "${record.metadata.id}#$t")
            }
        }

    private suspend fun readSpo2(range: HealthDateRange) = readAll(OxygenSaturationRecord::class, range).map {
        val t = it.time.toEpochMilli()
        SampleDto(MetricId.spo2, it.percentage.value, "%", t, t, tz,
            source(it.metadata), device(it.metadata), it.metadata.id)
    }

    private suspend fun readSleep(range: HealthDateRange): List<SessionDto> =
        readAll(SleepSessionRecord::class, range).map { record ->
            val stages = record.stages.map { StageDto(mapStage(it.stage), it.startTime.toEpochMilli(), it.endTime.toEpochMilli()) }
            val asleepSeconds = stages.filter { it.stage != SleepStage.AWAKE && it.stage != SleepStage.IN_BED }
                .sumOf { (it.end - it.start).toDouble() / 1000.0 }
            val inBedSeconds = (record.endTime.toEpochMilli() - record.startTime.toEpochMilli()).toDouble() / 1000.0
            SessionDto(
                kind = SessionKind.SLEEP_PRIMARY, subtype = record.title,
                start = record.startTime.toEpochMilli(), end = record.endTime.toEpochMilli(), tz = tz,
                sourceId = source(record.metadata), deviceId = device(record.metadata),
                externalId = record.metadata.id, stages = stages,
                timeAsleepSeconds = if (asleepSeconds > 0) asleepSeconds else null,
                timeInBedSeconds = inBedSeconds,
            )
        }

    private fun mapStage(hcStage: Int): SleepStage = when (hcStage) {
        SleepSessionRecord.STAGE_TYPE_DEEP -> SleepStage.DEEP
        SleepSessionRecord.STAGE_TYPE_REM -> SleepStage.REM
        SleepSessionRecord.STAGE_TYPE_LIGHT -> SleepStage.LIGHT
        SleepSessionRecord.STAGE_TYPE_AWAKE,
        SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> SleepStage.AWAKE
        else -> SleepStage.ASLEEP_UNSPECIFIED
    }

    companion object {
        /** Bounded retry budget for a single page read before treating the failure as terminal. */
        private const val maxPageReadRetries = 2
        private const val pageReadRetryBaseDelayMs = 200L

        /** READ permissions for the record types BADAN maps (I: raw data is not paywalled). */
        val permissions: Set<String> = setOf(
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(DistanceRecord::class),
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(RestingHeartRateRecord::class),
            HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
            HealthPermission.getReadPermission(RespiratoryRateRecord::class),
            HealthPermission.getReadPermission(OxygenSaturationRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
        )

        /** Contract to register in a Compose launcher for requesting the [permissions] above. */
        fun requestPermissionsContract() = PermissionController.createRequestPermissionResultContract()
    }
}
