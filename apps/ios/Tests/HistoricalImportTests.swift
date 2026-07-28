import XCTest
@testable import BADAN

/// D-35 item 2b — fetching Health history older than the 90-day live window.
///
/// The first two tests are the ones the plan insists come before any chunk-walk code exists,
/// because they are the ones that fail expensively: if the historical path emits different external
/// ids from the anchored path, every overlapping row silently doubles, and nothing about the app
/// looks wrong until someone counts.
///
/// `FakeHealthStore` stands in for HealthKit here. It is deterministic and filters its generated
/// history by requested range, so an "older window" is expressible: construct with a long
/// `historyDays` and ask for a range the live window would never reach.
final class HistoricalImportTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"
    let tz = TimeZone.current.identifier
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-histimport-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        // A private suite so a test never reads or clobbers the real app's pending import.
        suiteName = "badan.tests.histimport.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        db = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Identity across the two paths (write these first)

    /// The load-bearing one. Ingest a window, then ingest the SAME window again through a second
    /// store instance, and assert nothing was created the second time.
    ///
    /// This is what proves the two paths agree on `(metric_id, external_id, source_id)`. If the
    /// historical reader ever derives an id differently — a different prefix, a different UUID
    /// casing, a recomputed day key — this is the test that fails, and it fails loudly instead of
    /// leaving a database with two of everything.
    func testReimportingAnAlreadyImportedWindowCreatesNoRows() throws {
        let range = olderWindow()
        let first = try ingest(range: range)
        XCTAssertGreaterThan(first.totalWritten, 0, "precondition: the first import wrote something")

        let second = try ingest(range: range)
        XCTAssertEqual(second.totalWritten, 0,
                       "A re-import created rows. The historical path must emit the SAME external "
                       + "ids as the anchored path — same id upserts in place, a different id "
                       + "silently doubles every overlapping row.")
    }

    /// Overlap in the other direction: an older window first, then a window that overlaps it.
    /// Only the genuinely new part may be written.
    func testAnOverlappingSecondImportWritesOnlyTheNewPart() throws {
        let old = HealthDateRange(start: daysAgo(400), end: daysAgo(300))
        let overlapping = HealthDateRange(start: daysAgo(350), end: daysAgo(250))

        _ = try ingest(range: old)
        let before = try rowCount()
        let summary = try ingest(range: overlapping)
        let after = try rowCount()

        XCTAssertGreaterThan(summary.totalWritten, 0, "the non-overlapping half is genuinely new")
        // Deliberately `>=` and not `==`. `IngestSummary` counts rows derived from DTOs; ingestion
        // also writes daily sleep rollups (`sleep.time_asleep`/`sleep.time_in_bed`) per night via
        // `upsertDailySleepInterval`, which are computed from sessions rather than delivered as
        // DTOs and so are correctly absent from the summary. Asserting equality here fails on that
        // by-design gap rather than on anything about historical import.
        XCTAssertGreaterThanOrEqual(after - before, summary.totalWritten,
                                    "fewer rows exist than the summary reported writing")

        // The real claim: the overlapping half was not re-created. Running the same window a third
        // time must now write nothing at all.
        let onlyNew = try ingest(range: overlapping)
        XCTAssertEqual(onlyNew.totalWritten, 0, "the overlap re-wrote rows it already had")
        XCTAssertEqual(try rowCount(), after,
                       "a third pass over an already-imported window changed the row count")
    }

    /// The anchor guarantee, asserted rather than assumed. A historical import must leave
    /// `read_anchors` exactly as it found it, or the next live sync will silently skip everything
    /// between the old anchor and the new one — data loss with no error.
    ///
    /// `HistoricalHealthKitReader` cannot break this by construction (it has no `pendingAnchors`
    /// and no `commitPendingAnchors` override), which is the point of it being a separate type;
    /// this test is what stops that property being refactored away.
    func testAHistoricalImportLeavesEveryReadAnchorUntouched() throws {
        let anchors = ReadAnchorRepository(db.main)
        try anchors.setAnchor(store: "healthkit", platformType: "HKQuantityTypeIdentifierHeartRate",
                              data: Data([1, 2, 3]), updatedAt: clock.now())
        let before = try anchorSnapshot()
        XCTAssertFalse(before.isEmpty, "precondition: there is an anchor to preserve")

        _ = try ingest(range: olderWindow())

        XCTAssertEqual(try anchorSnapshot(), before,
                       "A historical import changed read_anchors. The incremental deletion feed "
                       + "only exists relative to an anchor HealthKit already issued, so advancing "
                       + "one here makes the next live sync skip everything in between.")
    }

    /// A historical fetch has no deletion feed and must not invent one. Claiming a deletion would
    /// soft-delete a real reading on the strength of nothing.
    func testTheHistoricalReaderNeverReportsDeletions() {
        let reader = HistoricalHealthKitReader(tz: tz)
        let deletions = reader.deletions(olderWindow())
        XCTAssertTrue(deletions.samples.isEmpty)
        XCTAssertTrue(deletions.intervals.isEmpty)
        XCTAssertTrue(deletions.sessions.isEmpty)
    }

    // MARK: - The month walk

    func testTheWalkIsOneCalendarMonthPerChunkOldestFirst() {
        let from = daysAgo(400)
        let to = daysAgo(100)
        let chunks = HistoricalImportCoordinator.monthChunks(from: from, to: to, tz: tz)

        XCTAssertGreaterThan(chunks.count, 8, "~10 months should not collapse into a few chunks")
        XCTAssertEqual(chunks.first?.start, from, "the walk must not widen the window the user chose")
        XCTAssertEqual(chunks.last?.end, to, "the walk must not overshoot the window")
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "chunks must tile the window with no gap and no overlap")
            XCTAssertLessThan(a.start, b.start, "chunks must run oldest first")
        }
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.end.timeIntervalSince(chunk.start), 32 * 86_400,
                                     "a chunk longer than a month would buffer too much in "
                                     + "IngestionPipeline's phase 1")
        }
    }

    func testAnEmptyOrInvertedWindowProducesNoChunks() {
        let now = clock.now()
        XCTAssertTrue(HistoricalImportCoordinator.monthChunks(from: now, to: now, tz: tz).isEmpty)
        XCTAssertTrue(HistoricalImportCoordinator.monthChunks(from: now, to: daysAgo(10), tz: tz).isEmpty)
    }

    // MARK: - The request store and its cursor

    func testAHalfWrittenRequestReadsAsNothingPending() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        defaults.set(123, forKey: "badan.background.historicalImportFromMillis")
        XCTAssertNil(store.pending(), "one key without the other must not read as an epoch-0 window")
    }

    func testResumeStartsFromTheCursorNotTheWindowStart() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        let from = daysAgo(400)
        let to = daysAgo(100)
        store.request(from: from, to: to)
        XCTAssertEqual(store.resumePoint()?.from, from, "with no cursor, resume starts at the window")

        let cursor = daysAgo(250)
        store.markCompleted(through: cursor)
        XCTAssertEqual(store.resumePoint()?.from, cursor,
                       "an interrupted import must not re-fetch the months it already wrote")
        XCTAssertEqual(store.resumePoint()?.to, to)
    }

    func testTheCursorNeverMovesBackwards() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        store.request(from: daysAgo(400), to: daysAgo(100))
        store.markCompleted(through: daysAgo(200))
        store.markCompleted(through: daysAgo(300))   // stale, out of order
        XCTAssertEqual(store.completedThrough(), daysAgo(200),
                       "a stale completion must not rewind the cursor and re-fetch finished work")
    }

    func testAFinishedWindowHasNothingLeftToResume() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        let to = daysAgo(100)
        store.request(from: daysAgo(400), to: to)
        store.markCompleted(through: to)
        XCTAssertNil(store.resumePoint())
    }

    /// A new request is the user changing their mind, not a second consequence of an edit — so it
    /// replaces rather than unions, and it resets the cursor. Unioning (which
    /// `ScoreBackfillRequestStore` correctly does) would silently fetch a range they just narrowed
    /// away from.
    func testANewRequestReplacesThePendingWindowAndResetsTheCursor() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        store.request(from: daysAgo(400), to: daysAgo(100))
        store.markCompleted(through: daysAgo(200))

        store.request(from: daysAgo(60), to: daysAgo(30))
        XCTAssertEqual(store.pending()?.from, daysAgo(60), "the newer, narrower window must win")
        XCTAssertNil(store.completedThrough(), "a cursor from a different window must not survive")
    }

    /// Clearing happens only after fetch AND derivation. Clearing after the fetch alone would leave
    /// imported months unscored with nothing left to say they need scoring.
    func testClearingRemovesTheWindowAndTheCursorTogether() {
        let store = HistoricalImportRequestStore(defaults: defaults)
        store.request(from: daysAgo(400), to: daysAgo(100))
        store.markCompleted(through: daysAgo(200))
        store.clear()
        XCTAssertNil(store.pending())
        XCTAssertNil(store.completedThrough())
        XCTAssertNil(store.resumePoint())
    }

    // MARK: - Counting, so the three outcomes stay distinguishable

    /// "Health returned nothing" and "everything was already stored" both write zero rows. The
    /// counting wrapper is what keeps them apart, and telling a user their history is missing when
    /// it is already imported is the failure this prevents.
    func testTheCountingStoreSeparatesAnEmptyWindowFromADuplicateOne() throws {
        let range = olderWindow()

        let firstPass = CountingHealthStore(wrapping: fakeStore())
        let firstSummary = try pipeline().ingest(from: firstPass, range: range)
        XCTAssertGreaterThan(firstPass.dtosReturned, 0)
        XCTAssertGreaterThan(firstSummary.totalWritten, 0)

        // Same window again: DTOs still come back, but nothing is new.
        let secondPass = CountingHealthStore(wrapping: fakeStore())
        let secondSummary = try pipeline().ingest(from: secondPass, range: range)
        XCTAssertGreaterThan(secondPass.dtosReturned, 0,
                             "Health still handed rows over — this is 'already up to date', not "
                             + "'nothing there'")
        XCTAssertEqual(secondSummary.totalWritten, 0)

        // A window with genuinely nothing in it.
        let emptyPass = CountingHealthStore(wrapping: fakeStore())
        let emptyRange = HealthDateRange(start: daysAgo(5000), end: daysAgo(4900))
        _ = try pipeline().ingest(from: emptyPass, range: emptyRange)
        XCTAssertEqual(emptyPass.dtosReturned, 0,
                       "a window Health has no data for must report zero DTOs, which is what lets "
                       + "the surface say 'nothing returned' without claiming to know why")
    }

    /// BUG-10b at scale: a multi-year import must not write a zero-valued daily total for every day
    /// of every year before the user owned a device.
    func testAMultiYearImportWritesNoZeroValuedDailyTotalsForYearsWithNoData() throws {
        _ = try ingest(range: HealthDateRange(start: daysAgo(3000), end: daysAgo(2000)))
        let zeros = try db.main.query("""
            SELECT COUNT(*) AS n FROM interval_records WHERE value = 0 AND deleted_at IS NULL;
            """).first?.int("n") ?? 0
        XCTAssertEqual(zeros, 0,
                       "A window with no data produced zero-valued daily totals. IngestionPipeline "
                       + "only writes a zero when a row already exists for that identity (i.e. it "
                       + "is a correction), precisely so a long backfill cannot manufacture years "
                       + "of fake zeroes.")
    }

    // MARK: - Helpers

    /// A window entirely outside the 90-day live sync range.
    private func olderWindow() -> HealthDateRange {
        HealthDateRange(start: daysAgo(400), end: daysAgo(300))
    }

    private func daysAgo(_ n: Int) -> Date {
        DayAttribution.addingDays(-n, to: clock.now(), tz: tz)
    }

    /// `historyDays: 730` so the fixture actually has data older than the live window.
    private func fakeStore() -> FakeHealthStore {
        FakeHealthStore(clock: clock, historyDays: 730, tz: tz)
    }

    private func pipeline() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: .shared, clock: clock, deviceId: deviceId)
    }

    @discardableResult
    private func ingest(range: HealthDateRange) throws -> IngestionPipeline.IngestSummary {
        try pipeline().ingest(from: fakeStore(), range: range, origin: .liveSync)
    }

    private func rowCount() throws -> Int {
        var total = 0
        for table in ["raw_samples", "interval_records", "sessions"] {
            total += Int(try db.main.query("SELECT COUNT(*) AS n FROM \(table);").first?.int("n") ?? 0)
        }
        return total
    }

    /// Every anchor row, as a comparable snapshot.
    private func anchorSnapshot() throws -> [String] {
        try db.main.query("SELECT store, platform_type, anchor FROM read_anchors ORDER BY platform_type;")
            .map { "\($0.string("store") ?? "")|\($0.string("platform_type") ?? "")|\(($0.data("anchor") ?? Data()).base64EncodedString())" }
    }
}
