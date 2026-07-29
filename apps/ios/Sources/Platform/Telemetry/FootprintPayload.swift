import Foundation

/// One learning footprint: which metric, which method, which direction, roughly how much, and
/// whether a calibration was in force (ADR-0011 / D-37).
///
/// Every field is either a contract identifier from the shipped app or a bucketed/boolean summary.
/// There is no reading, no offset magnitude, no date, and no identifier — and the `Codable`
/// conformance is written by hand rather than synthesised so that adding a stored property cannot
/// silently add a wire field.
struct Footprint: Codable, Hashable, Sendable {
    let metricId: String
    let algorithmId: String
    let algorithmSemver: String
    let direction: FeedbackDirection
    let eventCountBucket: EventCountBucket
    let calibrationApplied: Bool

    /// Never a raw count. The floor is 10 because that is the calibration minimum — below it
    /// nothing is emitted at all, so there is no bucket for it. A count of 1 would re-identify a
    /// single tap.
    enum EventCountBucket: String, Codable, Hashable, Sendable, CaseIterable {
        case tenToNineteen = "10-19"
        case twentyToFortyNine = "20-49"
        case fiftyPlus = "50+"

        /// `nil` below the floor, which is what makes "not enough feedback" unrepresentable rather
        /// than merely unsent.
        static func bucket(for count: Int, floor: Int) -> EventCountBucket? {
            guard count >= floor, count >= 10 else { return nil }
            switch count {
            case ..<20: return .tenToNineteen
            case ..<50: return .twentyToFortyNine
            default: return .fiftyPlus
            }
        }
    }
}

/// One submission. Matches `packages/contracts/telemetry/footprint.schema.json` exactly, which is
/// mirrored into the bundle and drift-gated in CI so client and server cannot disagree about what
/// may be sent.
struct FootprintBatch: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let contractVersion: String
    let footprints: [Footprint]

    static let currentSchemaVersion = 1

    init(appVersion: String, contractVersion: String, footprints: [Footprint]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.appVersion = appVersion
        self.contractVersion = contractVersion
        self.footprints = footprints
    }
}

/// Builds batches from local feedback, and is the ONE place a footprint comes into existence.
///
/// Takes counts and identifiers, never `DerivedValue`s or `MetricCalibration`s — so a reading or an
/// offset is not merely omitted here, it is never in scope to omit. That is what
/// `testFootprintPayloadContainsNoHealthValue` is really asserting.
enum FootprintBuilder {
    /// Everything needed to describe one (metric, method) pair's feedback, with no health data in
    /// the type at all.
    struct Source: Hashable, Sendable {
        let metricId: String
        let algorithmId: String
        let algorithmSemver: String
        let direction: FeedbackDirection
        let eventCount: Int
        let calibrationApplied: Bool
    }

    /// Footprints for every source that clears the floor. Sources below it are dropped entirely —
    /// not sent with a smaller bucket, not sent with a zero.
    static func build(from sources: [Source], appVersion: String, contractVersion: String,
                      floor: Int) -> FootprintBatch? {
        let footprints = sources.compactMap { source -> Footprint? in
            guard let bucket = Footprint.EventCountBucket.bucket(for: source.eventCount, floor: floor)
            else { return nil }
            return Footprint(metricId: source.metricId, algorithmId: source.algorithmId,
                             algorithmSemver: source.algorithmSemver, direction: source.direction,
                             eventCountBucket: bucket, calibrationApplied: source.calibrationApplied)
        }
        guard !footprints.isEmpty else { return nil }
        return FootprintBatch(appVersion: appVersion, contractVersion: contractVersion,
                              footprints: footprints)
    }
}
