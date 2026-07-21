import XCTest
@testable import BADAN

/// EPIC-23 — the score pipeline end to end: ingest → baselines → sleep → readiness → effort, run in
/// the published cross-metric order by `DerivationCoordinator`, over the deterministic
/// `FakeHealthStore` and a throwaway on-disk database (the same harness as `PipelineTests`).
///
/// These assert what the isolated engine tests cannot: that the engines are wired together, run in
/// the right order (proven by lineage — a readiness row must reference the sleep-performance value
/// that fed it), append rather than overwrite (I2), and are idempotent at the read model (a repeat
/// run over unchanged data grows nothing).
final class DerivationPipelineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000)) // fixed "now"
    let deviceId = "test-device"
    let tz = TimeZone.current.identifier

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-derivation-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400), end: clock.now())
    }

    /// Wires the four writing engines exactly as the composition root does, then returns the
    /// coordinator over them. Kept in one place so every test scores through the identical wiring.
    private func makeCoordinator() -> DerivationCoordinator {
        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        let baselines = BaselineEngine(derivation: derivation, measurements: measurements,
                                       registry: .shared, clock: clock, deviceId: deviceId)
        let sleep = SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                            clock: clock, deviceId: deviceId)
        let readiness = ReadinessEngine(derivation: derivation, measurements: measurements,
                                        clock: clock, deviceId: deviceId)
        let effort = EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                  clock: clock, deviceId: deviceId)
        return DerivationCoordinator(baselines: baselines, sleep: sleep, readiness: readiness, effort: effort)
    }

    private func ingest90Days() throws {
        _ = try IngestionPipeline(measurements: MeasurementRepository(db.main),
                                  catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: deviceId)
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz), range: range)
    }

    /// Latest readiness v2 identity, resolved from the same contract the engine stamps rows with, so
    /// the test recognizes a v2 row without hardcoding "2.0.0".
    private var readinessV2: AlgorithmVersion {
        ReadinessEngine(derivation: DerivationRepository(db.main), measurements: MeasurementRepository(db.main),
                        clock: clock, deviceId: deviceId).algorithm
    }

    // MARK: - Scores compute end to end, in order

    func testScoresComputeFromIngestedDataInCrossMetricOrder() throws {
        try ingest90Days()
        try makeCoordinator().recompute(asOf: clock.now(), tz: tz)

        let derivation = DerivationRepository(db.main)

        // Baselines ran first — a personal RHR band exists and, on 90 days, is past provisional.
        let rhrBaseline = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate),
                                        "baselines must run before any score reads them")
        XCTAssertFalse(rhrBaseline.provisional, "90 days is well past the provisional gate")

        // Sleep ran — sleep.performance exists for at least one recent night.
        let sleepPerf = try derivation.latestDerivedSeries(metricId: MetricID.sleepPerformance)
        XCTAssertFalse(sleepPerf.isEmpty, "SleepIntelligenceEngine must produce sleep.performance")

        // Readiness ran and produced the v2 score (not the interim baseline composite).
        let readinessRows = try derivation.latestDerivedSeries(metricId: MetricID.readinessScore)
        XCTAssertFalse(readinessRows.isEmpty, "ReadinessEngine must produce readiness.score")
        let v2 = readinessV2
        XCTAssertTrue(readinessRows.allSatisfy { $0.algorithmId == v2.algorithmId && $0.algorithmVersion == v2.semver },
                      "the pipeline must surface the v2 readiness score, never the interim @1.0.0 composite")

        // Ordering, proven by lineage rather than timestamps (a fixed clock stamps them equal): at
        // least one readiness row's manifest references the sleep.performance value that fed it —
        // which can only exist if sleep ran BEFORE readiness and readiness consumed its output.
        var readinessConsumedSleep = false
        for row in readinessRows {
            guard let manifestId = row.inputManifestId,
                  let manifest = try derivation.manifest(id: manifestId) else { continue }
            if manifest.inputs.contains(where: { $0.metricId == MetricID.sleepPerformance }) {
                readinessConsumedSleep = true
                break
            }
        }
        XCTAssertTrue(readinessConsumedSleep,
                      "readiness → sleep lineage must be present (proves sleep ran before readiness)")

        // Effort ran — effort.day exists for a recent day (zone-based or the labelled reduced-input
        // variant; either is a real row, the point is the engine ran and appended).
        let effortRows = try derivation.latestDerivedSeries(metricId: MetricID.effortDay)
        XCTAssertFalse(effortRows.isEmpty, "EffortEngine must produce effort.day")
    }

    // MARK: - Idempotent at the read model

    func testRecomputeIsIdempotentAtTheReadModel() throws {
        try ingest90Days()
        let coordinator = makeCoordinator()
        try coordinator.recompute(asOf: clock.now(), tz: tz)

        let derivation = DerivationRepository(db.main)
        let before = try scoreRowCounts(derivation)
        let latestBefore = try latestScoreValues(derivation)

        // Re-run over identical data at the same instant — every engine's skip-if-identical guard
        // must fire, appending nothing.
        try coordinator.recompute(asOf: clock.now(), tz: tz)

        let after = try scoreRowCounts(derivation)
        XCTAssertEqual(after, before, "a repeat recompute over unchanged data must append no new rows")
        XCTAssertEqual(try latestScoreValues(derivation), latestBefore,
                       "the read model (latest per period) must be unchanged by a no-op recompute")
    }

    // MARK: - Late overnight data appends a fresh readiness row (I2)

    func testLateOvernightDataAppendsANewReadinessRow() throws {
        try ingest90Days()
        let coordinator = makeCoordinator()
        try coordinator.recompute(asOf: clock.now(), tz: tz)

        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        let dayKey = DayAttribution.localDayKey(clock.now(), tz: tz)
        let periodKey = "day:" + dayKey
        let readinessBefore = try derivation.allDerived(metricId: MetricID.readinessScore)
            .filter { $0.periodKey == periodKey }.count

        // A better overnight HRV lands late for today (a higher-priority correction), moving the
        // score. Written straight to the store, then the pipeline is re-run — mirroring a late sync.
        let existing = try XCTUnwrap(try measurements.latestInterval(metricId: MetricID.hrv))
        let start = DayAttribution.startOfDay(clock.now(), tz: tz).addingTimeInterval(3 * 3600)
        let corrected = IntervalRecord(
            id: ULID.newID(), metricId: MetricID.hrv, value: existing.value + 25,
            unit: existing.unit, startAt: start, endAt: start, tzId: tz,
            aggregation: existing.aggregation, coverage: existing.coverage,
            provenance: existing.provenance, updatedAt: clock.now(), originDeviceId: deviceId)
        _ = try measurements.upsertIntervalRecord(corrected)

        // Advance the clock so the appended row is unambiguously the newest belief.
        clock.advance(by: 3600)
        try coordinator.recompute(asOf: clock.now(), tz: tz)

        let readinessAfter = try derivation.allDerived(metricId: MetricID.readinessScore)
            .filter { $0.periodKey == periodKey }
        XCTAssertEqual(readinessAfter.count, readinessBefore + 1,
                       "late overnight data must APPEND a new readiness row, not mutate the old one (I2)")
        let latest = try XCTUnwrap(try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey))
        XCTAssertEqual(latest.computedAt, clock.now(), "the latest read is the newest belief")
        // The superseded row is still present and untouched (I2: append, never overwrite).
        XCTAssertGreaterThanOrEqual(readinessAfter.count, 2)
    }

    // MARK: - Backfill scores a historical window

    func testBackfillScoresAHistoricalWindow() throws {
        try ingest90Days()
        let coordinator = makeCoordinator()
        let to = clock.now()
        let from = DayAttribution.addingDays(-10, to: to, tz: tz)
        let touched = try coordinator.backfill(from: from, to: to, tz: tz)
        XCTAssertGreaterThan(touched, 0, "a 10-day backfill over ingested history must score some days")

        // Readiness rows now span multiple distinct days, not just today.
        let days = Set(try DerivationRepository(db.main).latestDerivedSeries(metricId: MetricID.readinessScore)
            .map(\.periodKey))
        XCTAssertGreaterThan(days.count, 1, "backfill must score more than a single day")
    }

    // MARK: - Helpers

    private func scoreRowCounts(_ derivation: DerivationRepository) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for metricId in [MetricID.sleepPerformance, MetricID.sleepNeed, MetricID.readinessScore, MetricID.effortDay] {
            counts[metricId] = try derivation.allDerived(metricId: metricId).count
        }
        return counts
    }

    private func latestScoreValues(_ derivation: DerivationRepository) throws -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for metricId in [MetricID.sleepPerformance, MetricID.readinessScore, MetricID.effortDay] {
            var perPeriod: [String: Double] = [:]
            for row in try derivation.latestDerivedSeries(metricId: metricId) {
                perPeriod[row.periodKey] = row.value
            }
            out[metricId] = perPeriod
        }
        return out
    }
}
