import Foundation
import HealthKit

/// Real HealthKit integration boundary. It compiles and is safe on the simulator without a
/// HealthKit entitlement: availability is honest, authorization guards every type, and the
/// read methods are intentionally empty for this MVP (FakeHealthStore is the simulator data
/// source). This file exists to nail the real seam down without risky query-mapping code.
final class HealthKitAdapter: HealthStorePort {
    private let store = HKHealthStore()

    init() {}

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
        var read = Set<HKObjectType>()
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(t) }
        store.requestAuthorization(toShare: [], read: read) { granted, error in
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
