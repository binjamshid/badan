import HealthKit
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

    // MARK: - PERF-181 / EPIC-01: the HKTypeMap binding table

    /// The single check that stops the widened read set from failing silently. Both failure
    /// modes it covers are invisible at runtime: an unknown metric id makes
    /// `IngestionPipeline.writeSamples` `continue` past the row (query runs, nothing stored), and
    /// a non-converting unit stores an unconverted number tagged `.estimate`. See
    /// `HKTypeMap.validate`.
    func testTypeMapRowsAllResolveToRegistryMetricsWithConvertibleUnits() {
        let problems = HKTypeMap.validate(registry: .shared)
        XCTAssertTrue(problems.isEmpty, "HKTypeMap is inconsistent:\n" + problems.joined(separator: "\n"))
    }

    /// (DATA-08) The anchor key is the `read_anchors` primary key. Before PERF-181 the adapter
    /// wrote these strings by hand; the table now derives them from `rawValue`. If those ever
    /// diverge, every existing install silently loses its cursor and re-scans 90 days on upgrade
    /// — no error, just a slow sync and a pile of no-op upserts. Pinned here because nothing else
    /// would notice.
    func testAnchorKeysMatchTheLiteralsWrittenBeforeTheTypeMap() {
        XCTAssertEqual(HKQuantityTypeIdentifier.heartRate.rawValue, "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(HKQuantityTypeIdentifier.restingHeartRate.rawValue, "HKQuantityTypeIdentifierRestingHeartRate")
        XCTAssertEqual(HKCategoryTypeIdentifier.sleepAnalysis.rawValue, "HKCategoryTypeIdentifierSleepAnalysis")
    }

    /// `interval_records` upserts by `(metric_id, external_id, source_id)`. Steps shipped with a
    /// hand-built external id; deriving it from the metric id instead would orphan every stored
    /// steps row and insert a duplicate per day at the next sync. See
    /// `HKTypeMap.Entry.dailyTotalSlug`.
    func testStepsKeepsItsPreExistingDailyExternalId() throws {
        let steps = try XCTUnwrap(HKTypeMap.entry(for: .stepCount))
        XCTAssertEqual(steps.dailyTotalExternalId(dayKey: "2026-07-20"), "healthkit-steps-2026-07-20")
    }

    /// The families added by EPIC-01 have no legacy id to preserve, so they take the metric id —
    /// asserted so the two shapes stay visibly distinguishable rather than converging by accident.
    func testNewCumulativeTypesKeyTheirDailyTotalsByMetricId() throws {
        let energy = try XCTUnwrap(HKTypeMap.entry(for: .activeEnergyBurned))
        XCTAssertEqual(energy.dailyTotalExternalId(dayKey: "2026-07-20"),
                       "healthkit-activity.active_energy-2026-07-20")
    }

    /// Routes must never ride along in the first authorization sheet — they have their own
    /// consent screen and their own usage string (plan §13.1, and `project.yml` says so in as
    /// many words).
    func testRoutesAreNotInTheMainAuthorizationBundle() {
        XCTAssertFalse(HKTypeMap.authorizationReadTypes.contains(HKSeriesType.workoutRoute()),
                       "workout routes must be requested only from the route-consent screen")
        XCTAssertTrue(HKTypeMap.authorizationReadTypes.contains(HKObjectType.workoutType()),
                      "workouts themselves ARE in the main bundle (the usage string names them)")
        XCTAssertTrue(HealthKitAdapter.routeReadTypes.contains(HKSeriesType.workoutRoute()))
    }

    /// Wrist temperature and height are read (permission + observers) but produce no rows.
    /// Locked down so nobody "completes" the epic by writing an absolute temperature into a
    /// metric labelled *deviation* — see `HKTypeMap.NoIngestReason`.
    func testAuthorizationOnlyTypesCarryNoMetricId() throws {
        let wristTemp = try XCTUnwrap(HKTypeMap.entry(for: .appleSleepingWristTemperature))
        XCTAssertEqual(wristTemp.strategy, .authorizationOnly(.awaitingDerivation))
        XCTAssertNil(wristTemp.metricId,
                     "an absolute wrist temperature must not be stored as a deviation metric")

        let height = try XCTUnwrap(HKTypeMap.entry(for: .height))
        XCTAssertEqual(height.strategy, .authorizationOnly(.profileAttribute))
        XCTAssertNil(height.metricId, "height is a profile attribute, not a time series")

        XCTAssertFalse(HKTypeMap.sourceDiscoveryTypes.contains { $0.identifier == HKQuantityTypeIdentifier.height.rawValue },
                       "a type we never store rows from must not catalog a Source")
    }

    // MARK: - EPIC-01: unit fidelity per type

    /// Round-trips each new type's as-read value through the exact conversion
    /// `IngestionPipeline.canonicalValue` performs, asserting the stored number is the one a
    /// human would expect. These are the conversions where a silent factor error is most
    /// plausible and least visible.
    func testPerTypeUnitRoundTripFidelity() throws {
        func canonical(_ value: Double, _ identifier: HKQuantityTypeIdentifier) throws -> Double {
            let entry = try XCTUnwrap(HKTypeMap.entry(for: identifier))
            let metricId = try XCTUnwrap(entry.metricId)
            let definition = try XCTUnwrap(MetricRegistry.shared.definition(metricId))
            return try Units.convert(value, from: entry.badanUnit, to: definition.canonicalUnit)
        }

        // (DATA-02) HKUnit.percent() hands back 0.97 for a 97% reading. The registry canonical is
        // "percent", whose stored numbers are 0-100 — so 0.97 must land as 97, not as 0.97.
        XCTAssertEqual(try canonical(0.97, .oxygenSaturation), 97, accuracy: 1e-9)
        XCTAssertEqual(try canonical(0.183, .bodyFatPercentage), 18.3, accuracy: 1e-9)
        // kcal -> kJ. A dropped conversion here reads as a 4x understatement of every day's
        // energy, which looks plausible enough on a chart to go unnoticed.
        //
        // Tolerance is 1e-3 rather than 1e-6 because `Units.table` stores the kJ leg as
        // `0.239005736` (1/4.184 rounded to 9 places) and divides by it, which lands ~1.2e-6
        // relative off the exact 4.184 multiplication asserted here. That is ~0.004 kJ on a
        // 2,000 kJ day — far below the precision anything displays — and tightening the table's
        // constant instead would be false precision on a definition that is itself conventional.
        XCTAssertEqual(try canonical(500, .activeEnergyBurned), 500 * 4.184, accuracy: 1e-3)
        XCTAssertEqual(try canonical(1_600, .basalEnergyBurned), 1_600 * 4.184, accuracy: 1e-3)
        // Identity conversions, asserted anyway: they are identities only because the table says
        // so, and a wrong `badanUnit` would make them throw rather than round-trip.
        XCTAssertEqual(try canonical(42.5, .heartRateVariabilitySDNN), 42.5, accuracy: 1e-9)
        XCTAssertEqual(try canonical(14.2, .respiratoryRate), 14.2, accuracy: 1e-9)
        XCTAssertEqual(try canonical(48.6, .vo2Max), 48.6, accuracy: 1e-9)
        XCTAssertEqual(try canonical(79.4, .bodyMass), 79.4, accuracy: 1e-9)
        XCTAssertEqual(try canonical(58.2, .leanBodyMass), 58.2, accuracy: 1e-9)
        XCTAssertEqual(try canonical(6_500, .distanceWalkingRunning), 6_500, accuracy: 1e-9)
        XCTAssertEqual(try canonical(12, .flightsClimbed), 12, accuracy: 1e-9)
        XCTAssertEqual(try canonical(9_431, .stepCount), 9_431, accuracy: 1e-9)
    }

    /// `brpm` sat in the `count/min` dimension, so converting it to `breaths/min` threw and every
    /// value so labelled was stored unconverted and stamped `.estimate`. Latent (nothing in-tree
    /// emitted that spelling), fixed here, and pinned so it cannot regress.
    func testBreathsPerMinuteAliasesConvertAndDoNotCollideWithHeartRate() throws {
        XCTAssertEqual(try Units.convert(14.2, from: "brpm", to: "breaths/min"), 14.2, accuracy: 1e-9)
        XCTAssertThrowsError(try Units.convert(60, from: "bpm", to: "breaths/min"),
                             "a heart rate must never convert silently into a breathing rate")
    }

    func testVO2MaxLowercaseUnitSpellingConverts() throws {
        XCTAssertEqual(try Units.convert(48.6, from: "ml/kg/min", to: "mL/kg/min"), 48.6, accuracy: 1e-9)
    }

    // MARK: - A21/ADR-0010, D-26: blood glucose, widened the same way as any other single-instant vital

    /// The type-map row itself: an ordinary `.anchoredSample`/`.requiresAccessory` entry, no
    /// different in shape from SpO2/weight — the whole point of "same as any other widened metric".
    func testBloodGlucoseTypeMapEntry() throws {
        let entry = try XCTUnwrap(HKTypeMap.entry(for: .bloodGlucose))
        XCTAssertEqual(entry.metricId, MetricID.glucose)
        XCTAssertEqual(entry.strategy, .anchoredSample)
        XCTAssertEqual(entry.caveat, .requiresAccessory,
                       "a glucose reading only exists for days a connected meter/CGM measured one")
        XCTAssertEqual(entry.badanUnit, "mmol/L")
    }

    /// Reading directly in mmol/L (the registry canonical) makes this an identity conversion end to
    /// end — no `.estimate` stamp, unlike a type that has to cross units on the way in.
    func testBloodGlucoseUnitRoundTripIsIdentity() throws {
        let entry = try XCTUnwrap(HKTypeMap.entry(for: .bloodGlucose))
        let metricId = try XCTUnwrap(entry.metricId)
        let definition = try XCTUnwrap(MetricRegistry.shared.definition(metricId))
        XCTAssertEqual(definition.canonicalUnit, "mmol/L")
        XCTAssertEqual(try Units.convert(5.4, from: entry.badanUnit, to: definition.canonicalUnit), 5.4, accuracy: 1e-9)
    }

    /// The clinical mg/dL<->mmol/L conversion, exercised the direction a display/export unit
    /// switch would use it — a ~90 mg/dL fasting reading is ~5.0 mmol/L.
    func testGlucoseMgPerDlConvertsToMmolPerL() throws {
        XCTAssertEqual(try Units.convert(90, from: "mg/dL", to: "mmol/L"), 90 / 18.0182, accuracy: 1e-9)
        XCTAssertEqual(try Units.convert(5.0, from: "mmol/L", to: "mg/dL"), 5.0 * 18.0182, accuracy: 1e-9)
    }

    /// `body.glucose` is authorization-ONLY-adjacent in one sense (it needs an accessory), but it
    /// IS an ingesting row — this pins that it is NOT accidentally left `.authorizationOnly`, which
    /// would silently stop it from ever writing a row (see `HKTypeMap.validate`'s own doc on this
    /// exact silent-failure shape).
    func testBloodGlucoseIsNotAuthorizationOnly() throws {
        let entry = try XCTUnwrap(HKTypeMap.entry(for: .bloodGlucose))
        if case .authorizationOnly = entry.strategy {
            XCTFail("body.glucose must actually ingest, not just request permission")
        }
    }

    // MARK: - EPIC-01 task 9: source priority for the new families

    func testSourcePriorityRecognizesASmartScale() {
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.withings.wiScaleNG",
                                                       deviceModel: nil, deviceProductType: nil,
                                                       displayName: "Withings Health Mate"), 2,
                       "a body-composition source must not tie at 0 against a hand-typed weight")
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.example.scale", deviceModel: "Smart Scale",
                                                       deviceProductType: nil, displayName: "Scale App"), 2)
    }

    func testSourcePriorityRecognizesArabicScaleName() {
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.example.mizan", deviceModel: nil,
                                                       deviceProductType: nil, displayName: "ميزان ذكي"), 2,
                       "an Arabic-named scale (\"ميزان\") must not fall back to priority 0 (FIX-09)")
    }

    /// A phone must still be a phone — the scale tier is additive, not a catch-all that swallows
    /// the existing classification.
    func testSourcePriorityStillRanksPhoneBelowWearableAfterScaleTierAdded() {
        XCTAssertEqual(HealthKitAdapter.sourcePriority(bundleId: "com.apple.health", deviceModel: nil,
                                                       deviceProductType: "iPhone14,5", displayName: "iPhone"), 1)
    }

    // MARK: - EPIC-03: multi-batch route assembly

    private func routePoints(_ count: Int, from index: Int = 0) -> [RoutePointDTO] {
        (0..<count).map { i in
            RoutePointDTO(latitude: 24.7 + Double(index + i) * 1e-5,
                          longitude: 46.6 + Double(index + i) * 1e-5,
                          altitudeMeters: 600, horizontalAccuracyMeters: 5,
                          timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index + i)))
        }
    }

    /// `HKWorkoutRouteQuery` streams a long trace across several callbacks and only sets `done`
    /// on the last. An implementation that returned on the first callback would look correct on
    /// every short route and silently truncate every long one.
    func testRouteAccumulatorConcatenatesEveryDeliveryBatchInOrder() {
        var accumulator = HealthKitAdapter.RouteAccumulator()
        var expected: [RoutePointDTO] = []
        var cursor = 0
        for batchSize in [800, 800, 400, 1] {
            let batch = routePoints(batchSize, from: cursor)
            cursor += batchSize
            expected += batch
            accumulator.append(contentsOf: batch)
        }

        let points = accumulator.finish()
        XCTAssertEqual(points.count, 2_001, "no batch may be dropped between callbacks")
        XCTAssertEqual(points.map(\.timestamp), expected.map(\.timestamp),
                       "batches must concatenate in arrival order, not be interleaved or re-sorted")
    }

    func testRouteAccumulatorHandlesSingleBatchAndEmptyStream() {
        var single = HealthKitAdapter.RouteAccumulator()
        single.append(contentsOf: routePoints(3))
        XCTAssertEqual(single.finish().count, 3, "one batch must not be a special case")

        let empty = HealthKitAdapter.RouteAccumulator()
        XCTAssertTrue(empty.finish().isEmpty, "a route with no fixes yields no points, not a crash")
    }

    // MARK: - EPIC-03: route storage, batched and consent-stamped

    private func makeRoute(id: String, sessionId: String, points: [RoutePoint],
                           consent: RouteConsent = RouteConsent(granted: true, policyVersion: RouteConsent.currentPolicyVersion)) -> WorkoutRoute {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return WorkoutRoute(
            id: id, sessionId: sessionId, pointCount: points.count,
            startAt: points.first?.timestamp ?? now, endAt: points.last?.timestamp ?? now,
            consentSnapshot: consent,
            provenance: Provenance(sourceId: "watch-1", ingestionPath: .platformStore,
                                   externalId: "healthkit-route-\(sessionId)", measuredAt: now,
                                   measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: deviceId)
    }

    private func domainPoints(routeId: String, count: Int) -> [RoutePoint] {
        (0..<count).map { i in
            RoutePoint(routeId: routeId, seq: i, latitude: 24.7 + Double(i) * 1e-5,
                       longitude: 46.6 + Double(i) * 1e-5, altitudeMeters: 600,
                       horizontalAccuracyMeters: 5,
                       timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
    }

    /// 1,201 points crosses the 500-per-INSERT bound three times; the bound exists because one
    /// statement per point-list would exceed SQLite's bound-variable ceiling on a real ride.
    func testRoutePointsPersistAcrossInsertBatchesInOrder() throws {
        let repo = RouteRepository(db.main)
        let points = domainPoints(routeId: "route-1", count: 1_201)
        XCTAssertGreaterThan(points.count, RouteRepository.pointInsertBatchSize * 2,
                             "fixture must actually exercise multi-batch insertion")

        try db.main.transaction {
            _ = try repo.upsert(makeRoute(id: "route-1", sessionId: "session-1", points: points), points: points)
        }

        let stored = try repo.points(routeId: "route-1")
        XCTAssertEqual(stored.count, 1_201, "every point must survive batched insertion")
        XCTAssertEqual(stored.map(\.seq), Array(0..<1_201), "seq must stay contiguous across batches")
        XCTAssertEqual(stored.first?.latitude ?? 0, 24.7, accuracy: 1e-9)
        XCTAssertEqual(stored.last?.timestamp.timeIntervalSince1970 ?? 0,
                       1_700_000_000 + 1_200, accuracy: 1)
    }

    /// Routes are replaced wholesale, never merged — half an old trace interleaved with half a
    /// new one is a state no reader can interpret.
    func testReUpsertingARouteReplacesItsPointsRatherThanAppending() throws {
        let repo = RouteRepository(db.main)
        let first = domainPoints(routeId: "route-1", count: 900)
        try db.main.transaction {
            _ = try repo.upsert(makeRoute(id: "route-1", sessionId: "session-1", points: first), points: first)
        }

        let second = domainPoints(routeId: "route-1", count: 120)
        let wonId = try db.main.transaction {
            try repo.upsert(makeRoute(id: "route-2-fresh-ulid", sessionId: "session-1", points: second),
                            points: second)
        }

        XCTAssertEqual(wonId, "route-1",
                       "re-ingest must update the existing route row, not create a second one")
        XCTAssertEqual(try repo.pointCount(routeId: "route-1"), 120,
                       "the previous trace must be gone, not concatenated with the new one")
        XCTAssertEqual(try repo.routes(sessionId: "session-1").count, 1)
    }

    /// `consent_snapshot` is the answer to "was this row allowed to exist when it was written",
    /// so it has to survive the round trip intact rather than being reconstructed from the
    /// current toggle.
    func testRouteConsentSnapshotRoundTrips() throws {
        let repo = RouteRepository(db.main)
        let consent = RouteConsent(granted: true, policyVersion: "route-consent-v1",
                                   decidedAt: Date(timeIntervalSince1970: 1_699_000_000))
        let points = domainPoints(routeId: "route-1", count: 5)
        try db.main.transaction {
            _ = try repo.upsert(makeRoute(id: "route-1", sessionId: "session-1", points: points, consent: consent),
                                points: points)
        }

        let stored = try XCTUnwrap(try repo.route(id: "route-1"))
        XCTAssertEqual(stored.consentSnapshot, consent)
        XCTAssertEqual(stored.pointCount, 5)
        XCTAssertEqual(stored.provenance.sourceId, "watch-1",
                       "I1: a route carries the full provenance of the workout that produced it")
        XCTAssertEqual(stored.provenance.ingestionPath, .platformStore)
    }
}
