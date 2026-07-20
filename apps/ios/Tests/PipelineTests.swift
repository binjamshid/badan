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

    /// (EPIC-03) The fully-wired pipeline: routes and manual-log reconciliation only happen when
    /// their repositories are injected, so the workout tests build this rather than
    /// `makeIngestion()`.
    private func makeWorkoutIngestion() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: MetricRegistry.shared, clock: clock, deviceId: deviceId,
                          routes: RouteRepository(db.main),
                          logging: LoggingRepository(main: db.main, sensitive: db.sensitive))
    }

    /// Route consent as the settings toggle will supply it once EPIC-03's consent screen lands.
    private struct StubRouteConsent: RouteConsentProviding {
        let granted: Bool
        func routeConsent() -> RouteConsent {
            RouteConsent(granted: granted, policyVersion: RouteConsent.currentPolicyVersion,
                         decidedAt: granted ? Date(timeIntervalSince1970: 1_780_000_000) : nil)
        }
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

    // MARK: - EPIC-03: workout ingestion

    func testWorkoutsIngestAsSessionsWithTypedDetailAndProvenance() throws {
        let pipeline = makeWorkoutIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        let summary = try pipeline.ingest(from: store, range: range)

        XCTAssertGreaterThan(summary.workouts, 0, "sample data must produce ingested workouts")
        let measurements = MeasurementRepository(db.main)
        let workouts = try measurements.sessions(kind: .workout)
        XCTAssertFalse(workouts.isEmpty)

        let workout = try XCTUnwrap(workouts.first)
        let detail = try XCTUnwrap(workout.detail.workout, "kind=workout rows must carry WorkoutDetail")
        XCTAssertEqual(detail.schemaVersion, WorkoutDetail.currentSchemaVersion)
        XCTAssertEqual(detail.activityType, "running")
        XCTAssertFalse(detail.sourceWorkoutUUID.isEmpty)
        XCTAssertEqual(detail.hrSeriesRef, MetricID.heartRate,
                       "HR linkage resolves from the canonical store, never a duplicated series")
        XCTAssertNotNil(detail.totals.energyKcal)
        XCTAssertNotNil(detail.totals.avgHeartRateBpm)

        // I1: full provenance, not a partial stamp.
        XCTAssertEqual(workout.provenance.ingestionPath, .platformStore)
        XCTAssertFalse(workout.provenance.sourceId.isEmpty)
        XCTAssertNotNil(workout.provenance.externalId)
        XCTAssertFalse(workout.provenance.measuredTimezone.isEmpty)
        XCTAssertTrue(workout.provenance.qualityFlags.contains(.sampleData),
                      "fabricated rows stay labelled as fabricated wherever they travel")
    }

    /// A workout is attributed to the local day it STARTED in, deliberately unlike sleep, which
    /// is attributed to the morning it ends.
    func testWorkoutIsAttributedToTheDayItStarted() throws {
        let pipeline = makeWorkoutIngestion()
        _ = try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 30), range: range)

        let workout = try XCTUnwrap(try MeasurementRepository(db.main).sessions(kind: .workout).first)
        XCTAssertEqual(workout.localNight,
                       DayAttribution.localDayKey(workout.startAt, tz: workout.tzId))
    }

    func testWorkoutReingestIsIdempotent() throws {
        let pipeline = makeWorkoutIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 90)
        _ = try pipeline.ingest(from: store, range: range)
        let workoutCount = try count("sessions")

        let second = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(second.workouts, 0, "a replayed workout must upsert, not insert")
        XCTAssertEqual(try count("sessions"), workoutCount)
    }

    // MARK: - EPIC-03: route consent gating

    /// The acceptance criterion in as few lines as it can be stated: no route rows exist without
    /// the toggle. Consent-off is the DEFAULT, so this is also the behaviour a build that forgot
    /// to wire the toggle would get.
    func testNoRouteRowsAreWrittenWithoutConsent() throws {
        let pipeline = makeWorkoutIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 30,
                                    routeConsent: StubRouteConsent(granted: false))
        let summary = try pipeline.ingest(from: store, range: range)

        XCTAssertGreaterThan(summary.workouts, 0, "sanity: workouts themselves still ingest")
        XCTAssertEqual(summary.routes, 0)
        XCTAssertEqual(try count("workout_routes"), 0, "location data must not exist without consent")
        XCTAssertEqual(try count("route_points"), 0)

        let workout = try XCTUnwrap(try MeasurementRepository(db.main).sessions(kind: .workout).first)
        XCTAssertNil(workout.detail.workout?.routeRef,
                     "a nil routeRef must not be papered over with a dangling id")
    }

    func testRoutesIngestWithConsentAndStampTheirSnapshot() throws {
        let pipeline = makeWorkoutIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 30,
                                    routeConsent: StubRouteConsent(granted: true))
        let summary = try pipeline.ingest(from: store, range: range)

        XCTAssertGreaterThan(summary.routes, 0)
        let measurements = MeasurementRepository(db.main)
        let routeRepo = RouteRepository(db.main)
        let workout = try XCTUnwrap(try measurements.sessions(kind: .workout).first)

        let routeRef = try XCTUnwrap(workout.detail.workout?.routeRef,
                                     "a stored route must be reachable from its workout")
        let route = try XCTUnwrap(try routeRepo.route(id: routeRef),
                                  "routeRef must name a route row that actually exists")
        XCTAssertEqual(route.sessionId, workout.id)
        XCTAssertTrue(route.consentSnapshot.granted)
        XCTAssertEqual(route.consentSnapshot.policyVersion, RouteConsent.currentPolicyVersion)
        XCTAssertEqual(route.provenance.ingestionPath, .platformStore,
                       "I1: a route point's lineage resolves through its parent route")

        let points = try routeRepo.points(routeId: route.id)
        XCTAssertEqual(points.count, route.pointCount, "point_count must match the stored trace")
        XCTAssertEqual(points.map(\.seq), Array(0..<points.count))
    }

    func testRouteReingestReplacesRatherThanDuplicating() throws {
        let pipeline = makeWorkoutIngestion()
        let store = FakeHealthStore(clock: clock, historyDays: 30,
                                    routeConsent: StubRouteConsent(granted: true))
        _ = try pipeline.ingest(from: store, range: range)
        let routeRows = try count("workout_routes")
        let pointRows = try count("route_points")

        _ = try pipeline.ingest(from: store, range: range)

        XCTAssertEqual(try count("workout_routes"), routeRows, "a replayed route must update in place")
        XCTAssertEqual(try count("route_points"), pointRows,
                       "points are replaced wholesale, never appended to the previous trace")
    }

    // MARK: - EPIC-03: workout.session_overlap.v1

    /// The acceptance criterion: a manually-logged workout with an ingested twin is suppressed,
    /// with its lineage visible and reversible (I3). Suppression is journal-only because
    /// `workout_entries` carries no `suppressed_by` column — see
    /// `IngestionPipeline.dedupWorkouts`.
    func testIngestedWorkoutSuppressesItsManuallyLoggedTwin() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let store = FakeHealthStore(clock: clock, historyDays: 30)
        // Log a manual entry over the same window as one of the sample workouts, the way a user
        // would after finishing a run their watch also recorded.
        let sampleWorkout = try XCTUnwrap(store.readWorkouts(range).last)
        let now = clock.now()
        let manual = WorkoutEntry(id: ULID.newID(), activityType: "Run",
                                  startAt: sampleWorkout.start.addingTimeInterval(-120),
                                  endAt: sampleWorkout.end.addingTimeInterval(180), tzId: "UTC",
                                  energyKcal: 400, perceivedEffort: 6, ingestionPath: .manual,
                                  updatedAt: now, originDeviceId: deviceId)
        try logging.upsertWorkout(manual)

        let summary = try makeWorkoutIngestion().ingest(from: store, range: range)
        XCTAssertGreaterThan(summary.suppressed, 0)

        let decision = try XCTUnwrap(try ReconciliationRepository(db.main).forSuppressed(manual.id),
                                     "the manual twin must be journaled as suppressed")
        XCTAssertEqual(decision.rule, DedupLite.workoutRuleId)
        XCTAssertTrue(decision.reversible, "I3: every dedup decision stays reversible")
        XCTAssertEqual(decision.detail["suppressed_kind"], "manual_workout_entry")
        XCTAssertEqual(decision.detail["kept_kind"], "ingested_workout_session")
        XCTAssertNotNil(decision.detail["overlap_pct"], "lineage must state why it was suppressed")

        // I3: suppressed, never deleted — the row is untouched and still readable.
        let stillThere = try logging.workouts(from: manual.startAt.addingTimeInterval(-60),
                                              to: manual.endAt.addingTimeInterval(60))
        XCTAssertTrue(stillThere.contains { $0.id == manual.id },
                      "the manual entry itself must survive; only the decision hides it")

        // The winner it names is a real ingested workout session.
        let winner = try XCTUnwrap(try MeasurementRepository(db.main).session(id: decision.keptRecordId))
        XCTAssertEqual(winner.kind, .workout)
    }

    func testWorkoutDedupIsIdempotentAcrossReingest() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let store = FakeHealthStore(clock: clock, historyDays: 30)
        let sampleWorkout = try XCTUnwrap(store.readWorkouts(range).last)
        let now = clock.now()
        try logging.upsertWorkout(WorkoutEntry(id: ULID.newID(), activityType: "Run",
                                               startAt: sampleWorkout.start, endAt: sampleWorkout.end,
                                               tzId: "UTC", ingestionPath: .manual,
                                               updatedAt: now, originDeviceId: deviceId))

        let pipeline = makeWorkoutIngestion()
        _ = try pipeline.ingest(from: store, range: range)
        let decisionCount = try count("dedup_decisions")

        let second = try pipeline.ingest(from: store, range: range)
        XCTAssertEqual(second.suppressed, 0, "a re-ingest must not re-journal an existing decision")
        XCTAssertEqual(try count("dedup_decisions"), decisionCount)
    }

    /// A manual entry that merely shares an afternoon with an ingested workout is a different
    /// session and must survive untouched — the rule suppresses duplicates, not neighbours.
    func testNonOverlappingManualWorkoutIsNotSuppressed() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let store = FakeHealthStore(clock: clock, historyDays: 30)
        let sampleWorkout = try XCTUnwrap(store.readWorkouts(range).last)
        let now = clock.now()
        // Starts after the ingested workout has finished.
        let manual = WorkoutEntry(id: ULID.newID(), activityType: "Yoga",
                                  startAt: sampleWorkout.end.addingTimeInterval(3600),
                                  endAt: sampleWorkout.end.addingTimeInterval(3600 + 2700),
                                  tzId: "UTC", ingestionPath: .manual,
                                  updatedAt: now, originDeviceId: deviceId)
        try logging.upsertWorkout(manual)

        _ = try makeWorkoutIngestion().ingest(from: store, range: range)

        XCTAssertNil(try ReconciliationRepository(db.main).forSuppressed(manual.id),
                     "a separate session must not be suppressed just for sharing a day")
    }

    // MARK: - EPIC-01: the widened families reach the store

    func testWidenedFamiliesFlowThroughToStoredRows() throws {
        let pipeline = makeIngestion()
        _ = try pipeline.ingest(from: FakeHealthStore(clock: clock, historyDays: 90), range: range)
        let measurements = MeasurementRepository(db.main)

        // Sample data covers the subset of the widened set it can honestly fabricate; each of
        // these asserts the metric id resolves in the registry AND lands in the right table,
        // which together are what `HKTypeMap.validate` checks statically.
        XCTAssertFalse(try measurements.rawSamples(metricId: MetricID.spo2).isEmpty)
        XCTAssertFalse(try measurements.rawSamples(metricId: MetricID.weight).isEmpty)
        XCTAssertFalse(try measurements.intervalRecords(metricId: MetricID.hrv).isEmpty)
        XCTAssertFalse(try measurements.intervalRecords(metricId: MetricID.respiratoryRate).isEmpty)
        XCTAssertFalse(try measurements.intervalRecords(metricId: MetricID.activeEnergy).isEmpty)
        XCTAssertFalse(try measurements.intervalRecords(metricId: MetricID.distance).isEmpty)

        // Unit fidelity end-to-end: sample data emits active energy in kcal, the registry
        // canonical is kJ, so the stored value must be the converted one and must NOT be tagged
        // `.estimate` (which is what a failed conversion would leave behind).
        let energy = try XCTUnwrap(try measurements.intervalRecords(metricId: MetricID.activeEnergy).first)
        XCTAssertEqual(energy.unit, "kJ")
        // The generator clamps active energy to 200-750 kcal, i.e. 837-3138 kJ. An unconverted
        // value would sit inside the kcal band and below this floor — which is exactly what the
        // silent-failure mode looks like, since nothing else about the row would appear wrong.
        XCTAssertGreaterThan(energy.value, 800,
                             "kcal must be converted to the registry's canonical kJ, not passed through")
        XCTAssertFalse(energy.provenance.qualityFlags.contains(.estimate),
                       "a clean kcal->kJ conversion must not be stamped as an estimate")
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
