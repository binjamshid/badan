import XCTest
@testable import BADAN

/// EPIC-23 — baseline & calibration engine v2.
///
/// The pure-math goldens (`compute*`) assert the exact numbers the PUBLISHED contract constants
/// produce for a fixed input, and the mirror suite `BaselineEngineGoldenTest` on Android asserts
/// the SAME numbers — that cross-platform identity is the acceptance criterion, so the expected
/// values here and there are hand-derived once (scratch reference) and kept byte-identical.
///
/// The DB-backed tests cover what the pure core cannot: per-metric windows flowing through the
/// engine, log-domain band asymmetry, the covariate-context hook storing additively, append-only
/// recompute (I2), a DST window, and the 60d×20-metric performance budget.
final class BaselineEngineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"

    /// The real published contract — the same file the app ships. Goldens are asserted against
    /// THIS, not a fixture, so a constant edit that would move a band is caught here.
    var spec: BaselineSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-baseline-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Contract wiring

    func testSpecLoadsAndResolvesPerMetricWindows() {
        XCTAssertTrue(spec.isLoaded, "baseline.rolling_median_mad must load from the bundled contract")
        XCTAssertEqual(spec.algorithm.id, "baseline.rolling_median_mad@2.0.0")
        XCTAssertEqual(spec.defaultWindowDays, 28)
        XCTAssertEqual(spec.minPoints, 7)
        XCTAssertEqual(spec.outlierMadThreshold, 3.5, accuracy: 1e-9)

        XCTAssertEqual(spec.resolve(MetricID.hrv), BaselineWindowResolution(windowDays: 60, transform: .log))
        XCTAssertEqual(spec.resolve(MetricID.restingHeartRate), BaselineWindowResolution(windowDays: 14, transform: .identity))
        XCTAssertEqual(spec.resolve(MetricID.respiratoryRate), BaselineWindowResolution(windowDays: 14, transform: .identity))
        // A metric with no rule falls back to the default window / identity.
        XCTAssertEqual(spec.resolve("body.weight"), BaselineWindowResolution(windowDays: 28, transform: .identity))
    }

    // MARK: - Pure goldens (identical to BaselineEngineGoldenTest.kt)

    func testGoldenIdentityWithOutlierRejected() throws {
        // 13 steady RHR-like points + one 999 spike; the spike is >3.5 MADs out and is rejected
        // before the band is drawn, so it cannot move the personal normal it is then judged against.
        let values = [50.0, 52, 48, 51, 49, 50, 53, 47, 50, 51, 49, 52, 48, 999]
        let c = try XCTUnwrap(BaselineEngine.computeBaseline(
            values: values, resolution: spec.resolve(MetricID.restingHeartRate), spec: spec))
        XCTAssertEqual(c.center, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.spread, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.bandLow, 48.5174, accuracy: 1e-9)
        XCTAssertEqual(c.bandHigh, 51.4826, accuracy: 1e-9)
        XCTAssertEqual(c.nPoints, 13, "the spike is rejected, so n is 13 not 14")
        XCTAssertEqual(c.tier, .establishing)
    }

    func testGoldenLogDomainBandIsAsymmetric() throws {
        // HRV-like ms values, 60d/log window. The 300 spike is rejected; the band comes back
        // asymmetric in linear units (upper wider) because the median/MAD were taken on ln(value).
        let values = [45.0, 50, 55, 48, 52, 60, 42, 47, 53, 58, 44, 300]
        let c = try XCTUnwrap(BaselineEngine.computeBaseline(
            values: values, resolution: spec.resolve(MetricID.hrv), spec: spec))
        XCTAssertEqual(c.center, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.spread, 5.1186443699, accuracy: 1e-9)
        XCTAssertEqual(c.bandLow, 43.4111418516, accuracy: 1e-9)
        XCTAssertEqual(c.bandHigh, 57.5889021428, accuracy: 1e-9)
        XCTAssertEqual(c.nPoints, 11)
        XCTAssertEqual(c.tier, .provisional, "n=11 is below half of a 60-day window")
        XCTAssertGreaterThan(c.bandHigh - c.center, c.center - c.bandLow,
                             "log-domain band must be asymmetric — the upper edge is farther")
    }

    func testGoldenFlatWindowSkipsOutlierRejection() throws {
        // Every value identical: MAD is 0, so outlier rejection is skipped (a lone differing value
        // in an otherwise-flat window would be data, not noise) and nothing is dropped.
        let values = Array(repeating: 50.0, count: 14)
        let c = try XCTUnwrap(BaselineEngine.computeBaseline(
            values: values, resolution: spec.resolve(MetricID.restingHeartRate), spec: spec))
        XCTAssertEqual(c.center, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.spread, 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.bandLow, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.bandHigh, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.nPoints, 14)
        XCTAssertEqual(c.tier, .established)
    }

    func testGoldenLogSmallSample() throws {
        let values = [40.0, 50, 60]
        let c = try XCTUnwrap(BaselineEngine.computeBaseline(
            values: values, resolution: BaselineWindowResolution(windowDays: 3, transform: .log), spec: spec))
        XCTAssertEqual(c.center, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.spread, 10.4671025285, accuracy: 1e-9)
        XCTAssertEqual(c.bandLow, 38.1571464540, accuracy: 1e-9)
        XCTAssertEqual(c.bandHigh, 65.5185262088, accuracy: 1e-9)
        XCTAssertEqual(c.nPoints, 3)
    }

    func testLogTransformDropsNonPositiveValuesRatherThanClamping() throws {
        // A sensor zero is missing data, not ln(0) = -inf. Dropped before the band is drawn.
        let c = try XCTUnwrap(BaselineEngine.computeBaseline(
            values: [0.0, 50, 50, 50], resolution: BaselineWindowResolution(windowDays: 14, transform: .log), spec: spec))
        XCTAssertEqual(c.center, 50.0, accuracy: 1e-9)
        XCTAssertEqual(c.nPoints, 3, "the 0 is dropped, leaving 3 usable points")
    }

    // MARK: - Tier classification

    func testTierGatesOnPointsAndHalfWindow() {
        // 14d window: half-window (7) equals minPoints (7).
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 6, windowDays: 14, spec: spec), .provisional)
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 7, windowDays: 14, spec: spec), .establishing)
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 14, windowDays: 14, spec: spec), .established)
        // 60d HRV window: provisional holds until half the window (30) despite n>=minPoints.
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 7, windowDays: 60, spec: spec), .provisional)
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 29, windowDays: 60, spec: spec), .provisional)
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 30, windowDays: 60, spec: spec), .establishing)
        XCTAssertEqual(BaselineEngine.classifyTier(nPoints: 60, windowDays: 60, spec: spec), .established)
    }

    // MARK: - Retroactive labeling

    func testIsRetroactiveUsesGraceWindow() throws {
        let tz = "UTC"
        func day(_ key: String) -> Date { DayAttribution.date(fromDayKey: key, tz: tz)! }
        // graceDays = 2 (from the contract).
        XCTAssertFalse(BaselineEngine.isRetroactive(periodDayKey: "2026-05-01", computedAt: day("2026-05-01"), tz: tz, spec: spec),
                       "computed the same day is live, not retroactive")
        XCTAssertFalse(BaselineEngine.isRetroactive(periodDayKey: "2026-05-01", computedAt: day("2026-05-03"), tz: tz, spec: spec),
                       "computed within the grace window is still live")
        XCTAssertTrue(BaselineEngine.isRetroactive(periodDayKey: "2026-05-01", computedAt: day("2026-05-04"), tz: tz, spec: spec),
                      "computed past the grace window was computed later from history")
        XCTAssertTrue(BaselineEngine.isRetroactive(periodDayKey: "2026-05-01", computedAt: day("2026-07-20"), tz: tz, spec: spec))
    }

    // MARK: - Calibration read model

    func testCalibrationReadModelFromBaseline() {
        let baseline = Baseline(
            id: ULID.newID(), metricId: MetricID.hrv, windowDays: 60, center: 50, spread: 5,
            bandLow: 45, bandHigh: 56, nPoints: 40, provisional: false,
            algorithmVersion: spec.algorithm.id, validFrom: Date(), computedAt: Date(), unit: "ms")
        let cal = BaselineCalibration.from(baseline: baseline, spec: spec)
        XCTAssertEqual(cal.tier, .establishing, "40 of 60 days: past provisional, window not full")
        XCTAssertEqual(cal.nPoints, 40)
        XCTAssertEqual(cal.windowDays, 60)
        XCTAssertEqual(cal.transform, .log, "HRV's transform is reconstructed from the contract, not stored on the row")
        XCTAssertEqual(cal.maturity, 40.0 / 60.0, accuracy: 1e-9)
        XCTAssertFalse(cal.provisional)
    }

    // MARK: - DB: per-metric windows + log-domain through the engine

    func testEnginePerMetricWindowsAndLogBand() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)

        // 40 prior days of HRV (positive, varied) and RHR.
        for daysAgo in 1...40 {
            try insert(measurements, metricId: MetricID.hrv, daysAgo: daysAgo, value: 48 + Double(daysAgo % 5) * 2, asOf: asOf, tz: tz)
            try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 50 + Double(daysAgo % 3), asOf: asOf, tz: tz)
        }
        let engine = BaselineEngine(derivation: derivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try engine.recompute(metricId: MetricID.hrv, asOf: asOf, tz: tz)
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz)

        let hrv = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.hrv))
        XCTAssertEqual(hrv.windowDays, 60, "HRV uses the 60-day window from the contract, not the default")
        XCTAssertGreaterThan(hrv.bandHigh - hrv.center, hrv.center - hrv.bandLow,
                             "HRV band must be log-domain asymmetric")

        let rhr = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate))
        XCTAssertEqual(rhr.windowDays, 14, "RHR uses the 14-day window")
    }

    // MARK: - DB: covariate-context hook (EPIC-39 prep)

    func testCovariateContextStoresBaselinesAdditivelyWithUnconditionedFallback() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        for daysAgo in 1...14 { try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 50, asOf: asOf, tz: tz) }

        let engine = BaselineEngine(derivation: derivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        // Unconditioned baseline, then a per-context one (a stand-in for a future cycle phase). The
        // engine does NOT read cycle data — it stores under whatever context it is handed.
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz, context: "default")
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz, context: "cycle:luteal")

        let unconditioned = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate, context: "default"))
        let conditioned = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate, context: "cycle:luteal"))
        XCTAssertEqual(unconditioned.covariateContext, "default")
        XCTAssertEqual(conditioned.covariateContext, "cycle:luteal")
        XCTAssertNotEqual(unconditioned.id, conditioned.id, "the two contexts are separate rows, stored additively")
        XCTAssertEqual(countBaselines(context: "default"), 1)
        XCTAssertEqual(countBaselines(context: "cycle:luteal"), 1)
    }

    // MARK: - DB: append-only recompute (I2)

    func testRecomputeIsIdempotentThenAppendsAcrossDays() throws {
        let tz = "UTC"
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        for daysAgo in 1...14 { try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 50, asOf: day0, tz: tz) }

        let engine = BaselineEngine(derivation: derivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(day0), deviceId: deviceId)
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: day0, tz: tz)
        XCTAssertEqual(countBaselines(context: "default"), 1)

        // Idempotent: re-running over unchanged data at the same as-of day writes nothing.
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: day0, tz: tz)
        XCTAssertEqual(countBaselines(context: "default"), 1, "an unchanged recompute must not grow the table")

        // A LATER as-of day with changed data appends a fresh baseline row; the earlier one is
        // retained (I2 — history of what BADAN believed is preserved).
        let day1 = DayAttribution.addingDays(1, to: day0, tz: tz)
        for daysAgo in 1...14 { try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 60, asOf: day1, tz: tz) }
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: day1, tz: tz)
        XCTAssertEqual(countBaselines(context: "default"), 2, "a new as-of day appends, never mutates the prior row")
        let latest = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate))
        XCTAssertEqual(latest.center, 60, accuracy: 1e-9, "latest read returns the newest belief")
    }

    func testCompositeRecomputeAppendsNewDerivedRowAndRetainsOld() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        // Sleep + RHR history so readiness composites compute. RHR carries real variation so its
        // baseline has a non-zero spread — otherwise z would be 0 and no score could ever move.
        for daysAgo in 1...20 {
            try insert(measurements, metricId: MetricID.timeAsleep, daysAgo: daysAgo, value: 7 * 3600, asOf: asOf, tz: tz)
            try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 50 + Double(daysAgo % 3), asOf: asOf, tz: tz)
        }

        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: FixedClock(asOf), deviceId: deviceId).recomputeAll(asOf: asOf, tz: tz)
        let after1 = try derivation.allDerived(metricId: "readiness.score").count
        XCTAssertGreaterThan(after1, 0)

        // Change an input day so its score moves, recompute at a LATER clock → a new row appends
        // for that day; the original computed_at row is still there (never mutated/deleted).
        let targetDay = DayAttribution.localDayKey(DayAttribution.addingDays(-1, to: asOf, tz: tz), tz: tz)
        try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: 1, value: 90, asOf: asOf, tz: tz)
        let later = FixedClock(asOf.addingTimeInterval(3600))
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: later, deviceId: deviceId).recomputeAll(asOf: asOf, tz: tz)

        let rows = try derivation.allDerived(metricId: "readiness.score").filter { $0.periodKey == "day:" + targetDay }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "a changed score appends a new row, keeping the old one (I2)")
        let latest = try XCTUnwrap(try derivation.latestDerived(metricId: "readiness.score", periodKey: "day:" + targetDay))
        XCTAssertEqual(latest.computedAt, later.now(), "the latest read is the newest belief")
    }

    func testVersionBumpAppendsEvenWhenBandUnchanged() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        // time_asleep bands over a 28-day window; a spec with an empty window table resolves it to the
        // SAME default window + identity transform, so the bumped spec reproduces a byte-identical band.
        for daysAgo in 1...28 { try insert(measurements, metricId: MetricID.timeAsleep, daysAgo: daysAgo, value: 25200, asOf: asOf, tz: tz) }

        // First pass at the published version.
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: FixedClock(asOf), deviceId: deviceId)
            .recompute(metricId: MetricID.timeAsleep, asOf: asOf, tz: tz)
        XCTAssertEqual(countBaselines(context: "default"), 1)

        // Second pass: identical params, bumped algorithm version, later clock. The band is byte-identical,
        // yet it must APPEND under the new version — never be skipped by the value-only guard (finding #5).
        let bumped = BaselineSpec(
            algorithm: AlgorithmVersion(algorithmId: spec.algorithm.algorithmId, semver: "9.9.9",
                                        introducedIn: spec.algorithm.introducedIn),
            defaultWindowDays: spec.defaultWindowDays, minPoints: spec.minPoints, madToSigma: spec.madToSigma,
            bandSigmas: spec.bandSigmas, outlierMadThreshold: spec.outlierMadThreshold,
            establishingFraction: spec.establishingFraction, retroactiveGraceDays: spec.retroactiveGraceDays,
            byMetric: [:], isLoaded: true)
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: FixedClock(asOf.addingTimeInterval(3600)), deviceId: deviceId, spec: bumped)
            .recompute(metricId: MetricID.timeAsleep, asOf: asOf, tz: tz)

        XCTAssertEqual(countBaselines(context: "default"), 2, "same band + bumped version appends, keeping the old row")
        let latest = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.timeAsleep))
        XCTAssertEqual(latest.algorithmVersion, "baseline.rolling_median_mad@9.9.9", "the latest read carries the bumped version")
        XCTAssertEqual(latest.center, 25200, accuracy: 1e-9, "only the version changed, not the band")
    }

    // MARK: - DST window

    func testWindowIsDSTSafe() throws {
        // America/New_York springs forward on 2026-03-08. A window stepped with raw 86,400s
        // multiples would be an hour short across that day and could drop a calendar day; the
        // Calendar-based stepping counts exactly 14 days.
        let tz = "America/New_York"
        let asOf = DayAttribution.date(fromDayKey: "2026-03-15", tz: tz)!.addingTimeInterval(12 * 3600)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        for daysAgo in 1...14 { try insert(measurements, metricId: MetricID.restingHeartRate, daysAgo: daysAgo, value: 50, asOf: asOf, tz: tz) }

        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: FixedClock(asOf), deviceId: deviceId)
            .recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz)
        let baseline = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate))
        XCTAssertEqual(baseline.nPoints, 14, "all 14 prior calendar days fall in the window across the DST boundary")
    }

    // MARK: - Performance (60d × 20 metrics < 5s)

    func testFullRecomputePerformanceBudget() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let metrics = Array(MetricRegistry.shared.baselineEligible.prefix(20)).map(\.metricId)
        for metricId in metrics {
            for daysAgo in 1...60 { try insert(measurements, metricId: metricId, daysAgo: daysAgo, value: 50 + Double(daysAgo % 7), asOf: asOf, tz: tz) }
        }
        let engine = BaselineEngine(derivation: derivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        let start = Date()
        try engine.recomputeAll(asOf: asOf, tz: tz)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "full recompute (60d × 20 metrics) must stay under the 5s device budget (was \(elapsed)s)")
    }

    // MARK: - Fixtures

    /// Insert (or correct in place, via a per-day external id) one metric's value for the local day
    /// `daysAgo` before `asOf`. A stable external id keyed on the calendar day is what makes a
    /// re-insert a CORRECTION of that day rather than a second same-day row — so the append tests
    /// mutate exactly the day they mean to.
    private func insert(_ measurements: MeasurementRepository, metricId: String, daysAgo: Int,
                        value: Double, asOf: Date, tz: String) throws {
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let day = DayAttribution.addingDays(-daysAgo, to: dayStart, tz: tz)
        let dayKey = DayAttribution.localDayKey(day, tz: tz)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: day, endAt: DayAttribution.addingDays(1, to: day, tz: tz), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, externalId: "\(metricId)#\(dayKey)",
                                   measuredAt: day, measuredTimezone: tz, recordedAt: day, ingestedAt: day),
            updatedAt: day, originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(record)
    }

    private func countBaselines(context: String) -> Int {
        let rows = (try? db.main.query("SELECT COUNT(*) AS c FROM baselines WHERE covariate_context = ?;", [.text(context)])) ?? []
        return Int(rows.first?.int("c") ?? 0)
    }
}
