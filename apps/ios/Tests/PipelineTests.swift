import XCTest
@testable import BADAN

/// End-to-end validation of the data layer: ingestion → dedup → baselines → insights →
/// export, driven by the deterministic FakeHealthStore against a throwaway on-disk database.
final class PipelineTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000)) // fixed "now"
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

    private func makeIngestion() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
    }

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400), end: clock.now())
    }

    // MARK: - Ingestion + dedup

    func testIngestionCreatesSourcesAndSessions() throws {
        let pipeline = makeIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        let summary = try pipeline.ingest(from: store, range: range)

        XCTAssertGreaterThan(summary.sessions, 0, "should ingest sleep sessions")
        XCTAssertGreaterThan(summary.intervals, 0, "should ingest daily interval metrics")

        let sources = try CatalogRepository(db.main).sources()
        XCTAssertEqual(sources.count, 2, "watch + iPhone sources")
    }

    func testSleepDedupSuppressesOneSourcePerNight() throws {
        let pipeline = makeIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        let summary = try pipeline.ingest(from: store, range: range)
        XCTAssertGreaterThan(summary.suppressed, 0, "overlapping sleep should be deduped")

        let measurements = MeasurementRepository(db.main)
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: TimeZone.current.identifier)
        // Look back a few nights for a definitely-complete night.
        var checkedNight: String?
        for offset in 1...5 {
            let d = clock.now().addingTimeInterval(Double(-offset) * 86_400)
            let key = DayAttribution.localNight(sessionEnd: d, tz: TimeZone.current.identifier)
            let all = try measurements.allSleepSessions(localNight: key, includeSuppressed: true)
            if all.count >= 2 { checkedNight = key; break }
        }
        let nightKey = try XCTUnwrap(checkedNight ?? night)
        let visible = try measurements.allSleepSessions(localNight: nightKey, includeSuppressed: false)
        let all = try measurements.allSleepSessions(localNight: nightKey, includeSuppressed: true)
        XCTAssertEqual(visible.count, 1, "exactly one sleep session survives dedup for a night")
        XCTAssertGreaterThan(all.count, visible.count, "the loser is suppressed, not deleted")

        // A reversible decision was journaled and points at a real winner.
        let decisions = try ReconciliationRepository(db.main).recent(limit: 100)
        XCTAssertFalse(decisions.isEmpty)
        XCTAssertTrue(decisions.allSatisfy { $0.reversible })
    }

    func testReingestIsIdempotent() throws {
        let pipeline = makeIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        _ = try pipeline.ingest(from: store, range: range)
        let second = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(second.samples, 0)
        XCTAssertEqual(second.intervals, 0)
        XCTAssertEqual(second.sessions, 0)
        XCTAssertEqual(second.suppressed, 0, "re-running ingestion must be a no-op")
    }

    // MARK: - Derivation

    func testBaselinesComputed() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 90), range: range)
        let engine = BaselineEngine(derivation: DerivationRepository(db.main),
                                    measurements: MeasurementRepository(db.main),
                                    registry: MetricRegistry.shared, clock: clock, deviceId: deviceId)
        try engine.recomputeAll(asOf: clock.now())

        let rhr = try DerivationRepository(db.main).latestBaseline(metricId: MetricID.restingHeartRate)
        let baseline = try XCTUnwrap(rhr, "RHR baseline should exist after 90 days of data")
        XCTAssertGreaterThan(baseline.center, 40)
        XCTAssertLessThan(baseline.center, 90)
        XCTAssertLessThanOrEqual(baseline.bandLow, baseline.center)
        XCTAssertGreaterThanOrEqual(baseline.bandHigh, baseline.center)
        XCTAssertFalse(baseline.provisional, "90 days is well past the provisional threshold")
    }

    func testInsightsGeneratedBilingual() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 90), range: range)
        let deriv = DerivationRepository(db.main)
        let meas = MeasurementRepository(db.main)
        try BaselineEngine(derivation: deriv, measurements: meas, registry: .shared,
                           clock: clock, deviceId: deviceId).recomputeAll(asOf: clock.now())
        let insights = InsightRepository(db.main)
        try InsightEngine(insights: insights, derivation: deriv, measurements: meas,
                          templates: .shared, registry: .shared, clock: clock, deviceId: deviceId)
            .generate(forDay: clock.now().addingTimeInterval(-86_400), tz: TimeZone.current.identifier)

        let recent = try insights.recent(limit: 20)
        XCTAssertFalse(recent.isEmpty, "at least one insight should be generated")
        for insight in recent {
            XCTAssertFalse(insight.renderedText.en.isEmpty)
            XCTAssertFalse(insight.renderedText.ar.isEmpty, "insight must carry Arabic too")
        }
    }

    // MARK: - Export

    func testCSVExportRoundTrips() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)
        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)
        let result = try runner.run(scope: .everything, format: .csv)
        XCTAssertGreaterThan(result.rowCount, 0)
        XCTAssertFalse(result.fileURLs.isEmpty)
        var foundHeader = false
        for url in result.fileURLs where url.pathExtension == "csv" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("record_id") && text.contains("canonical_value") && text.contains("suppressed_by") {
                foundHeader = true
            }
        }
        XCTAssertTrue(foundHeader, "CSV must carry the provenance-complete header")
        let job = try XCTUnwrap(try ExportJobRepository(db.main).recent(limit: 1).first)
        XCTAssertEqual(job.status, .completed)
        XCTAssertNotNil(job.manifest?.checksums)
    }

    // MARK: - Sensitive namespace purge (regression: repo references must survive)

    func testSensitivePurgeKeepsRepositoryUsable() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let now = clock.now()
        try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: 4,
                                               occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId))
        XCTAssertEqual(try logging.allSymptoms().count, 1)

        // Purge (as Settings' sensitive toggle does) — the file is deleted and recreated.
        try db.purgeSensitiveNamespace()
        XCTAssertEqual(try logging.allSymptoms().count, 0, "purge empties the sensitive namespace")

        // The SAME repository must still be able to write afterwards (connection identity preserved).
        try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: "fatigue", severity: 3,
                                               occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId))
        XCTAssertEqual(try logging.allSymptoms().count, 1, "logging works after purge — no stale connection")
    }

    func testJSONExportHasManifest() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)
        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)
        let result = try runner.run(scope: .everything, format: .json)
        let jsonURL = try XCTUnwrap(result.fileURLs.first { $0.pathExtension == "json" })
        let data = try Data(contentsOf: jsonURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["manifest"], "JSON bundle must include a manifest")
    }
}
