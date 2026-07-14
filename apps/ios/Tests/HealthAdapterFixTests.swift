import XCTest
@testable import BADAN

/// Regression coverage for the panel-review-2026-07 fixes to `HealthKitAdapter` and
/// `MeasurementRepository` that are testable without a real HealthKit runtime (HealthKit
/// itself only runs on-device/simulator with entitlements, so `HealthKitAdapter`'s
/// `HKHealthStore`-backed methods aren't exercised here — see the accompanying fix report for
/// what remains device-only).
///
/// - DATA-12: `upsertRawSample`/`upsertSession`'s `DO UPDATE SET` clauses must refresh
///   `measured_at`/`recorded_at` (+ `tz_id`/`measured_tz` for sessions) on conflict, mirroring
///   the `upsertIntervalRecord` fix (OPT-170) — verified end-to-end against a real temp DB,
///   following `PipelineTests`' setup pattern.
/// - FIX-09: `HealthKitAdapter.sourcePriority`, factored out as a static pure function
///   specifically so it's unit-testable, must assign the pipeline's wearable/phone priority
///   tiers from locale-independent signals (bundle id, device model/productType) and from
///   name keywords that include Arabic equivalents, not just English ones.
final class HealthAdapterFixTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - DATA-12: upsert SET lists must refresh measured_at/recorded_at (+ tz_id/measured_tz)

    func testRawSampleUpsertRefreshesMeasuredAtAndRecordedAtOnConflict() throws {
        let repo = MeasurementRepository(db.main)
        let firstMeasuredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondMeasuredAt = Date(timeIntervalSince1970: 1_700_100_000)

        func sample(measuredAt: Date) -> RawSample {
            RawSample(id: ULID.newID(), metricId: MetricID.heartRate, value: 60, unit: "bpm",
                      originalValue: 60, originalUnit: "bpm", startAt: measuredAt, endAt: measuredAt,
                      tzId: "UTC",
                      provenance: Provenance(sourceId: "watch-1", ingestionPath: .platformStore,
                                             externalId: "ext-raw-1", measuredAt: measuredAt,
                                             measuredTimezone: "UTC", recordedAt: measuredAt,
                                             ingestedAt: measuredAt),
                      updatedAt: measuredAt, originDeviceId: deviceId)
        }

        let firstWasNew = try repo.upsertRawSample(sample(measuredAt: firstMeasuredAt))
        XCTAssertTrue(firstWasNew)
        let secondWasNew = try repo.upsertRawSample(sample(measuredAt: secondMeasuredAt))
        XCTAssertFalse(secondWasNew, "same identity (metric_id, external_id, source_id) must update, not insert")

        let rows = try repo.rawSamples(metricId: MetricID.heartRate)
        XCTAssertEqual(rows.count, 1, "the conflicting write must update the existing row, not create a second one")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.provenance.measuredAt.timeIntervalSince1970,
                       secondMeasuredAt.timeIntervalSince1970, accuracy: 1,
                       "DATA-12: measured_at must be refreshed by the DO UPDATE SET, not left stale")
        XCTAssertEqual(row.provenance.recordedAt.timeIntervalSince1970,
                       secondMeasuredAt.timeIntervalSince1970, accuracy: 1,
                       "DATA-12: recorded_at must be refreshed by the DO UPDATE SET, not left stale")
    }

    func testSessionUpsertRefreshesMeasuredAtTzIdAndMeasuredTzOnConflict() throws {
        let repo = MeasurementRepository(db.main)
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let secondStart = Date(timeIntervalSince1970: 1_700_100_000)

        func session(start: Date, tz: String) -> Session {
            Session(id: ULID.newID(), kind: .sleepPrimary, startAt: start,
                   endAt: start.addingTimeInterval(3600), tzId: tz, localNight: "2023-11-14",
                   provenance: Provenance(sourceId: "watch-1", ingestionPath: .platformStore,
                                          externalId: "ext-session-1", measuredAt: start,
                                          measuredTimezone: tz, recordedAt: start, ingestedAt: start),
                   updatedAt: start, originDeviceId: deviceId)
        }

        let firstWasNew = try repo.upsertSession(session(start: firstStart, tz: "UTC"))
        XCTAssertTrue(firstWasNew)
        let secondWasNew = try repo.upsertSession(session(start: secondStart, tz: "Asia/Riyadh"))
        XCTAssertFalse(secondWasNew, "same identity (kind, external_id, source_id) must update, not insert")

        let rows = try repo.sessions(kind: .sleepPrimary)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.provenance.measuredAt.timeIntervalSince1970,
                       secondStart.timeIntervalSince1970, accuracy: 1,
                       "DATA-12: session measured_at must be refreshed by the DO UPDATE SET")
        XCTAssertEqual(row.provenance.recordedAt.timeIntervalSince1970,
                       secondStart.timeIntervalSince1970, accuracy: 1,
                       "DATA-12: session recorded_at must be refreshed by the DO UPDATE SET")
        XCTAssertEqual(row.tzId, "Asia/Riyadh",
                       "DATA-12: session tz_id must be refreshed by the DO UPDATE SET")
        XCTAssertEqual(row.provenance.measuredTimezone, "Asia/Riyadh",
                       "DATA-12: session measured_tz must be refreshed by the DO UPDATE SET")
    }

    // MARK: - FIX-09: locale-independent source priority

    func testSourcePriorityRecognizesAppleWatchBundleAndModel() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.apple.health.ABCDEF-1234",
                                                deviceModel: "Watch", deviceProductType: "Watch6,1",
                                                displayName: "My Watch")
        XCTAssertEqual(p, 2, "an Apple Watch bundle-id namespace + watch model must get wearable priority")
    }

    func testSourcePriorityRecognizesWatchProductTypeAloneWithoutAppleBundle() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.example.thirdparty",
                                                deviceModel: nil, deviceProductType: "Watch6,1",
                                                displayName: "Third-Party App")
        XCTAssertEqual(p, 2, "a watch-class productType alone (independent of bundle id) must get wearable priority")
    }

    func testSourcePriorityRecognizesIPhoneByProductType() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.apple.health", deviceModel: nil,
                                                deviceProductType: "iPhone14,5", displayName: "iPhone")
        XCTAssertEqual(p, 1, "an iPhone productType must get phone priority")
    }

    func testSourcePriorityRecognizesArabicWearableName() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.example.thirdparty", deviceModel: nil,
                                                deviceProductType: nil, displayName: "ساعة ذكية")
        XCTAssertEqual(p, 2, "an Arabic-named watch (\"ساعة\") must not fall back to priority 0 (FIX-09)")
    }

    func testSourcePriorityRecognizesArabicRingAndBandNames() {
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.example.ring", deviceModel: nil,
                                                        deviceProductType: nil, displayName: "خاتم صحي"), 2)
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.example.band", deviceModel: nil,
                                                        deviceProductType: nil, displayName: "سوار اللياقة"), 2)
    }

    func testSourcePriorityRecognizesArabicPhoneName() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.example.thirdparty", deviceModel: nil,
                                                deviceProductType: nil, displayName: "هاتف المستخدم")
        XCTAssertEqual(p, 1, "an Arabic-named phone (\"هاتف\") must not fall back to priority 0 (FIX-09)")
    }

    func testSourcePriorityUnknownSourceDefaultsToZero() {
        let p = HealthKitAdapter.sourcePriority(bundleId: "com.example.unknownapp", deviceModel: nil,
                                                deviceProductType: nil, displayName: "Some Health App")
        XCTAssertEqual(p, 0)
    }
}
