import Foundation
import HealthKit

/// Real HealthKit integration boundary. It compiles and is safe on the simulator without a
/// HealthKit entitlement: availability is honest, authorization guards every type, and the
/// read methods are intentionally empty for this MVP (FakeHealthStore is the simulator data
/// source). This file exists to nail the real seam down without risky query-mapping code.
final class HealthKitAdapter: HealthStorePort {
    private let store = HKHealthStore()

    init() {}

    /// The MVP read set. Built once (rather than per `requestAuthorization` call) since each
    /// type is a pure lookup of a fixed identifier. TODO(PERF-181): once more of the 44-metric
    /// ontology gets real HealthKit backing, derive this from `MetricDefinition` instead of
    /// hand-maintaining it here — that's a `registry.json` contract change (Android-affecting
    /// too) and belongs to a dedicated ontology-expansion effort, not this cache-only fix.
    private static let readTypes: Set<HKObjectType> = {
        var read = Set<HKObjectType>()
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(t) }
        return read
    }()

    func availability() -> HealthAvailability {
        HKHealthStore.isHealthDataAvailable() ? .available : .unsupported
    }

    func sourceDescriptors() -> [SourceDescriptor] {
        [SourceDescriptor(id: "healthkit", displayName: "Apple Health", type: .healthkit,
                          bundleId: "com.apple.health", priority: 80)]
    }

    /// Ask to READ the MVP types. Each type is guarded with if-let so a platform that lacks
    /// one simply skips it rather than crashing.
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { completion(false, nil); return }
        store.requestAuthorization(toShare: [], read: Self.readTypes) { granted, error in
            completion(granted, error)
        }
    }

    func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
        [] // TODO: map HK query results to DTOs (post-MVP)
    }

    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
        [] // TODO: map HK query results to DTOs (post-MVP)
    }

    func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
        [] // TODO: map HK query results to DTOs (post-MVP)
    }
}
