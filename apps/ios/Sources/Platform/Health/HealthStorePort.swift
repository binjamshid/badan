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

    public init(metricId: String, value: Double, unit: String, start: Date, end: Date, tz: String,
                aggregation: Aggregation, sourceId: String, deviceId: String? = nil, externalId: String,
                qualityFlags: [QualityFlag] = []) {
        self.metricId = metricId; self.value = value; self.unit = unit; self.start = start; self.end = end
        self.tz = tz; self.aggregation = aggregation; self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.qualityFlags = qualityFlags
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
/// Sessions are deliberately not represented here: a deleted sleep sample within an otherwise-
/// intact night self-corrects for free the next time that night is rebuilt from HealthKit's
/// full current sample set (see `HealthKitAdapter`'s night-rebuild seam) — only a night with
/// EVERY sample deleted would need an explicit signal, and HealthKit's deletion API gives no
/// date to attribute such a deletion to a night with. That gap is a documented limitation, not
/// an oversight (see `HealthKitAdapter.readSessions`'s doc comment).
public struct HealthStoreDeletions: Sendable {
    public var samples: [DeletedExternalRecord]
    public var intervals: [DeletedExternalRecord]
    public init(samples: [DeletedExternalRecord] = [], intervals: [DeletedExternalRecord] = []) {
        self.samples = samples; self.intervals = intervals
    }
}

public protocol HealthStorePort {
    func availability() -> HealthAvailability
    func sourceDescriptors() -> [SourceDescriptor]
    func readSamples(_ range: HealthDateRange) -> [SampleDTO]
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO]
    func readSessions(_ range: HealthDateRange) -> [SessionDTO]
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
    func deletions(_ range: HealthDateRange) -> HealthStoreDeletions { HealthStoreDeletions() }
    func commitPendingAnchors() {}
}
