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

/// Typed episode detail carried as a JSON column. `mergedFrom` records which raw session
/// ids were combined during dedup — the lineage the anatomy/provenance sheets render.
public struct SessionDetail: Codable, Hashable, Sendable {
    public var mergedFrom: [String]
    public var timeAsleepSeconds: Double?
    public var timeInBedSeconds: Double?
    public var stageSummarySeconds: [String: Double]   // stage rawValue -> seconds

    public init(mergedFrom: [String] = [], timeAsleepSeconds: Double? = nil,
                timeInBedSeconds: Double? = nil, stageSummarySeconds: [String: Double] = [:]) {
        self.mergedFrom = mergedFrom
        self.timeAsleepSeconds = timeAsleepSeconds
        self.timeInBedSeconds = timeInBedSeconds
        self.stageSummarySeconds = stageSummarySeconds
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
