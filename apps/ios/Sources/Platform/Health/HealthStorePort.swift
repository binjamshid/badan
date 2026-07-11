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

    public init(metricId: String, value: Double, unit: String, start: Date, end: Date? = nil,
                tz: String, sourceId: String, deviceId: String? = nil, externalId: String) {
        self.metricId = metricId; self.value = value; self.unit = unit; self.start = start
        self.end = end; self.tz = tz; self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
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

    public init(metricId: String, value: Double, unit: String, start: Date, end: Date, tz: String,
                aggregation: Aggregation, sourceId: String, deviceId: String? = nil, externalId: String) {
        self.metricId = metricId; self.value = value; self.unit = unit; self.start = start; self.end = end
        self.tz = tz; self.aggregation = aggregation; self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
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

    public init(kind: SessionKind, subtype: String? = nil, start: Date, end: Date, tz: String,
                sourceId: String, deviceId: String? = nil, externalId: String, stages: [StageDTO] = [],
                timeAsleepSeconds: Double? = nil, timeInBedSeconds: Double? = nil) {
        self.kind = kind; self.subtype = subtype; self.start = start; self.end = end; self.tz = tz
        self.sourceId = sourceId; self.deviceId = deviceId; self.externalId = externalId
        self.stages = stages; self.timeAsleepSeconds = timeAsleepSeconds; self.timeInBedSeconds = timeInBedSeconds
    }
}

public protocol HealthStorePort {
    func availability() -> HealthAvailability
    func sourceDescriptors() -> [SourceDescriptor]
    func readSamples(_ range: HealthDateRange) -> [SampleDTO]
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO]
    func readSessions(_ range: HealthDateRange) -> [SessionDTO]
}
