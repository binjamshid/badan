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

    private func count(_ table: String) throws -> Int {
        Int(try db.main.query("SELECT COUNT(*) AS c FROM \(table);").first?.int("c") ?? 0)
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

    // MARK: - P2: bounded write batches

    /// `applyIngestBatched` slices every write list with this, so an off-by-one here would drop
    /// or duplicate rows on a real backfill.
    func testChunkingCoversEveryElementExactlyOnceAtBoundaries() {
        for count in [0, 1, 999, 1000, 1001, 2000, 2001] {
            let input = Array(0..<count)
            let chunks = input.badanChunked(1000)
            XCTAssertEqual(chunks.flatMap { $0 }, input,
                           "chunking \(count) elements must preserve every element and their order")
            for chunk in chunks {
                XCTAssertLessThanOrEqual(chunk.count, 1000, "no batch may exceed the bound")
            }
        }
    }

    func testChunkingAnEmptyListProducesNoBatches() {
        XCTAssertTrue([Int]().badanChunked(1000).isEmpty,
                      "an empty ingest must open no write transactions at all")
    }

    /// A zero/negative bound would otherwise loop forever or crash `stride`; ingest must degrade
    /// to one transaction rather than hang.
    func testChunkingWithANonPositiveSizeFallsBackToASingleBatch() {
        XCTAssertEqual([1, 2, 3].badanChunked(0).count, 1)
        XCTAssertEqual([1, 2, 3].badanChunked(0).flatMap { $0 }, [1, 2, 3])
    }

    /// The batched write phase must produce exactly what the single-transaction one did: same
    /// rows, same dedup outcome, and still idempotent on replay (which is what makes an
    /// interrupted backfill safe — see `IngestionPipeline.ingest`).
    func testBatchedIngestIsStillIdempotentAcrossManyBatches() throws {
        let pipeline = makeIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)

        let first = try pipeline.ingest(from: store, range: range)
        XCTAssertGreaterThan(first.samples, 0, "sanity: the fixture wrote rows")
        let sampleCount = try count("raw_samples")

        let second = try pipeline.ingest(from: store, range: range)

        XCTAssertEqual(second.samples, 0, "a replayed batch must upsert, not insert")
        XCTAssertEqual(try count("raw_samples"), sampleCount,
                       "P2: re-running an interrupted backfill must not duplicate rows — this is "
                           + "the property that lets anchors commit only after every batch")
    }

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

    // MARK: - NEW-01 first fact

    /// `FirstFact.select` prefers the freshest generated insight over a composed baseline
    /// statement — seeded directly (no need for a full 90-day ingest) so this stays fast.
    func testFirstFactPrefersFreshestInsight() throws {
        let insights = InsightRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let format = ValueFormatter(profile: CustomizationProfile(), registry: .shared)

        // A confident (non-provisional) baseline exists too, but the insight should win.
        try derivation.upsertBaseline(makeBaseline(metricId: MetricID.timeAsleep, center: 7 * 3600))
        let insight = Insight(id: ULID.newID(), insightType: "statusExplanation", templateId: "vitals_within_band",
                              templateVersion: "1", metricIds: [MetricID.timeAsleep], periodKey: "day:2026-07-01",
                              depthVariant: .casual,
                              renderedText: LocalizedString(en: "Your sleep is 7h 12m today.", ar: "نومك اليوم 7س 12د."),
                              evidenceRefs: [], generatedAt: clock.now())
        try insights.insert(insight)

        let fact = try FirstFact.select(insights: insights, derivation: derivation, format: format)
        XCTAssertEqual(fact, insight.renderedText)
    }

    /// With no generated insight, `FirstFact.select` falls back to a composed baseline
    /// statement for the first eligible metric with a confident (non-provisional) baseline.
    func testFirstFactFallsBackToBaselineStatement() throws {
        let insights = InsightRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let format = ValueFormatter(profile: CustomizationProfile(), registry: .shared)

        try derivation.upsertBaseline(makeBaseline(metricId: MetricID.timeAsleep, center: 7 * 3600))

        let fact = try XCTUnwrap(try FirstFact.select(insights: insights, derivation: derivation, format: format))
        XCTAssertEqual(fact, Loc.firstFactSleepBaseline.filling(["value": format.full(metricId: MetricID.timeAsleep, canonicalValue: 7 * 3600)]))
        XCTAssertFalse(fact.ar.isEmpty, "the baseline-statement fallback must carry Arabic too")
    }

    /// No insight, no confident baseline anywhere — `FirstFact.select` returns `nil` rather
    /// than fabricating a fact, so callers show the honest "still settling in" notice.
    func testFirstFactReturnsNilWhenNothingIsAvailable() throws {
        let insights = InsightRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let format = ValueFormatter(profile: CustomizationProfile(), registry: .shared)

        let fact = try FirstFact.select(insights: insights, derivation: derivation, format: format)
        XCTAssertNil(fact)
    }

    /// A still-provisional baseline (thin data) must not be presented as a settled fact.
    func testFirstFactSkipsProvisionalBaseline() throws {
        let insights = InsightRepository(db.main)
        let derivation = DerivationRepository(db.main)
        let format = ValueFormatter(profile: CustomizationProfile(), registry: .shared)

        var provisional = makeBaseline(metricId: MetricID.timeAsleep, center: 7 * 3600)
        provisional.provisional = true
        provisional.nPoints = 2
        try derivation.upsertBaseline(provisional)

        let fact = try FirstFact.select(insights: insights, derivation: derivation, format: format)
        XCTAssertNil(fact)
    }

    private func makeBaseline(metricId: String, center: Double) -> Baseline {
        Baseline(id: ULID.newID(), metricId: metricId, windowDays: 14, center: center,
                spread: center * 0.05, bandLow: center * 0.9, bandHigh: center * 1.1,
                nPoints: 14, provisional: false, algorithmVersion: BaselineEngine.baselineAlgorithm.id,
                validFrom: clock.now(), computedAt: clock.now(), unit: "s")
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

    // MARK: - Export scope filtering

    func testExportExcludesSensitiveWhenScopeOptsOut() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let now = clock.now()
        try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: 4,
                                               occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId))
        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: logging,
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)

        let withoutSensitive = try runner.run(scope: ExportScope(includeSensitive: false), format: .json)
        let excludedURL = try XCTUnwrap(withoutSensitive.fileURLs.first { $0.pathExtension == "json" })
        let excludedText = try String(contentsOf: excludedURL, encoding: .utf8)
        XCTAssertFalse(excludedText.contains("headache"), "symptoms must not appear when includeSensitive is false")

        // An `includeSensitive` export is now encrypted end-to-end (review ledger #19, deferred
        // fix 3 / FEAT-185; ADR-0008) — `withSensitive.fileURLs` holds one `.badanenc` container,
        // not a plain `bundle.json`, so this decrypts it before checking the content is there.
        let passphrase = "correct horse battery staple"
        let withSensitive = try runner.run(scope: ExportScope(includeSensitive: true), format: .json,
                                           passphrase: passphrase)
        let containerURL = try XCTUnwrap(withSensitive.fileURLs.first)
        let decrypted = try ExportEncryptor.decrypt(Data(contentsOf: containerURL), passphrase: passphrase)
        let bundleFile = try XCTUnwrap(decrypted.first { $0.name == "bundle.json" })
        let includedText = try XCTUnwrap(String(data: bundleFile.data, encoding: .utf8))
        XCTAssertTrue(includedText.contains("headache"), "symptoms must appear when includeSensitive is true")
    }

    func testExportFamilyFilterNarrowsRows() throws {
        let pipeline = makeIngestion()
        try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)
        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main),
                                  logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)

        let unfiltered = try runner.run(scope: .everything, format: .csv)
        let unfilteredRawURL = try XCTUnwrap(unfiltered.fileURLs.first { $0.lastPathComponent == "raw.csv" })
        let unfilteredText = try String(contentsOf: unfilteredRawURL, encoding: .utf8)
        XCTAssertTrue(unfilteredText.contains("heart."), "sanity: heart-family rows exist without a filter")

        let sleepOnly = try runner.run(scope: ExportScope(families: ["sleep"]), format: .csv)
        let sleepRawURL = try XCTUnwrap(sleepOnly.fileURLs.first { $0.lastPathComponent == "raw.csv" })
        let sleepText = try String(contentsOf: sleepRawURL, encoding: .utf8)
        XCTAssertFalse(sleepText.contains("heart."), "a family filter must exclude other families' rows")
        XCTAssertTrue(sleepText.contains("sleep."), "the selected family's rows must still be present")
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
