import Foundation
import HealthKit

/// LAB-11's HealthKit half: asks for clinical-record access and hands back raw FHIR blobs.
///
/// Everything this type does is I/O. It performs no interpretation whatsoever — parsing lives in
/// `FHIRObservationParser` and mapping in `ClinicalRecordImporter`, both pure and both fully
/// tested. That split is deliberate and is the same posture `GattServiceAdapters` took when no BLE
/// hardware was available: **no device with real clinical records was available while this was
/// built**, so the code that cannot be verified here is kept as thin and as free of decisions as
/// possible, and everything that can be verified was.
///
/// What that means concretely, stated rather than glossed: the calls below are written against
/// Apple's documented clinical-records API and compile, but the end-to-end path — authorization
/// sheet, a real provider account, real returned FHIR — has NOT been exercised on a device. Treat
/// the first real run as the actual verification.
protocol ClinicalRecordStorePort: Sendable {
    /// Whether this build can request clinical records at all. False on a simulator, on an
    /// unsupported region, or without the entitlement.
    func isAvailable() -> Bool
    /// Presents the clinical-records authorization sheet. Returns whether it completed, NOT whether
    /// access was granted — HealthKit deliberately never reveals a read denial (the same
    /// `requestAuthorization` semantics `HealthKitAdapter` already documents), so an empty result
    /// must always be shown as "nothing found" plus a settings hint, never as "you denied this".
    func requestAuthorization() async -> Bool
    /// Every lab-result clinical record currently on the device, as `(sourceName, fhirJSON)` pairs.
    func fetchLabRecords() async -> [(sourceName: String, data: Data)]
}

final class HealthKitClinicalStore: ClinicalRecordStorePort {
    private let store = HKHealthStore()

    private var labRecordType: HKClinicalType? {
        HKObjectType.clinicalType(forIdentifier: .labResultRecord)
    }

    /// Clinical records are region- and institution-gated by Apple: `clinicalType(forIdentifier:)`
    /// returns nil where the feature is unsupported, and the simulator has no connected provider
    /// accounts. Both are ordinary "not available here" answers, not failures.
    func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable() && labRecordType != nil
    }

    func requestAuthorization() async -> Bool {
        guard let labRecordType else { return false }
        return await withCheckedContinuation { continuation in
            // `toShare: []` — BADAN never writes clinical records, and asking for write access on
            // a medical record would be both false and a review risk. Read-only, exactly as the
            // rest of the app's HealthKit usage.
            store.requestAuthorization(toShare: [], read: [labRecordType]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func fetchLabRecords() async -> [(sourceName: String, data: Data)] {
        guard let labRecordType else { return [] }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: labRecordType, predicate: nil,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let records = (samples as? [HKClinicalRecord]) ?? []
                // `compactMap` with a tuple result needs the optional spelled out — Swift will not
                // infer `nil` against a tuple return type.
                let payloads: [(sourceName: String, data: Data)] = records.compactMap { record -> (sourceName: String, data: Data)? in
                    guard let resource = record.fhirResource else { return nil }
                    // The provider name comes from the sample's own source (the Health app's
                    // record of which account wrote it), falling back to the record's display
                    // name. `HKClinicalRecord` exposes no URL of its own.
                    return (sourceName: record.sourceRevision.source.name, data: resource.data)
                }
                continuation.resume(returning: payloads)
            }
            store.execute(query)
        }
    }
}
