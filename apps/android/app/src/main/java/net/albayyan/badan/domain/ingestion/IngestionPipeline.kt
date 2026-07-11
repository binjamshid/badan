package net.albayyan.badan.domain.ingestion

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.ReconciliationDecision
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionDetail
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceStatus
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.platform.health.HealthDateRange
import net.albayyan.badan.platform.health.HealthStorePort
import net.albayyan.badan.platform.health.SourceDescriptor
import net.albayyan.badan.platform.health.StageDto
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.ReconciliationRepository

/**
 * The single path health data takes to become BADAN facts: register sources/devices, pull
 * samples/intervals/sessions from a [HealthStorePort], canonicalize units, stamp embedded
 * provenance, then run dedup-lite over each affected night. Every write is idempotent by
 * upstream identity (metric/external/source), so re-ingesting the same range is a no-op —
 * no duplicate rows and no duplicate reconciliation decisions.
 */
class IngestionPipeline(
    private val measurements: MeasurementRepository,
    private val catalog: CatalogRepository,
    private val reconciliation: ReconciliationRepository,
    private val registry: MetricRegistry,
    private val clock: Clock,
    private val deviceId: String,
) {
    /**
     * New rows created this run, per family (derived rollups are excluded — they are a
     * side effect for charts, not upstream facts). A clean re-ingest returns all zeros.
     */
    data class IngestSummary(
        var samples: Int = 0,
        var intervals: Int = 0,
        var sessions: Int = 0,
        var suppressed: Int = 0,
        /** Records skipped because their metric id has no `registry` definition — a registry/adapter mismatch. */
        var unmapped: Int = 0,
        val unmappedMetricIds: MutableSet<String> = mutableSetOf(),
    )

    fun ingest(port: HealthStorePort, range: HealthDateRange): IngestSummary {
        val now = clock.now()
        val summary = IngestSummary()

        // (a) Register sources + devices and build the dedup priority map from descriptors.
        val descriptors = port.sourceDescriptors()
        val priorityBySource = upsertSourcesAndDevices(descriptors, now)

        // (b) Pull raw payloads.
        val samples = port.readSamples(range)
        val intervals = port.readIntervals(range)
        val sessionDTOs = port.readSessions(range)

        // (c) Instant readings -> raw_samples (canonicalized, provenance stamped).
        for (dto in samples) {
            val def = registry.definition(dto.metricId)
            if (def == null) {
                summary.unmapped += 1
                summary.unmappedMetricIds.add(dto.metricId)
                continue
            }
            val value = Units.toCanonical(dto.value, dto.unit, def.canonicalUnit)
            val sample = RawSample(
                id = Ulid.newId(), metricId = dto.metricId, value = value, unit = def.canonicalUnit,
                originalValue = dto.value, originalUnit = dto.unit, startAt = dto.start, endAt = dto.end,
                tzId = dto.tz,
                provenance = platformProvenance(
                    sourceId = dto.sourceId, deviceId = dto.deviceId, externalId = dto.externalId,
                    measuredAt = dto.start, tz = dto.tz, now = now,
                ),
                updatedAt = now, originDeviceId = deviceId,
            )
            if (measurements.upsertRawSample(sample)) summary.samples += 1
        }

        // (c) Normalized aggregates -> interval_records.
        for (dto in intervals) {
            val def = registry.definition(dto.metricId)
            if (def == null) {
                summary.unmapped += 1
                summary.unmappedMetricIds.add(dto.metricId)
                continue
            }
            val value = Units.toCanonical(dto.value, dto.unit, def.canonicalUnit)
            val record = IntervalRecord(
                id = Ulid.newId(), metricId = dto.metricId, value = value, unit = def.canonicalUnit,
                startAt = dto.start, endAt = dto.end, tzId = dto.tz, aggregation = dto.aggregation,
                provenance = platformProvenance(
                    sourceId = dto.sourceId, deviceId = dto.deviceId, externalId = dto.externalId,
                    measuredAt = dto.start, tz = dto.tz, now = now,
                ),
                updatedAt = now, originDeviceId = deviceId,
            )
            if (measurements.upsertIntervalRecord(record)) summary.intervals += 1
        }

        // (d) Episodes -> sessions (+ stages). Record which nights this run touched.
        val affectedNights = mutableSetOf<String>()
        for (dto in sessionDTOs) {
            val night = DayAttribution.localNight(dto.end, dto.tz)
            affectedNights.add(night)
            val session = Session(
                id = Ulid.newId(), kind = dto.kind, subtype = dto.subtype, startAt = dto.start,
                endAt = dto.end, tzId = dto.tz, localNight = night,
                detail = SessionDetail(
                    timeAsleepSeconds = dto.timeAsleepSeconds,
                    timeInBedSeconds = dto.timeInBedSeconds,
                    stageSummarySeconds = stageSummary(dto.stages),
                ),
                provenance = platformProvenance(
                    sourceId = dto.sourceId, deviceId = dto.deviceId, externalId = dto.externalId,
                    measuredAt = dto.start, tz = dto.tz, now = now,
                ),
                updatedAt = now, originDeviceId = deviceId,
            )
            val stages = dto.stages.mapIndexed { i, s ->
                SessionStage(sessionId = session.id, seq = i, stage = s.stage, startAt = s.start, endAt = s.end)
            }
            if (measurements.upsertSession(session, stages)) summary.sessions += 1
        }

        // (e)+(f) Dedup each affected night, then rebuild its daily sleep rollups.
        val batchId = Ulid.newId()
        for (night in affectedNights.sorted()) {
            summary.suppressed += dedup(night, priorityBySource, batchId, now)
        }

        return summary
    }

    // MARK: - Dedup + derived rollups

    /** Reconcile one night and return how many *new* suppressions were journaled. */
    private fun dedup(night: String, priorityBySource: Map<String, Int>, batchId: String, now: Long): Int {
        val sessions = measurements.allSleepSessions(night, true)
        val byId = HashMap<String, Session>()
        for (s in sessions) byId.putIfAbsent(s.id, s)
        val outcome = DedupLite.reconcile(sessions) { priorityBySource[it] ?: 0 }
        val winnerId = outcome.winnerId ?: return 0

        var newSuppressions = 0
        for (sup in outcome.suppressed) {
            // Idempotent: already suppressed by this winner -> don't re-suppress or re-journal.
            if (byId[sup.loserId]?.provenance?.suppressedBy == sup.winnerId) continue
            measurements.setSuppressed("sessions", sup.loserId, sup.winnerId, now)
            reconciliation.insert(
                ReconciliationDecision(
                    id = Ulid.newId(), batchId = batchId, rule = DedupLite.ruleId, ruleVersion = "v1",
                    keptRecordId = sup.winnerId, suppressedRecordId = sup.loserId, score = sup.score,
                    decidedAt = now, detail = sup.detail,
                ),
            )
            newSuppressions += 1
        }

        // Record lineage on the winner (which raw sessions were merged into it).
        val loserIds = outcome.suppressed.map { it.loserId }.sorted()
        val winner = byId[winnerId]
        if (loserIds.isNotEmpty() && winner != null && winner.detail.mergedFrom.toSet() != loserIds.toSet()) {
            val updated = winner.copy(
                detail = winner.detail.copy(mergedFrom = loserIds),
                updatedAt = now,
            )
            measurements.upsertSession(updated)
        }

        // (e) Rebuild the night's daily sleep rollups from the surviving primary sleep so
        // charts/baselines read one uniform interval regardless of how many sources reported.
        val primary = measurements.primarySleep(night)
        if (primary != null) {
            upsertDailySleepInterval("sleep.time_asleep", primary.detail.timeAsleepSeconds, primary, night, now)
            upsertDailySleepInterval("sleep.time_in_bed", primary.detail.timeInBedSeconds, primary, night, now)
        }
        return newSuppressions
    }

    /**
     * Upsert one derived daily sleep interval (unit "s"), keyed idempotently by night so a
     * re-ingest updates in place. Provenance is derived from the winning session.
     */
    private fun upsertDailySleepInterval(
        metricId: String,
        seconds: Double?,
        winner: Session,
        night: String,
        now: Long,
    ) {
        if (seconds == null) return
        val provenance = Provenance(
            sourceId = winner.provenance.sourceId, deviceId = winner.provenance.deviceId,
            ingestionPath = IngestionPath.DERIVED, externalId = "derived.$metricId.$night",
            measuredAt = winner.startAt, measuredTimezone = winner.tzId,
            recordedAt = now, ingestedAt = now, algorithmVersionId = DedupLite.ruleId,
        )
        val record = IntervalRecord(
            id = Ulid.newId(), metricId = metricId, value = seconds, unit = "s",
            startAt = winner.startAt, endAt = winner.endAt, tzId = winner.tzId,
            aggregation = Aggregation.DURATION, provenance = provenance, updatedAt = now, originDeviceId = deviceId,
        )
        measurements.upsertIntervalRecord(record)
    }

    // MARK: - Sources / devices

    /**
     * Upsert a Source (and Device, when present) per descriptor and return the sourceId ->
     * dedup-priority map. Explicit descriptor priority wins; otherwise a wrist device
     * outranks a phone (watch > phone), falling back to 0.
     */
    private fun upsertSourcesAndDevices(descriptors: List<SourceDescriptor>, now: Long): Map<String, Int> {
        val priorityBySource = mutableMapOf<String, Int>()
        for (d in descriptors) {
            val existing = catalog.source(d.id)
            catalog.upsertSource(
                Source(
                    id = d.id, type = d.type, displayName = d.displayName,
                    platformBundleId = d.bundleId, status = SourceStatus.ACTIVE,
                    connectedAt = existing?.connectedAt ?: now, lastDeliveryAt = now,
                    updatedAt = now, originDeviceId = deviceId,
                ),
            )

            val deviceKey = d.deviceId
            if (deviceKey != null) {
                val priorDevice = catalog.devices(d.id).firstOrNull { it.id == deviceKey }
                catalog.upsertDevice(
                    Device(
                        id = deviceKey, sourceId = d.id, name = d.deviceName ?: d.displayName,
                        model = d.deviceModel, firstSeen = priorDevice?.firstSeen ?: now, lastSeen = now,
                        updatedAt = now, originDeviceId = deviceId,
                    ),
                )
            }

            priorityBySource[d.id] = inferredPriority(d)
        }
        return priorityBySource
    }

    /**
     * Fallback contract for source integrations that don't set an explicit [SourceDescriptor.priority]:
     * an English "watch"/"phone" substring match in the device name/model/display name, else 0
     * (lowest priority). Every descriptor today (`FakeHealthStore`, `HealthConnectAdapter`) sets an
     * explicit non-zero priority, so this path is currently unexercised in practice — it exists as
     * the documented default a future source integration falls back to.
     */
    internal fun inferredPriority(d: SourceDescriptor): Int {
        if (d.priority != 0) return d.priority
        val hay = ((d.deviceName ?: "") + " " + (d.deviceModel ?: "") + " " + d.displayName).lowercase()
        if (hay.contains("watch")) return 2
        if (hay.contains("phone")) return 1
        return 0
    }

    // MARK: - Helpers

    private fun platformProvenance(
        sourceId: String,
        deviceId: String?,
        externalId: String,
        measuredAt: Long,
        tz: String,
        now: Long,
    ): Provenance =
        Provenance(
            sourceId = sourceId, deviceId = deviceId, ingestionPath = IngestionPath.PLATFORM_STORE,
            externalId = externalId, measuredAt = measuredAt, measuredTimezone = tz,
            recordedAt = now, ingestedAt = now,
        )

    private fun stageSummary(stages: List<StageDto>): Map<String, Double> {
        val summary = mutableMapOf<String, Double>()
        for (s in stages) {
            val key = s.stage.code
            summary[key] = (summary[key] ?: 0.0) + (s.end - s.start) / 1000.0
        }
        return summary
    }
}
