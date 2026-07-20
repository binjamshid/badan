import Foundation

public enum Aggregation: String, Codable, Hashable, Sendable {
    case sum, mean, min, max, duration, latest
}

/// Instant / short-interval readings kept for lineage and the power explorer. `value` is
/// always in the metric's canonical unit; `originalValue`/`originalUnit` preserve what was
/// received (I: preserve provenance and source lineage).
public struct RawSample: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var value: Double          // canonical (SI) value
    public var unit: String           // canonical unit
    public var originalValue: Double
    public var originalUnit: String
    public var startAt: Date
    public var endAt: Date?
    public var tzId: String
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, metricId: String, value: Double, unit: String,
                originalValue: Double, originalUnit: String, startAt: Date, endAt: Date? = nil,
                tzId: String, provenance: Provenance, updatedAt: Date, originDeviceId: String,
                deletedAt: Date? = nil) {
        self.id = id; self.metricId = metricId; self.value = value; self.unit = unit
        self.originalValue = originalValue; self.originalUnit = originalUnit
        self.startAt = startAt; self.endAt = endAt; self.tzId = tzId
        self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

/// Normalized aggregates treated as canonical facts (daily steps, nightly time-asleep).
/// The default read layer for charts.
public struct IntervalRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var metricId: String
    public var value: Double
    public var unit: String
    public var startAt: Date
    public var endAt: Date
    public var tzId: String
    public var aggregation: Aggregation
    public var coverage: Double        // 0...1
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, metricId: String, value: Double, unit: String, startAt: Date,
                endAt: Date, tzId: String, aggregation: Aggregation, coverage: Double = 1.0,
                provenance: Provenance, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.metricId = metricId; self.value = value; self.unit = unit
        self.startAt = startAt; self.endAt = endAt; self.tzId = tzId
        self.aggregation = aggregation; self.coverage = coverage; self.provenance = provenance
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

public enum SessionKind: String, Codable, Hashable, Sendable {
    case sleepPrimary
    case sleepNap
    case workout

    public var isSleep: Bool { self == .sleepPrimary || self == .sleepNap }
}

public enum SleepStage: String, Codable, Hashable, Sendable, CaseIterable {
    case inBed, awake, light, deep, rem, asleepUnspecified

    public var displayName: LocalizedString {
        switch self {
        case .inBed: return LocalizedString(en: "In bed", ar: "في السرير")
        case .awake: return LocalizedString(en: "Awake", ar: "مستيقظ")
        case .light: return LocalizedString(en: "Light", ar: "خفيف")
        case .deep: return LocalizedString(en: "Deep", ar: "عميق")
        case .rem: return LocalizedString(en: "REM", ar: "حركة العين")
        case .asleepUnspecified: return LocalizedString(en: "Asleep", ar: "نائم")
        }
    }
}

/// The totals a platform reports alongside a workout episode (plan §9.1).
///
/// All optional because no source reports all of them: a pool swim carries no distance from a
/// phone, an indoor bike carries no elevation, a third-party app may write nothing but a
/// duration. Absent stays absent and is never coerced to zero — "0 kcal" and "not recorded" are
/// different claims, and only one of them is true.
///
/// Units are as-reported (kcal, metres, bpm) rather than canonical, because this struct is the
/// *record of what the source said*. The canonical, registry-unit values live in the
/// `workout.*` metrics; this is the lineage those are read against (I5: raw and derived stay
/// separable).
public struct WorkoutTotals: Codable, Hashable, Sendable {
    public var energyKcal: Double?
    public var distanceMeters: Double?
    public var avgHeartRateBpm: Double?
    public var maxHeartRateBpm: Double?
    public var elevationGainMeters: Double?

    public init(energyKcal: Double? = nil, distanceMeters: Double? = nil,
                avgHeartRateBpm: Double? = nil, maxHeartRateBpm: Double? = nil,
                elevationGainMeters: Double? = nil) {
        self.energyKcal = energyKcal; self.distanceMeters = distanceMeters
        self.avgHeartRateBpm = avgHeartRateBpm; self.maxHeartRateBpm = maxHeartRateBpm
        self.elevationGainMeters = elevationGainMeters
    }
}

/// The workout half of `SessionDetail`, versioned (plan §9.1).
///
/// `schemaVersion` is here because this payload is JSON in a column and therefore has no
/// migration story of its own: a reader three versions from now needs to know what shape it is
/// holding. The contract that keeps it readable is **additive-optional only** — new fields are
/// added as `Optional` with a default, existing fields are never renamed, retyped, or given new
/// meaning under the same name. Breaking that doesn't throw: `MeasurementRepository.readSession`
/// decodes with `?? SessionDetail()`, so a payload that stops decoding silently becomes an empty
/// detail and the workout's totals vanish with no error anywhere. If a genuinely incompatible
/// change is ever needed, bump `schemaVersion`, keep decoding the old shape, and migrate on read.
public struct WorkoutDetail: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// A stable BADAN slug (`HKTypeMap.activitySlug` / Health Connect's mirror), never a
    /// platform's numeric enum value — see that function's doc for why.
    public var activityType: String
    public var totals: WorkoutTotals
    /// The platform's own workout id, kept here in addition to `Provenance.externalId` so an
    /// exported workout object correlates against Apple Health without the reader needing to
    /// know how BADAN composes external ids.
    public var sourceWorkoutUUID: String
    /// `workout_routes.id`, when a route was ingested under consent. Nil is the normal case and
    /// carries no signal about whether a route exists upstream — only about whether BADAN was
    /// permitted to read one.
    public var routeRef: String?
    /// The metric id whose canonical series covers this workout's window (`heart.hr`), NOT a
    /// copy of the series. Plan §9.1 is explicit that HR linkage resolves from the canonical
    /// store; duplicating a few thousand HR samples per workout would double the store's largest
    /// table to answer a question `rawSamples(metricId:from:to:)` already answers from
    /// `startAt`/`endAt`.
    public var hrSeriesRef: String?

    public init(schemaVersion: Int = WorkoutDetail.currentSchemaVersion, activityType: String,
                totals: WorkoutTotals = WorkoutTotals(), sourceWorkoutUUID: String,
                routeRef: String? = nil, hrSeriesRef: String? = nil) {
        self.schemaVersion = schemaVersion; self.activityType = activityType; self.totals = totals
        self.sourceWorkoutUUID = sourceWorkoutUUID; self.routeRef = routeRef
        self.hrSeriesRef = hrSeriesRef
    }
}

/// Typed episode detail carried as a JSON column. `mergedFrom` records which raw session
/// ids were combined during dedup — the lineage the anatomy/provenance sheets render.
public struct SessionDetail: Codable, Hashable, Sendable {
    public var mergedFrom: [String]
    public var timeAsleepSeconds: Double?
    public var timeInBedSeconds: Double?
    public var stageSummarySeconds: [String: Double]   // stage rawValue -> seconds
    /// Present only on `kind == .workout` rows (EPIC-03). Optional, so every sleep session
    /// already in the database — written before this field existed — still decodes: Swift's
    /// synthesized decoder treats a missing key for an `Optional` as `nil`, which is the whole
    /// reason this is an added optional field rather than a second detail column.
    public var workout: WorkoutDetail?

    public init(mergedFrom: [String] = [], timeAsleepSeconds: Double? = nil,
                timeInBedSeconds: Double? = nil, stageSummarySeconds: [String: Double] = [:],
                workout: WorkoutDetail? = nil) {
        self.mergedFrom = mergedFrom
        self.timeAsleepSeconds = timeAsleepSeconds
        self.timeInBedSeconds = timeInBedSeconds
        self.stageSummarySeconds = stageSummarySeconds
        self.workout = workout
    }
}

/// Sleep / workout episodes. `localNight` (YYYY-MM-DD) is the sleep-attribution key that
/// powers the "last night" query even across DST and post-midnight bedtimes.
public struct Session: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SessionKind
    public var subtype: String?
    public var startAt: Date
    public var endAt: Date
    public var tzId: String
    public var localNight: String?
    public var detail: SessionDetail
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, kind: SessionKind, subtype: String? = nil, startAt: Date,
                endAt: Date, tzId: String, localNight: String? = nil,
                detail: SessionDetail = SessionDetail(), provenance: Provenance, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.subtype = subtype; self.startAt = startAt
        self.endAt = endAt; self.tzId = tzId; self.localNight = localNight; self.detail = detail
        self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    public var durationSeconds: Double { endAt.timeIntervalSince(startAt) }
}

// MARK: - Workout routes (plan §9.2, migration v4)

/// The route-consent state at a moment in time.
///
/// Routes are location data and gate independently of every other health class (plan §4.11, in
/// the spirit of I7): connecting HealthKit does not imply them, the sensitive-records toggle
/// does not imply them, and export carries its own separate route opt-in. This value is what
/// ingestion consults and what is frozen into `workout_routes.consent_snapshot`.
public struct RouteConsent: Codable, Hashable, Sendable {
    public var granted: Bool
    /// Which version of the route-consent explainer the user actually agreed to. Recorded
    /// because "they consented" is not a durable fact on its own: if the explainer is later
    /// rewritten to describe a wider use, rows captured under the old text must stay
    /// distinguishable rather than be retroactively covered by wording nobody ever saw.
    public var policyVersion: String
    public var decidedAt: Date?

    public init(granted: Bool, policyVersion: String, decidedAt: Date? = nil) {
        self.granted = granted; self.policyVersion = policyVersion; self.decidedAt = decidedAt
    }

    /// Bump when the route-consent copy changes materially.
    public static let currentPolicyVersion = "route-consent-v1"
    public static let denied = RouteConsent(granted: false, policyVersion: currentPolicyVersion)
}

/// A workout's GPS trace: the consent-bearing parent of its points.
///
/// The route, not the point, is the unit of consent, of provenance (I1) and of replacement.
/// `pointCount` is stored rather than counted on read so a list of workouts can show "1,842
/// points" without loading 1,842 rows per workout.
public struct WorkoutRoute: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// `sessions.id` of the `kind == .workout` episode this trace belongs to.
    public var sessionId: String
    public var pointCount: Int
    public var startAt: Date
    public var endAt: Date
    /// Consent as it stood when these rows were written — see `RouteConsent`. Export gating
    /// reads the CURRENT toggle; this exists so "was this row allowed to exist when it was
    /// written" stays answerable after the fact.
    public var consentSnapshot: RouteConsent
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, sessionId: String, pointCount: Int, startAt: Date, endAt: Date,
                consentSnapshot: RouteConsent, provenance: Provenance, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.sessionId = sessionId; self.pointCount = pointCount
        self.startAt = startAt; self.endAt = endAt; self.consentSnapshot = consentSnapshot
        self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }
}

/// One GPS fix within a route, ordered by `seq`.
///
/// No provenance and no convention columns, mirroring `SessionStage` — see migration v4's
/// `route_points` comment for why both omissions are load-bearing rather than an oversight.
public struct RoutePoint: Codable, Hashable, Sendable, Identifiable {
    public var routeId: String
    public var seq: Int
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var timestamp: Date

    public var id: String { "\(routeId):\(seq)" }

    public init(routeId: String, seq: Int, latitude: Double, longitude: Double,
                altitudeMeters: Double? = nil, horizontalAccuracyMeters: Double? = nil,
                timestamp: Date) {
        self.routeId = routeId; self.seq = seq; self.latitude = latitude; self.longitude = longitude
        self.altitudeMeters = altitudeMeters; self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
    }
}

public struct SessionStage: Codable, Hashable, Sendable, Identifiable {
    public var sessionId: String
    public var seq: Int
    public var stage: SleepStage
    public var startAt: Date
    public var endAt: Date

    public var id: String { "\(sessionId):\(seq)" }
    public var durationSeconds: Double { endAt.timeIntervalSince(startAt) }

    public init(sessionId: String, seq: Int, stage: SleepStage, startAt: Date, endAt: Date) {
        self.sessionId = sessionId; self.seq = seq; self.stage = stage
        self.startAt = startAt; self.endAt = endAt
    }
}
