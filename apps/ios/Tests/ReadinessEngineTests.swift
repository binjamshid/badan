import XCTest
@testable import BADAN

/// EPIC-25 — Readiness engine v2 (`composite.readiness_score@2.0.0`).
///
/// The pure-composite goldens (`composite`) assert the exact numbers the PUBLISHED weights produce
/// for fixed inputs, and the mirror suite `ReadinessEngineGoldenTest` on Android asserts the SAME
/// numbers — that cross-platform identity is the acceptance criterion, so the expected values here and
/// there are hand-derived once and kept byte-identical.
///
/// The DB-backed tests cover what the pure core cannot: the full missing-input matrix flowing through
/// the engine, the two-source-HRV conflict resolving to the priority device (with that device visible
/// in the manifest lineage), reduced-input confidence capping, append-only recompute on late data
/// (I2), and the v1→v2 migration (old rows keep their old id; latest read is v2).
final class ReadinessEngineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"
    let tz = "UTC"
    let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    /// The real published contract — the same file the app ships. Goldens are asserted against THIS,
    /// so a weight edit that would move a score is caught here.
    var spec: ReadinessSpec { .load(from: .shared) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-readiness-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Contract wiring

    func testSpecLoadsPublishedWeightsAndGates() {
        XCTAssertTrue(spec.isLoaded, "composite.readiness_score must load from the bundled contract")
        XCTAssertEqual(spec.algorithm.id, "composite.readiness_score@2.0.0")
        XCTAssertEqual(spec.params.weight(for: .hrv), 0.5, accuracy: 1e-9)
        XCTAssertEqual(spec.params.weight(for: .rhr), 0.2, accuracy: 1e-9)
        XCTAssertEqual(spec.params.weight(for: .respiratoryRate), 0.1, accuracy: 1e-9)
        XCTAssertEqual(spec.params.weight(for: .sleepPerformance), 0.2, accuracy: 1e-9)
        XCTAssertEqual(spec.params.totalWeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(spec.params.zClampSigmas, 2.5, accuracy: 1e-9)
        XCTAssertEqual(spec.params.minInputsForFullScore, 3)
        XCTAssertEqual(spec.params.minInputsToScoreAtAll, 2)
        XCTAssertTrue(spec.params.algorithmProvisional, "the launch weights are provisional pending A3 validation")
    }

    // MARK: - Pure composite goldens (identical to ReadinessEngineGoldenTest.kt)

    func testGoldenFullComposite() throws {
        // HRV +1σ (favourable → 70), RHR +1σ (unfavourable → 30), RR at baseline (50), sleep 90%.
        // .5·70 + .2·30 + .1·50 + .2·90 = 35 + 6 + 5 + 18 = 64.
        let present = [vital(.hrv, z: 1), vital(.rhr, z: 1), vital(.respiratoryRate, z: 0), sleep(90)]
        let c = try XCTUnwrap(ReadinessEngine.composite(present: present, params: spec.params))
        XCTAssertEqual(c.score, 64.0, accuracy: 1e-9)
        XCTAssertEqual(c.confidence, 1.0, accuracy: 1e-9, "all present + established → full confidence")
        XCTAssertEqual(c.variant, .full)
        XCTAssertTrue(c.provisional, "the algorithm itself is provisional, so every v2 row is flagged")
        XCTAssertEqual(contribution(c, .hrv), 35.0, accuracy: 1e-9)
        XCTAssertEqual(contribution(c, .rhr), 6.0, accuracy: 1e-9)
        XCTAssertEqual(contribution(c, .respiratoryRate), 5.0, accuracy: 1e-9)
        XCTAssertEqual(contribution(c, .sleepPerformance), 18.0, accuracy: 1e-9)
        XCTAssertEqual(c.contributions.reduce(0) { $0 + $1.contribution }, c.score, accuracy: 1e-9,
                       "Σ contributions == the score, by construction")
    }

    func testGoldenMissingHrvReducedAndCapped() throws {
        // HRV absent. Present weight = .5, renormalized to .4/.2/.4. .4·30 + .2·50 + .4·90 = 58.
        let present = [vital(.rhr, z: 1), vital(.respiratoryRate, z: 0), sleep(90)]
        let c = try XCTUnwrap(ReadinessEngine.composite(present: present, params: spec.params))
        XCTAssertEqual(c.score, 58.0, accuracy: 1e-9)
        XCTAssertEqual(c.confidence, 0.5, accuracy: 1e-9, "missing HRV (weight .5) caps confidence at .5 — no magic constant")
        guard case let .reducedInput(missing) = c.variant else { return XCTFail("expected reduced-input variant") }
        XCTAssertEqual(Set(missing), [.hrv])
    }

    func testGoldenTwoInputMinimumIsReduced() throws {
        // HRV +1σ (70) and sleep 70%. Present weight .7 → renormalized .5/.7, .2/.7. Both 70 → 70.
        let present = [vital(.hrv, z: 1), sleep(70)]
        let c = try XCTUnwrap(ReadinessEngine.composite(present: present, params: spec.params))
        XCTAssertEqual(c.score, 70.0, accuracy: 1e-9)
        XCTAssertEqual(c.confidence, 0.7, accuracy: 1e-9)
        guard case let .reducedInput(missing) = c.variant else { return XCTFail("two inputs (< minInputsForFullScore) is a reduced variant") }
        XCTAssertEqual(Set(missing), [.rhr, .respiratoryRate])
    }

    func testGoldenClampBoundsTheComposite() throws {
        // Wild z well past the clamp on every vital, plus oversized sleep — all pinned to the extreme.
        let maxed = [vital(.hrv, z: 3), vital(.rhr, z: -3), vital(.respiratoryRate, z: -3), sleep(130)]
        XCTAssertEqual(try XCTUnwrap(ReadinessEngine.composite(present: maxed, params: spec.params)).score, 100.0, accuracy: 1e-9)
        let floored = [vital(.hrv, z: -3), vital(.rhr, z: 3), vital(.respiratoryRate, z: 3), sleep(0)]
        XCTAssertEqual(try XCTUnwrap(ReadinessEngine.composite(present: floored, params: spec.params)).score, 0.0, accuracy: 1e-9)
    }

    func testBelowMinimumInputsScoresNothing() {
        // One input is never enough — an honest absence beats a confident number built from one signal.
        XCTAssertNil(ReadinessEngine.composite(present: [sleep(80)], params: spec.params))
        XCTAssertNil(ReadinessEngine.composite(present: [vital(.hrv, z: 1)], params: spec.params))
    }

    /// The full completeness matrix: scoreability, variant, and the weight-coverage confidence cap for
    /// every present-input combination. Documents `docs/algorithms/readiness.md`'s table in code.
    func testMissingInputMatrix() throws {
        let allMature = { (present: [ReadinessInputSample]) -> ReadinessComputation? in
            ReadinessEngine.composite(present: present, params: self.spec.params)
        }
        // HRV present: full at ≥3 inputs, coverage follows which light input is missing.
        assertScore(allMature([vital(.hrv, z: 0), vital(.rhr, z: 0), vital(.respiratoryRate, z: 0), sleep(50)]),
                    variantFull: true, confidence: 1.0)
        assertScore(allMature([vital(.hrv, z: 0), vital(.rhr, z: 0), sleep(50)]),
                    variantFull: true, confidence: 0.9)   // RR (.1) missing
        assertScore(allMature([vital(.hrv, z: 0), vital(.rhr, z: 0), vital(.respiratoryRate, z: 0)]),
                    variantFull: true, confidence: 0.8)   // sleep (.2) missing
        assertScore(allMature([vital(.hrv, z: 0), sleep(50)]),
                    variantFull: false, confidence: 0.7)  // two inputs → reduced
        // HRV absent: always reduced, always capped ≤ .5.
        assertScore(allMature([vital(.rhr, z: 0), vital(.respiratoryRate, z: 0), sleep(50)]),
                    variantFull: false, confidence: 0.5)
        assertScore(allMature([vital(.rhr, z: 0), sleep(50)]),
                    variantFull: false, confidence: 0.4)
        assertScore(allMature([vital(.respiratoryRate, z: 0), sleep(50)]),
                    variantFull: false, confidence: 0.3)
        // Single input — nothing renders.
        XCTAssertNil(allMature([vital(.rhr, z: 0)]))
    }

    func testConfidenceTracksBaselineMaturity() throws {
        // The least-mature contributing baseline drags confidence down even when everything is present.
        let present = [vital(.hrv, z: 0, maturity: 0.4), vital(.rhr, z: 0), vital(.respiratoryRate, z: 0), sleep(50)]
        let c = try XCTUnwrap(ReadinessEngine.composite(present: present, params: spec.params))
        XCTAssertEqual(c.confidence, 0.4, accuracy: 1e-9, "coverage 1.0 × min-maturity 0.4")
    }

    func testProvisionalIsIndependentOfCompleteness() throws {
        // Isolate the provisional logic from the (currently always-provisional) algorithm flag.
        let stableParams = ReadinessParams(
            weights: spec.params.weights, zClampSigmas: spec.params.zClampSigmas,
            minInputsForFullScore: spec.params.minInputsForFullScore,
            minInputsToScoreAtAll: spec.params.minInputsToScoreAtAll, algorithmProvisional: false)
        let established = [vital(.hrv, z: 0), vital(.rhr, z: 0), vital(.respiratoryRate, z: 0), sleep(50)]
        XCTAssertFalse(try XCTUnwrap(ReadinessEngine.composite(present: established, params: stableParams)).provisional)
        // One still-provisional baseline makes the whole score provisional (cold-start honesty).
        let coldHrv = [vital(.hrv, z: 0, provisional: true), vital(.rhr, z: 0), vital(.respiratoryRate, z: 0), sleep(50)]
        XCTAssertTrue(try XCTUnwrap(ReadinessEngine.composite(present: coldHrv, params: stableParams)).provisional)
    }

    // MARK: - DB: full morning compute + persistence

    func testMorningComputeAppendsV2RowWithContributionManifest() throws {
        let (measurements, derivation) = repos()
        seedEstablishedBaselines(derivation)
        // All vitals at baseline (z 0 → sub 50); sleep 80%. .5·50+.2·50+.1·50+.2·80 = 56.
        _ = try insertVital(measurements, MetricID.hrv, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.restingHeartRate, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.respiratoryRate, value: 15, sourceId: "watch")
        try insertSleepPerformance(derivation, value: 80)

        let engine = ReadinessEngine(derivation: derivation, measurements: measurements,
                                     clock: FixedClock(asOf), deviceId: deviceId)
        let result = try XCTUnwrap(try engine.compute(asOf: asOf, tz: tz))
        XCTAssertEqual(result.computation.score, 56.0, accuracy: 1e-9)
        XCTAssertEqual(result.computation.variant, .full)

        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        XCTAssertEqual(row.value, 56.0, accuracy: 1e-9)
        XCTAssertEqual(row.algorithmId, "composite.readiness_score")
        XCTAssertEqual(row.algorithmVersion, "2.0.0", "the morning score is stamped v2, not the interim v1 composite")
        XCTAssertEqual(row.unit, "score_0_100")
        XCTAssertTrue(row.provisional)

        let manifest = try XCTUnwrap(try derivation.manifest(id: try XCTUnwrap(row.inputManifestId)))
        XCTAssertEqual(manifest.inputs.count, 4)
        let contribSum = manifest.inputs.compactMap(\.weight).reduce(0, +)
        XCTAssertEqual(contribSum, row.value, accuracy: 1e-9,
                       "each input's manifest weight is its additive contribution; Σ == the score")
    }

    // MARK: - DB: two-source HRV conflict → priority device fed the score

    func testTwoSourceHrvResolvesToPriorityDeviceInLineage() throws {
        let (measurements, derivation) = repos()
        seedEstablishedBaselines(derivation)
        // A watch (priority 2) and a phone (priority 1) both report last night's HRV. Neither is
        // dedup-suppressed (vitals aren't), so both are live rows and the engine must resolve.
        let watchId = try insertVital(measurements, MetricID.hrv, value: 60, sourceId: "watch")
        let phoneId = try insertVital(measurements, MetricID.hrv, value: 40, sourceId: "phone")
        _ = try insertVital(measurements, MetricID.restingHeartRate, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.respiratoryRate, value: 15, sourceId: "watch")
        try insertSleepPerformance(derivation, value: 80)

        let priority: (String) -> Int = { ["watch": 2, "phone": 1][$0] ?? 0 }
        let engine = ReadinessEngine(derivation: derivation, measurements: measurements,
                                     clock: FixedClock(asOf), deviceId: deviceId, priorityForSource: priority)
        let result = try XCTUnwrap(try engine.compute(asOf: asOf, tz: tz))

        // Both raw rows are retained (I3 — nothing deleted); the score used the priority device.
        XCTAssertEqual(try measurements.intervalRecords(metricId: MetricID.hrv).count, 2)
        let hrv = try XCTUnwrap(result.computation.contributions.first { $0.input == .hrv })
        XCTAssertEqual(hrv.recordId, watchId, "the higher-priority watch record fed the score")
        XCTAssertEqual(hrv.measuredValue, 60, accuracy: 1e-9)
        XCTAssertEqual(hrv.sourceId, "watch")
        XCTAssertNotEqual(hrv.recordId, phoneId)

        // The manifest lineage carries the winning record id, so the anatomy sheet can name the device.
        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        let manifest = try XCTUnwrap(try derivation.manifest(id: try XCTUnwrap(row.inputManifestId)))
        XCTAssertEqual(manifest.inputs.first { $0.metricId == MetricID.hrv }?.recordId, watchId)
    }

    // MARK: - DB: reduced-input variant (no HRV) is distinctly labelled + capped

    func testReducedInputWhenHrvMissing() throws {
        let (measurements, derivation) = repos()
        // Only RHR + RR baselines/records + sleep — no HRV anywhere. Never imputed.
        insertBaseline(derivation, MetricID.restingHeartRate, center: 50, spread: 5)
        insertBaseline(derivation, MetricID.respiratoryRate, center: 15, spread: 2)
        _ = try insertVital(measurements, MetricID.restingHeartRate, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.respiratoryRate, value: 15, sourceId: "watch")
        try insertSleepPerformance(derivation, value: 80)

        let engine = ReadinessEngine(derivation: derivation, measurements: measurements,
                                     clock: FixedClock(asOf), deviceId: deviceId)
        let result = try XCTUnwrap(try engine.compute(asOf: asOf, tz: tz))
        guard case let .reducedInput(missing) = result.computation.variant else {
            return XCTFail("a missing-HRV score must be a distinctly-labelled reduced variant")
        }
        XCTAssertTrue(missing.contains(.hrv))
        XCTAssertLessThanOrEqual(result.computation.confidence, 0.5, "missing HRV caps confidence at ≤ .5")

        let row = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        XCTAssertLessThanOrEqual(try XCTUnwrap(row.confidence), 0.5)
    }

    func testNotScoreableWithASingleInput() throws {
        let (measurements, derivation) = repos()
        try insertSleepPerformance(derivation, value: 80)   // one input only
        let engine = ReadinessEngine(derivation: derivation, measurements: measurements,
                                     clock: FixedClock(asOf), deviceId: deviceId)
        XCTAssertNil(try engine.compute(asOf: asOf, tz: tz), "one input → no score")
        XCTAssertTrue(try derivation.allDerived(metricId: MetricID.readinessScore).isEmpty, "and no row is written")
    }

    // MARK: - DB: append-only recompute on late data (I2)

    func testLateDataAppendsNewRowKeepingTheOld() throws {
        let (measurements, derivation) = repos()
        seedEstablishedBaselines(derivation)
        _ = try insertVital(measurements, MetricID.hrv, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.restingHeartRate, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.respiratoryRate, value: 15, sourceId: "watch")
        try insertSleepPerformance(derivation, value: 80)

        try ReadinessEngine(derivation: derivation, measurements: measurements,
                            clock: FixedClock(asOf), deviceId: deviceId).compute(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.readinessScore).count, 1)

        // Re-running over unchanged data is idempotent (a repeat morning trigger writes nothing).
        try ReadinessEngine(derivation: derivation, measurements: measurements,
                            clock: FixedClock(asOf.addingTimeInterval(60)), deviceId: deviceId).compute(asOf: asOf, tz: tz)
        XCTAssertEqual(try derivation.allDerived(metricId: MetricID.readinessScore).count, 1,
                       "unchanged recompute must not grow the table")

        // Late overnight HRV lands (a higher value, later updatedAt) → the score moves → a new row
        // appends at a fresh computedAt; the original is retained (I2).
        _ = try insertVital(measurements, MetricID.hrv, value: 62, sourceId: "watch",
                            updatedAt: asOf.addingTimeInterval(120))
        let later = FixedClock(asOf.addingTimeInterval(3600))
        try ReadinessEngine(derivation: derivation, measurements: measurements,
                            clock: later, deviceId: deviceId).compute(asOf: asOf, tz: tz)
        let rows = try derivation.allDerived(metricId: MetricID.readinessScore)
        XCTAssertEqual(rows.count, 2, "late data appends, never mutates the prior row")
        let latest = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        XCTAssertEqual(latest.computedAt, later.now(), "latest read is the newest belief")
        XCTAssertTrue(rows.allSatisfy { $0.algorithmVersion == "2.0.0" })
    }

    // MARK: - DB: v1 → v2 migration (old rows keep their old algorithm id)

    func testV1RowIsRetainedAndV2Supersedes() throws {
        let (measurements, derivation) = repos()
        // A legacy v1 readiness row already exists for the day (from the interim BaselineEngine composite).
        let legacy = DerivedValue(
            id: ULID.newID(), metricId: MetricID.readinessScore, value: 72, unit: "score_0_100",
            periodKey: periodKey, provisional: true, algorithmId: "composite.readiness_score",
            algorithmVersion: "1.0.0", computedAt: asOf.addingTimeInterval(-3600),
            updatedAt: asOf.addingTimeInterval(-3600), originDeviceId: deviceId)
        try derivation.appendDerived(legacy)

        seedEstablishedBaselines(derivation)
        _ = try insertVital(measurements, MetricID.hrv, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.restingHeartRate, value: 50, sourceId: "watch")
        _ = try insertVital(measurements, MetricID.respiratoryRate, value: 15, sourceId: "watch")
        try insertSleepPerformance(derivation, value: 80)

        try ReadinessEngine(derivation: derivation, measurements: measurements,
                            clock: FixedClock(asOf), deviceId: deviceId).compute(asOf: asOf, tz: tz)

        let rows = try derivation.allDerived(metricId: MetricID.readinessScore)
        XCTAssertEqual(rows.count, 2, "the v1 row is never rewritten (I2); v2 appends alongside it")
        let v1 = try XCTUnwrap(rows.first { $0.algorithmVersion == "1.0.0" })
        XCTAssertEqual(v1.value, 72, accuracy: 1e-9, "the old row keeps its old value and id")
        XCTAssertEqual(v1.id, legacy.id)
        let latest = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        XCTAssertEqual(latest.algorithmVersion, "2.0.0", "the latest read surfaces v2")
    }

    // MARK: - Fixtures

    private var periodKey: String { "day:" + DayAttribution.localDayKey(asOf, tz: tz) }

    private func repos() -> (MeasurementRepository, DerivationRepository) {
        (MeasurementRepository(db.main), DerivationRepository(db.main))
    }

    private func vital(_ input: ReadinessInput, z: Double, maturity: Double = 1.0, provisional: Bool = false) -> ReadinessInputSample {
        ReadinessInputSample(input: input, measuredValue: 0, z: z, maturity: maturity,
                             provisional: provisional, recordId: "rec-\(input.rawValue)", sourceId: "src")
    }

    private func sleep(_ performance: Double, maturity: Double = 1.0, provisional: Bool = false) -> ReadinessInputSample {
        ReadinessInputSample(input: .sleepPerformance, measuredValue: performance, z: nil, maturity: maturity,
                             provisional: provisional, recordId: "rec-sleep", sourceId: nil)
    }

    private func contribution(_ c: ReadinessComputation, _ input: ReadinessInput) -> Double {
        c.contributions.first { $0.input == input }?.contribution ?? .nan
    }

    private func assertScore(_ c: ReadinessComputation?, variantFull: Bool, confidence: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let c else { return XCTFail("expected a score", file: file, line: line) }
        if case .full = c.variant {
            XCTAssertTrue(variantFull, "expected reduced variant", file: file, line: line)
        } else {
            XCTAssertFalse(variantFull, "expected full variant", file: file, line: line)
        }
        XCTAssertEqual(c.confidence, confidence, accuracy: 1e-9, file: file, line: line)
    }

    private func seedEstablishedBaselines(_ derivation: DerivationRepository) {
        insertBaseline(derivation, MetricID.hrv, center: 50, spread: 5)
        insertBaseline(derivation, MetricID.restingHeartRate, center: 50, spread: 5)
        insertBaseline(derivation, MetricID.respiratoryRate, center: 15, spread: 2)
    }

    /// An established baseline (nPoints == windowDays → maturity 1.0) so confidence is driven by input
    /// completeness, not calibration, in the DB tests.
    private func insertBaseline(_ derivation: DerivationRepository, _ metricId: String,
                                center: Double, spread: Double, windowDays: Int = 14, provisional: Bool = false) {
        try? derivation.upsertBaseline(Baseline(
            id: ULID.newID(), metricId: metricId, windowDays: windowDays, center: center, spread: spread,
            bandLow: center - spread, bandHigh: center + spread, nPoints: windowDays, provisional: provisional,
            algorithmVersion: "baseline.rolling_median_mad@2.0.0", validFrom: asOf, computedAt: asOf, unit: "unit"))
    }

    /// One interval reading for the local day of `asOf`, from `sourceId`. A per-source external id
    /// keeps two sources' same-day readings as two live rows (the two-source-HRV case).
    @discardableResult
    private func insertVital(_ measurements: MeasurementRepository, _ metricId: String, value: Double,
                             sourceId: String, updatedAt: Date? = nil) throws -> String {
        let start = DayAttribution.startOfDay(asOf, tz: tz).addingTimeInterval(6 * 3600)
        let record = IntervalRecord(
            id: ULID.newID(), metricId: metricId, value: value, unit: "unit",
            startAt: start, endAt: start.addingTimeInterval(3600), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: sourceId, ingestionPath: .platformStore,
                                   externalId: "\(metricId)#\(sourceId)", measuredAt: start,
                                   measuredTimezone: tz, recordedAt: start, ingestedAt: start),
            updatedAt: updatedAt ?? asOf, originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(record)
        return record.id
    }

    private func insertSleepPerformance(_ derivation: DerivationRepository, value: Double,
                                        confidence: Double? = nil, provisional: Bool = false) throws {
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.sleepPerformance, value: value, unit: "percent",
            periodKey: periodKey, confidence: confidence, provisional: provisional,
            algorithmId: "sleep.performance", algorithmVersion: "0.1.0",
            computedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))
    }
}
