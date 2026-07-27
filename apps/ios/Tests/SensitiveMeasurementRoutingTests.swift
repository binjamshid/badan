import XCTest
@testable import BADAN

/// A21/D-26 scope-gap closure: `sensitiveClass: sensitivePlus` measured metrics live in
/// `badan_sensitive.db`, not `badan.db`.
///
/// Every assertion about PLACEMENT here goes around `MeasurementRepository` and reads raw SQL off a
/// named connection. That is the whole point of the file: `MeasurementRepository` is the type that
/// decides placement, so asking it where a row is would confirm only that it is self-consistent —
/// it would pass identically if routing were removed and everything went back to `badan.db`. The
/// two things D-26 left broken (unencrypted at rest, and untouched by "erase sensitive records")
/// are both properties of the FILE, so the file is what gets checked.
final class SensitiveMeasurementRoutingTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-routing-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func routed() -> MeasurementRepository {
        MeasurementRepository(db.main, sensitive: db.sensitive)
    }

    private func count(_ connection: SQLiteConnection, _ table: String, metricId: String) throws -> Int {
        try connection.query("SELECT COUNT(*) AS n FROM \(table) WHERE metric_id = ?;", [.text(metricId)])
            .first?.intValue("n") ?? 0
    }

    private func sample(metricId: String, value: Double, externalId: String) -> RawSample {
        RawSample(id: ULID.newID(), metricId: metricId, value: value, unit: "mmol/L",
                  originalValue: value, originalUnit: "mmol/L",
                  startAt: clock.now(), endAt: nil, tzId: "Asia/Muscat",
                  provenance: Provenance(sourceId: "src", ingestionPath: .platformStore,
                                         externalId: externalId, measuredAt: clock.now(),
                                         measuredTimezone: "Asia/Muscat",
                                         recordedAt: clock.now(), ingestedAt: clock.now()),
                  updatedAt: clock.now(), originDeviceId: "dev", deletedAt: nil)
    }

    // MARK: - Placement

    /// The core claim. Glucose in the sensitive file, zero glucose rows in main.
    func testGlucoseRawSampleLandsInTheSensitiveFileAndNotMain() throws {
        try routed().upsertRawSample(sample(metricId: MetricID.glucose, value: 5.4, externalId: "g1"))

        XCTAssertEqual(try count(db.sensitive, "raw_samples", metricId: MetricID.glucose), 1,
                       "a sensitivePlus metric belongs in badan_sensitive.db")
        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.glucose), 0,
                       "no copy may remain in the unencrypted main database")
    }

    /// The other half: routing must not drag ordinary metrics along with it. A regression that sent
    /// everything to the sensitive file would pass the test above and break the entire app.
    func testNonSensitiveMetricStillLandsInMain() throws {
        try routed().upsertRawSample(sample(metricId: MetricID.restingHeartRate, value: 58, externalId: "r1"))

        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.restingHeartRate), 1)
        XCTAssertEqual(try count(db.sensitive, "raw_samples", metricId: MetricID.restingHeartRate), 0)
    }

    /// A read through the routed repository has to follow the write. Without this, glucose would be
    /// written correctly and then be invisible everywhere in the app.
    func testRoutedReadFindsASensitiveRow() throws {
        try routed().upsertRawSample(sample(metricId: MetricID.glucose, value: 6.1, externalId: "g2"))

        let rows = try routed().rawSamples(metricId: MetricID.glucose)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value ?? 0, 6.1, accuracy: 1e-9)
    }

    /// Single-connection mode is what ~60 existing test files and `Database.inMemoryFallback()`
    /// construct. It must behave exactly as it did before routing existed.
    func testSingleConnectionModeKeepsEverythingInOneFile() throws {
        try MeasurementRepository(db.main).upsertRawSample(
            sample(metricId: MetricID.glucose, value: 5.0, externalId: "g3"))

        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.glucose), 1,
                       "with no sensitive connection supplied there is nowhere else for it to go")
    }

    // MARK: - The user-visible defect this closes

    /// D-26's concrete consequence, as a test: a user taps "erase sensitive records", is told their
    /// sensitive health data is gone, and — before this change — kept their entire glucose history.
    func testPurgingSensitiveRecordsActuallyRemovesGlucose() throws {
        try routed().upsertRawSample(sample(metricId: MetricID.glucose, value: 5.4, externalId: "g4"))
        try routed().upsertRawSample(sample(metricId: MetricID.restingHeartRate, value: 58, externalId: "r2"))
        XCTAssertEqual(try routed().rawSamples(metricId: MetricID.glucose).count, 1, "precondition")

        try db.purgeSensitiveNamespace()

        XCTAssertEqual(try routed().rawSamples(metricId: MetricID.glucose).count, 0,
                       "the purge's central promise — gone from this device — must hold for glucose")
        XCTAssertEqual(try routed().rawSamples(metricId: MetricID.restingHeartRate).count, 1,
                       "and must not touch non-sensitive history")
    }

    // MARK: - Relocation of an upgrading install

    /// Simulates the install D-26 actually shipped: glucose rows already sitting in `badan.db`.
    /// Writing them through single-connection mode reproduces the old placement exactly, then a
    /// fresh `Database` open (what a launch after updating the app does) must move them.
    func testRelocatorMovesPreExistingGlucoseOutOfMain() throws {
        let legacy = MeasurementRepository(db.main)
        try legacy.upsertRawSample(sample(metricId: MetricID.glucose, value: 5.4, externalId: "old1"))
        try legacy.upsertRawSample(sample(metricId: MetricID.glucose, value: 7.2, externalId: "old2"))
        try legacy.upsertRawSample(sample(metricId: MetricID.restingHeartRate, value: 58, externalId: "old3"))
        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.glucose), 2, "precondition")

        let outcome = try SensitiveMeasurementRelocator.run(main: db.main, sensitive: db.sensitive)

        XCTAssertEqual(outcome.rawSamples, 2)
        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.glucose), 0,
                       "the unencrypted copies must be gone, not merely soft-deleted")
        XCTAssertEqual(try count(db.sensitive, "raw_samples", metricId: MetricID.glucose), 2)
        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.restingHeartRate), 1,
                       "non-sensitive rows are not relocated")
    }

    /// Values must survive the move intact — a relocation that rounded, retyped, or dropped a NULL
    /// would corrupt the history it is meant to protect.
    func testRelocationPreservesValuesAndProvenance() throws {
        let original = sample(metricId: MetricID.glucose, value: 5.4321, externalId: "keep")
        try MeasurementRepository(db.main).upsertRawSample(original)

        try SensitiveMeasurementRelocator.run(main: db.main, sensitive: db.sensitive)

        let moved = try XCTUnwrap(try routed().rawSamples(metricId: MetricID.glucose).first)
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.value, 5.4321, accuracy: 1e-12)
        XCTAssertEqual(moved.unit, original.unit)
        XCTAssertEqual(moved.provenance.externalId, "keep")
        XCTAssertEqual(moved.provenance.ingestionPath, .platformStore)
        XCTAssertNil(moved.endAt, "a NULL column must come across as NULL, not as an epoch-zero date")
    }

    /// Idempotent: the relocator runs on every single launch, so a second run must find nothing and
    /// must not disturb what the first one moved.
    func testRelocatorIsIdempotent() throws {
        try MeasurementRepository(db.main).upsertRawSample(
            sample(metricId: MetricID.glucose, value: 5.4, externalId: "once"))
        XCTAssertEqual(try SensitiveMeasurementRelocator.run(main: db.main, sensitive: db.sensitive).rawSamples, 1)

        let second = try SensitiveMeasurementRelocator.run(main: db.main, sensitive: db.sensitive)

        XCTAssertTrue(second.isEmpty, "nothing left to move")
        XCTAssertEqual(try count(db.sensitive, "raw_samples", metricId: MetricID.glucose), 1,
                       "and the row that was already moved is untouched")
    }

    /// A soft-deleted sensitive row must move too: its tombstone still has to reach a delta export,
    /// and its value/provenance are still sensitive while it sits there.
    func testRelocatorMovesSoftDeletedRowsAsWell() throws {
        let legacy = MeasurementRepository(db.main)
        try legacy.upsertRawSample(sample(metricId: MetricID.glucose, value: 5.4, externalId: "gone"))
        _ = try legacy.softDelete(table: "raw_samples", metricId: MetricID.glucose,
                                  externalId: "gone", sourceId: nil, updatedAt: clock.now())

        try SensitiveMeasurementRelocator.run(main: db.main, sensitive: db.sensitive)

        XCTAssertEqual(try count(db.main, "raw_samples", metricId: MetricID.glucose), 0)
        XCTAssertEqual(try count(db.sensitive, "raw_samples", metricId: MetricID.glucose), 1)
    }

    // MARK: - Statements that span both files

    /// A delta export's `deletions[]` must include tombstones from BOTH files. Missing the sensitive
    /// half would leave a downstream store serving a glucose reading the user deleted.
    func testTombstonesSpanBothDatabases() throws {
        let repo = routed()
        try repo.upsertRawSample(sample(metricId: MetricID.glucose, value: 5.4, externalId: "tg"))
        try repo.upsertRawSample(sample(metricId: MetricID.restingHeartRate, value: 58, externalId: "tr"))
        let watermark = clock.now().addingTimeInterval(-60)
        _ = try repo.softDelete(table: "raw_samples", metricId: MetricID.glucose,
                                externalId: "tg", sourceId: nil, updatedAt: clock.now())
        _ = try repo.softDelete(table: "raw_samples", metricId: MetricID.restingHeartRate,
                                externalId: "tr", sourceId: nil, updatedAt: clock.now())

        let tombstones = try repo.tombstones(since: watermark)

        XCTAssertEqual(tombstones.count, 2, "one from each file")
        XCTAssertEqual(tombstones.map(\.recordId), tombstones.map(\.recordId).sorted(),
                       "the export contract's deterministic record_id order must survive the merge")
    }

    /// `setSuppressed` takes a table name and a row id with no metric to route on, so it runs
    /// against both files. `sessions` exists only in main — aiming it at the sensitive file would
    /// throw "no such table" and break every sleep dedup in the app.
    func testSuppressingASessionDoesNotThrowOnTheSensitiveFile() throws {
        let session = Session(id: ULID.newID(), kind: .sleepPrimary, subtype: nil,
                              startAt: clock.now().addingTimeInterval(-28_800), endAt: clock.now(),
                              tzId: "Asia/Muscat", localNight: "2026-07-27", detail: SessionDetail(),
                              provenance: Provenance(sourceId: "src", ingestionPath: .platformStore,
                                                     externalId: "s1", measuredAt: clock.now(),
                                                     measuredTimezone: "Asia/Muscat",
                                                     recordedAt: clock.now(), ingestedAt: clock.now()),
                              updatedAt: clock.now(), originDeviceId: "dev", deletedAt: nil)
        try routed().upsertSession(session)

        XCTAssertNoThrow(try routed().setSuppressed(table: "sessions", recordId: session.id,
                                                    by: nil, updatedAt: clock.now()))
    }

    /// And suppression must still actually reach a sensitive row.
    func testSuppressingASensitiveRowWorksThroughBothConnections() throws {
        let row = sample(metricId: MetricID.glucose, value: 5.4, externalId: "sup")
        try routed().upsertRawSample(row)

        try routed().setSuppressed(table: "raw_samples", recordId: row.id, by: "winner", updatedAt: clock.now())

        XCTAssertTrue(try routed().rawSamples(metricId: MetricID.glucose).isEmpty,
                      "a suppressed row drops out of the default read")
        XCTAssertEqual(try routed().rawSamples(metricId: MetricID.glucose, includeSuppressed: true).count, 1)
    }

    // MARK: - The rule itself

    /// `MeasurementRouting` reads the registry rather than hardcoding metric ids — the property that
    /// makes a future sensitive-plus metric land correctly with no code change.
    func testRoutingRuleComesFromTheRegistryNotAHardcodedList() throws {
        XCTAssertTrue(MeasurementRouting.isSensitive(metricId: MetricID.glucose))
        XCTAssertFalse(MeasurementRouting.isSensitive(metricId: MetricID.restingHeartRate))
        XCTAssertFalse(MeasurementRouting.isSensitive(metricId: "not.a.real.metric"),
                       "an id the registry has never heard of cannot be sensitive-plus")
        XCTAssertTrue(MeasurementRouting.sensitiveMetricIds().contains(MetricID.glucose))
    }
}
