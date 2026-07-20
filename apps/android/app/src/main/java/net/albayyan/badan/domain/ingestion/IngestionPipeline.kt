package net.albayyan.badan.domain.ingestion

import net.albayyan.badan.core.Clock
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.core.Units
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.ReconciliationDecision
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionDetail
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceStatus
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.RoutePoint
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.WorkoutDetail
import net.albayyan.badan.domain.WorkoutRoute
import net.albayyan.badan.domain.WorkoutTotals
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.platform.health.BackfillWindow
import net.albayyan.badan.platform.health.HealthDateRange
import net.albayyan.badan.platform.health.HealthStorePort
import net.albayyan.badan.platform.health.IntervalDto
import net.albayyan.badan.platform.health.RouteDto
import net.albayyan.badan.platform.health.SampleDto
import net.albayyan.badan.platform.health.SessionDto
import net.albayyan.badan.platform.health.SourceDescriptor
import net.albayyan.badan.platform.health.StageDto
import net.albayyan.badan.storage.repositories.CatalogRepository
import net.albayyan.badan.storage.repositories.MeasurementRepository
import net.albayyan.badan.storage.repositories.ReconciliationRepository
import net.albayyan.badan.storage.repositories.RouteRepository

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
    /**
     * Where consent-gated GPS traces land. Null (the default) means routes are dropped even if a
     * port offers them — the correct behaviour for any caller that has not deliberately opted into
     * storing location data, and the reason this is defaulted rather than required.
     */
    private val routes: RouteRepository? = null,
) {
    /**
     * New rows created this run, per family (derived rollups are excluded — they are a
     * side effect for charts, not upstream facts). A clean re-ingest returns all zeros.
     */
    data class IngestSummary(
        var samples: Int = 0,
        var intervals: Int = 0,
        var sessions: Int = 0,
        var workouts: Int = 0,
        var routes: Int = 0,
        var routePoints: Int = 0,
        var suppressed: Int = 0,
        /** Records skipped because their metric id has no `registry` definition — a registry/adapter mismatch. */
        var unmapped: Int = 0,
        val unmappedMetricIds: MutableSet<String> = mutableSetOf(),
        /**
         * What each platform type could honestly cover this run (plan §14 backfill honesty).
         * Passed straight through from the port so the banner reports the sync that happened,
         * not a guess about what a sync would do.
         */
        var backfillWindows: List<BackfillWindow> = emptyList(),
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
                    measuredAt = dto.start, tz = dto.tz, now = now, qualityFlags = dto.qualityFlags,
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
                    measuredAt = dto.start, tz = dto.tz, now = now, qualityFlags = dto.qualityFlags,
                ),
                updatedAt = now, originDeviceId = deviceId,
            )
            if (measurements.upsertIntervalRecord(record)) summary.intervals += 1
        }

        // (d) Episodes -> sessions (+ stages). Record which nights this run touched.
        val affectedNights = mutableSetOf<String>()
        val affectedWorkoutDays = mutableSetOf<String>()
        // Upstream identity -> the BADAN session id it was written under, so a route read in the
        // same pass can be attached without a second lookup per route.
        val workoutSessionIds = mutableMapOf<String, String>()
        for (dto in sessionDTOs) {
            val isWorkout = dto.kind == SessionKind.WORKOUT
            // Workouts are attributed to the day they *start*: a run beginning at 23:40 belongs to
            // that evening's training, whereas sleep is attributed to the morning it ends (the
            // "last night" key). Using one rule for both would file late-night workouts under
            // tomorrow and quietly break every "what did I do today" query.
            val dayKey = if (isWorkout) {
                DayAttribution.localDayKey(dto.start, dto.tz)
            } else {
                DayAttribution.localNight(dto.end, dto.tz)
            }
            if (isWorkout) affectedWorkoutDays.add(dayKey) else affectedNights.add(dayKey)

            val detail = if (isWorkout) {
                SessionDetail(
                    workout = WorkoutDetail(
                        activityType = dto.activityType,
                        totals = WorkoutLinkage.totals(dto, samples, intervals),
                        sourceWorkoutId = dto.externalId,
                    ),
                )
            } else {
                SessionDetail(
                    timeAsleepSeconds = dto.timeAsleepSeconds,
                    timeInBedSeconds = dto.timeInBedSeconds,
                    stageSummarySeconds = stageSummary(dto.stages),
                )
            }

            val session = Session(
                id = Ulid.newId(), kind = dto.kind, subtype = dto.subtype, startAt = dto.start,
                endAt = dto.end, tzId = dto.tz, localNight = dayKey,
                detail = detail,
                provenance = platformProvenance(
                    sourceId = dto.sourceId, deviceId = dto.deviceId, externalId = dto.externalId,
                    measuredAt = dto.start, tz = dto.tz, now = now, qualityFlags = dto.qualityFlags,
                ),
                updatedAt = now, originDeviceId = deviceId,
            )
            val stages = dto.stages.mapIndexed { i, s ->
                SessionStage(sessionId = session.id, seq = i, stage = s.stage, startAt = s.start, endAt = s.end)
            }
            val created = measurements.upsertSession(session, stages)
            if (created) {
                summary.sessions += 1
                if (isWorkout) summary.workouts += 1
            }
            if (isWorkout) {
                // On an update `upsertSession` wrote to the pre-existing row, not to `session.id`,
                // so the id a route must point at is the stored one. Resolving it here (rather
                // than trusting the freshly-minted ULID) is what stops a re-synced workout's route
                // from being attached to a session row that was never inserted.
                val storedId = if (created) {
                    session.id
                } else {
                    measurements.sessionIdFor(SessionKind.WORKOUT, dto.externalId, dto.sourceId)
                }
                if (storedId != null) workoutSessionIds[dto.externalId] = storedId
            }
        }

        // (e) Consent-gated GPS traces. The port returns nothing unless both its own toggle and
        // the platform's per-route consent were satisfied (see `HealthConnectAdapter.readRoutes`),
        // and a pipeline with no `routes` repository drops them regardless — two independent
        // reasons a route can be absent, neither of which is an error.
        //
        // Drained unconditionally, before the null check on the repository: `readRoutes` empties an
        // in-process buffer the port filled during `readSessions`, so skipping the call would leave
        // coordinates sitting in the adapter until the next sync overwrote them. Data the pipeline
        // has decided not to store should stop existing at that decision, not linger in memory.
        val pendingRoutes = port.readRoutes(range)
        val routeRepo = routes
        if (routeRepo != null) {
            for (route in pendingRoutes) {
                val sessionId = workoutSessionIds[route.sessionExternalId] ?: continue
                if (writeRoute(routeRepo, route, sessionId, now)) summary.routes += 1
                summary.routePoints += route.points.size
            }
        }

        // (f)+(g) Dedup each affected night, then rebuild its daily sleep rollups.
        val batchId = Ulid.newId()
        for (night in affectedNights.sorted()) {
            summary.suppressed += dedup(night, priorityBySource, batchId, now)
        }
        for (day in affectedWorkoutDays.sorted()) {
            summary.suppressed += dedupWorkouts(day, priorityBySource, batchId, now)
        }

        // (h) Only now, with every write above issued, is it safe to advance the port's
        // incremental-read cursors. See `HealthStorePort.commitPendingReadState` and
        // `HealthConnectAdapter.commitPendingReadState` — the ordering here is the whole
        // guarantee, not a formality.
        port.commitPendingReadState()
        summary.backfillWindows = port.backfillWindows()

        return summary
    }

    /**
     * Write one route plus its points, stamping full provenance on the route (I1) and the
     * consent state the port captured at read time (plan §9.2).
     *
     * `ingestionPath` is `platformStore` like any other ingested fact: a route is not derived and
     * not manual, and labelling it otherwise would make "where did this come from" answer
     * differently for a workout and the trace inside it.
     */
    private fun writeRoute(repo: RouteRepository, dto: RouteDto, sessionId: String, now: Long): Boolean {
        val route = WorkoutRoute(
            id = Ulid.newId(), sessionId = sessionId, pointCount = dto.points.size,
            startAt = dto.start, endAt = dto.end, consentSnapshot = dto.consentSnapshot,
            provenance = platformProvenance(
                sourceId = dto.sourceId, deviceId = dto.deviceId, externalId = dto.externalId,
                measuredAt = dto.start, tz = dto.tz, now = now, qualityFlags = dto.qualityFlags,
            ),
            updatedAt = now, originDeviceId = deviceId,
        )
        // Point ids are assigned against the route the repository actually writes to, so `seq` is
        // taken from the DTO rather than re-derived here.
        val points = dto.points.map {
            RoutePoint(
                routeId = route.id, seq = it.seq, lat = it.lat, lon = it.lon,
                altitudeM = it.altitudeM, horizontalAccuracyM = it.horizontalAccuracyM,
                timestamp = it.timestamp,
            )
        }
        return repo.upsertRoute(route, points)
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
            upsertDailySleepInterval(MetricId.timeAsleep, primary.detail.timeAsleepSeconds, primary, night, now)
            upsertDailySleepInterval(MetricId.timeInBed, primary.detail.timeInBedSeconds, primary, night, now)
            upsertStageIntervals(primary, night, now)
        }
        return newSuppressions
    }

    /**
     * The night's per-stage durations as `sleep.deep` / `sleep.rem` / `sleep.light` / `sleep.awake`
     * daily intervals.
     *
     * Stage data was already being ingested — every stage lands in `session_stages` — but it stopped
     * there, so four registry metrics that exist and are `baselineEligible` had nothing writing
     * them. Charts and baselines read `interval_records`, not `session_stages`, which meant deep and
     * REM sleep were present in the database and absent from the product. Rolling them up here
     * fabricates nothing: it is the same [stageSummary] the session row already carries, reshaped
     * into the rows the rest of the app reads.
     *
     * Derived from the deduped winner, alongside time_asleep/time_in_bed and for the same reason: a
     * night reported by both Samsung Health and a Garmin would otherwise contribute two sets of
     * stage rows and every chart would double-count deep sleep.
     *
     * Only stages the source actually reported are written. A writer that reports deep and light but
     * no REM gets no `sleep.rem` row rather than a zero — zero is a claim ("you had no REM"), and
     * the honest statement for an unreported stage is silence. [SleepStage.IN_BED] and
     * [SleepStage.ASLEEP_UNSPECIFIED] are skipped because neither has a registry metric: in-bed time
     * is already `sleep.time_in_bed`, and unspecified sleep is precisely the absence of a stage
     * breakdown, so filing it under one would invent the detail it is telling us it does not have.
     */
    private fun upsertStageIntervals(primary: Session, night: String, now: Long) {
        for ((stage, metricId) in SleepStageRollup.metrics) {
            val seconds = primary.detail.stageSummarySeconds[stage.code] ?: continue
            upsertDailySleepInterval(metricId, seconds, primary, night, now)
        }
    }

    /**
     * Reconcile one day's ingested workouts under `workout.session_overlap.v1` and return how many
     * *new* suppressions were journaled.
     *
     * Scope, stated because the absence is deliberate: this reconciles ingested workouts against
     * each other (two apps both writing the same run — the ordinary Android case, plan §10). It
     * does NOT yet suppress the manual `workout_entries` twin that plan §9.1 also describes.
     * `workout_entries` has no `suppressed_by` column, so there is nowhere to record the decision
     * on the row, and adding one is a forward-only migration owned outside this change. The rule
     * itself handles both sides already — `DedupLite.reconcileWorkouts` takes an `isManual` flag
     * and is tested against it — so wiring the manual half is a call site plus a migration, not a
     * redesign. Until then a manual duplicate stays visible, which is the safe direction: showing
     * the user a row they typed is a smaller error than hiding it with no way to reverse.
     */
    private fun dedupWorkouts(day: String, priorityBySource: Map<String, Int>, batchId: String, now: Long): Int {
        val sessions = measurements.sessionsForDay(SessionKind.WORKOUT, day, includeSuppressed = true)
        if (sessions.size < 2) return 0
        val byId = sessions.associateBy { it.id }
        val candidates = sessions.map {
            DedupLite.WorkoutCandidate(
                id = it.id, sourceId = it.provenance.sourceId,
                startAt = it.startAt, endAt = it.endAt, isManual = false,
            )
        }

        var newSuppressions = 0
        for (outcome in DedupLite.reconcileWorkouts(candidates) { priorityBySource[it] ?: 0 }) {
            for (sup in outcome.suppressed) {
                // Idempotent in exactly the way the sleep path is: already suppressed by this same
                // winner means the decision was made on an earlier run and must not be journaled
                // twice, or every sync would grow `dedup_decisions` without deciding anything new.
                if (byId[sup.loserId]?.provenance?.suppressedBy == sup.winnerId) continue
                measurements.setSuppressed("sessions", sup.loserId, sup.winnerId, now)
                reconciliation.insert(
                    ReconciliationDecision(
                        id = Ulid.newId(), batchId = batchId, rule = DedupLite.workoutRuleId,
                        ruleVersion = "v1", keptRecordId = sup.winnerId, suppressedRecordId = sup.loserId,
                        score = sup.score, decidedAt = now, detail = sup.detail,
                    ),
                )
                newSuppressions += 1
            }

            val loserIds = outcome.suppressed.map { it.loserId }.sorted()
            val winner = outcome.winnerId?.let { byId[it] }
            if (loserIds.isNotEmpty() && winner != null && winner.detail.mergedFrom.toSet() != loserIds.toSet()) {
                measurements.upsertSession(
                    winner.copy(detail = winner.detail.copy(mergedFrom = loserIds), updatedAt = now),
                )
            }
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
        qualityFlags: List<QualityFlag> = emptyList(),
    ): Provenance =
        Provenance(
            sourceId = sourceId, deviceId = deviceId, ingestionPath = IngestionPath.PLATFORM_STORE,
            externalId = externalId, measuredAt = measuredAt, measuredTimezone = tz,
            recordedAt = now, ingestedAt = now, qualityFlags = qualityFlags,
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

/**
 * Which sleep stages roll up into a daily `interval_records` row, and into which metric.
 *
 * A top-level object rather than a private map for the reason [WorkoutLinkage] below is one: this
 * module has no `androidTest` source set, so `IngestionPipeline.dedup` — which needs a database —
 * cannot be exercised in a JVM test, and the decision most likely to be wrong (which metric id a
 * stage becomes, and which stages get one at all) would otherwise be reachable by nothing.
 *
 * A map, not a `when` over [SleepStage], so the omissions read as omissions. [SleepStage.IN_BED]
 * and [SleepStage.ASLEEP_UNSPECIFIED] are absent deliberately — in-bed time is already
 * `sleep.time_in_bed`, and "asleep, stage unspecified" is precisely the *absence* of a breakdown,
 * so filing it under a stage would invent the detail the source just said it does not have. A
 * stage added to the enum later is simply not rolled up until someone names its metric here, which
 * is the safe default: the alternative is writing a metric id the registry does not define, which
 * `MetricRegistry` would then fail to resolve on every read.
 */
internal object SleepStageRollup {
    val metrics: Map<SleepStage, String> = mapOf(
        SleepStage.DEEP to MetricId.sleepDeep,
        SleepStage.REM to MetricId.sleepRem,
        SleepStage.LIGHT to MetricId.sleepLight,
        SleepStage.AWAKE to MetricId.sleepAwake,
    )
}

/**
 * Links an ingested workout to the metric rows that overlap it, producing the totals stored in
 * `SessionDetail.workout` (plan §9.1 / §20 EPIC-03 task 4).
 *
 * Why this exists on Android at all: HealthKit hands over an `HKWorkout` with `totalEnergyBurned`
 * and `totalDistance` already on it, while Health Connect models a workout as a bare envelope —
 * type, title, segments, laps — with energy, distance and heart rate living in entirely separate
 * records that merely overlap the session window. The totals a user sees have to be assembled
 * from those, and the assembly rule is worth stating precisely because it is easy to get
 * plausibly wrong.
 *
 * Deliberately NOT duplicating rows: nothing here writes a metric row. The heart-rate samples
 * inside a workout are already stored once as `raw_samples`; these totals are a summary computed
 * over them, and the session's window is what re-derives the link on read. Copying the series into
 * the workout would double the storage and create two versions of one fact that can disagree.
 *
 * Kept a top-level object, not a private method, so the rule is reachable from tests without a
 * database — it is the piece most likely to drift from iOS, and the fixtures compare the two.
 */
internal object WorkoutLinkage {

    /**
     * Cumulative interval metrics (energy, distance) are attributed to a workout only when the
     * interval is FULLY CONTAINED in the workout window, rather than by proportional overlap.
     *
     * The tradeoff, stated plainly because it is a real one: containment under-counts. A writer
     * that emits one energy record spanning a whole day contributes nothing to any workout, and a
     * segment that straddles the finish line is dropped.
     *
     * Proportional overlap was rejected because its failure mode is far worse and invisible.
     * Attributing a fraction of a day-long 9,000 kJ bucket to a 45-minute run yields roughly
     * 280 kJ of pure fiction — a number in a plausible range, on a screen, that no source ever
     * measured. Under-counting surfaces as null (see below), which the UI renders as "—";
     * over-counting surfaces as a confident wrong number. Given a choice between saying nothing
     * and saying something invented, BADAN says nothing.
     */
    private fun containedSum(
        intervals: List<IntervalDto>,
        metricId: String,
        sourceId: String,
        start: Long,
        end: Long,
    ): Double? {
        var total = 0.0
        var contributors = 0
        for (i in intervals) {
            if (i.metricId != metricId) continue
            // Same writer only. Two apps both recording the run would otherwise have their energy
            // summed into one total roughly twice the truth — the exact multi-writer hazard the
            // Android source-priority work exists for, reappearing at the totals layer where no
            // dedup rule is looking.
            if (i.sourceId != sourceId) continue
            if (i.start < start || i.end > end) continue
            total += i.value
            contributors += 1
        }
        // Null, not 0.0: "no contributing record" and "the source measured zero" are different
        // claims, and only one of them is true here.
        return if (contributors > 0) total else null
    }

    /**
     * Heart-rate statistics over the workout window. Exact rather than attributed — a sample has
     * an instant, not a span, so there is no allocation question to get wrong.
     *
     * Restricted to the workout's own writer for the same reason [containedSum] is: a max taken
     * across two devices reports the higher of two sensors' readings as if one device saw it.
     */
    private fun heartRate(samples: List<SampleDto>, sourceId: String, start: Long, end: Long): Pair<Double, Double>? {
        var sum = 0.0
        var count = 0
        var max = Double.NEGATIVE_INFINITY
        for (s in samples) {
            if (s.metricId != MetricId.heartRate) continue
            if (s.sourceId != sourceId) continue
            if (s.start < start || s.start > end) continue
            sum += s.value
            if (s.value > max) max = s.value
            count += 1
        }
        if (count == 0) return null
        return (sum / count) to max
    }

    fun totals(session: SessionDto, samples: List<SampleDto>, intervals: List<IntervalDto>): WorkoutTotals {
        val hr = heartRate(samples, session.sourceId, session.start, session.end)
        return WorkoutTotals(
            // Units here are the DTOs' as-received units, which for the Health Connect adapter are
            // already the registry canonicals (kJ, m, bpm) — see `HcTypeMap.Entry.unit`, where
            // that alignment is a deliberate choice rather than a coincidence. A port that emits
            // other units would need conversion added here; none does today, and a fixture would
            // catch it if one started.
            energyKj = session.totals?.energyKj
                ?: containedSum(intervals, MetricId.activeEnergy, session.sourceId, session.start, session.end),
            distanceM = session.totals?.distanceM
                ?: containedSum(intervals, MetricId.distance, session.sourceId, session.start, session.end),
            avgHrBpm = session.totals?.avgHrBpm ?: hr?.first,
            maxHrBpm = session.totals?.maxHrBpm ?: hr?.second,
            // No Health Connect source: FloorsClimbedRecord counts flights, which is not elevation
            // gain in metres and must not be dressed up as it. Populated only by a port that
            // genuinely reports it (HealthKit does), left null here rather than approximated.
            elevationGainM = session.totals?.elevationGainM,
        )
    }
}
