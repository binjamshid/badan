import Foundation
import HealthKit

/// The one place an `HKSample` becomes a BADAN DTO.
///
/// Extracted from `HealthKitAdapter` when D-35's historical reader arrived (item 2b). Both paths
/// now map through here, and that is the entire point: unit conversion, measured-timezone
/// resolution, provenance ids and external-id derivation are where ingestion correctness actually
/// lives, and a second hand-rolled copy is precisely how two paths drift.
///
/// The external ids matter most. The historical reader must emit the SAME external id the anchored
/// path emits for the same underlying sample, because upsert identity is
/// `(metric_id, external_id, source_id)`: the same id means a re-fetch updates in place, a
/// different id means the row silently doubles. Sharing the mapper is what makes that structural
/// rather than a thing someone has to remember.
///
/// Static and free of adapter state by design — everything it needs is passed in, so it is
/// callable from a type that holds no anchors at all.
enum HKSampleMapping {
    /// Used when a sample's own bundle identifier is empty, so a source row always has an id.
    ///
    /// This exact string is load-bearing beyond this file: `HealthKitAdapter` files merged daily
    /// totals under it and keys every read anchor by it (`anchors.anchor(store:)`). Changing it
    /// would orphan every existing anchor and re-file existing rows under a new source.
    static let fallbackSourceId = "healthkit"

    static func provenanceIds(for sample: HKSample) -> (sourceId: String, deviceId: String?) {
        let bundleId = sample.sourceRevision.source.bundleIdentifier
        let sourceId = bundleId.isEmpty ? fallbackSourceId : bundleId
        let deviceId = sample.device?.localIdentifier ?? sample.device?.name
        return (sourceId, deviceId)
    }

    /// The timezone a sample was actually measured in (DATA-07), not whatever zone this device
    /// happens to be in right now: HealthKit stamps `HKMetadataKeyTimeZone` on a sample when the
    /// recording device knew its own zone at write time (Apple Watch and most first-party sources
    /// do), which is what `DayAttribution`'s "timezone at measurement" contract needs for correct
    /// day/night bucketing after travel — attributing a post-trip backfill to today's zone silently
    /// misfiles historical nights.
    ///
    /// This matters more for the historical path than for live sync, not less: a multi-year import
    /// is exactly the case where the reading's own zone and the device's current zone diverge.
    ///
    /// Returns the measured zone plus whether it is a fallback, so `.tzAssumed` can be stamped.
    static func measuredTimeZone(for sample: HKSample, fallbackTz: String) -> (tz: String, assumed: Bool) {
        if let raw = sample.metadata?[HKMetadataKeyTimeZone] as? String, TimeZone(identifier: raw) != nil {
            return (raw, false)
        }
        return (fallbackTz, true)
    }

    /// A discrete quantity sample → `SampleDTO`. `externalId` is the HealthKit UUID, which is
    /// globally unique regardless of source and is also what `DeletedExternalRecord` maps back to.
    static func sampleDTO(_ sample: HKSample, entry: HKTypeMap.Entry, metricId: String,
                          fallbackTz: String) -> SampleDTO? {
        guard let qs = sample as? HKQuantitySample else { return nil }
        let (sourceId, deviceId) = provenanceIds(for: qs)
        let (tzId, tzAssumed) = measuredTimeZone(for: qs, fallbackTz: fallbackTz)
        return SampleDTO(metricId: metricId, value: qs.quantity.doubleValue(for: entry.hkUnit),
                         unit: entry.badanUnit, start: qs.startDate, end: qs.endDate, tz: tzId,
                         sourceId: sourceId, deviceId: deviceId, externalId: qs.uuid.uuidString,
                         qualityFlags: tzAssumed ? [.tzAssumed] : [])
    }

    /// An already-summarized discrete sample → `IntervalDTO`, carried through with its own span.
    static func intervalDTO(_ sample: HKSample, entry: HKTypeMap.Entry, metricId: String,
                            aggregation: Aggregation, fallbackTz: String) -> IntervalDTO? {
        guard let qs = sample as? HKQuantitySample else { return nil }
        let (sourceId, deviceId) = provenanceIds(for: qs)
        let (tzId, tzAssumed) = measuredTimeZone(for: qs, fallbackTz: fallbackTz)
        return IntervalDTO(metricId: metricId, value: qs.quantity.doubleValue(for: entry.hkUnit),
                           unit: entry.badanUnit, start: qs.startDate, end: qs.endDate, tz: tzId,
                           aggregation: aggregation, sourceId: sourceId, deviceId: deviceId,
                           externalId: qs.uuid.uuidString,
                           qualityFlags: tzAssumed ? [.tzAssumed] : [])
    }
}
