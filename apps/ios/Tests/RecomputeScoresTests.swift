import XCTest
@testable import BADAN

/// D-35 item 2a — "Recompute scores", the plain verb for re-deriving from readings already stored.
///
/// `DerivationCoordinator.backfill` was already tested and already had callers (both import screens
/// drive it; the HR-max editor queues it). What is new is the span it runs over and the guarantee
/// that running it is safe to repeat, so that is what these cover.
final class RecomputeScoresTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"
    let tz = TimeZone.current.identifier

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-recompute-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The span

    /// A fresh install has nothing stored. The caller must be able to tell that apart from a real
    /// window, rather than being handed an arbitrary one to run over.
    func testTheStoredSpanIsNilBeforeAnythingIsIngested() throws {
        XCTAssertNil(try MeasurementRepository(db.main).storedMeasurementSpan())
    }

    func testTheStoredSpanCoversTheIngestedHistory() throws {
        try ingest()
        let span = try XCTUnwrap(try MeasurementRepository(db.main).storedMeasurementSpan())

        XCTAssertLessThan(span.from, span.to)
        // 90 days of fixture, so the span must reach materially further back than a week.
        XCTAssertGreaterThan(span.to.timeIntervalSince(span.from), 30 * 86_400,
                             "the span should cover the ingested history, not just recent rows")
        XCTAssertLessThanOrEqual(span.to, clock.now().addingTimeInterval(86_400),
                                 "the span must not extend past the data that exists")
    }

    // MARK: - Recompute behaviour

    /// The claim the Settings row makes: running it again over unchanged data changes nothing.
    /// I2 means derivation appends, so a recompute that was NOT idempotent would grow the table
    /// every time someone tapped the button.
    func testRecomputingTwiceOverUnchangedDataWritesNothingTheSecondTime() throws {
        try ingest()
        let coordinator = makeCoordinator()
        let span = try XCTUnwrap(try MeasurementRepository(db.main).storedMeasurementSpan())

        _ = try coordinator.backfill(from: span.from, to: clock.now(), tz: tz)
        let afterFirst = try derivedCount()
        XCTAssertGreaterThan(afterFirst, 0, "precondition: the first run produced scores")

        _ = try coordinator.backfill(from: span.from, to: clock.now(), tz: tz)
        XCTAssertEqual(try derivedCount(), afterFirst,
                       "a recompute over unchanged data appended rows. Tapping Recompute repeatedly "
                       + "must be a no-op, not a way to grow derived_values without bound.")
    }

    /// Recompute never removes history (I2). The point is worth pinning separately from the count
    /// above: identical totals would also be consistent with delete-then-reinsert.
    func testRecomputingNeverDeletesAnEarlierDerivedRow() throws {
        try ingest()
        let coordinator = makeCoordinator()
        let span = try XCTUnwrap(try MeasurementRepository(db.main).storedMeasurementSpan())
        _ = try coordinator.backfill(from: span.from, to: clock.now(), tz: tz)

        let idsBefore = try derivedIds()
        XCTAssertFalse(idsBefore.isEmpty, "precondition: there are rows to preserve")

        _ = try coordinator.backfill(from: span.from, to: clock.now(), tz: tz)

        XCTAssertTrue(idsBefore.isSubset(of: try derivedIds()),
                      "a recompute removed derived rows. Derivation appends and supersedes by "
                      + "computed_at (I2); it never rewrites what BADAN believed earlier.")
    }

    /// The sleep limitation is real, pre-existing, and now stated in the UI — so it is worth a test
    /// that fails if it silently changes, in either direction. `backfill` anchors the sleep cluster
    /// at `to` and emits roughly the last month of nights; days at the far end of a 90-day window
    /// get readiness but no sleep score.
    func testBackfillScoresReadinessAcrossTheWindowButSleepOnlyNearTheEnd() throws {
        try ingest()
        let coordinator = makeCoordinator()
        let span = try XCTUnwrap(try MeasurementRepository(db.main).storedMeasurementSpan())
        _ = try coordinator.backfill(from: span.from, to: clock.now(), tz: tz)

        let readinessDays = try periodKeyCount(metricId: MetricID.readinessScore)
        let sleepDays = try periodKeyCount(metricId: MetricID.sleepScore)

        XCTAssertGreaterThan(readinessDays, 60,
                             "readiness is computed per day across the whole window")
        XCTAssertLessThan(sleepDays, readinessDays,
                          "sleep is a bounded rolling measure anchored at `to`, so it must cover "
                          + "fewer nights than readiness covers days. If this ever becomes equal, "
                          + "the in-app caveat in RecomputeScoresCopy.sleepCaveat is now wrong.")
    }

    // MARK: - Helpers

    private func ingest() throws {
        _ = try IngestionPipeline(measurements: MeasurementRepository(db.main),
                                  catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: deviceId)
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz),
                    range: HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400),
                                           end: clock.now()))
    }

    private func makeCoordinator() -> DerivationCoordinator {
        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        return DerivationCoordinator(
            baselines: BaselineEngine(derivation: derivation, measurements: measurements,
                                      registry: .shared, clock: clock, deviceId: deviceId),
            sleep: SleepIntelligenceEngine(derivation: derivation, measurements: measurements,
                                           clock: clock, deviceId: deviceId),
            readiness: ReadinessEngine(derivation: derivation, measurements: measurements,
                                       clock: clock, deviceId: deviceId),
            effort: EffortEngine(derivation: derivation, measurements: measurements,
                                 registry: .shared, clock: clock, deviceId: deviceId))
    }

    private func derivedCount() throws -> Int {
        Int(try db.main.query("SELECT COUNT(*) AS n FROM derived_values;").first?.int("n") ?? 0)
    }

    private func derivedIds() throws -> Set<String> {
        Set(try db.main.query("SELECT id FROM derived_values;").compactMap { $0.string("id") })
    }

    private func periodKeyCount(metricId: String) throws -> Int {
        Int(try db.main.query(
            "SELECT COUNT(DISTINCT period_key) AS n FROM derived_values WHERE metric_id = ?;",
            [.text(metricId)]).first?.int("n") ?? 0)
    }
}
