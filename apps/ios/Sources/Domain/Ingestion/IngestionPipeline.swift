import Foundation

/// (AUDIT 2026-08-06, SLEEP-H2) A `HealthStorePort` that can say which local nights it just
/// rebuilt in FULL — meaning it re-read that night's complete current sleep sample set and the
/// `SessionDTO`s it returned for the night are the whole truth about it, not an addition to
/// whatever is already stored.
///
/// An opt-in side protocol rather than a defaulted `HealthStorePort` requirement, deliberately.
/// Only a port that can distinguish "this night holds no sleep" from "I could not read this
/// night" may claim a rebuild — HealthKit answers a denied READ with an empty set and no error,
/// so `HistoricalHealthKitReader` conforms to neither and says so in its own doc. A port that
/// does not conform is treated as claiming nothing, and its nights are upserted into exactly as
/// they always were.
protocol SleepNightRebuilding {
    func rebuiltSleepNights(_ range: HealthDateRange) -> Set<String>
}

/// The single path health data takes to become BADAN facts: register sources/devices, pull
/// samples/intervals/sessions from a `HealthStorePort`, canonicalize units, stamp embedded
/// provenance, then run dedup-lite over each affected night. Every write is idempotent by
/// upstream identity (metric/external/source), so re-ingesting the same range is a no-op —
/// no duplicate rows and no duplicate reconciliation decisions. Any future importer (Apple
/// Health export, vendor file, etc.) must route its rows through this same `ingest` entry
/// point rather than writing directly, so overlapping live-sync and import data are
/// reconciled by the identical dedup-lite pass instead of silently double-counting.
final class IngestionPipeline {
    private let measurements: MeasurementRepository
    private let catalog: CatalogRepository
    private let reconciliation: ReconciliationRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    /// Route storage (EPIC-03). Optional, and its absence is a hard gate rather than a
    /// degradation: with no repository, consented routes read from the platform are dropped
    /// instead of stored. Defaulted to `nil` so this stays additive for callers that predate
    /// routes; wiring it is a deliberate act alongside wiring the consent provider into the
    /// adapter, which is the pairing that has to be reviewed together.
    private let routes: RouteRepository?
    /// Manual logs (EPIC-03). Needed only by `workout.session_overlap.v1`, which reconciles
    /// ingested workouts against manually-logged twins in `workout_entries`. Without it the
    /// rule simply does not run — manual duplicates stay visible, which is the safe direction
    /// (nothing is suppressed that shouldn't be).
    private let logging: LoggingRepository?
    /// EPIC-43 follow-up slice (plan §7A.6/§9.19): the reconciliation-v2 engine's own conflict
    /// ledger (`data_conflicts`) and per-metric default priority rules. Optional and additive
    /// for the identical reason `routes`/`logging` are: without `dataConflicts`,
    /// `reconcileMetricConflicts` below simply does not run — no conflict is detected, nothing is
    /// suppressed, and every pre-existing caller (`AppEnvironment`'s own construction site before
    /// this slice, every test file's `makeIngestion()`) keeps compiling and behaving exactly as
    /// before. `sourcePriorityRules` is independently optional: without it, `ConflictDecisionEngine.decide`
    /// simply never reaches its `SourcePriorityRule` fallback (rule 5) — the earlier, unconditional
    /// rules (manual-wins, most-recent-weight, chest-strap) are entirely unaffected.
    private let dataConflicts: DataConflictRepository?
    private let sourcePriorityRules: SourcePriorityRuleRepository?

    init(measurements: MeasurementRepository, catalog: CatalogRepository,
         reconciliation: ReconciliationRepository, registry: MetricRegistry,
         clock: Clock, deviceId: String,
         routes: RouteRepository? = nil, logging: LoggingRepository? = nil,
         dataConflicts: DataConflictRepository? = nil,
         sourcePriorityRules: SourcePriorityRuleRepository? = nil) {
        self.measurements = measurements
        self.catalog = catalog
        self.reconciliation = reconciliation
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
        self.routes = routes
        self.logging = logging
        self.dataConflicts = dataConflicts
        self.sourcePriorityRules = sourcePriorityRules
    }

    /// What provenance a single `ingest` call stamps on every row it writes.
    ///
    /// Defaulted to `.liveSync` so every existing caller (foreground/background HealthKit sync,
    /// the demo seed) is byte-identical to before this type existed. A file importer passes
    /// `.fileImport(batchId:)` instead, which is the seam the pipeline's type doc promises: an
    /// Apple Health archive routes its rows through this same `ingest`, deduped and provenanced
    /// by the identical pass as live sync, but every row reads `ingestionPath = .import` (I1) and
    /// carries a one-tap-undo `importBatchId` (the `batch_id` column, `idx_raw_batch`) so the
    /// whole import is reversible via `import_batches` lineage. Derived rollups written inside the
    /// same run keep `ingestionPath = .derived` regardless — they are recomputable, not imported.
    struct IngestOrigin {
        var ingestionPath: IngestionPath
        var importBatchId: String?

        /// Live HealthKit/Health Connect sync — the historical, and still default, behavior.
        static let liveSync = IngestOrigin(ingestionPath: .platformStore, importBatchId: nil)

        /// A file import (Apple Health export archive). Stamps `ingestionPath = .import` and the
        /// batch id every row must carry for one-tap undo.
        static func fileImport(batchId: String) -> IngestOrigin {
            IngestOrigin(ingestionPath: .fileImport, importBatchId: batchId)
        }
    }

    /// New rows created this run, per family (derived rollups are excluded — they are a
    /// side effect for charts, not upstream facts). A clean re-ingest returns all zeros.
    struct IngestSummary {
        var samples: Int = 0
        var intervals: Int = 0
        var sessions: Int = 0
        /// Workout sessions specifically. Counted separately from `sessions` (which stays sleep)
        /// so "a re-ingest created nothing" can be asserted per family — a workout regression
        /// hiding inside a nonzero sleep count is exactly the kind of thing the idempotence
        /// tests exist to catch.
        var workouts: Int = 0
        /// Routes WRITTEN this run — inserted or replaced, unlike the counters above, which count
        /// only new rows. A route is replaced wholesale on every re-delivery (see
        /// `RouteRepository`), so "new" is not a property it has. Always 0 without route consent,
        /// by construction.
        var routes: Int = 0
        var suppressed: Int = 0

        /// New rows written across every family. `routes` is excluded on purpose: it counts rows
        /// replaced wholesale rather than newly created (see its own doc), so folding it in would
        /// make an all-zero "nothing was new" summary read as nonzero on every re-ingest that
        /// carried a route.
        ///
        /// Read this as "new rows derived from the DTOs this run was handed", NOT as "every row
        /// this run wrote". Ingestion also writes the daily sleep rollups
        /// (`sleep.time_asleep`/`sleep.time_in_bed`) through `upsertDailySleepInterval`, which are
        /// computed from sessions rather than delivered as DTOs and are deliberately not counted
        /// here. `0` is still the exact and reliable signal for "nothing new arrived", which is
        /// what the historical import surface uses to say "Already up to date".
        var totalWritten: Int { samples + intervals + sessions + workouts }
    }

    func ingest(from port: HealthStorePort, range: HealthDateRange,
                origin: IngestOrigin = .liveSync) throws -> IngestSummary {
        // (DATA-08) Phase 1: pull every payload from `port` BEFORE any write transaction is
        // open. HealthKit round-trips are real synchronous I/O (each bridges a completion-
        // handler query onto this thread via a semaphore — see `HealthKitAdapter`'s type doc);
        // running them inside `measurements.transaction` used to hold the DB write lock for
        // their entire duration, stalling any other read against the same connection for as
        // long as HealthKit took to answer (part of EDGE-04). Deliberately NOT calling
        // `port.commitPendingAnchors()` yet either — see phase 3 below for why.
        let descriptors = port.sourceDescriptors()
        let samples = port.readSamples(range)
        let intervals = port.readIntervals(range)
        let sessionDTOs = port.readSessions(range)
        // Workouts and their (consent-gated) routes. Read in phase 1 with everything else so the
        // route streaming — which is several HealthKit round trips per workout — happens before
        // any write lock is taken, not while one is held.
        let workoutDTOs = port.readWorkouts(range)
        // Must run after the read* calls above for this same `range` — see
        // `HealthStorePort.deletions(_:)`'s doc.
        let deletions = port.deletions(range)
        // (SLEEP-H2) Drained here for the same reason and with the same ordering requirement as
        // `deletions` above: it reports what `readSessions` just did. A port that cannot claim a
        // full-night rebuild claims nothing, and nothing is pruned.
        let rebuiltNights = (port as? SleepNightRebuilding)?.rebuiltSleepNights(range) ?? []

        // Phase 2: the write transactions. `measurements`, `catalog` and `reconciliation` all
        // share the same main-DB connection, so batching upserts into a transaction (rather than
        // committing per row) turns what used to be hundreds of implicit WAL commit+fsyncs into a
        // handful (PERF-02, audit 2026-07-12).
        //
        // (P2) Batched rather than ONE transaction spanning the whole ingest. That single
        // transaction held the connection's lock for the entire write — and on a first connect
        // that is 90 days of a dense Apple Watch history, which is where the audit's multi-second
        // UI stalls came from: `SQLiteConnection` serialises everything through one lock, so
        // every main-thread read (Home, LogHub, Settings) waited for the whole backfill to
        // finish. Batching bounds each lock hold to `writeBatchSize` rows while keeping the
        // commit count small — the middle ground PERF-02 was reaching for.
        //
        // Anchors still commit once, after ALL batches (phase 3), which is what makes this safe
        // to interrupt: a crash between batches leaves the cursor unadvanced, so the next sync
        // replays the whole range and every upsert is idempotent by upstream identity. Partial
        // progress is never mistaken for complete progress.
        let summary = try applyIngestBatched(descriptors: descriptors, samples: samples,
                                             intervals: intervals, sessionDTOs: sessionDTOs,
                                             workoutDTOs: workoutDTOs, deletions: deletions,
                                             rebuiltNights: rebuiltNights, origin: origin)

        // (DATA-08) Phase 3: only persist the port's read cursor/anchor AFTER the write
        // transaction above has actually committed. Persisting eagerly (the old behavior) only
        // worked because the anchor repo happened to share the ingest write's connection/
        // transaction; once HealthKit reads run outside that transaction (phase 1), persisting
        // early would let the cursor advance past data whose write could still fail to commit,
        // silently dropping that data forever instead of safely retrying it on the next sync.
        // No-ops for stores with no such cursor (e.g. `FakeHealthStore`).
        port.commitPendingAnchors()
        return summary
    }

    // MARK: - Ingest body (runs inside `measurements.transaction` above)

    /// Rows per write transaction (P2).
    ///
    /// Large enough that the commit count stays small on a 90-day backfill (PERF-02's concern),
    /// small enough that no single lock hold is long enough to stall a main-thread read for a
    /// user-perceptible time. A round number rather than a tuned one — the win here is bounding
    /// the hold at all, not the exact bound; profile on a real dense history before tuning.
    private static let writeBatchSize = 2_000

    /// Phase 2, in bounded transactions. See `ingest`'s comment for why this isn't one
    /// transaction, and for why interrupting it between batches is safe.
    private func applyIngestBatched(descriptors: [SourceDescriptor], samples: [SampleDTO],
                                    intervals: [IntervalDTO], sessionDTOs: [SessionDTO],
                                    workoutDTOs: [WorkoutDTO],
                                    deletions: HealthStoreDeletions,
                                    rebuiltNights: Set<String>,
                                    origin: IngestOrigin) throws -> IngestSummary {
        let now = clock.now()
        var summary = IngestSummary()

        // (a)+(b) Sources/devices and deletions: bounded by the number of real sources and by
        // what changed since the last sync, so they stay one small transaction. Deletions are
        // applied before any fresh write (BUG-10a), so a row both deleted and (implausibly)
        // re-delivered in the same batch ends up live rather than stuck soft-deleted.
        let priorityBySource = try measurements.transaction { () -> [String: Int] in
            let priorities = try upsertSourcesAndDevices(descriptors, now: now)
            for del in deletions.samples {
                try measurements.softDelete(table: "raw_samples", metricId: del.metricId,
                                            externalId: del.externalId, sourceId: del.sourceId, updatedAt: now)
            }
            for del in deletions.intervals {
                try measurements.softDelete(table: "interval_records", metricId: del.metricId,
                                            externalId: del.externalId, sourceId: del.sourceId, updatedAt: now)
            }
            // (EPIC-03) Workout sessions deleted upstream. `sessions` has no `metric_id` column,
            // so `metricId` is passed nil — which is correct rather than lossy: a workout
            // deletion's `externalId` embeds the platform's own workout UUID and is unique on its
            // own (see `HealthStoreDeletions`). Sleep never populates this list.
            for del in deletions.sessions {
                try measurements.softDelete(table: "sessions", metricId: nil,
                                            externalId: del.externalId, sourceId: del.sourceId, updatedAt: now)
            }
            return priorities
        }

        // (c) The big one on a first connect: a dense watch history is overwhelmingly raw samples.
        for batch in samples.badanChunked(Self.writeBatchSize) {
            try measurements.transaction { summary.samples += try writeSamples(batch, now: now, origin: origin) }
        }

        // (c) Interval aggregates — at most a few per metric per day, but batched on the same
        // rule so a wide backfill can't grow an unbounded transaction here either.
        for batch in intervals.badanChunked(Self.writeBatchSize) {
            try measurements.transaction { summary.intervals += try writeIntervals(batch, now: now, origin: origin) }
        }

        let batchId = ULID.newID()

        // (h) EPIC-43 follow-up slice (plan §7A.6/§9.19) — the missing caller `DataConflictsScreen`'s
        // own doc names: reconciliation-v2 over the metrics/days THIS run's intervals/samples
        // touched. Entirely additive and orthogonal to (e)/(f)/(g) below — it reads rows this run
        // already wrote via the SAME `measurements` read paths, and never touches `sessions` or
        // `workout_entries`, so sleep dedup and workout dedup are byte-for-byte unaffected by its
        // presence (see `reconcileMetricConflicts`'s own doc for what it does and does not do).
        summary.suppressed += try measurements.transaction {
            try reconcileMetricConflicts(intervals, samples, batchId: batchId, now: now)
        }

        // (d) Episodes -> sessions (+ stages). Record which nights this run touched.
        // Invariant this scoping relies on: `range` must be a superset of any night whose
        // dedup state could need re-evaluation. True today (a fixed 90-day re-ingest always
        // re-covers every prior night), but re-verify before incremental/delta sync ships,
        // since a partial-range sync could otherwise skip re-dedup for an untouched night.
        var affectedNights = Set<String>()
        for batch in sessionDTOs.badanChunked(Self.writeBatchSize) {
            try measurements.transaction {
                let (nights, written) = try writeSessions(batch, now: now, origin: origin)
                affectedNights.formUnion(nights)
                summary.sessions += written
            }
        }

        // (d1) (AUDIT 2026-08-06, SLEEP-H2) Hold every fully-rebuilt night to the set the port
        // just emitted for it. Runs after (d) so the fresh rows exist, and before (e) so the
        // night is reconciled against the corrected set rather than against the orphan.
        if !rebuiltNights.isEmpty {
            try measurements.transaction {
                try pruneRebuiltNights(rebuiltNights, emitted: sessionDTOs, now: now)
            }
            // A night the rebuild emptied has no DTO and so never reached `affectedNights` via
            // `writeSessions` — but its rollups still name sessions that are now tombstoned, so it
            // has to be reconciled too.
            affectedNights.formUnion(rebuiltNights)
        }

        // (d2) Workout episodes -> sessions (+ routes). Batched on the same rule; a workout's
        // route rows are written inside the same transaction as the session they belong to, so a
        // route can never outlive a failed session write and dangle against a missing
        // `session_id`.
        for batch in workoutDTOs.badanChunked(Self.writeBatchSize) {
            try measurements.transaction {
                let written = try writeWorkouts(batch, now: now, origin: origin)
                summary.workouts += written.sessions
                summary.routes += written.routes
            }
        }

        // (e)+(f) Dedup each affected night, then rebuild its daily sleep rollups. One
        // transaction per night: already naturally bounded (one night's sessions), and keeping
        // each night atomic means a night is never left half-reconciled.
        for night in affectedNights.sorted() {
            summary.suppressed += try measurements.transaction {
                try dedup(night: night, priorityBySource: priorityBySource, batchId: batchId, now: now)
            }
        }

        // (g) `workout.session_overlap.v1`. Runs after every workout has landed, so a manual
        // entry is compared against the complete ingested set for its window rather than against
        // whichever batch happened to contain its twin.
        if !workoutDTOs.isEmpty {
            summary.suppressed += try measurements.transaction {
                try dedupWorkouts(workoutDTOs, batchId: batchId, now: now)
            }
        }

        return summary
    }

    /// (d2) Ingested workouts -> `sessions` rows with a versioned `WorkoutDetail` payload
    /// (plan §9.1), plus their consent-gated routes.
    ///
    /// Workouts are attributed to the local day they START in, deliberately unlike sleep, which
    /// `DayAttribution.localNight` attributes to the morning it ENDS. A 23:30 run belongs to that
    /// evening — calling it tomorrow's workout because it crossed midnight would misfile it
    /// against the day the person actually trained. Sleep's rule exists because a night that
    /// begins on Tuesday is universally called "Tuesday night"; no equivalent convention makes a
    /// late run belong to Wednesday.
    private func writeWorkouts(_ workoutDTOs: ArraySlice<WorkoutDTO>,
                               now: Date, origin: IngestOrigin) throws -> (sessions: Int, routes: Int) {
        var writtenSessions = 0
        var writtenRoutes = 0
        for dto in workoutDTOs {
            let detail = WorkoutDetail(
                activityType: dto.activityType, totals: dto.totals,
                sourceWorkoutUUID: dto.sourceWorkoutUUID,
                // `hrSeriesRef` names the canonical series the workout's window is read against
                // (plan §9.1) — the samples themselves are already in `raw_samples` from the
                // heart-rate read path, and copying them per workout would duplicate the store's
                // largest table for no new information.
                hrSeriesRef: MetricID.heartRate)
            let session = Session(
                id: ULID.newID(), kind: .workout, subtype: dto.activityType, startAt: dto.start,
                endAt: dto.end, tzId: dto.tz,
                localNight: DayAttribution.localDayKey(dto.start, tz: dto.tz),
                detail: SessionDetail(workout: detail),
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                               externalId: dto.externalId, measuredAt: dto.start,
                                               tz: dto.tz, now: now, origin: origin,
                                               qualityFlags: dto.qualityFlags),
                updatedAt: now, originDeviceId: deviceId)
            let isNew = try measurements.upsertSession(session)
            if isNew { writtenSessions += 1 }

            // The session id that actually won: `upsertSession` returns false when an existing
            // row was updated, and in that case the route must attach to the STORED row's id,
            // not to the freshly-generated one we tried to insert. Re-reading by identity is the
            // only way to learn it, and it only happens for workouts that carry a route.
            guard let routeDTO = dto.route, let routes else { continue }
            let ownerId = isNew ? session.id
                : try measurements.session(externalId: dto.externalId, sourceId: dto.sourceId)?.id
            guard let ownerId else { continue }
            if try writeRoute(routeDTO, sessionId: ownerId, workout: dto, now: now,
                              repository: routes, origin: origin) {
                writtenRoutes += 1
            }
        }
        return (writtenSessions, writtenRoutes)
    }

    /// Store one consented route and point its session's `WorkoutDetail.routeRef` at it.
    ///
    /// The `routeRef` write is a second `upsertSession` rather than something folded into the
    /// first, because the route's id is only known after `RouteRepository.upsert` resolves which
    /// row won. Cheap (one workout, one update) and it keeps the invariant that a `routeRef` in
    /// the database always names a route row that exists — the alternative, guessing the id
    /// before writing it, produces a dangling reference whenever the route write fails.
    ///
    /// (I1) The route carries the full embedded provenance of the workout that produced it, not
    /// a reduced version: it came from the same source, the same device, the same ingestion path
    /// and the same instant. Its points inherit that through `route_id` (see migration v4).
    private func writeRoute(_ routeDTO: RouteDTO, sessionId: String, workout: WorkoutDTO,
                            now: Date, repository: RouteRepository, origin: IngestOrigin) throws -> Bool {
        // Belt-and-braces: the adapter does not read routes without consent, so an
        // un-granted snapshot should be unreachable. It is checked anyway because this is the
        // last point before location data becomes rows on disk, and the cost of the check is
        // nothing next to the cost of being wrong about the layer above.
        guard routeDTO.consent.granted, !routeDTO.points.isEmpty else { return false }

        let provenance = platformProvenance(sourceId: workout.sourceId, deviceId: workout.deviceId,
                                            externalId: routeDTO.externalId, measuredAt: workout.start,
                                            tz: workout.tz, now: now, origin: origin,
                                            qualityFlags: workout.qualityFlags)
        let routeId = ULID.newID()
        let points = routeDTO.points.enumerated().map { index, p in
            RoutePoint(routeId: routeId, seq: index, latitude: p.latitude, longitude: p.longitude,
                       altitudeMeters: p.altitudeMeters,
                       horizontalAccuracyMeters: p.horizontalAccuracyMeters, timestamp: p.timestamp)
        }
        let route = WorkoutRoute(
            id: routeId, sessionId: sessionId, pointCount: points.count,
            startAt: points.first?.timestamp ?? workout.start,
            endAt: points.last?.timestamp ?? workout.end,
            consentSnapshot: routeDTO.consent, provenance: provenance,
            updatedAt: now, originDeviceId: deviceId)
        let storedId = try repository.upsert(route, points: points)

        if var session = try measurements.session(id: sessionId),
           session.detail.workout?.routeRef != storedId {
            session.detail.workout?.routeRef = storedId
            session.updatedAt = now
            try measurements.upsertSession(session)
        }
        return true
    }

    /// (c) Instant readings -> raw_samples (canonicalized, provenance stamped).
    private func writeSamples(_ samples: ArraySlice<SampleDTO>, now: Date, origin: IngestOrigin) throws -> Int {
        var written = 0
        for dto in samples {
            guard let def = registry.definition(dto.metricId) else { continue }
            let (value, flags) = canonicalValue(dto.value, from: dto.unit, canonical: def.canonicalUnit)
            let sample = RawSample(
                id: ULID.newID(), metricId: dto.metricId, value: value, unit: def.canonicalUnit,
                originalValue: dto.value, originalUnit: dto.unit, startAt: dto.start, endAt: dto.end,
                tzId: dto.tz,
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                                externalId: dto.externalId, measuredAt: dto.start,
                                                tz: dto.tz, now: now, origin: origin,
                                                qualityFlags: dto.qualityFlags + flags),
                updatedAt: now, originDeviceId: deviceId)
            if try measurements.upsertRawSample(sample) { written += 1 }
        }
        return written
    }

    /// (c) Normalized aggregates -> interval_records.
    private func writeIntervals(_ intervals: ArraySlice<IntervalDTO>, now: Date, origin: IngestOrigin) throws -> Int {
        var written = 0
        for dto in intervals {
            guard let def = registry.definition(dto.metricId) else { continue }
            if dto.isRecomputedDailyTotal, dto.value == 0 {
                // (BUG-10b) A zero-sum day on a recomputed total means every contributing sample
                // the platform store knows about for that day summed to zero — either genuinely
                // no activity, or (the case this exists for) every sample was deleted since the
                // last sync. Only write it when a row already exists at this identity: that's
                // the correction case. A fresh zero row for a day the store has simply never
                // reported anything for (e.g. before the user owned a phone/watch) would
                // manufacture up to 90 noise rows on every first-connect backfill, which is
                // exactly the failure mode this guard exists to avoid — see
                // `HealthKitAdapter.readDailySum`'s doc for why the adapter emits the zero-day
                // DTO unconditionally and leaves this decision to the pipeline, which is the
                // layer with DB access to make it.
                //
                // (EPIC-01) Keyed off `isRecomputedDailyTotal` rather than
                // `metricId == MetricID.steps`, which is what it said while steps was the only
                // type read this way. Active energy, basal energy, distance and flights are read
                // by the identical statistics-collection strategy and need the identical
                // treatment; an id list would have had to grow in lockstep with `HKTypeMap`, and
                // forgetting to grow it fails in the silent direction (up to 90 fabricated
                // zero rows per family per first connect).
                guard try measurements.intervalRecordExists(metricId: dto.metricId, externalId: dto.externalId) else { continue }
            }
            let (value, flags) = canonicalValue(dto.value, from: dto.unit, canonical: def.canonicalUnit)
            let record = IntervalRecord(
                id: ULID.newID(), metricId: dto.metricId, value: value, unit: def.canonicalUnit,
                startAt: dto.start, endAt: dto.end, tzId: dto.tz, aggregation: dto.aggregation,
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                                externalId: dto.externalId, measuredAt: dto.start,
                                                tz: dto.tz, now: now, origin: origin,
                                                qualityFlags: dto.qualityFlags + flags),
                updatedAt: now, originDeviceId: deviceId)
            if try measurements.upsertIntervalRecord(record) { written += 1 }
        }
        return written
    }

    /// (d) Episodes -> sessions (+ stages). Returns the nights this batch touched, so the caller
    /// can reconcile each of them once after every session has landed.
    private func writeSessions(_ sessionDTOs: ArraySlice<SessionDTO>,
                               now: Date, origin: IngestOrigin) throws -> (nights: Set<String>, written: Int) {
        var affectedNights = Set<String>()
        var written = 0
        for dto in sessionDTOs {
            let night = DayAttribution.localNight(sessionEnd: dto.end, tz: dto.tz)
            affectedNights.insert(night)
            let session = Session(
                id: ULID.newID(), kind: dto.kind, subtype: dto.subtype, startAt: dto.start,
                endAt: dto.end, tzId: dto.tz, localNight: night,
                detail: SessionDetail(timeAsleepSeconds: dto.timeAsleepSeconds,
                                      timeInBedSeconds: dto.timeInBedSeconds,
                                      stageSummarySeconds: stageSummary(dto.stages)),
                provenance: platformProvenance(sourceId: dto.sourceId, deviceId: dto.deviceId,
                                               externalId: dto.externalId, measuredAt: dto.start,
                                               tz: dto.tz, now: now, origin: origin,
                                               qualityFlags: dto.qualityFlags),
                updatedAt: now, originDeviceId: deviceId)
            let stages = dto.stages.enumerated().map { i, s in
                SessionStage(sessionId: session.id, seq: i, stage: s.stage, startAt: s.start, endAt: s.end)
            }
            if try measurements.upsertSession(session, stages: stages) { written += 1 }
        }
        return (affectedNights, written)
    }

    /// (d1) (AUDIT 2026-08-06, SLEEP-H2) Tombstone every stored sleep session in a fully-rebuilt
    /// night that the rebuild no longer claims.
    ///
    /// The leak this closes: `HealthKitAdapter.disambiguateWithinNight` numbers a night's clusters
    /// by POSITION within the night (`base`, `base-1`, `base-2`), so deleting the night's LAST
    /// cluster in Health makes the rebuild emit `base` and `base-1` and simply stop mentioning
    /// `base-2`. Nothing then removed it: `writeSessions` only upserts, sleep never populates
    /// `HealthStoreDeletions.sessions` (that list is written exclusively by the workout read —
    /// see the comment on the deletions loop above), and `DedupLite` suppresses only losers that
    /// OVERLAP a winner, which a cluster at a different time of day never does. The orphan stayed
    /// live and unsuppressed and kept feeding `SleepIntelligenceEngine` — as nap credit against
    /// the following night's need, or as asleep seconds inflating the night's total. Deleting an
    /// EARLIER cluster happened to self-heal (the survivor shifts down into the lower-ordinal id
    /// and the two rows then overlap 1.0, so dedup suppresses one), which is why this only ever
    /// showed up for the trailing cluster — the afternoon nap, i.e. the common case.
    ///
    /// Soft-deleted, never hard (I3), and revivable: `upsertSession`'s `DO UPDATE SET` carries
    /// `deleted_at=excluded.deleted_at`, so a cluster that comes back is un-tombstoned by the next
    /// rebuild rather than staying dead.
    ///
    /// Two scoping conditions, both required, so this can only ever reach rows the rebuild
    /// actually owns: the row's `ingestionPath` is `.platformStore`, and its `externalId` is in
    /// `HealthKitAdapter.sleepExternalIdPrefix`'s namespace. A manually-logged or
    /// differently-imported sleep row for the same night is left alone. Nights the port did not
    /// report as rebuilt are never visited at all — a partial-range or delta-only sync would
    /// otherwise tombstone live sessions it simply had not read.
    private func pruneRebuiltNights(_ nights: Set<String>, emitted: [SessionDTO], now: Date) throws {
        var emittedIdsByNight: [String: Set<String>] = [:]
        for dto in emitted {
            emittedIdsByNight[DayAttribution.localNight(sessionEnd: dto.end, tz: dto.tz), default: []]
                .insert(dto.externalId)
        }
        for night in nights.sorted() {
            // Absent rather than empty is the same thing here, and deliberately so: a night the
            // rebuild emptied (every sample deleted in Health) must have its stale rows removed,
            // which is the case F4 exists for and could not previously reach.
            let stillClaimed = emittedIdsByNight[night] ?? []
            for stored in try measurements.allSleepSessions(localNight: night, includeSuppressed: true) {
                guard stored.provenance.ingestionPath == .platformStore,
                      let externalId = stored.provenance.externalId,
                      externalId.hasPrefix(HealthKitAdapter.sleepExternalIdPrefix),
                      !stillClaimed.contains(externalId)
                else { continue }
                try measurements.softDelete(table: "sessions", metricId: nil, externalId: externalId,
                                            sourceId: stored.provenance.sourceId, updatedAt: now)
            }
        }
    }

    // MARK: - Dedup + derived rollups

    /// Reconcile one night and return how many *new* suppressions were journaled.
    ///
    /// Primary sleep and naps are reconciled as two independent same-kind competitions
    /// (never mixed into one winner pool): the downstream daily-sleep rollup below only ever
    /// reads `sleepPrimary` rows, so a long/high-priority nap must never be able to out-rank the
    /// night's actual primary sleep session.
    private func dedup(night: String, priorityBySource: [String: Int],
                       batchId: String, now: Date) throws -> Int {
        let sessions = try measurements.allSleepSessions(localNight: night, includeSuppressed: true)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let priority: (String) -> Int = { priorityBySource[$0] ?? 0 }
        let primaryOutcome = DedupLite.reconcile(sessions: sessions.filter { $0.kind == .sleepPrimary },
                                                 priorityForSource: priority)
        let napOutcome = DedupLite.reconcile(sessions: sessions.filter { $0.kind == .sleepNap },
                                             priorityForSource: priority)

        var newSuppressions = 0
        for outcome in [primaryOutcome, napOutcome] {
            for sup in outcome.suppressed {
                // Idempotent: already suppressed by this winner -> don't re-suppress or re-journal.
                if byId[sup.loserId]?.provenance.suppressedBy == sup.winnerId { continue }
                try measurements.setSuppressed(table: "sessions", recordId: sup.loserId,
                                               by: sup.winnerId, updatedAt: now)
                try reconciliation.insert(ReconciliationDecision(
                    id: ULID.newID(), batchId: batchId, rule: DedupLite.ruleId, ruleVersion: "v1",
                    keptRecordId: sup.winnerId, suppressedRecordId: sup.loserId, score: sup.score,
                    decidedAt: now, detail: sup.detail))
                newSuppressions += 1
            }
        }

        // Compensate: un-suppress any session whose recorded suppressor is stale under this
        // run's fresh outcome (e.g. a device-name/priority change flipped which source wins).
        // Without this, an old winner's suppression could outlive the winner that caused it,
        // leaving two simultaneously-visible "surviving" sessions for the same night.
        let currentLoserIds = Set(primaryOutcome.suppressed.map { $0.loserId } + napOutcome.suppressed.map { $0.loserId })
        for s in sessions where s.provenance.suppressedBy != nil && !currentLoserIds.contains(s.id) {
            try measurements.setSuppressed(table: "sessions", recordId: s.id, by: nil, updatedAt: now)
        }

        // Record lineage on the primary-sleep winner (which raw sessions were merged into it).
        if let winnerId = primaryOutcome.winnerId {
            let loserIds = primaryOutcome.suppressed.map { $0.loserId }.sorted()
            if !loserIds.isEmpty, var winner = byId[winnerId],
               Set(winner.detail.mergedFrom) != Set(loserIds) {
                winner.detail.mergedFrom = loserIds
                winner.updatedAt = now
                try measurements.upsertSession(winner)
            }
        }

        // (e) Rebuild the night's daily sleep rollups from the surviving primary sleep so
        // charts/baselines read one uniform interval regardless of how many sources reported.
        //
        // (AUDIT 2026-08-06, SLEEP-H1) The night's TOTAL, summed across every surviving primary
        // cluster — deliberately not `measurements.primarySleep(localNight:)`, which returns ONE
        // row. A night can legitimately hold more than one unsuppressed `sleepPrimary`:
        // `HealthKitAdapter.makeSession` calls any cluster with at least
        // `sleepPrimaryMinSeconds` (3h) of asleep time primary, `groupIntoSessions` splits on any
        // wake gap over `sleepClusterGapSeconds` (3h), and `DedupLite.reconcile` only suppresses
        // losers that actually OVERLAP a winner — two disjoint clusters score 0 against each other
        // and both survive. `SleepIntelligenceEngine.assembleNights` sums them on purpose ("a
        // split night is one night's sleep, not two", golden-tested), so a single-row rollup made
        // `sleep.time_asleep` state a fraction of the night the derivation layer had already
        // agreed was one night — and `BaselineEngine.latestPerDay` reads that understated interval
        // back in as the baseline the engine then scores the full total against.
        //
        // Ordered `start_at ASC` by `allSleepSessions`, so `first` is the night's earliest
        // cluster. That is deliberately the anchor for provenance and lineage: it matches
        // `SleepNight.primarySessionId` (`sessionIds.first` over start-sorted clusters), so the
        // rollup and the derived night name the same session as the night's origin.
        let primaries = try measurements.allSleepSessions(localNight: night, includeSuppressed: false)
            .filter { $0.kind == .sleepPrimary }
        if let anchor = primaries.first {
            try upsertDailySleepInterval(metricId: "sleep.time_asleep",
                                         seconds: totalSeconds(primaries.map { $0.detail.timeAsleepSeconds }),
                                         winner: anchor, night: night, now: now)
            try upsertDailySleepInterval(metricId: "sleep.time_in_bed",
                                         seconds: totalSeconds(primaries.map { $0.detail.timeInBedSeconds }),
                                         winner: anchor, night: night, now: now)
            try upsertStageIntervals(primaries: primaries, anchor: anchor, night: night, now: now)
        } else {
            try tombstoneSleepRollups(night: night, now: now)
        }
        return newSuppressions
    }

    /// (SLEEP-H2) A night with no surviving primary sleep must not keep the derived rollups a
    /// previous run wrote for it.
    ///
    /// Newly reachable because the rebuilt-night prune above can now empty a night whose sleep the
    /// user deleted in Health. Without this, `sleep.time_asleep` (and its stage siblings) would
    /// keep reporting a night that no longer has a session behind it — the same "BADAN kept
    /// showing sleep the user had already removed" failure one layer up, and worse than the gap
    /// because the number looks measured.
    ///
    /// Soft-deleted rather than suppressed, unlike the winner-flip cases in
    /// `upsertDailySleepInterval`/`suppressStageRollupWithoutABasis`: those have a winner to point
    /// `suppressed_by` at, and this case is defined by there not being one. Revivable for the same
    /// reason every tombstone here is — `upsertIntervalRecord` carries `deleted_at` across, so if
    /// primary sleep returns to this night the next rollup write un-deletes the row in place.
    private func tombstoneSleepRollups(night: String, now: Date) throws {
        for metricId in ["sleep.time_asleep", "sleep.time_in_bed"] + Self.stageRollupMetrics {
            try measurements.softDelete(table: "interval_records", metricId: metricId,
                                        externalId: "derived.\(metricId).\(night)",
                                        sourceId: nil, updatedAt: now)
        }
    }

    /// (SLEEP-H1) Sum the figures that are present, or `nil` when none is.
    ///
    /// The `nil` matters: it keeps `upsertDailySleepInterval`'s "no basis, write nothing" branch
    /// reachable for a night whose sources reported no asleep/in-bed figure at all, rather than
    /// collapsing that absence into a fabricated `0 s` carrying full provenance. A cluster that
    /// reported nothing simply contributes nothing to a night where another cluster did.
    private func totalSeconds(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }

    /// `workout.session_overlap.v1` (EPIC-03, plan §9.1): an ingested workout suppresses a
    /// manually-logged twin. Returns how many *new* suppressions were journaled.
    ///
    /// Suppression here is journal-only, and that is a schema fact rather than a shortcut:
    /// `workout_entries` (migration v1) carries no `suppressed_by` column, so there is no flag to
    /// set — and adding one would mean a new migration, which this change does not need. I3 is
    /// satisfied without it: the manual row is never touched, the decision is written to
    /// `dedup_decisions` with `reversible = true`, and read models resolve suppression through
    /// `ReconciliationRepository.forSuppressed(entryId)` — whose backing index
    /// `idx_dedup_suppressed` exists precisely for this lookup direction. Reversal is
    /// `markReversed`, after which the entry reappears with nothing to restore, because nothing
    /// was ever removed.
    ///
    /// **Any surface listing manual workouts must consult `forSuppressed`** — a unified workout
    /// list that reads `LoggingRepository.workouts` alone will show both the ingested workout and
    /// its manual twin, which is the duplicate this rule exists to remove.
    ///
    /// Idempotent by the same shape the sleep rule uses, adapted to the journal: a decision that
    /// already names this winner is skipped rather than re-inserted, so a re-ingest journals
    /// nothing and `summary.suppressed` stays 0.
    private func dedupWorkouts(_ workoutDTOs: [WorkoutDTO], batchId: String, now: Date) throws -> Int {
        guard let logging else { return 0 }
        guard let earliest = workoutDTOs.map(\.start).min(),
              let latest = workoutDTOs.map(\.end).max() else { return 0 }

        // Scoped to the span this run's workouts actually cover rather than to the whole ingest
        // range. On a first-connect backfill the two are nearly the same, but on the ordinary
        // case — an incremental sync delivering one new workout — this reads a day of manual
        // entries instead of ninety. Padded by one day on each side so a manual entry typed with
        // a rough start/end still overlaps its twin.
        let padding: TimeInterval = 86_400
        let manual = try logging.workouts(from: earliest.addingTimeInterval(-padding),
                                          to: latest.addingTimeInterval(padding))
        guard !manual.isEmpty else { return 0 }
        let ingested = try measurements.sessions(kind: .workout,
                                                 from: earliest.addingTimeInterval(-padding),
                                                 to: latest.addingTimeInterval(padding))

        var newSuppressions = 0
        for suppression in DedupLite.reconcileWorkouts(ingested: ingested, manual: manual) {
            let existing = try reconciliation.forSuppressed(suppression.manualEntryId)
            if existing?.keptRecordId == suppression.ingestedSessionId { continue }
            try reconciliation.insert(ReconciliationDecision(
                id: ULID.newID(), batchId: batchId, rule: DedupLite.workoutRuleId,
                ruleVersion: DedupLite.workoutRuleVersion,
                keptRecordId: suppression.ingestedSessionId,
                suppressedRecordId: suppression.manualEntryId,
                score: suppression.score, decidedAt: now, detail: suppression.detail))
            newSuppressions += 1
        }
        return newSuppressions
    }

    // MARK: - Reconciliation-v2 (EPIC-43 follow-up slice, plan §7A.6/§9.19)

    /// Metric ids where two sources disagreeing about the SAME day is worth surfacing at all. A
    /// short, explicit list — not "every metric" — because a cross-source disagreement is only a
    /// meaningful question for a metric that names ONE true daily fact (an overnight HRV/resting-
    /// heart-rate average, a single body weight for the day). Two sources reporting different
    /// STEP counts for a day, say, is normal (different sensors count differently) and not a
    /// "which one is right" question this engine should ever answer. Mirrors
    /// `ConflictDecisionEngine.manualWinsMetrics`'s own "named list, not every metric" shape.
    ///
    /// Split by which table backs the metric (`interval_records` vs `raw_samples`) because that's
    /// what decides which existing `MeasurementRepository` read path resolves its candidates.
    ///
    /// `internal` rather than `private` (2026-07-27) so `ConflictResolutionService` can resolve a
    /// conflict back to the SAME table this detector wrote it from, instead of re-deriving that
    /// mapping from the registry's `kind`. Re-deriving looked equivalent and is not:
    /// `heart.rhr`/`heart.hrv` are `kind: derived` in `registry.json` yet are detected out of
    /// `interval_records` here, so a registry-driven copy returned "no table" for exactly the two
    /// metrics that produce most real conflicts — the resolve action would have compiled, shipped,
    /// and silently done nothing. Same two-copies-drift failure this file's own audit-fix comment
    /// below already describes for `CandidateReading.classification`.
    static let intervalConflictMetrics: Set<String> = [MetricID.restingHeartRate, MetricID.hrv]
    // (A21/D-26) `MetricID.glucose` rides the GENERAL reconciliation-v2 path, deliberately NOT
    // `ConflictDecisionEngine.manualWinsMetrics` (I4's weight rule): the blueprint DESCRIBES a
    // glucose-specific source-priority order (store point > vendor API > fingerstick) as the
    // eventual intent, but no such rule is seeded anywhere today — grepped `SourcePriorityRule.swift`
    // /`SourcePriorityRuleRepository.swift`/`SourcePriorityEditorScreen.swift` (audit 2026-07-24):
    // no default `body.glucose` row exists in any of them. A manual fingerstick is its own
    // lowest-priority CLASSIFICATION (already `SourcePriorityRule.ClassificationKey.manual`, which
    // every manual entry gets from `classification(forSourceId:isManualEntry:)` below regardless of
    // metric), not an automatic override — so it only wins a conflict if a saved `SourcePriorityRule`
    // for `body.glucose` ranks it above whatever device sources disagreed, and only once such a rule
    // is actually created (today: never seeded, only ever user-authored via the Source Priority
    // Editor). With no vendor integration built yet (A21 defers that) and no seeded rule either, only
    // the "two platform-store sources disagree, no saved rule" case is reachable today, which falls
    // straight to this general path's unresolved-conflict-surfaced-to-the-user fallback (rule 5:
    // `SourcePriorityRule` if one exists, else left unresolved) — safe and correct, just not yet the
    // specific store>vendor>fingerstick ordering the blueprint eventually wants.
    /// `internal` for the reason `intervalConflictMetrics` above documents.
    static let sampleConflictMetrics: Set<String> = [MetricID.weight, MetricID.glucose]

    /// A relative difference below this is "the same reading, twice" (per-source rounding/sensor
    /// noise), not a genuine disagreement — never worth flagging. Chosen generously (5%) so this
    /// stays a "two sources meaningfully disagree" detector, not a hair-trigger on ordinary
    /// measurement noise between two otherwise-agreeing devices.
    private static let materialDifferenceThreshold = 0.05

    /// The missing caller `DataConflictsScreen`'s own doc names: detects genuine cross-source
    /// disagreements for `intervalConflictMetrics`/`sampleConflictMetrics` on the days THIS run's
    /// intervals/samples touched, and either auto-resolves a confident one (a `SourcePriorityRule`
    /// winner, or one of `ConflictDecisionEngine`'s unconditional named defaults such as most-
    /// recent-weight-wins) — suppressing the loser and journaling a `ReconciliationDecision`
    /// exactly like `dedup(night:...)` above already does for sleep — or, when `decide` returns
    /// `nil`, leaves it for the person to resolve by inserting a NEW `DataConflict` row
    /// (`DataConflictsScreen`'s "Unresolved" list).
    ///
    /// Without `dataConflicts` wired (see its own doc on the stored property), this is a no-op:
    /// nothing is read, nothing is suppressed, nothing is journaled — the same "the rule simply
    /// does not run" contract `logging`/`routes` already have on this type.
    ///
    /// Entirely additive and orthogonal to sleep/workout dedup: it only ever reads
    /// `interval_records`/`raw_samples` for `MetricID.restingHeartRate`/`.hrv`/`.weight` and only
    /// ever writes `data_conflicts` or `dedup_decisions` (+ that record's own `suppressed_by`) —
    /// it never reads or writes `sessions`/`workout_entries`, so `dedup(night:...)` and
    /// `dedupWorkouts` above run exactly as they did before this method existed.
    private func reconcileMetricConflicts(_ intervalDTOs: [IntervalDTO], _ sampleDTOs: [SampleDTO],
                                          batchId: String, now: Date) throws -> Int {
        guard let dataConflicts else { return 0 }

        // Which (metric, day) windows THIS run actually touched — scoped this way (not "every day
        // in the range") for the same reason `dedup`'s `affectedNights` is scoped to nights
        // sessions touched: bounding an ordinary incremental sync to a day or two of work instead
        // of re-scanning the whole range on every run.
        struct ConflictWindow: Hashable { let metricId: String; let dayKey: String; let tz: String }
        var intervalWindows = Set<ConflictWindow>()
        for dto in intervalDTOs where Self.intervalConflictMetrics.contains(dto.metricId) {
            intervalWindows.insert(ConflictWindow(metricId: dto.metricId,
                                                   dayKey: DayAttribution.localDayKey(dto.start, tz: dto.tz), tz: dto.tz))
        }
        var sampleWindows = Set<ConflictWindow>()
        for dto in sampleDTOs where Self.sampleConflictMetrics.contains(dto.metricId) {
            sampleWindows.insert(ConflictWindow(metricId: dto.metricId,
                                                 dayKey: DayAttribution.localDayKey(dto.start, tz: dto.tz), tz: dto.tz))
        }
        guard !intervalWindows.isEmpty || !sampleWindows.isEmpty else { return 0 }

        // AUDIT FIX (debt-closeout wave 2): fetched ONCE per ingest run (not per window) so
        // `classification(forSourceId:isManualEntry:)` below can resolve each candidate's real
        // classification without a query per candidate. Before this fix, `CandidateReading.classification`
        // was never set at all here, so it silently defaulted to `""` — which never matches any of
        // `SourcePriorityRule.ClassificationKey`'s non-empty constants, meaning a saved
        // `SourcePriorityRule` (and the hardcoded chest-strap default) could NEVER actually resolve a
        // real conflict, regardless of what a person configured in Source Priority Editor.
        let sources = try catalog.sources(includeHidden: true)
        let devicesBySource = Dictionary(grouping: try catalog.devices(), by: \.sourceId)
        let sourcesById = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        func classification(forSourceId sourceId: String, isManualEntry: Bool) -> String {
            if isManualEntry { return SourcePriorityRule.ClassificationKey.manual }
            guard let source = sourcesById[sourceId] else { return "" }
            let classId = SensorQualityMap.shared.classId(for: source, devices: devicesBySource[sourceId] ?? [])
            return SourcePriorityRule.ClassificationKey.fromSensorClassId(classId) ?? ""
        }

        var newDecisions = 0
        for w in intervalWindows.sorted(by: { ($0.metricId, $0.dayKey) < ($1.metricId, $1.dayKey) }) {
            guard let dayStart = DayAttribution.date(fromDayKey: w.dayKey, tz: w.tz) else { continue }
            let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: w.tz)
            let records = try measurements.intervalRecords(metricId: w.metricId, from: dayStart, to: dayEnd,
                                                            includeSuppressed: false)
            newDecisions += try reconcileConflictWindow(records: records, table: "interval_records",
                                                        metricId: w.metricId, dayStart: dayStart, dayEnd: dayEnd,
                                                        batchId: batchId, now: now, dataConflicts: dataConflicts,
                                                        classification: classification)
        }
        for w in sampleWindows.sorted(by: { ($0.metricId, $0.dayKey) < ($1.metricId, $1.dayKey) }) {
            guard let dayStart = DayAttribution.date(fromDayKey: w.dayKey, tz: w.tz) else { continue }
            let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: w.tz)
            let records = try measurements.rawSamples(metricId: w.metricId, from: dayStart, to: dayEnd,
                                                       includeSuppressed: false)
            newDecisions += try reconcileConflictWindow(records: records, table: "raw_samples",
                                                        metricId: w.metricId, dayStart: dayStart, dayEnd: dayEnd,
                                                        batchId: batchId, now: now, dataConflicts: dataConflicts,
                                                        classification: classification)
        }
        return newDecisions
    }

    /// One (metric, day) window's worth of `reconcileMetricConflicts` — generic over
    /// `IntervalRecord`/`RawSample` (see `ConflictRecord` below) so the interval- and sample-backed
    /// metrics share exactly one candidate-building/decide/persist path rather than two drifting
    /// copies of it.
    private func reconcileConflictWindow<T: ConflictRecord>(
        records: [T], table: String, metricId: String, dayStart: Date, dayEnd: Date,
        batchId: String, now: Date, dataConflicts: DataConflictRepository,
        classification: (_ sourceId: String, _ isManualEntry: Bool) -> String
    ) throws -> Int {
        let bySource = Dictionary(grouping: records, by: { $0.provenance.sourceId })
        // A conflict needs 2+ DIFFERENT sources reporting for this exact day — one source writing
        // several rows (which shouldn't happen under this metric's upsert identity, but costs
        // nothing to guard) is not a disagreement between sources.
        guard bySource.count >= 2 else { return 0 }

        // One candidate per source: its most-recently-measured reading in this window — the same
        // "most recent, id breaks a tie" idiom `ConflictDecisionEngine.mostRecent` already uses.
        let perSource: [T] = bySource.values.map { rows in
            rows.sorted { a, b in
                a.provenance.measuredAt != b.provenance.measuredAt
                    ? a.provenance.measuredAt > b.provenance.measuredAt : a.id < b.id
            }.first! // safe: `Dictionary(grouping:)` never produces an empty value array
        }

        // Not every multi-source day is a genuine disagreement — two sources CONFIRMING the same
        // reading (within `materialDifferenceThreshold`) is not a conflict, never flagged as one.
        let values = perSource.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max(), minValue != maxValue else { return 0 }
        guard (maxValue - minValue) / max(abs(minValue), abs(maxValue), 1) > Self.materialDifferenceThreshold
        else { return 0 }

        let candidates = perSource.map { record -> CandidateReading in
            let isManual = record.provenance.ingestionPath == .manual
            return CandidateReading(id: record.id, sourceId: record.provenance.sourceId,
                                    classification: classification(record.provenance.sourceId, isManual),
                                    isManualEntry: isManual, measuredAt: record.provenance.measuredAt)
        }
        let scope = ConflictScope.metric(id: metricId)
        let priorityRule = try sourcePriorityRules?.rule(forMetric: metricId)

        guard let outcome = ConflictDecisionEngine.decide(scope: scope, candidates: candidates, priorityRule: priorityRule)
        else {
            // Genuinely unresolved: surface it for the person to decide (I3/I5) rather than
            // guessing — unless an identical conflict is already open for this exact candidate
            // set, which keeps a re-ingest of the same disagreement from re-inserting duplicates.
            let candidateIds = Set(candidates.map(\.id))
            let alreadyOpen = try dataConflicts.conflicts(scopeKey: scope.storageKey).contains {
                $0.status == .unresolved && Set($0.candidateRecordIds) == candidateIds
            }
            guard !alreadyOpen else { return 0 }
            try dataConflicts.insert(DataConflict(
                id: ULID.newID(clock: clock), scope: scope, windowStart: dayStart, windowEnd: dayEnd,
                candidateRecordIds: candidates.map(\.id), detectedAt: now, updatedAt: now, originDeviceId: deviceId))
            return 0 // a new conflict is not itself a suppression
        }

        // Confident, auto-resolved: suppress the loser(s) and journal it exactly like the
        // existing dedup paths above (`dedup(night:...)`) already do for sleep.
        var written = 0
        for decision in outcome.makeDecisions(batchId: batchId, clock: clock) {
            // Idempotent, mirroring `dedupWorkouts`'s own check: a re-ingest reaching the identical
            // winner for this loser must not re-suppress or re-journal it.
            if try reconciliation.forSuppressed(decision.suppressedRecordId)?.keptRecordId == decision.keptRecordId {
                continue
            }
            try measurements.setSuppressed(table: table, recordId: decision.suppressedRecordId,
                                           by: decision.keptRecordId, updatedAt: now)
            try reconciliation.insert(decision)
            written += 1
        }
        return written
    }

    /// Upsert one derived daily sleep interval (unit "s"), keyed idempotently by night so a
    /// re-ingest updates in place.
    ///
    /// (DATA-01) The contract (`DayAttribution.localNight`) attributes a sleep session to the
    /// morning it ENDS. But every downstream day-keying — `BaselineEngine.latestPerDay` and
    /// `InsightEngine`'s day windowing, both via `MeasurementRepository.intervalRecords(from:to:)`
    /// which filters on `start_at` — keys off this row's `startAt`. Storing the winner's real
    /// bedtime there (the previous evening) silently shifted night N's sleep facts onto day
    /// N-1. Fixed by anchoring `startAt`/`endAt` to the *stored night's* day boundaries
    /// (`DayAttribution.date(fromDayKey:)`) instead of the session's real start/end — this row
    /// is a daily fact, not the session record, so it doesn't need to carry the literal
    /// bedtime/wake instants; that lineage already lives on the `Session` itself and is what
    /// the Metric Detail provenance row shows via `provenance.measuredAt` below, which we keep
    /// pointed at the real bedtime on purpose (verified no UI reads this row's own `startAt` as
    /// a clock time — only as a day-bucketing key).
    private func upsertDailySleepInterval(metricId: String, seconds: Double?,
                                          winner: Session, night: String, now: Date) throws {
        guard let seconds else { return }
        guard let dayStart = DayAttribution.date(fromDayKey: night, tz: winner.tzId) else { return }
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: winner.tzId)
        let externalId = "derived.\(metricId).\(night)"

        // Provenance is derived from the winning session; `measuredAt` intentionally keeps the
        // real bedtime (unlike `startAt` on the record itself) so lineage/provenance UI can
        // still show when sleep actually began.
        let provenance = Provenance(
            sourceId: winner.provenance.sourceId, deviceId: winner.provenance.deviceId,
            ingestionPath: .derived, externalId: externalId,
            measuredAt: winner.startAt, measuredTimezone: winner.tzId,
            recordedAt: now, ingestedAt: now, algorithmVersionId: DedupLite.ruleId)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: seconds, unit: "s",
            startAt: dayStart, endAt: dayEnd, tzId: winner.tzId,
            aggregation: .duration, provenance: provenance, updatedAt: now, originDeviceId: deviceId)
        try measurements.upsertIntervalRecord(record)

        // (DATA-05) The upsert identity is (metric_id, external_id, source_id). `externalId`
        // above is fixed per night, but `sourceId` is the dedup winner's — so a winner flip
        // across re-ingests (a device-priority/name change, or new data reversing last night's
        // decision) can't match the prior row under `ON CONFLICT`, leaving a stale rollup
        // stranded under the old source alongside the fresh one (two visible intervals for one
        // night). Rather than inventing a synthetic source id (which would blur the real
        // winning device's name out of the Metric Detail lineage row — verified that row reads
        // this exact `provenance.sourceId`), find every rollup row still carrying tonight's
        // `externalId` and suppress every one that isn't tonight's winner, un-suppressing the
        // winner's own row in case an earlier flip had suppressed it (mirrors the session-level
        // compensation loop in `dedup(night:...)` above).
        let rowsForNight = try measurements.intervalRecords(metricId: metricId, from: dayStart, to: dayEnd, includeSuppressed: true)
            .filter { $0.provenance.externalId == externalId }
        guard let currentRow = rowsForNight.first(where: { $0.provenance.sourceId == winner.provenance.sourceId }) else { return }
        for r in rowsForNight {
            let shouldBeSuppressed = r.id != currentRow.id
            if shouldBeSuppressed, r.provenance.suppressedBy != currentRow.id {
                try measurements.setSuppressed(table: "interval_records", recordId: r.id, by: currentRow.id, updatedAt: now)
            } else if !shouldBeSuppressed, r.provenance.suppressedBy != nil {
                try measurements.setSuppressed(table: "interval_records", recordId: r.id, by: nil, updatedAt: now)
            }
        }
    }

    // MARK: - Per-stage nightly rollups

    /// The four stage ids `registry.json` v0.2.0 carries, in a fixed order so a night's rows are
    /// written deterministically rather than in whatever order a dictionary iterates.
    private static let stageRollupMetrics = [MetricID.sleepAwake, MetricID.sleepDeep,
                                             MetricID.sleepLight, MetricID.sleepRem]

    /// (COV-01) Emit `sleep.deep` / `sleep.rem` / `sleep.light` / `sleep.awake` as daily interval
    /// rows for the night's dedup winner.
    ///
    /// The stage data itself has been ingested since the beginning — `writeSessions` stores every
    /// segment in `session_stages` and `SessionDetail.stageSummarySeconds` — but it existed ONLY
    /// as session detail, so four registry ids with real data behind them had no writer and read
    /// as empty everywhere a metric is read as a metric (Metric Detail, baselines, insights,
    /// CSV/JSON export). The audit counted them as not flowing, correctly.
    ///
    /// Goes through `upsertDailySleepInterval` rather than building rows here, deliberately: that
    /// method is where DATA-01's day-anchoring and DATA-05's winner-flip suppression live, and
    /// both bugs apply to a stage row exactly as they apply to `sleep.time_asleep`. Re-deriving
    /// either one at a second call site is how they come back.
    ///
    /// (SLEEP-H1) Summed over the night's whole surviving primary set for the same reason
    /// `sleep.time_asleep` is — a split night's second cluster is stage data belonging to this
    /// night, and reading one session's stages made `sleep.deep` disagree with a
    /// `sleep.time_asleep` that had just been written as the total. `anchor` (the earliest
    /// cluster) supplies provenance and the day key only.
    private func upsertStageIntervals(primaries: [Session], anchor: Session,
                                      night: String, now: Date) throws {
        let seconds = try stageSeconds(for: primaries)
        for metricId in Self.stageRollupMetrics {
            if let value = seconds[metricId] {
                try upsertDailySleepInterval(metricId: metricId, seconds: value,
                                             winner: anchor, night: night, now: now)
            } else {
                try suppressStageRollupWithoutABasis(metricId: metricId, winner: anchor,
                                                     night: night, now: now)
            }
        }
    }

    /// (SLEEP-H1) The night's per-stage seconds: every primary cluster that genuinely stages sleep,
    /// summed; empty when none of them does.
    ///
    /// Per cluster rather than over one flattened segment list, because `stageSeconds(forOne:)`'s
    /// `sleep.awake` clipping is defined relative to *that cluster's* sleep onset. A split night
    /// has two onsets — the second cluster's settling-down stretch is pre-onset time for that
    /// cluster, not post-onset wakefulness of the first — so flattening would fold a whole
    /// re-settling period into "awake after sleep onset" and overstate the metric under its own
    /// registry label. A cluster that stages nothing contributes nothing rather than zeros, which
    /// keeps the honesty gate meaningful on a night where only one source staged.
    private func stageSeconds(for sessions: [Session]) throws -> [String: Double] {
        var totals: [String: Double] = [:]
        for session in sessions {
            let perCluster = try stageSeconds(forOne: session)
            guard !perCluster.isEmpty else { continue }
            for (metricId, value) in perCluster { totals[metricId, default: 0] += value }
        }
        return totals
    }

    /// (COV-01) Per-stage seconds for ONE primary cluster, or an EMPTY map when this source does
    /// not stage sleep at all. Summed across the night's clusters by `stageSeconds(for:)` above.
    ///
    /// Read from `session_stages` rather than from the winner's `detail.stageSummarySeconds`,
    /// even though the latter is already sitting in memory. `sleep.awake` is defined by the
    /// registry as awake time *after sleep onset* ("Awake time after sleep onset", explainer:
    /// "The total time you were awake after first falling asleep") — a flat stage→seconds summary
    /// has thrown away the ordering needed to tell the settling-down stretch before sleep from a
    /// mid-night waking, so summing its `awake` bucket would overstate the metric by the whole
    /// sleep-onset latency. That is wrong under the metric's own label, not merely imprecise, and
    /// it is the kind of error nobody catches from a chart.
    ///
    /// The empty-map guard is the honesty gate. It requires at least one of deep/REM/light before
    /// emitting anything, because that is what distinguishes a source that stages sleep from one
    /// that does not: HealthKit's unstaged vocabulary is `inBed`/`awake`/`asleepUnspecified` (see
    /// `HealthKitAdapter.mapSleepStage`), so a device that can only say "asleep" produces none of
    /// the three. Without the gate every such night would get four rows reading 0 s of deep, REM
    /// and light sleep — fabricated zeros carrying full provenance, which reads as "you got no
    /// deep sleep" rather than "this device doesn't measure that". Once the gate passes, a stage
    /// that is genuinely absent from a staged night IS zero, and writing 0 is a fact.
    ///
    /// `asleepUnspecified` time on an otherwise-staged night is deliberately attributed to no
    /// stage. It is time the source declined to classify, and folding it into `sleep.light`
    /// because light sleep is the most common stage would be a guess presented as a measurement.
    private func stageSeconds(forOne winner: Session) throws -> [String: Double] {
        let segments = try measurements.stages(sessionId: winner.id).sorted { $0.startAt < $1.startAt }
        guard segments.contains(where: { Self.stagedSleepMarkers.contains($0.stage) }),
              // Sleep onset: the first segment the source calls sleep of any kind. `inBed` is
              // excluded alongside `awake` for the same reason `HealthKitAdapter.makeSession`
              // excludes it from `timeAsleepSeconds` — it is a container for the night, not a
              // claim about being asleep.
              let onset = segments.first(where: { $0.stage != .awake && $0.stage != .inBed })?.startAt
        else { return [:] }

        var totals: [String: Double] = [MetricID.sleepAwake: 0, MetricID.sleepDeep: 0,
                                        MetricID.sleepLight: 0, MetricID.sleepRem: 0]
        for segment in segments {
            let duration = segment.endAt.timeIntervalSince(segment.startAt)
            switch segment.stage {
            case .deep: totals[MetricID.sleepDeep]? += duration
            case .rem: totals[MetricID.sleepRem]? += duration
            case .light: totals[MetricID.sleepLight]? += duration
            case .awake:
                // Clipped at onset so a segment straddling the moment sleep began contributes
                // only its post-onset part, and a wholly pre-onset one contributes nothing.
                totals[MetricID.sleepAwake]? += max(0, segment.endAt.timeIntervalSince(max(segment.startAt, onset)))
            case .inBed, .asleepUnspecified:
                continue
            }
        }
        return totals
    }

    /// The stages whose presence proves a source actually stages sleep — see `stageSeconds`.
    private static let stagedSleepMarkers: Set<SleepStage> = [.deep, .rem, .light]

    /// (COV-01) The winner-flip case DATA-05 does not reach: a night whose rollups were written
    /// from a staging source, whose dedup winner has since flipped to a source that stages
    /// nothing.
    ///
    /// `upsertDailySleepInterval`'s DATA-05 compensation only runs when a row is written, and it
    /// resolves "who won" by finding the row carrying the winner's `sourceId`. Neither holds
    /// here — nothing is written and no row for the new winner exists — so without this the old
    /// staging source's `sleep.deep` row would stay live under a night now attributed to a device
    /// that never measured a stage in its life. That is a real number attached to the wrong
    /// provenance, which is worse than the gap.
    ///
    /// Suppressed rather than deleted (I3), and the suppressor is the winning SESSION's id rather
    /// than another `interval_records` id, because in this case no interval row won — the session
    /// did. `Provenance.suppressedBy` is documented as "the winning record's id" and is not
    /// constrained to the same table; `dedupWorkouts` already journals a session id as the
    /// `keptRecordId` for a suppressed `workout_entries` row, so a cross-table lineage pointer is
    /// existing vocabulary here, not a new idea. Reversible by construction: if a staging source
    /// wins the night back, `upsertStageIntervals` takes the write branch and
    /// `upsertDailySleepInterval`'s compensation un-suppresses the winner's own row.
    private func suppressStageRollupWithoutABasis(metricId: String, winner: Session,
                                                  night: String, now: Date) throws {
        guard let dayStart = DayAttribution.date(fromDayKey: night, tz: winner.tzId) else { return }
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: winner.tzId)
        let externalId = "derived.\(metricId).\(night)"
        let rowsForNight = try measurements.intervalRecords(metricId: metricId, from: dayStart,
                                                            to: dayEnd, includeSuppressed: true)
            .filter { $0.provenance.externalId == externalId }
        // Idempotent in the same shape as `dedup`'s session loop: a row already suppressed by
        // this winner is left alone, so a re-ingest of a non-staging night writes nothing.
        for row in rowsForNight where row.provenance.suppressedBy != winner.id {
            try measurements.setSuppressed(table: "interval_records", recordId: row.id,
                                           by: winner.id, updatedAt: now)
        }
    }

    // MARK: - Sources / devices

    /// Upsert a Source (and Device, when present) per descriptor and return the sourceId ->
    /// dedup-priority map. Explicit descriptor priority wins; otherwise a wrist device
    /// outranks a phone (watch > phone), falling back to 0.
    ///
    /// (AUDIT 2026-08-06, INGESTION-01) The map covers every source in the STORED catalog, not
    /// only the ones THIS run's port handed over. `HistoricalHealthKitReader.sourceDescriptors()`
    /// deliberately returns `[]` — it reads the same store live sync already catalogued and must
    /// not race to author those rows — so on that path the map used to come back EMPTY, and
    /// `dedup(night:priorityBySource:)` resolved every source to `?? 0`. With every source tied at
    /// zero, `DedupLite.reconcile` fell straight through its priority comparison to "longest
    /// duration, then id": an Apple Watch night lost to a phone sleep-app's longer in-bed cluster,
    /// the compensation loop flipped the stored suppressions, and the rollups were rewritten from
    /// the phone's numbers — for EVERY night in the import window, including the ~90 days live
    /// sync had already reconciled correctly, since the two windows overlap by construction and
    /// `HistoricalHealthKitReader.readSessions` rebuilds every night in its range unconditionally.
    /// Nothing repaired it afterwards: live sync only re-dedups a night when HealthKit re-delivers
    /// a sleep sample for it, which never happens for settled history.
    ///
    /// The catalog is where the answer actually lives, so the map is seeded from there rather than
    /// from whichever descriptors happened to arrive.
    private func upsertSourcesAndDevices(_ descriptors: [SourceDescriptor], now: Date) throws -> [String: Int] {
        // Fetch the known device set once instead of re-querying per descriptor — devices
        // rarely change between ingest calls, and this runs on every sync, not just the first.
        let allDevices = try catalog.devices()
        // (INGESTION-01) Seed from the stored catalog first; the descriptor loop below then
        // overwrites its own entries with the fresher, explicit value. A descriptor is strictly
        // better information than a re-derivation — it carries the source's own `priority` — but
        // its ABSENCE says nothing at all about a source, which is the assumption that broke.
        var priorityBySource = try storedSourcePriorities(devices: allDevices)
        for d in descriptors {
            let existing = try catalog.source(id: d.id)
            // AUDIT FIX (debt-closeout wave 2, pre-existing gap): this used to hardcode
            // `type: .healthkit` regardless of `d.type`, so a file-imported source (GPX/TCX/CSV,
            // `d.type == .fileImport`) was always misclassified — `SensorQualityMap.classId`'s own
            // `sourceTypeDefaults` fallback maps `"healthkit"` to `"unknown"` but `"import"` to the
            // correct `"file_import"`, and a file-import source has no associated Device row for the
            // keyword matcher to save it. Predates this wave, but only became consequential once file
            // import shipped as a real feature in this same wave.
            try catalog.upsertSource(Source(
                id: d.id, type: d.type, displayName: d.displayName, platformBundleId: d.bundleId,
                status: .active, connectedAt: existing?.connectedAt ?? now, lastDeliveryAt: now,
                updatedAt: now, originDeviceId: deviceId))

            if let deviceKey = d.deviceId {
                let priorDevice = allDevices.first { $0.sourceId == d.id && $0.id == deviceKey }
                try catalog.upsertDevice(Device(
                    id: deviceKey, sourceId: d.id, name: d.deviceName ?? d.displayName, model: d.deviceModel,
                    firstSeen: priorDevice?.firstSeen ?? now, lastSeen: now, updatedAt: now, originDeviceId: deviceId))
            }

            priorityBySource[d.id] = inferredPriority(d)
        }
        return priorityBySource
    }

    /// (INGESTION-01) The dedup priority of every source already in the catalog, whether or not
    /// this run's port described it.
    ///
    /// `sources` carries no priority column — dedup priority is derived, never stored — so this
    /// re-derives it from exactly the naming signals a descriptor carries, read back out of the
    /// catalog rows that descriptor wrote: the source's display name plus the name/model of each
    /// device filed under it. For a source live sync has seen, the two paths therefore agree.
    /// What is deliberately NOT recovered is a descriptor's explicit non-zero `priority`, because
    /// that value was never persisted; a port that supplies one still overwrites this entry in
    /// `upsertSourcesAndDevices` above, and a port that supplies no descriptors at all gets the
    /// keyword tier instead of a flat zero, which is the whole point.
    private func storedSourcePriorities(devices: [Device]) throws -> [String: Int] {
        let devicesBySource = Dictionary(grouping: devices, by: \.sourceId)
        var priorityBySource: [String: Int] = [:]
        for source in try catalog.sources(includeHidden: true) {
            let words = (devicesBySource[source.id] ?? []).flatMap { [$0.name, $0.model ?? ""] } + [source.displayName]
            priorityBySource[source.id] = Self.priorityForNaming(words.joined(separator: " "))
        }
        return priorityBySource
    }

    /// Non-Apple wearable keywords recognized as a wrist/ring-class device (same tier as
    /// "watch"): without this, any two of these default to priority 0 and are reconciled by
    /// arbitrary id tie-breaking instead of a meaningful source-quality signal.
    private static let wearableKeywords = ["watch", "ring", "band", "oura", "whoop", "fenix", "garmin", "fitbit", "polar"]

    private func inferredPriority(_ d: SourceDescriptor) -> Int {
        if d.priority != 0 { return d.priority }
        return Self.priorityForNaming((d.deviceName ?? "") + " " + (d.deviceModel ?? "") + " " + d.displayName)
    }

    /// Wrist/ring class > phone > unknown, from whatever naming signal is available. Shared by the
    /// descriptor path and the stored-catalog path (INGESTION-01) so the two cannot drift into
    /// disagreeing about the same physical device depending on which port did the reading.
    private static func priorityForNaming(_ text: String) -> Int {
        let hay = text.lowercased()
        if wearableKeywords.contains(where: hay.contains) { return 2 }
        if hay.contains("phone") { return 1 }
        return 0
    }

    // MARK: - Helpers

    /// The embedded provenance for one raw/session/workout row. `origin` decides the ingestion
    /// path and (for imports) the batch id — `.liveSync` reproduces the historical
    /// `ingestionPath = .platformStore, importBatchId = nil` exactly, so this method's output is
    /// unchanged for every sync caller. Named `platform`Provenance for continuity; the name now
    /// means "an upstream-sourced row" (platform store OR file import), as opposed to the
    /// `.derived` provenance the nightly rollups build.
    private func platformProvenance(sourceId: String, deviceId: String?, externalId: String,
                                    measuredAt: Date, tz: String, now: Date,
                                    origin: IngestOrigin = .liveSync,
                                    qualityFlags: [QualityFlag] = []) -> Provenance {
        Provenance(sourceId: sourceId, deviceId: deviceId, ingestionPath: origin.ingestionPath,
                   externalId: externalId, importBatchId: origin.importBatchId,
                   measuredAt: measuredAt, measuredTimezone: tz,
                   recordedAt: now, ingestedAt: now, qualityFlags: qualityFlags)
    }

    /// Convert an as-received value into `canonical`, explicitly (not silently) marking the
    /// value `.estimate` when the conversion fails (unknown/incompatible unit) so a malformed
    /// source unit never masquerades as a valid canonical value with zero trace.
    private func canonicalValue(_ value: Double, from unit: String, canonical: String) -> (Double, [QualityFlag]) {
        if let converted = try? Units.convert(value, from: unit, to: canonical) {
            return (converted, [])
        }
        return (value, [.estimate])
    }

    private func stageSummary(_ stages: [StageDTO]) -> [String: Double] {
        var summary: [String: Double] = [:]
        for s in stages {
            summary[s.stage.rawValue, default: 0] += s.end.timeIntervalSince(s.start)
        }
        return summary
    }
}

// MARK: - Reconciliation-v2 candidate records

/// What `reconcileConflictWindow` needs from a row, regardless of which table it came from —
/// `IntervalRecord` (RHR/HRV) or `RawSample` (weight). Kept to exactly the three fields the
/// candidate-building/decide/persist path actually reads, so a third conflict-checked metric
/// backed by yet another table only needs a one-line conformance, never a second copy of that
/// path's logic.
private protocol ConflictRecord {
    var id: String { get }
    var value: Double { get }
    var provenance: Provenance { get }
}

extension IntervalRecord: ConflictRecord {}
extension RawSample: ConflictRecord {}

// MARK: - Batching

extension Array {
    /// Split into consecutive slices of at most `size` elements, preserving order.
    ///
    /// (P2) Used to bound how many rows a single ingest write transaction holds the DB lock for.
    /// Slices rather than copies: a first-connect backfill can be hundreds of thousands of
    /// samples, and re-allocating each batch would add avoidable memory pressure to the exact
    /// path this exists to make lighter. Prefixed `badan` to make clear at the call site that
    /// this is ours and not a stdlib member.
    func badanChunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self[...]] }
        return stride(from: 0, to: count, by: size).map { start in
            self[start..<Swift.min(start + size, count)]
        }
    }
}
