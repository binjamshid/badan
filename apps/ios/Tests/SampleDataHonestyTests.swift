import XCTest
@testable import BADAN

/// The sample/demo data must be recognisable as fabricated everywhere it travels — not only on
/// the screen that shows the banner.
///
/// The gap these cover: sample rows were exported into a checksummed CSV/JSON bundle carrying a
/// real `com.apple.health` attribution, with no marker in the database, the files, or the
/// manifest. A recipient of that export — a clinician, a family member, the user themselves a
/// year later — had no way to tell 90 days of invented readings from measured ones. The banner
/// made the app honest; the artifact it produced was not.
final class SampleDataHonestyTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-sample-honesty-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-30 * 86400), end: clock.now())
    }

    private func makeIngestion() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main), catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main), registry: .shared,
                          clock: clock, deviceId: deviceId)
    }

    private func makeRunner() -> ExportRunner {
        ExportRunner(measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
                     logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
                     exportJobs: ExportJobRepository(db.main), registry: .shared,
                     clock: clock, appVersion: "test", deviceId: deviceId)
    }

    // MARK: - The generator marks its own output

    func testEveryFabricatedRowCarriesTheSampleDataFlag() {
        let store = FakeHealthStore(clock: clock, historyDays: 30)

        let samples = store.readSamples(range)
        let intervals = store.readIntervals(range)
        let sessions = store.readSessions(range)

        XCTAssertFalse(samples.isEmpty, "sanity: the generator produced rows to check")
        XCTAssertTrue(samples.allSatisfy { $0.qualityFlags.contains(.sampleData) },
                      "every fabricated sample must carry .sampleData")
        XCTAssertTrue(intervals.allSatisfy { $0.qualityFlags.contains(.sampleData) },
                      "every fabricated interval must carry .sampleData")
        XCTAssertTrue(sessions.allSatisfy { $0.qualityFlags.contains(.sampleData) },
                      "every fabricated session must carry .sampleData")
    }

    /// Fabricated data must never claim Apple's identity: `source_app` in an exported CSV comes
    /// straight from here.
    func testSimulatedSourcesDoNotClaimAppleHealthProvenance() {
        let descriptors = FakeHealthStore(clock: clock, historyDays: 7).sourceDescriptors()

        XCTAssertFalse(descriptors.isEmpty)
        for descriptor in descriptors {
            XCTAssertNotEqual(descriptor.bundleId, "com.apple.health",
                              "sample data must not be attributed to Apple Health")
            XCTAssertTrue(descriptor.displayName.lowercased().contains("sample"),
                          "a source the user sees must say it is sample data — got "
                              + "\"\(descriptor.displayName)\"")
        }
    }

    /// The watch-beats-phone priority gap is why two overlapping sleep sources exist at all; the
    /// honesty rename must not flatten the dedup path it feeds.
    func testSimulatedSourcesKeepTheirDedupPriorityOrdering() {
        let descriptors = FakeHealthStore(clock: clock, historyDays: 7).sourceDescriptors()
        let priorities = descriptors.map(\.priority)

        XCTAssertEqual(Set(priorities).count, descriptors.count,
                       "the wearable/phone priority gap must survive the rename")
    }

    // MARK: - The flag survives ingestion into the database

    func testSampleFlagSurvivesIngestionAndIsReadableFromTheDatabase() throws {
        try makeIngestion().ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        let stored = try MeasurementRepository(db.main).rawSamples(metricId: MetricID.heartRate)
        XCTAssertFalse(stored.isEmpty, "sanity: heart-rate samples were ingested")
        XCTAssertTrue(stored.allSatisfy { $0.provenance.qualityFlags.contains(.sampleData) },
                      "the flag must round-trip through quality_flags, not stop at the DTO")
    }

    // MARK: - The export discloses it

    func testCSVExportOfSampleDataDisclosesItInTheManifest() throws {
        try makeIngestion().ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        let result = try makeRunner().run(scope: .everything, format: .csv)
        let manifest = try XCTUnwrap(result.job.manifest)

        XCTAssertGreaterThan(manifest.sampleDataRowCount, 0,
                             "a checksummed export of fabricated readings must say so")
        XCTAssertTrue(manifest.dataQualityNote.contains("SAMPLE DATA"),
                      "the disclosure must be human-readable too, not only a row count")
    }

    func testExportedCSVRowsThemselvesCarryTheSampleFlag() throws {
        try makeIngestion().ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        let result = try makeRunner().run(scope: .everything, format: .csv)

        var sawFlaggedRow = false
        for url in result.fileURLs where url.lastPathComponent == "raw.csv" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(QualityFlag.sampleData.rawValue) { sawFlaggedRow = true }
            XCTAssertFalse(text.contains("com.apple.health"),
                           "no exported sample row may be attributed to Apple Health")
        }
        XCTAssertTrue(sawFlaggedRow,
                      "the sample marker must reach the file — a manifest note alone is lost the "
                          + "moment a single CSV is opened on its own")
    }

    func testJSONBundleExportOfSampleDataDisclosesItInTheEmbeddedManifest() throws {
        try makeIngestion().ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        let result = try makeRunner().run(scope: .everything, format: .json)
        let bundleURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "bundle.json" })
        let text = try String(contentsOf: bundleURL, encoding: .utf8)

        XCTAssertGreaterThan(try XCTUnwrap(result.job.manifest).sampleDataRowCount, 0)
        XCTAssertTrue(text.contains("SAMPLE DATA"),
                      "the self-contained bundle must carry the disclosure inside the file")
    }

    /// The counterpart that keeps the disclosure meaningful: a real export must NOT be labelled
    /// sample data, or the warning becomes noise users learn to ignore.
    func testRealDataExportIsNotLabelledAsSampleData() throws {
        let now = clock.now()
        _ = try MeasurementRepository(db.main).upsertRawSample(
            RawSample(id: ULID.newID(), metricId: MetricID.heartRate, value: 62, unit: "bpm",
                      originalValue: 62, originalUnit: "bpm", startAt: now, tzId: "UTC",
                      provenance: Provenance(sourceId: "watch-1", ingestionPath: .platformStore,
                                             externalId: "real-1", measuredAt: now,
                                             measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
                      updatedAt: now, originDeviceId: deviceId))

        let result = try makeRunner().run(scope: .everything, format: .csv)
        let manifest = try XCTUnwrap(result.job.manifest)

        XCTAssertEqual(manifest.sampleDataRowCount, 0,
                       "a real measurement must never be flagged as fabricated")
        XCTAssertFalse(manifest.dataQualityNote.contains("SAMPLE DATA"),
                       "the sample warning must stay absent from real exports so it keeps meaning "
                           + "something when it does appear")
    }

    // MARK: - The honesty layer survives encryption (review ledger #19, deferred fix 3 / FEAT-185)

    /// Encrypting `includeSensitive` exports (ADR-0008) must not become a second way to lose the
    /// sample-data disclosure — the manifest's "SAMPLE DATA" note and each row's own
    /// `.sampleData` flag must both still be readable once the container is decrypted, exactly
    /// as they were in a plain (non-sensitive) export before this fix.
    func testEncryptedExportOfSampleDataStillDisclosesItAfterDecrypt() throws {
        try makeIngestion().ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        var scope = ExportScope.everything
        scope.includeSensitive = true // the only way to exercise the encrypted path
        let passphrase = "correct horse battery staple"
        let result = try makeRunner().run(scope: scope, format: .csv, passphrase: passphrase)

        XCTAssertEqual(result.job.manifest?.encrypted, true, "sanity: this export took the encrypted path")
        XCTAssertGreaterThan(try XCTUnwrap(result.job.manifest).sampleDataRowCount, 0,
                             "the persisted job's own manifest must still count sample rows post-encryption")

        let containerURL = try XCTUnwrap(result.fileURLs.first)
        let decrypted = try ExportEncryptor.decrypt(Data(contentsOf: containerURL), passphrase: passphrase)

        let manifestFile = try XCTUnwrap(decrypted.first { $0.name == "manifest.json" })
        let manifestText = try XCTUnwrap(String(data: manifestFile.data, encoding: .utf8))
        XCTAssertTrue(manifestText.contains("SAMPLE DATA"),
                      "the decrypted manifest.json must still carry the human-readable disclosure")

        let rawFile = try XCTUnwrap(decrypted.first { $0.name == "raw.csv" })
        let rawText = try XCTUnwrap(String(data: rawFile.data, encoding: .utf8))
        XCTAssertTrue(rawText.contains(QualityFlag.sampleData.rawValue),
                      "decrypted rows must still carry the per-row sampleData quality flag")
        XCTAssertFalse(rawText.contains("com.apple.health"),
                       "no decrypted sample row may be attributed to Apple Health")
    }
}
