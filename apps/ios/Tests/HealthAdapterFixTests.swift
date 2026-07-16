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

    // MARK: - F1: two clusters in one night must not share an identity

    /// A night-keyed `externalId` plus migration v3's `(external_id, source_id)` identity index
    /// meant a nap and the night's primary sleep — same source, same night — upserted onto each
    /// other, so the second cluster written silently replaced the first. Apple Watch tracks naps
    /// by default, so this destroyed real users' sleep data.
    private func sleepSession(night: String, startOffsetHours: Double, durationHours: Double,
                              kind: SessionKind = .sleepPrimary,
                              sourceId: String = "watch-1") -> SessionDTO {
        // Night key "2023-11-14" -> that day's 00:00 UTC, so offsets read as hours around it.
        let nightStart = Date(timeIntervalSince1970: 1_699_920_000)
        let start = nightStart.addingTimeInterval(startOffsetHours * 3600)
        return SessionDTO(kind: kind, start: start,
                          end: start.addingTimeInterval(durationHours * 3600), tz: "UTC",
                          sourceId: sourceId, externalId: "healthkit-sleep-\(sourceId)-\(night)",
                          stages: [], timeAsleepSeconds: durationHours * 3600,
                          timeInBedSeconds: durationHours * 3600)
    }

    func testTwoClustersInOneNightGetDistinctExternalIds() {
        let primary = sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7)
        let nap = sleepSession(night: "2023-11-14", startOffsetHours: 14, durationHours: 1, kind: .sleepNap)

        let out = HealthKitAdapter.disambiguateWithinNight([primary, nap])

        XCTAssertEqual(Set(out.map(\.externalId)).count, 2,
                       "F1: a nap and the night's primary sleep must not collide on one identity")
        XCTAssertEqual(out.count, 2, "no cluster may be dropped by disambiguation")
    }

    func testFirstClusterKeepsBareNightKeyedIdSoExistingRowsStillUpsert() {
        let primary = sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7)
        let nap = sleepSession(night: "2023-11-14", startOffsetHours: 14, durationHours: 1, kind: .sleepNap)

        let out = HealthKitAdapter.disambiguateWithinNight([nap, primary])
        let byStart = out.sorted { $0.start < $1.start }

        XCTAssertEqual(byStart[0].externalId, "healthkit-sleep-watch-1-2023-11-14",
                       "F1: the earliest cluster keeps the legacy bare id so sessions written by "
                           + "earlier builds keep upserting in place instead of being orphaned")
        XCTAssertEqual(byStart[1].externalId, "healthkit-sleep-watch-1-2023-11-14-1",
                       "F1: later clusters are suffixed by their ordinal within the night")
    }

    func testDisambiguationIsStableAcrossRebuildsRegardlessOfInputOrder() {
        let primary = sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7)
        let napA = sleepSession(night: "2023-11-14", startOffsetHours: 13, durationHours: 1, kind: .sleepNap)
        let napB = sleepSession(night: "2023-11-14", startOffsetHours: 16, durationHours: 1, kind: .sleepNap)

        func ids(_ sessions: [SessionDTO]) -> [String] {
            HealthKitAdapter.disambiguateWithinNight(sessions)
                .sorted { $0.start < $1.start }.map(\.externalId)
        }

        // `sessionsForNight` re-clusters the whole night every rebuild; HealthKit hands back
        // samples unsorted, so identity must not depend on the order they arrive in.
        XCTAssertEqual(ids([primary, napA, napB]), ids([napB, primary, napA]),
                       "F1: ordinals must depend only on cluster start, not on input order")
    }

    func testClustersFromDifferentSourcesOnOneNightAreNotOrdinalled() {
        let watch = sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7,
                                 sourceId: "watch-1")
        let phone = sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7,
                                 sourceId: "phone-1")

        let out = HealthKitAdapter.disambiguateWithinNight([watch, phone])

        // Different sources already differ in both `source_id` and the id's embedded source, so
        // they never collided; suffixing them would gratuitously orphan their existing rows.
        XCTAssertEqual(Set(out.map(\.externalId)),
                       ["healthkit-sleep-watch-1-2023-11-14", "healthkit-sleep-phone-1-2023-11-14"],
                       "F1: two sources reporting the same night must both keep their bare ids")
    }

    /// The end-to-end shape of the bug: two clusters, one night, one source, written through the
    /// real repository must leave two rows — not one silently overwritten by the other.
    func testTwoClustersInOneNightPersistAsTwoSessionRows() throws {
        let repo = MeasurementRepository(db.main)
        let dtos = HealthKitAdapter.disambiguateWithinNight([
            sleepSession(night: "2023-11-14", startOffsetHours: -1, durationHours: 7),
            sleepSession(night: "2023-11-14", startOffsetHours: 14, durationHours: 1, kind: .sleepNap),
        ])

        for dto in dtos {
            _ = try repo.upsertSession(
                Session(id: ULID.newID(), kind: dto.kind, startAt: dto.start, endAt: dto.end,
                        tzId: dto.tz, localNight: "2023-11-14",
                        provenance: Provenance(sourceId: dto.sourceId, ingestionPath: .platformStore,
                                               externalId: dto.externalId, measuredAt: dto.start,
                                               measuredTimezone: dto.tz, recordedAt: dto.start,
                                               ingestedAt: dto.start),
                        updatedAt: dto.start, originDeviceId: deviceId))
        }

        let stored = try repo.sessions(kind: .sleepPrimary) + repo.sessions(kind: .sleepNap)
        XCTAssertEqual(stored.count, 2,
                       "F1: the nap must not overwrite the night's primary sleep via ON CONFLICT")
    }
}
