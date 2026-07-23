import XCTest
@testable import BADAN

/// EPIC-43 follow-up slice (plan §7A.6/§9.19): proves `IngestionPipeline` is actually the missing
/// caller `DataConflictsScreen`'s own doc named — that reconciliation-v2 (`ConflictDecisionEngine`
/// + `DataConflictRepository`) is now wired into the real ingestion path, not merely exercised by
/// `DataConflictTests`' unit tests against the pure engine.
///
/// Three properties, mirroring `PipelineTests`/`IncrementalSyncFixTests`' own hand-built
/// `HealthStorePort` stub convention (not `FakeHealthStore`, whose RHR/HRV/weight are all single-
/// sourced and so never exercise this new path at all — see the third test below):
/// 1. Two genuinely disagreeing readings for the same metric/day produce a real `DataConflict`
///    row, visible via `DataConflictRepository.unresolved()`.
/// 2. A clearly-winning case (no manual candidate, so `ConflictDecisionEngine`'s unconditional
///    most-recent-weight-wins default applies) does NOT create a `DataConflict` — it suppresses
///    the loser and journals a `ReconciliationDecision`, exactly like the pre-existing dedup paths
///    already do.
/// 3. The pre-existing sleep/workout dedup behavior is byte-for-byte unchanged by this addition.
final class IngestionReconciliationWiringTests: XCTestCase {
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

    private var range: HealthDateRange {
        HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400), end: clock.now())
    }

    /// The reconciliation-v2 repositories are optional/additive on `IngestionPipeline` (mirroring
    /// `routes`/`logging`'s own "absent = the step does not run" contract) — every test here wires
    /// them explicitly so the new step is actually reachable.
    private func makeIngestion() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main), catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main), registry: MetricRegistry.shared,
                          clock: clock, deviceId: deviceId,
                          dataConflicts: DataConflictRepository(main: db.main),
                          sourcePriorityRules: SourcePriorityRuleRepository(main: db.main))
    }

    // MARK: - (1) Genuine disagreement -> a real, unresolved DataConflict

    func testGenuinelyDisagreeingReadingsProduceAnUnresolvedDataConflict() throws {
        let day = clock.now().addingTimeInterval(-3 * 86_400)
        let store = TwoSourceRHRConflictStore(day: day)
        let pipeline = makeIngestion()
        _ = try pipeline.ingest(from: store, range: range)

        let conflicts = try DataConflictRepository(main: db.main).unresolved()
        XCTAssertEqual(conflicts.count, 1,
                       "two sources materially disagreeing on the same day's RHR must open exactly one conflict")
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.scope, .metric(id: MetricID.restingHeartRate))
        XCTAssertEqual(conflict.status, .unresolved)
        XCTAssertEqual(conflict.candidateRecordIds.count, 2, "both disagreeing candidates must be named")
        XCTAssertNil(conflict.resolvedByDecisionId)

        // I3/I5: an unresolved conflict decides nothing — neither candidate is suppressed, and
        // nothing was journaled to the pre-existing reconciliation ledger for it.
        let live = try MeasurementRepository(db.main)
            .intervalRecords(metricId: MetricID.restingHeartRate, includeSuppressed: false)
        XCTAssertEqual(live.count, 2, "both disagreeing readings must remain visible while unresolved")
        XCTAssertEqual(Set(live.map(\.id)), Set(conflict.candidateRecordIds))
        XCTAssertTrue(try ReconciliationRepository(db.main).recent(limit: 50).isEmpty,
                     "an unresolved conflict must not also be journaled as a decided dedup")
    }

    /// A re-ingest of the identical disagreement must not open a second, duplicate conflict.
    func testReingestOfTheSameDisagreementDoesNotDuplicateTheConflict() throws {
        let day = clock.now().addingTimeInterval(-3 * 86_400)
        let store = TwoSourceRHRConflictStore(day: day)
        let pipeline = makeIngestion()
        _ = try pipeline.ingest(from: store, range: range)
        _ = try pipeline.ingest(from: store, range: range)

        let conflicts = try DataConflictRepository(main: db.main).unresolved()
        XCTAssertEqual(conflicts.count, 1, "re-ingesting the same disagreement must be idempotent, not duplicate")
    }

    // MARK: - (2) Clearly-winning case -> ReconciliationDecision, no DataConflict

    func testClearlyWinningWeightCaseAutoResolvesWithoutOpeningADataConflict() throws {
        let day = clock.now().addingTimeInterval(-4 * 86_400)
        let store = TwoSourceWeightAutoResolveStore(older: day, newer: day.addingTimeInterval(4 * 3600))
        let pipeline = makeIngestion()
        let summary = try pipeline.ingest(from: store, range: range)

        XCTAssertTrue(try DataConflictRepository(main: db.main).unresolved().isEmpty,
                     "a confidently auto-resolved outcome must not also surface as an open DataConflict")

        let measurements = MeasurementRepository(db.main)
        let allWeights = try measurements.rawSamples(metricId: MetricID.weight, includeSuppressed: true)
        XCTAssertEqual(allWeights.count, 2)
        let newer = try XCTUnwrap(allWeights.first { $0.provenance.sourceId == "weight-src-new" })
        let older = try XCTUnwrap(allWeights.first { $0.provenance.sourceId == "weight-src-old" })

        XCTAssertNil(newer.provenance.suppressedBy, "the most-recently-measured weight reading must win")
        XCTAssertEqual(older.provenance.suppressedBy, newer.id,
                       "the older reading is suppressed by the winner, never deleted (I3)")

        // Persisted through the SAME pre-existing reconciliation repository the dedup paths use —
        // not a second, parallel ledger.
        let decision = try XCTUnwrap(try ReconciliationRepository(db.main).forSuppressed(older.id))
        XCTAssertEqual(decision.keptRecordId, newer.id)
        XCTAssertEqual(decision.rule, ConflictDecisionEngine.mostRecentWeightRuleId)
        XCTAssertEqual(decision.ruleVersion, "v1")
        XCTAssertTrue(decision.reversible, "I3: every dedup decision (including reconciliation-v2's) stays reversible")

        XCTAssertGreaterThan(summary.suppressed, 0,
                             "the auto-resolved suppression must be counted, exactly like the existing dedup paths")
    }

    /// A re-ingest of the identical winning case must not re-suppress or re-journal it.
    func testReingestOfTheSameAutoResolvedCaseIsIdempotent() throws {
        let day = clock.now().addingTimeInterval(-4 * 86_400)
        let store = TwoSourceWeightAutoResolveStore(older: day, newer: day.addingTimeInterval(4 * 3600))
        let pipeline = makeIngestion()
        _ = try pipeline.ingest(from: store, range: range)
        let decisionCount = try count("dedup_decisions")

        let second = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(second.suppressed, 0, "a re-ingest must not re-journal an already-decided conflict")
        XCTAssertEqual(try count("dedup_decisions"), decisionCount)
    }

    // MARK: - (3) Existing sleep/workout dedup is unchanged

    /// `FakeHealthStore`'s RHR/HRV/weight all come from exactly one source (`src_watch`), so this
    /// new step has nothing to resolve there — it must stay completely inert, and every existing
    /// sleep/workout dedup guarantee (`PipelineTests`) must still hold with the new repositories
    /// wired in.
    func testExistingSleepAndWorkoutDedupIsUnchangedByTheNewWiring() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let store = FakeHealthStore(clock: clock, historyDays: 90)

        // A manually-logged twin of one of the sample workouts, exactly as
        // `PipelineTests.testIngestedWorkoutSuppressesItsManuallyLoggedTwin` sets one up.
        let sampleWorkout = try XCTUnwrap(store.readWorkouts(range).last)
        let now = clock.now()
        let manual = WorkoutEntry(id: ULID.newID(), activityType: "Run",
                                  startAt: sampleWorkout.start.addingTimeInterval(-120),
                                  endAt: sampleWorkout.end.addingTimeInterval(180), tzId: "UTC",
                                  energyKcal: 400, perceivedEffort: 6, ingestionPath: .manual,
                                  updatedAt: now, originDeviceId: deviceId)
        try logging.upsertWorkout(manual)

        let pipeline = IngestionPipeline(
            measurements: MeasurementRepository(db.main), catalog: CatalogRepository(db.main),
            reconciliation: ReconciliationRepository(db.main), registry: MetricRegistry.shared,
            clock: clock, deviceId: deviceId,
            routes: RouteRepository(db.main), logging: logging,
            dataConflicts: DataConflictRepository(main: db.main),
            sourcePriorityRules: SourcePriorityRuleRepository(main: db.main))
        let summary = try pipeline.ingest(from: store, range: range)

        // Sleep dedup: still exactly one surviving session per checked night, same as
        // `PipelineTests.testSleepDedupSuppressesOneSourcePerNight`.
        XCTAssertGreaterThan(summary.suppressed, 0, "overlapping sleep should still be deduped")
        let measurements = MeasurementRepository(db.main)
        var checkedNight: String?
        for offset in 1...5 {
            let d = clock.now().addingTimeInterval(Double(-offset) * 86_400)
            let key = DayAttribution.localNight(sessionEnd: d, tz: TimeZone.current.identifier)
            let all = try measurements.allSleepSessions(localNight: key, includeSuppressed: true)
            if all.count >= 2 { checkedNight = key; break }
        }
        let nightKey = try XCTUnwrap(checkedNight, "sanity: some night must have 2+ sleep sessions to dedup")
        let visible = try measurements.allSleepSessions(localNight: nightKey, includeSuppressed: false)
        let all = try measurements.allSleepSessions(localNight: nightKey, includeSuppressed: true)
        XCTAssertEqual(visible.count, 1, "sleep dedup must still leave exactly one survivor per night")
        XCTAssertGreaterThan(all.count, visible.count, "the loser is still suppressed, not deleted")

        // Workout dedup: the manual twin is still suppressed by its ingested twin, exactly as before.
        let decision = try XCTUnwrap(try ReconciliationRepository(db.main).forSuppressed(manual.id),
                                     "the manual twin must still be journaled as suppressed")
        XCTAssertEqual(decision.rule, DedupLite.workoutRuleId)
        XCTAssertTrue(decision.reversible)

        // reconciliation-v2 must stay inert: FakeHealthStore's conflict-checked metrics are all
        // single-sourced, so there is no genuine cross-source disagreement for it to find.
        XCTAssertTrue(try DataConflictRepository(main: db.main).unresolved().isEmpty,
                     "reconciliation-v2 must not fabricate a conflict when every candidate metric is single-sourced")
    }

    /// Re-ingesting the full `FakeHealthStore` fixture twice must remain a complete no-op the
    /// second time — the same idempotence guarantee `PipelineTests.testReingestIsIdempotent`
    /// asserts, now with the new reconciliation-v2 repositories wired in too.
    func testFakeHealthStoreReingestRemainsIdempotentWithTheNewWiring() throws {
        let pipeline = makeIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        _ = try pipeline.ingest(from: store, range: range)
        let second = try pipeline.ingest(from: store, range: range)

        XCTAssertEqual(second.samples, 0)
        XCTAssertEqual(second.intervals, 0)
        XCTAssertEqual(second.sessions, 0)
        XCTAssertEqual(second.suppressed, 0, "re-running ingestion must still be a no-op")
    }

    // MARK: - Helpers

    private func count(_ table: String) throws -> Int {
        Int(try db.main.query("SELECT COUNT(*) AS c FROM \(table);").first?.int("c") ?? 0)
    }

    // MARK: - Fixtures

    /// Two sources reporting materially different resting-heart-rate values for the identical
    /// day — a genuine disagreement, with no `SourcePriorityRule` registered for either candidate
    /// to resolve it, so `ConflictDecisionEngine.decide` must return `nil` (unresolved).
    private final class TwoSourceRHRConflictStore: HealthStorePort {
        let day: Date
        init(day: Date) { self.day = day }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "rhr-conflict-src-a", displayName: "Conflict source A", type: .healthkit, priority: 10),
             SourceDescriptor(id: "rhr-conflict-src-b", displayName: "Conflict source B", type: .healthkit, priority: 10)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
            [IntervalDTO(metricId: MetricID.restingHeartRate, value: 52, unit: "bpm", start: day,
                        end: day.addingTimeInterval(3600), tz: "UTC", aggregation: .mean,
                        sourceId: "rhr-conflict-src-a", externalId: "rhr-conflict-a"),
             IntervalDTO(metricId: MetricID.restingHeartRate, value: 91, unit: "bpm", start: day,
                        end: day.addingTimeInterval(3600), tz: "UTC", aggregation: .mean,
                        sourceId: "rhr-conflict-src-b", externalId: "rhr-conflict-b")]
        }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    }

    /// Two sources reporting materially different weight values for the identical day, neither
    /// manually entered — `ConflictDecisionEngine.decide` resolves this automatically via its
    /// unconditional "most-recent weight wins" default (§7A.6), with no `SourcePriorityRule`
    /// needed at all.
    private final class TwoSourceWeightAutoResolveStore: HealthStorePort {
        let older: Date
        let newer: Date
        init(older: Date, newer: Date) { self.older = older; self.newer = newer }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "weight-src-old", displayName: "Old scale", type: .healthkit, priority: 10),
             SourceDescriptor(id: "weight-src-new", displayName: "New scale", type: .healthkit, priority: 10)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
            [SampleDTO(metricId: MetricID.weight, value: 70.0, unit: "kg", start: older, tz: "UTC",
                      sourceId: "weight-src-old", externalId: "weight-old"),
             SampleDTO(metricId: MetricID.weight, value: 82.0, unit: "kg", start: newer, tz: "UTC",
                      sourceId: "weight-src-new", externalId: "weight-new")]
        }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    }
}
