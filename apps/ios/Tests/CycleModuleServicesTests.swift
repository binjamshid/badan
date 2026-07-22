import XCTest
@testable import BADAN

/// EPIC-39 (Phase 3F slice 2) — `CycleModuleServices` composition-layer tests: `refreshAll`'s
/// append-only behavior and anomaly dedup, the `cycleModuleEnabled`/`cyclePredictionsPaused` gate
/// on phase-conditioned baseline recompute (mirroring `CyclePhaseCovariateCoordinatorTests`'s own
/// gate-testing style), and `purgeCycleData()`'s real per-module purge.
@MainActor
final class CycleModuleServicesTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!
    private let device = "test-device"
    private let tz = "UTC"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-cycle-module-services-\(UUID().uuidString)", isDirectory: true)
        env = AppEnvironment(database: try Database(directory: tempDir),
                             clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    override func tearDownWithError() throws {
        env = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Fixtures

    private func cycleRecord(startAt: Date) -> CycleRecord {
        let id = ULID.newID()
        return CycleRecord(
            id: id, startAt: startAt, ongoing: false, originalId: id,
            provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                  measuredAt: startAt, measuredTimezone: tz,
                                  recordedAt: startAt, ingestedAt: startAt),
            updatedAt: startAt, originDeviceId: device)
    }

    /// 7 period starts, 28 days apart except the LAST gap (45 days) — a single, deliberate
    /// cycle-length deviation against an otherwise perfectly regular baseline, chosen by hand
    /// against `CycleAnomalyEngine`'s real median/MAD math:
    ///   - baseline = the first 5 gaps (all 28 days) -> median 28, MAD 0, spread floor 1.0,
    ///     band = 28 +/- (1.4826 * 2.0 * 1.0) = [25.03, 30.97].
    ///   - current (6th, most recent) gap = 45 days -> outside the band -> `cycleLengthDeviation`
    ///     fires, and ONLY that type (only one point deviates, so neither the
    ///     two-consecutive-points nor the three-of-last-four `repeatedIrregularity` rule trips).
    /// 6 completed cycles also clears both `CyclePredictionEngine.phaseMinimumCompletedCycles` (3)
    /// and `CyclePhaseCovariateCoordinator.minPhaseConfidenceForConditionedRecompute` (a calendar-only
    /// phase estimate at 6 completed cycles carries confidence 0.55, per
    /// `CyclePredictionEngine.phaseConfidence`) — so the gate tests below have a real, confident,
    /// `.calendarOnly` estimate to gate on rather than a synthetic one.
    /// Returns the `asOf` this fixture's tests should recompute against: the most recent cycle's
    /// own start.
    @discardableResult
    private func insertSevenCycleFixture(_ services: CycleModuleServices, day0: Date) throws -> Date {
        let offsetsInDays: [Double] = [0, 28, 56, 84, 112, 140, 185]
        for offset in offsetsInDays {
            try services.cycleRecords.insertRecord(cycleRecord(startAt: day0.addingTimeInterval(offset * 86_400)))
        }
        return day0.addingTimeInterval(offsetsInDays.last! * 86_400)
    }

    /// Real HRV vitals in the main DB (`env.measurements`) so `BaselineEngine.recompute` (called
    /// through `CyclePhaseCovariateCoordinator` when the gate passes) has something to actually
    /// build a band from — a metric with no data in its window is a silent no-op by that engine's
    /// own documented behavior, which would make a passing gate indistinguishable from a failing
    /// one in these tests.
    private func insertHRVWindow(asOf: Date) throws {
        for daysAgo in 1...20 {
            let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
            let day = DayAttribution.addingDays(-daysAgo, to: dayStart, tz: tz)
            let dayKey = DayAttribution.localDayKey(day, tz: tz)
            let record = IntervalRecord(
                id: ULID.newID(), metricId: MetricID.hrv, value: 50, unit: "ms",
                startAt: day, endAt: DayAttribution.addingDays(1, to: day, tz: tz), tzId: tz, aggregation: .mean,
                provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, externalId: "hrv#\(dayKey)",
                                      measuredAt: day, measuredTimezone: tz, recordedAt: day, ingestedAt: day),
                updatedAt: day, originDeviceId: device)
            _ = try env.measurements.upsertIntervalRecord(record)
        }
    }

    private func rowCount(_ connection: SQLiteConnection, table: String) throws -> Int {
        let rows = try connection.query("SELECT COUNT(*) AS c FROM \"\(table)\";")
        return Int(rows.first?.int("c") ?? 0)
    }

    /// Every row `CyclePhaseCovariateCoordinator` ever writes lands in the SENSITIVE `baselines`
    /// table under a phase-word `covariate_context` (never `"default"`) — see that type's own I7
    /// header. A plain count of the whole table is therefore exactly "how many phase-conditioned
    /// baselines exist right now" for these tests' purposes.
    private func sensitiveBaselineCount() throws -> Int {
        try rowCount(env.database.sensitive, table: "baselines")
    }

    // MARK: - refreshAll: append-only (prediction / phase estimate)

    func testRefreshAllAlwaysAppendsPredictionAndPhaseEstimateEvenWhenCalledTwiceInARow() throws {
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))

        try services.refreshAll(asOf: asOf)
        try services.refreshAll(asOf: asOf)

        XCTAssertEqual(try rowCount(env.database.sensitive, table: "cycle_predictions"), 2,
                       "a recompute always inserts a fresh prediction row (I2), never updates in place")
        XCTAssertEqual(try rowCount(env.database.sensitive, table: "cycle_phase_estimates"), 2,
                       "a recompute always inserts a fresh phase-estimate row (I2), never updates in place")
    }

    // MARK: - refreshAll: anomaly dedup by type

    func testRefreshAllDedupsRepeatedAnomalyDetectionsOfTheSameTypeByType() throws {
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))

        try services.refreshAll(asOf: asOf)
        let firstPass = try services.anomalies.liveEvents()
        XCTAssertEqual(firstPass.filter { $0.type == .cycleLengthDeviation }.count, 1,
                       "the deliberately-deviated final gap must be detected on the first pass")

        try services.refreshAll(asOf: asOf)
        let secondPass = try services.anomalies.liveEvents()
        XCTAssertEqual(secondPass.filter { $0.type == .cycleLengthDeviation }.count, 1,
                       "calling refreshAll again with the SAME underlying condition must not create a " +
                       "second live event of the same type — this is the dedup refreshAll depends on to " +
                       "be callable after every log action without spamming duplicate cards")
    }

    func testRefreshAllAppendsAFreshAnomalyOnceThePriorOneOfTheSameTypeWasDismissed() throws {
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))

        try services.refreshAll(asOf: asOf)
        let first = try XCTUnwrap(try services.anomalies.liveEvents().first { $0.type == .cycleLengthDeviation })
        try services.anomalies.updateState(id: first.id, state: .dismissed, at: asOf)

        try services.refreshAll(asOf: asOf)
        let stillLive = try services.anomalies.liveEvents()
            .filter { $0.type == .cycleLengthDeviation && $0.state != .dismissed }
        XCTAssertEqual(stillLive.count, 1,
                       "once the prior event of this type was dismissed (not just re-detected), a fresh " +
                       "detection of the same type may land again")
    }

    // MARK: - refreshAll: cycleModuleEnabled / cyclePredictionsPaused gate on phase-conditioned baselines

    func testRefreshAllSkipsPhaseConditionedBaselineRecomputeWhenModuleDisabled() throws {
        // Default profile: cycleModuleEnabled == false (opt-in).
        XCTAssertFalse(env.profile.cycleModuleEnabled)
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))
        try insertHRVWindow(asOf: asOf)

        try services.refreshAll(asOf: asOf)

        XCTAssertEqual(try sensitiveBaselineCount(), 0,
                       "the module is off — refreshAll must never touch phase-conditioned baselines")
    }

    func testRefreshAllSkipsPhaseConditionedBaselineRecomputeWhenPredictionsPaused() throws {
        env.update { $0.cycleModuleEnabled = true; $0.cyclePredictionsPaused = true }
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))
        try insertHRVWindow(asOf: asOf)

        try services.refreshAll(asOf: asOf)

        XCTAssertEqual(try sensitiveBaselineCount(), 0,
                       "predictions are paused — refreshAll must never touch phase-conditioned baselines, " +
                       "even though the module itself is enabled")
    }

    func testRefreshAllRecomputesPhaseConditionedBaselinesWhenModuleEnabledAndNotPaused() throws {
        env.update { $0.cycleModuleEnabled = true }
        XCTAssertFalse(env.profile.cyclePredictionsPaused, "paused defaults false")
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))
        try insertHRVWindow(asOf: asOf)

        try services.refreshAll(asOf: asOf)

        XCTAssertGreaterThan(try sensitiveBaselineCount(), 0,
                             "module enabled and not paused, with a confident calendar-only phase " +
                             "estimate on file — the gate must pass and write a phase-conditioned band")
    }

    // MARK: - purgeCycleData

    func testPurgeCycleDataEmptiesAllSixTablesAndPhaseLabeledBaselinesWhileLeavingUnrelatedSensitiveDataUntouched() throws {
        env.update { $0.cycleModuleEnabled = true }
        let services = CycleModuleServices(env: env)
        let asOf = try insertSevenCycleFixture(services, day0: Date(timeIntervalSince1970: 1_800_000_000))
        try insertHRVWindow(asOf: asOf)
        try services.refreshAll(asOf: asOf)

        // AUDIT FIX: the fixture above never touched flow_logs/contraceptive_context_logs, which
        // made this test's post-purge assertions for those two tables vacuously true (they'd pass
        // whether or not purgeCycleData() actually deleted anything from either one). Populate both
        // for real so all SIX tables are genuinely exercised, not just four of them.
        let anyCycleId = try XCTUnwrap(try services.cycleRecords.liveRecords().first?.id)
        try services.flowLogs.insert(FlowLog(
            id: ULID.newID(), cycleId: anyCycleId, occurredAt: asOf, originalLabel: "medium",
            normalizedIntensity: 0.5,
            provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                  measuredAt: asOf, measuredTimezone: tz, recordedAt: asOf, ingestedAt: asOf),
            updatedAt: asOf, originDeviceId: device))
        try services.contraceptiveContext.insert(ContraceptiveContextLog(
            id: ULID.newID(), methodType: .pill, startAt: asOf,
            provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                  measuredAt: asOf, measuredTimezone: tz, recordedAt: asOf, ingestedAt: asOf),
            updatedAt: asOf, originDeviceId: device))

        // Confirm the fixture actually populated every table this purge is responsible for, and the
        // sensitive baselines table — otherwise a passing "now it's empty" assertion below would be
        // vacuously true rather than a real test of the purge.
        for table in ["cycle_records", "flow_logs", "contraceptive_context_logs",
                      "cycle_predictions", "cycle_phase_estimates", "cycle_anomaly_events"] {
            XCTAssertGreaterThan(try rowCount(env.database.sensitive, table: table), 0,
                                 "\(table) must be non-empty before purge for this test to be meaningful")
        }
        XCTAssertGreaterThan(try sensitiveBaselineCount(), 0,
                             "a phase-conditioned baseline must exist before purge for this test to be meaningful")

        // Unrelated sensitive data (a journal entry, sharing the SAME sensitive database file) —
        // this must survive a cycle-only purge completely untouched.
        let journalEntry = JournalEntry(
            id: ULID.newID(), behaviorId: "caffeine", valueKind: .boolean, occurredAt: asOf, tzId: tz,
            provenance: Provenance(sourceId: device, deviceId: device, ingestionPath: .manual,
                                  measuredAt: asOf, measuredTimezone: tz, recordedAt: asOf, ingestedAt: asOf),
            updatedAt: asOf, originDeviceId: device)
        try env.journal.insertEntry(journalEntry)

        try services.purgeCycleData()

        for table in ["cycle_records", "flow_logs", "contraceptive_context_logs",
                      "cycle_predictions", "cycle_phase_estimates", "cycle_anomaly_events"] {
            XCTAssertEqual(try rowCount(env.database.sensitive, table: table), 0,
                          "\(table) must be fully emptied by purgeCycleData()")
        }
        XCTAssertEqual(try sensitiveBaselineCount(), 0,
                       "every phase-labeled baseline row must be removed by purgeCycleData() " +
                       "(CYCLE-08: purge must invalidate derived values, not just raw rows)")
        XCTAssertEqual(try env.journal.allEntries().count, 1,
                       "unrelated sensitive data (the journal) must survive a cycle-only purge untouched")
    }
}
