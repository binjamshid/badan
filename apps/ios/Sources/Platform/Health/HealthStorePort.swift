import Foundation

/// Platform-neutral DTOs and the port BADAN reads health data through. The real
/// HealthKit/Health Connect adapters and the FakeHealthStore all conform to this, so the
/// ingestion pipeline is identical regardless of source (the seam that keeps UI decoupled
/// from any vendor schema). This is an MVP subset of blueprint §51.1.
public struct HealthDateRange: Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

public enum HealthAvailability: String, Sendable {
    case available
    case notInstalled
    case unsupported
}

public struct SourceDescriptor: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var type: SourceType
    public var bundleId: String?
    public var deviceId: String?
    public var deviceName: String?
    public var deviceModel: String?
    /// Higher wins dedup ties (I4: device wins by source priority for non-manual metrics).
    public var priority: Int

    public init(id: String, displayName: String, type: SourceType, bundleId: String? = nil,
                deviceId: String? = nil, deviceName: String? = nil, deviceModel: String? = nil, priority: Int) {
        self.id = id; self.displayName = displayName; self.type = type; self.bundleId = bundleId
        self.deviceId = deviceId; self.deviceName = deviceName; self.deviceModel = deviceModel; self.priority = priority
    }
}

public struct SampleDTO: Sendable {
    public var metricId: String
    public var value: Double
    public var unit: String
    public var start: Date
    public var end: Date?
    public var tz: String
    public var sourceId: String
    public var deviceId: String?
    public var externalId: String
    /// Honest quality annotations the adapter already knows about at read time (e.g.
    /// `.tzAssumed` when `tz` above is a device-clock fallback rather than a per-sample
    /// measured zone) — merged into the record's stamped `Provenance` by `IngestionPipeline`
    /// (completes wave-1 DATA-07). Defaulted so existing DTO call sites/conformers (incl.
    /// `FakeHealthStore` and test stubs) keep compiling unchanged.
    public var qualityFlags: [QualityFlag]

    public init(metricId: String, value: Double, unit: String, start: Date, end: Date? = nil,
                tz: String, sourceId: String, deviceId: String? = nil, externalId: String,
                qualityFlags: [QualityFlag] = []) {
        self.metricId = metricId; self.value = value; self.unit = unit; self.start = start
        self.end = end; self.tz = tz; self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.qualityFlags = qualityFlags
    }
}

public struct IntervalDTO: Sendable {
    public var metricId: String
    public var value: Double
    public var unit: String
    public var start: Date
    public var end: Date
    public var tz: String
    public var aggregation: Aggregation
    public var sourceId: String
    public var deviceId: String?
    public var externalId: String
    /// See `SampleDTO.qualityFlags`.
    public var qualityFlags: [QualityFlag]
    /// True when this row is a COMPLETE recomputation of a day's total from every contributing
    /// sample the store currently holds (the `HKStatisticsCollectionQuery` /
    /// Health-Connect-aggregate shape), rather than one reading among several.
    ///
    /// The distinction only matters for zero (BUG-10b): for a recomputed total, `value == 0`
    /// asserts "everything that contributes to this day sums to zero", which is a real
    /// correction when a row already exists — but on a first-connect backfill it is also what a
    /// day the user never wore a device looks like, so `IngestionPipeline.writeIntervals` writes
    /// it only when there is an existing row to correct. For a non-recomputed row a zero is just
    /// a reading and gets written normally.
    ///
    /// Declared by the adapter rather than inferred downstream from a metric-id list: the
    /// property is about how the value was *obtained*, which only the adapter knows, and the
    /// id-list version of this check had to be edited every time a family was added (it said
    /// `metricId == steps` and would have silently mis-handled active energy, distance and
    /// flights the moment those landed).
    public var isRecomputedDailyTotal: Bool

    public init(metricId: String, value: Double, unit: String, start: Date, end: Date, tz: String,
                aggregation: Aggregation, sourceId: String, deviceId: String? = nil, externalId: String,
                qualityFlags: [QualityFlag] = [], isRecomputedDailyTotal: Bool = false) {
        self.metricId = metricId; self.value = value; self.unit = unit; self.start = start; self.end = end
        self.tz = tz; self.aggregation = aggregation; self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.qualityFlags = qualityFlags
        self.isRecomputedDailyTotal = isRecomputedDailyTotal
    }
}

public struct StageDTO: Sendable {
    public var stage: SleepStage
    public var start: Date
    public var end: Date
    public init(stage: SleepStage, start: Date, end: Date) { self.stage = stage; self.start = start; self.end = end }
}

public struct SessionDTO: Sendable {
    public var kind: SessionKind
    public var subtype: String?
    public var start: Date
    public var end: Date
    public var tz: String
    public var sourceId: String
    public var deviceId: String?
    public var externalId: String
    public var stages: [StageDTO]
    public var timeAsleepSeconds: Double?
    public var timeInBedSeconds: Double?
    /// See `SampleDTO.qualityFlags`.
    public var qualityFlags: [QualityFlag]

    public init(kind: SessionKind, subtype: String? = nil, start: Date, end: Date, tz: String,
                sourceId: String, deviceId: String? = nil, externalId: String, stages: [StageDTO] = [],
                timeAsleepSeconds: Double? = nil, timeInBedSeconds: Double? = nil,
                qualityFlags: [QualityFlag] = []) {
        self.kind = kind; self.subtype = subtype; self.start = start; self.end = end; self.tz = tz
        self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.stages = stages; self.timeAsleepSeconds = timeAsleepSeconds; self.timeInBedSeconds = timeInBedSeconds
        self.qualityFlags = qualityFlags
    }
}

// MARK: - Workouts (EPIC-03)

// `WorkoutTotals` and `RouteConsent` are domain values (`Domain/Measurements.swift`), not DTO
// shapes — they are persisted verbatim into `sessions.detail` and
// `workout_routes.consent_snapshot` respectively, so defining them here and re-declaring them
// there would be two structs that must never diverge. The port uses the domain types directly,
// exactly as it already does for `SessionKind`, `SleepStage`, `Aggregation` and `QualityFlag`.

/// One GPS fix from a workout route. Deliberately a flat value type with no provenance of its
/// own — provenance lives on the parent route (see `migration v4`'s `route_points` comment for
/// why duplicating 12 columns across thousands of points is the wrong shape).
public struct RoutePointDTO: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, altitudeMeters: Double? = nil,
                horizontalAccuracyMeters: Double? = nil, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude; self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters; self.timestamp = timestamp
    }
}

/// A workout's GPS trace, already accumulated across however many callback batches the platform
/// delivered it in (`HKWorkoutRouteQuery` streams; see `HealthKitAdapter.RouteAccumulator`).
///
/// A `RouteDTO` only ever exists when route consent was granted at read time — the adapter does
/// not read routes otherwise, so there is no "unconsented route" value in flight anywhere. The
/// `consent` it carries is the state as it stood at that moment, recorded so
/// `workout_routes.consent_snapshot` can answer "was this row allowed to exist when it was
/// written" after a later toggle-off (plan §9.2).
public struct RouteDTO: Sendable {
    public var externalId: String
    public var points: [RoutePointDTO]
    public var consent: RouteConsent

    public init(externalId: String, points: [RoutePointDTO], consent: RouteConsent) {
        self.externalId = externalId; self.points = points; self.consent = consent
    }
}

/// An ingested workout episode. Becomes a `sessions` row with `kind = .workout` and a versioned
/// `WorkoutDetail` payload (plan §9.1) — never its own table, because a workout IS an episode
/// and `sessions` is the episode table.
public struct WorkoutDTO: Sendable {
    /// A stable BADAN slug (`HKTypeMap.activitySlug`), never the platform's numeric enum.
    public var activityType: String
    public var start: Date
    public var end: Date
    public var tz: String
    public var sourceId: String
    public var deviceId: String?
    public var externalId: String
    /// The platform's own id for this workout, kept in the detail payload as well as in
    /// provenance so an export reader who never sees our schema can still correlate against
    /// Apple Health.
    public var sourceWorkoutUUID: String
    public var totals: WorkoutTotals
    /// Present only with route consent — see `RouteDTO`.
    public var route: RouteDTO?
    /// See `SampleDTO.qualityFlags`.
    public var qualityFlags: [QualityFlag]

    public init(activityType: String, start: Date, end: Date, tz: String, sourceId: String,
                deviceId: String? = nil, externalId: String, sourceWorkoutUUID: String,
                totals: WorkoutTotals = WorkoutTotals(), route: RouteDTO? = nil,
                qualityFlags: [QualityFlag] = []) {
        self.activityType = activityType; self.start = start; self.end = end; self.tz = tz
        self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.sourceWorkoutUUID = sourceWorkoutUUID; self.totals = totals; self.route = route
        self.qualityFlags = qualityFlags
    }
}

// MARK: - Route consent (plan §4.11 / §9.2)

/// Supplies the live route-consent state to the ingestion path.
///
/// A protocol rather than a stored `Bool` because consent is revocable at any moment and the
/// answer must be read at the instant a route would be written, not captured whenever the
/// adapter happened to be constructed — the adapter outlives a settings toggle (it is rebuilt
/// per sync, but a long backfill spans minutes).
public protocol RouteConsentProviding: Sendable {
    func routeConsent() -> RouteConsent
}

/// Fail-closed default: no routes unless something explicitly says otherwise.
///
/// This is the default on `HealthKitAdapter.init` on purpose. A default of "granted", or a
/// nil-means-allowed optional, would mean that forgetting to wire the toggle silently ingests
/// location history — the single worst failure mode in this epic, and one that no test of the
/// happy path would catch. Wiring the real provider is a visible, deliberate act.
public struct DeniedRouteConsent: RouteConsentProviding {
    public init() {}
    public func routeConsent() -> RouteConsent { .denied }
}

// MARK: - Backfill honesty (EPIC-01 task 8)

/// How much history one read type can actually produce, versus how much was asked for.
///
/// A first connect requests 90 days and the UI used to imply it received 90 days of everything.
/// It never does — see `HKTypeMap.BackfillCaveat`. This pairs the structural caveat with the
/// empirical fact (the oldest sample the store will actually hand over) so a surface can say
/// "blood oxygen goes back to 12 March" instead of implying three months of it exist.
///
/// `earliestAvailable == nil` means the store returned nothing in the requested window, which is
/// honestly reported as "no history yet" — it is NOT evidence of a denied permission, because
/// HealthKit never reveals read denials (see `HealthKitAdapter.requestAuthorization`).
public struct HealthBackfillWindow: Sendable, Hashable {
    public var platformType: String
    public var metricId: String?
    public var requestedStart: Date
    public var earliestAvailable: Date?

    public init(platformType: String, metricId: String?, requestedStart: Date, earliestAvailable: Date?) {
        self.platformType = platformType; self.metricId = metricId
        self.requestedStart = requestedStart; self.earliestAvailable = earliestAvailable
    }

    /// True when the store has data reaching back to (or past) what was requested.
    public var coversRequestedRange: Bool {
        guard let earliestAvailable else { return false }
        return earliestAvailable <= requestedStart
    }
}

/// One HealthKit (or other platform store) deletion surfaced since the last incremental read,
/// keyed the same way the record was keyed at ingest time so `MeasurementRepository` can find
/// and soft-delete the matching row (BUG-10). `sourceId` is optional: `HKDeletedObject` exposes
/// only the deleted sample's own UUID, never which source wrote it, but that's fine in practice
/// — the `externalId` HealthKit gives raw samples/intervals (the sample's own UUID) is globally
/// unique regardless of source, so it alone is enough to pin down the row without ambiguity.
public struct DeletedExternalRecord: Sendable {
    public var metricId: String?
    public var externalId: String
    public var sourceId: String?
    public init(metricId: String? = nil, externalId: String, sourceId: String? = nil) {
        self.metricId = metricId; self.externalId = externalId; self.sourceId = sourceId
    }
}

/// Deletions since the last incremental read, split by which table they apply to (BUG-10).
///
/// `sessions` covers WORKOUT sessions only, and the asymmetry with sleep is the point.
///
/// Sleep deletions still have no representation here, for the reason originally documented: a
/// deleted sleep sample inside an otherwise-intact night self-corrects when that night is
/// rebuilt from HealthKit's full current sample set (see `HealthKitAdapter`'s night-rebuild
/// seam), and a night with EVERY sample deleted cannot be identified at all, because
/// `HKDeletedObject` carries no date and a sleep session's `externalId` is night-keyed rather
/// than UUID-keyed — there is nothing to match a bare UUID against.
///
/// A workout has none of that trouble (EPIC-03): one HKWorkout is one session, and its
/// `externalId` embeds that workout's own UUID, so a deletion maps to exactly one row by exact
/// identity — the same clean mapping heart-rate samples have. Deleting a workout in Health
/// therefore soft-deletes BADAN's copy, rather than leaving a workout the user has already
/// removed visible forever. Only the workout read path populates this; the sleep path must not,
/// since its UUIDs would match nothing (harmless, but it would imply a capability that isn't
/// there).
public struct HealthStoreDeletions: Sendable {
    public var samples: [DeletedExternalRecord]
    public var intervals: [DeletedExternalRecord]
    public var sessions: [DeletedExternalRecord]
    public init(samples: [DeletedExternalRecord] = [], intervals: [DeletedExternalRecord] = [],
                sessions: [DeletedExternalRecord] = []) {
        self.samples = samples; self.intervals = intervals; self.sessions = sessions
    }
}

public protocol HealthStorePort {
    func availability() -> HealthAvailability
    func sourceDescriptors() -> [SourceDescriptor]
    func readSamples(_ range: HealthDateRange) -> [SampleDTO]
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO]
    func readSessions(_ range: HealthDateRange) -> [SessionDTO]
    /// Ingested workout episodes in `range`, each with its totals and — only when route consent
    /// is granted at read time — its GPS trace (EPIC-03). New protocol requirement with a
    /// default empty implementation (see the extension below) so conformers with no workout
    /// support keep compiling and honestly report "no workouts."
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO]
    /// Per-type "how far back does this actually go", for surfaces that would otherwise imply
    /// the full requested window exists for every type (EPIC-01 task 8).
    ///
    /// Deliberately NOT called by `IngestionPipeline.ingest`: on the real adapter this is one
    /// extra bounded query per read type, which is fine when a Sources/backfill screen asks for
    /// it and pure waste on every foreground sync. Default `[]` means "this store makes no
    /// claim", which a UI must render as absence of information rather than as full coverage.
    func backfillWindows(_ range: HealthDateRange) -> [HealthBackfillWindow]
    /// Deletions surfaced by the most recent `readSamples`/`readIntervals` calls for this same
    /// `range` (BUG-10) — callers must invoke this AFTER those, not standalone. New protocol
    /// requirement with a default (see the extension below), so existing conformers with no
    /// incremental-delete signal (`FakeHealthStore`, fixed test stubs) keep compiling unchanged
    /// and correctly report "nothing was deleted."
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions
    /// Persist whatever read cursor/anchor the most recent read* calls advanced (DATA-08).
    /// Callers must invoke this ONLY after the write transaction those reads feed has actually
    /// committed, so a failed ingest replays from the last successfully-persisted position
    /// instead of silently skipping data that never made it to disk. New protocol requirement
    /// with a default no-op (see the extension below) for conformers with no such cursor.
    func commitPendingAnchors()
}

public extension HealthStorePort {
    func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] { [] }
    func backfillWindows(_ range: HealthDateRange) -> [HealthBackfillWindow] { [] }
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions { HealthStoreDeletions() }
    func commitPendingAnchors() {}
}
