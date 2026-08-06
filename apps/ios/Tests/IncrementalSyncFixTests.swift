import XCTest
@testable import BADAN

/// Correctness of incremental (re-)ingestion — the seam a recurring foreground sync depends
/// on. Mirrors `PipelineTests`' temp-`Database` harness. Each test drives `IngestionPipeline`
/// across TWO `ingest(from:range:)` calls against small, hand-built `HealthStorePort` stubs
/// (not `FakeHealthStore`, which regenerates a fixed deterministic snapshot rather than
/// simulating a real store's delta/deletion behavior across syncs).
///
/// Covers:
/// - BUG-10a: a HealthKit deletion soft-deletes the matching row and reads exclude it.
/// - BUG-11a/b/c: a sleep session delivered across two syncs (and one that flips
///   primary/nap classification between them) upserts as exactly ONE row, never a duplicate.
/// - DATA-08: a failed write transaction never lets the port persist its read anchor.
/// - tzAssumed threading: an adapter-supplied quality flag survives into stored `Provenance`.
final class IncrementalSyncFixTests: XCTestCase {
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

    /// A settled morning earlier on the fixed clock's own UTC day (~07:46). The split-night and
    /// rebuild fixtures key their nights off this rather than off `now`, so a SECOND cluster
    /// belonging to the same local night — the afternoon episode that both SLEEP-H1 and SLEEP-H2
    /// turn on — still ends inside `range` instead of being filtered out as future data.
    private var morning: Date { clock.now().addingTimeInterval(-6 * 3600) }

    // MARK: - BUG-10a: deletions soft-delete and reads exclude them

    func testDeletionSoftDeletesRowAndReadsExcludeIt() throws {
        let pipeline = makeIngestion()
        let store = DeletableHeartRateStore(start: clock.now().addingTimeInterval(-3600))

        _ = try pipeline.ingest(from: store, range: range)
        let measurements = MeasurementRepository(db.main)
        XCTAssertEqual(try measurements.rawSamples(metricId: MetricID.heartRate).count, 1,
                       "first sync should have ingested the sample")

        // Second sync: the sample is gone from HealthKit and its deletion is reported instead.
        store.phase = 1
        _ = try pipeline.ingest(from: store, range: range)

        XCTAssertEqual(try measurements.rawSamples(metricId: MetricID.heartRate).count, 0,
                       "reads must exclude the soft-deleted row (they already filter deleted_at IS NULL)")

        // Confirm it's soft-deleted (INVARIANT I3), not hard-deleted.
        let raw = try db.main.query("SELECT deleted_at FROM raw_samples WHERE external_id = ?;",
                                    [.text(store.externalId)])
        XCTAssertEqual(raw.count, 1, "the row itself must still physically exist")
        XCTAssertNotNil(raw.first?.date("deleted_at"), "and be marked deleted rather than removed")
    }

    // MARK: - BUG-11: night-keyed identity + full-night rebuild + conflict-target fix

    func testSleepDeliveredInTwoHalvesProducesOneSessionWithFullDuration() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = NightRebuildSleepStore(night: night, tz: "UTC", nightEnd: clock.now())

        _ = try pipeline.ingest(from: store, range: range) // phase 0: first half only (2h)
        store.phase = 1
        _ = try pipeline.ingest(from: store, range: range) // phase 1: full night (8h)

        let measurements = MeasurementRepository(db.main)
        let sessions = try measurements.allSleepSessions(localNight: night, includeSuppressed: true)
        XCTAssertEqual(sessions.count, 1,
                       "a night delivered across two syncs must upsert as ONE row, not a duplicate")
        let survivor = try XCTUnwrap(sessions.first)
        let asleep = try XCTUnwrap(survivor.detail.timeAsleepSeconds)
        XCTAssertEqual(asleep, 8 * 3600, accuracy: 0.5,
                       "the surviving row must reflect the full rebuilt night, not the first partial delivery")
    }

    func testSleepKindFlipUpdatesInPlaceWithoutDuplicate() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = NightRebuildSleepStore(night: night, tz: "UTC", nightEnd: clock.now())

        _ = try pipeline.ingest(from: store, range: range) // phase 0: 2h -> classifies as nap
        let measurements = MeasurementRepository(db.main)
        let afterFirst = try measurements.allSleepSessions(localNight: night, includeSuppressed: true)
        XCTAssertEqual(afterFirst.count, 1)
        let firstKind: SessionKind = try XCTUnwrap(afterFirst.first).kind
        XCTAssertEqual(firstKind, SessionKind.sleepNap)

        store.phase = 1
        _ = try pipeline.ingest(from: store, range: range) // phase 1: 8h -> classifies as primary

        let afterSecond = try measurements.allSleepSessions(localNight: night, includeSuppressed: true)
        XCTAssertEqual(afterSecond.count, 1,
                       "a kind flip (nap -> primary) must UPDATE the existing row, never duplicate it")
        let secondKind: SessionKind = try XCTUnwrap(afterSecond.first).kind
        XCTAssertEqual(secondKind, SessionKind.sleepPrimary,
                       "kind must be recomputed and overwritten on upsert")
    }

    // MARK: - DATA-08: anchors are never committed past a failed write transaction

    func testAnchorsNotPersistedWhenWriteTransactionThrows() throws {
        let pipeline = makeIngestion()
        let store = CountingCommitStore()

        // Force the write transaction to throw partway through by breaking a table it needs.
        // This exercises the DATA-08 API shape directly: `IngestionPipeline.ingest` only
        // reaches `port.commitPendingAnchors()` on the line AFTER `measurements.transaction {}`
        // returns, so if that closure throws, commitPendingAnchors() must never run — a failed
        // ingest must replay from the last successfully-committed position, not skip ahead.
        try db.main.execute("DROP TABLE sources;")

        XCTAssertThrowsError(try pipeline.ingest(from: store, range: range))
        XCTAssertEqual(store.commitCount, 0,
                       "a failed ingest must not let the port commit anchors past uncommitted data")
    }

    /// (EPIC-01/EPIC-03) The same guarantee, now with every widened family in flight at once.
    ///
    /// The original test proved the API shape with an empty store. Once eleven more types share
    /// `runAnchoredQuery` and `pendingAnchors`, the failure mode to rule out is different and
    /// worse: one type persisting its anchor eagerly (a plausible "optimization" for a type whose
    /// read looks self-contained) would advance that single cursor past data whose write never
    /// committed, silently dropping it forever while every other type replayed correctly. This
    /// exercises a store carrying samples, intervals, a session and a workout together, so a
    /// per-type shortcut has somewhere to show up.
    func testAnchorsNotPersistedForAnyWidenedTypeWhenWriteTransactionThrows() throws {
        let pipeline = makeIngestion()
        let store = WidenedFamiliesStore(now: clock.now())

        // Sanity: the fixture really does carry every family, so a green result cannot come from
        // the store having handed over nothing.
        XCTAssertFalse(store.readSamples(range).isEmpty)
        XCTAssertFalse(store.readIntervals(range).isEmpty)
        XCTAssertFalse(store.readWorkouts(range).isEmpty)

        try db.main.execute("DROP TABLE sources;")

        XCTAssertThrowsError(try pipeline.ingest(from: store, range: range))
        XCTAssertEqual(store.commitCount, 0,
                       "no type may persist its anchor when the write transaction for its data failed")
    }

    // MARK: - tzAssumed threading (completes wave-1 DATA-07)

    func testTzAssumedQualityFlagPropagatesIntoStoredProvenance() throws {
        let pipeline = makeIngestion()
        let store = TzAssumedSampleStore(start: clock.now().addingTimeInterval(-1800))
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        let stored = try measurements.rawSamples(metricId: MetricID.heartRate)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored.first?.provenance.qualityFlags.contains(.tzAssumed) ?? false,
                     "IngestionPipeline must merge the adapter-supplied qualityFlags into stamped Provenance")
    }

    // MARK: - INGESTION-01: a port with no descriptors must not zero every source's priority

    /// The historical-import shape. `HistoricalHealthKitReader.sourceDescriptors()` returns `[]`
    /// on purpose — it reads the same store live sync already catalogued — but the pipeline used
    /// to derive `priorityBySource` from THAT RUN's descriptors alone, so the map came back empty
    /// and `dedup(night:)` resolved every source to `?? 0`. `DedupLite.reconcile` then fell
    /// through its priority comparison to "longest duration, then id", handing the night to
    /// whichever source recorded the longest span — for every night in the import window,
    /// including the ones live sync had already reconciled correctly.
    ///
    /// Two sources, one night: the watch reports 7h05m and the phone's sleep app reports a
    /// containing 8h20m in-bed cluster. Priority says watch; duration says phone.
    func testDescriptorlessPortStillReconcilesByStoredSourcePriority() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let live = TwoSourceNightStore(night: night, tz: "UTC", nightEnd: morning,
                                       withDescriptors: true)
        _ = try pipeline.ingest(from: live, range: range)

        let measurements = MeasurementRepository(db.main)
        func survivorSourceId() throws -> String? {
            try measurements.allSleepSessions(localNight: night, includeSuppressed: false)
                .first?.provenance.sourceId
        }
        XCTAssertEqual(try survivorSourceId(), TwoSourceNightStore.watchSource,
                       "precondition: with descriptors present the watch already wins on priority")

        // Now the historical-import path re-delivers the identical night and describes no sources.
        let historical = TwoSourceNightStore(night: night, tz: "UTC", nightEnd: morning,
                                             withDescriptors: false)
        _ = try pipeline.ingest(from: historical, range: range)

        XCTAssertEqual(try survivorSourceId(), TwoSourceNightStore.watchSource,
                       "INGESTION-01: priority must come from the stored source catalog, not only "
                           + "from this run's descriptors — otherwise every source ties at 0 and the "
                           + "phone's longer in-bed cluster takes the night from the watch")
    }

    /// The same failure one layer down, at the rollup: a flipped winner rewrites
    /// `sleep.time_asleep` from the losing source's numbers.
    func testDescriptorlessPortDoesNotRewriteTheNightlyRollupFromTheLosingSource() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        _ = try pipeline.ingest(from: TwoSourceNightStore(night: night, tz: "UTC",
                                                          nightEnd: morning, withDescriptors: true),
                                range: range)
        _ = try pipeline.ingest(from: TwoSourceNightStore(night: night, tz: "UTC",
                                                          nightEnd: morning, withDescriptors: false),
                                range: range)

        let measurements = MeasurementRepository(db.main)
        let rollups = try measurements.intervalRecords(metricId: "sleep.time_asleep",
                                                       includeSuppressed: false)
            .filter { $0.provenance.externalId == "derived.sleep.time_asleep.\(night)" }
        XCTAssertEqual(rollups.count, 1, "one night, one live rollup row")
        XCTAssertEqual(try XCTUnwrap(rollups.first).value, TwoSourceNightStore.watchAsleepSeconds,
                       accuracy: 0.5,
                       "INGESTION-01: the rollup must still be written from the watch's numbers")
    }

    // MARK: - SLEEP-H1: the nightly rollup is the night's total, not one cluster's

    /// A split night — two primary clusters separated by a wake gap longer than the adapter's
    /// 3h clustering gap, both over the 3h `sleepPrimaryMinSeconds` bar, neither overlapping the
    /// other so neither is suppressed. `SleepIntelligenceEngine.assembleNights` sums them into one
    /// night on purpose ("a split night is one night's sleep, not two", golden-tested), but the
    /// rollup read `measurements.primarySleep(localNight:)` — ONE row, `ORDER BY start_at DESC` —
    /// so `sleep.time_asleep` reported only the LAST cluster. That understated interval is what
    /// `BaselineEngine.latestPerDay` consumes, so the engine ended up scoring the summed night
    /// against a baseline built from fractions of nights.
    func testSplitNightRollupIsTheSumOfEverySurvivingPrimaryCluster() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = SplitNightSleepStore(night: night, tz: "UTC", nightEnd: morning)
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        let primaries = try measurements.allSleepSessions(localNight: night, includeSuppressed: false)
            .filter { $0.kind == .sleepPrimary }
        XCTAssertEqual(primaries.count, 2,
                       "precondition: two disjoint primary clusters both survive dedup")

        let rollups = try measurements.intervalRecords(metricId: "sleep.time_asleep",
                                                       includeSuppressed: false)
            .filter { $0.provenance.externalId == "derived.sleep.time_asleep.\(night)" }
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(try XCTUnwrap(rollups.first).value,
                       SplitNightSleepStore.firstAsleep + SplitNightSleepStore.secondAsleep,
                       accuracy: 0.5,
                       "SLEEP-H1: sleep.time_asleep must be the night's total across every "
                           + "surviving primary cluster, not the latest-starting one's alone")
    }

    /// The rollup's provenance must name the night's FIRST cluster, matching
    /// `SleepNight.primarySessionId` (`sessionIds.first`) in the derivation layer — one night, one
    /// winner, one reader.
    func testSplitNightRollupIsAnchoredOnTheEarliestCluster() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        _ = try pipeline.ingest(from: SplitNightSleepStore(night: night, tz: "UTC",
                                                           nightEnd: morning),
                                range: range)

        let measurements = MeasurementRepository(db.main)
        let earliest = try XCTUnwrap(
            measurements.allSleepSessions(localNight: night, includeSuppressed: false)
                .first { $0.kind == .sleepPrimary })
        let rollup = try XCTUnwrap(
            measurements.intervalRecords(metricId: "sleep.time_asleep", includeSuppressed: false)
                .first { $0.provenance.externalId == "derived.sleep.time_asleep.\(night)" })
        XCTAssertEqual(rollup.provenance.measuredAt.timeIntervalSince1970,
                       earliest.startAt.timeIntervalSince1970, accuracy: 1,
                       "SLEEP-H1: the rollup's bedtime lineage is the night's first cluster")

        let named = try XCTUnwrap(measurements.primarySleep(localNight: night))
        XCTAssertEqual(named.id, earliest.id,
                       "SLEEP-H1: primarySleep must name the night's first cluster (ASC), not a "
                           + "later same-night episode")
    }

    // MARK: - SLEEP-H2: a full-night rebuild must be authoritative, not merely additive

    /// Delete the night's LAST cluster in Health and the rebuild simply stops emitting its
    /// positional id (`base-1`). Nothing tombstoned it: `writeSessions` only upserts, sleep never
    /// populates `HealthStoreDeletions.sessions`, and `DedupLite` cannot suppress a cluster that
    /// overlaps nothing. The orphan stayed live and kept accruing nap credit against the next
    /// night's need, forever.
    func testDeletedTrailingClusterIsTombstonedByTheNextFullNightRebuild() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = RebuiltNightStore(night: night, tz: "UTC", nightEnd: morning)

        _ = try pipeline.ingest(from: store, range: range) // night + afternoon nap
        let measurements = MeasurementRepository(db.main)
        XCTAssertEqual(try measurements.allSleepSessions(localNight: night, includeSuppressed: false).count, 2,
                       "precondition: the night starts out with two clusters")

        store.phase = 1 // the nap is deleted in Health; the rebuild emits only the night
        _ = try pipeline.ingest(from: store, range: range)

        let live = try measurements.allSleepSessions(localNight: night, includeSuppressed: false)
        XCTAssertEqual(live.count, 1,
                       "SLEEP-H2: a cluster the full-night rebuild no longer claims must not stay live")
        XCTAssertEqual(live.first?.kind, SessionKind.sleepPrimary,
                       "the surviving row is the night itself, not the deleted nap")

        let rows = try db.main.query("SELECT deleted_at FROM sessions WHERE external_id = ?;",
                                     [.text(store.napExternalId)])
        XCTAssertEqual(rows.count, 1, "soft-deleted (I3), never removed")
        XCTAssertNotNil(rows.first?.date("deleted_at"), "and actually tombstoned")
    }

    /// The payload that actually hurts: the orphaned nap's seconds must stop reaching
    /// `SleepIntelligenceEngine`, which is what subtracts them from the following night's need.
    func testDeletedNapStopsFeedingNapCreditAfterTheRebuild() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = RebuiltNightStore(night: night, tz: "UTC", nightEnd: morning)
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        func napSeconds() throws -> Double {
            // Exactly the read `SleepIntelligenceEngine.recompute` performs: live rows only.
            let sessions = try measurements.sessions(from: range.start, to: range.end)
            let inputs = sessions.compactMap { s -> SleepSessionInput? in
                guard s.kind == .sleepPrimary || s.kind == .sleepNap else { return nil }
                return SleepSessionInput(
                    sessionId: s.id, kind: s.kind == .sleepNap ? .nap : .primary,
                    startEpoch: s.startAt.timeIntervalSince1970,
                    endEpoch: s.endAt.timeIntervalSince1970, tzId: s.tzId,
                    asleepSeconds: s.detail.timeAsleepSeconds ?? 0,
                    inBedSeconds: s.detail.timeInBedSeconds ?? 0,
                    awakeIntervals: [], hasStages: false)
            }
            return SleepIntelligenceEngine.assembleNights(inputs).napSecondsByDayKey[night] ?? 0
        }
        XCTAssertEqual(try napSeconds(), RebuiltNightStore.napAsleep, accuracy: 0.5,
                       "precondition: the nap counts while it exists")

        store.phase = 1
        _ = try pipeline.ingest(from: store, range: range)

        XCTAssertEqual(try napSeconds(), 0, accuracy: 0.5,
                       "SLEEP-H2: a nap deleted in Health must stop crediting against the next "
                           + "night's sleep need")
    }

    /// The scoping guard. A port that cannot claim a full-night rebuild claims nothing, and its
    /// nights are upserted into exactly as before — otherwise a delta-only or partial-range sync
    /// would tombstone live sessions it never read.
    func testAPortThatClaimsNoRebuildNeverPrunesAnything() throws {
        let pipeline = makeIngestion()
        let night = DayAttribution.localNight(sessionEnd: clock.now(), tz: "UTC")
        let store = RebuiltNightStore(night: night, tz: "UTC", nightEnd: morning)
        store.claimsRebuilds = false

        _ = try pipeline.ingest(from: store, range: range)
        store.phase = 1
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        XCTAssertEqual(try measurements.allSleepSessions(localNight: night, includeSuppressed: false).count, 2,
                       "without a rebuild claim the pipeline must not delete anything it was not handed")
    }

    // MARK: - INGESTION-02: the daily-sum read window

    // (AUDIT 2026-08-06, INGESTION-02) The widest-blast-radius finding of the audit set, and the
    // only one whose fix sits BELOW the `HealthStorePort` seam: `readDailySum` needs a live
    // `HKHealthStore`, so no stub in this file can drive it end to end. `dayAlignedWindow` was
    // extracted `static` and pure precisely so the part that was wrong is reachable from a test —
    // and then shipped without one. This is that test.
    //
    // The defect: `HKStatisticsCollectionQuery` anchored its buckets at local midnight while the
    // PREDICATE began at `range.start`, which every caller builds with
    // `DayAttribution.addingDays(-n, to: now, tz:)` — preserving the wall-clock time of day by
    // construction. Bucket 0 was therefore a whole local day whose sum counted only the samples
    // recorded after HH:MM, and Apple documents `enumerateStatistics(from:to:)` as yielding "the
    // time interval that contains the start date" rather than skipping it. That partial was
    // upserted over the correct total under the stable day-keyed external id, one day per sync,
    // permanently — and near local midnight it rounds to ~0, where BUG-10b's guard reads it as a
    // correction and zeroes the day outright.
    //
    // Expectations are computed from a `Calendar` built here rather than from `DayAttribution`, so
    // these assert the property itself instead of agreeing with the implementation's own helper.

    private func zoned(_ tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    /// The fix itself: whatever time of day the caller's range begins at, the read starts at the
    /// midnight of the local day CONTAINING it, so bucket 0 is fully covered.
    func testTheDailySumWindowStartsAtLocalMidnightNotTheCallersTimeOfDay() throws {
        let tz = "Asia/Riyadh"
        // 20:15 local — the shape `addingDays(-90, to: now)` produces for an evening sync, and the
        // exact input that made bucket 0 a partial day.
        let start = try XCTUnwrap(zoned(tz).date(from: DateComponents(
            year: 2026, month: 5, day: 2, hour: 20, minute: 15)))
        let window = HealthKitAdapter.dayAlignedWindow(
            HealthDateRange(start: start, end: start.addingTimeInterval(90 * 86_400)), tz: tz)

        let parts = zoned(tz).dateComponents([.hour, .minute, .second], from: window.start)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0,
                       "INGESTION-02: a window starting at the caller's HH:MM makes the first "
                           + "statistics bucket a partial day, which then overwrites the real total")
    }

    /// The invariant that was actually violated. The anchor was already midnight; the predicate
    /// was not. Nothing downstream can be correct while those two disagree, so pin them equal.
    func testTheStatisticsAnchorAndThePredicateStartAgree() throws {
        let tz = "Asia/Riyadh"
        let start = try XCTUnwrap(zoned(tz).date(from: DateComponents(
            year: 2026, month: 5, day: 2, hour: 20, minute: 15)))
        let window = HealthKitAdapter.dayAlignedWindow(
            HealthDateRange(start: start, end: start.addingTimeInterval(86_400)), tz: tz)

        XCTAssertEqual(window.anchor, window.start,
                       "the bucket anchor and the predicate must describe the same instant — the "
                           + "gap between them WAS the bug")
    }

    /// Widening only. A window that moved forward would drop the very hours the fix exists to
    /// recover, and one that moved back a whole day would re-read a day nobody asked for.
    func testTheDailySumWindowWidensBackwardsByLessThanOneDay() throws {
        let tz = "Asia/Riyadh"
        for hour in [0, 1, 12, 20, 23] {
            let start = try XCTUnwrap(zoned(tz).date(from: DateComponents(
                year: 2026, month: 5, day: 2, hour: hour, minute: 30)))
            let window = HealthKitAdapter.dayAlignedWindow(
                HealthDateRange(start: start, end: start.addingTimeInterval(86_400)), tz: tz)

            XCTAssertLessThanOrEqual(window.start, start, "the window must never narrow (hour \(hour))")
            XCTAssertGreaterThan(window.start, start.addingTimeInterval(-86_400),
                                 "the window must not reach back past the containing day (hour \(hour))")
        }
    }

    /// The `to` end is deliberately the caller's. On the live path the last bucket is today, which
    /// is legitimately partial-so-far and is corrected by the next sync; snapping it forward would
    /// invent a day that has not happened.
    func testTheDailySumWindowLeavesTheCallersEndAlone() throws {
        let tz = "Asia/Riyadh"
        let start = try XCTUnwrap(zoned(tz).date(from: DateComponents(
            year: 2026, month: 5, day: 2, hour: 20, minute: 15)))
        let end = start.addingTimeInterval(37 * 3_600)
        let window = HealthKitAdapter.dayAlignedWindow(HealthDateRange(start: start, end: end), tz: tz)

        XCTAssertEqual(window.end, end)
    }

    /// Midnight is a property of the user's zone, not of UTC — the alignment has to move with the
    /// zone or a user east of Greenwich gets a window starting mid-afternoon the day before.
    func testTheDailySumWindowIsMidnightInTheGivenZoneNotUTC() throws {
        let instant = Date(timeIntervalSince1970: 1_777_000_000)
        for tz in ["Asia/Riyadh", "America/New_York", "Australia/Sydney"] {
            let window = HealthKitAdapter.dayAlignedWindow(
                HealthDateRange(start: instant, end: instant.addingTimeInterval(86_400)), tz: tz)
            let parts = zoned(tz).dateComponents([.hour, .minute, .second], from: window.start)
            XCTAssertEqual([parts.hour, parts.minute, parts.second], [0, 0, 0],
                           "window start must be local midnight in \(tz)")
        }
    }

    /// A spring-forward day has no 00:00–01:00 hour in some zones and is 23 hours long in most.
    /// `startOfDay` is the calendar's answer to that, and this pins that the window uses it rather
    /// than subtracting a fixed 86,400.
    func testTheDailySumWindowIsCorrectAcrossASpringForwardBoundary() throws {
        let tz = "America/New_York" // DST begins 2026-03-08
        let start = try XCTUnwrap(zoned(tz).date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 20, minute: 15)))
        let window = HealthKitAdapter.dayAlignedWindow(
            HealthDateRange(start: start, end: start.addingTimeInterval(86_400)), tz: tz)

        XCTAssertTrue(zoned(tz).isDate(window.start, inSameDayAs: start),
                      "the window must land on the same local day the caller's start falls in")
        let parts = zoned(tz).dateComponents([.hour, .minute, .second], from: window.start)
        XCTAssertEqual([parts.hour, parts.minute, parts.second], [0, 0, 0])
    }

    /// (AUDIT 2026-08-06) The repair guarantee, and the promise the Fetch Health history copy now
    /// makes in place of the old "it never changes what you already have": a second read that
    /// disagrees with what is stored CORRECTS the stored row.
    ///
    /// This is the mechanism a user's recovery from INGESTION-02 depends on. Those days cannot be
    /// repaired from anything on the device — `interval_records` upserts in place on
    /// `(metric_id, external_id, source_id)` with no revision chain, so the correct total the
    /// earlier syncs wrote is gone — and Health is the only remaining source of truth. If this
    /// upsert ever became append-or-ignore, the truncated days would be unrepairable.
    func testARereadCorrectsADailyTotalThatWasStoredWrong() throws {
        let pipeline = makeIngestion()
        let dayStart = DayAttribution.startOfDay(clock.now(), tz: "UTC")
        let store = DailyTotalStore(dayStart: dayStart)

        // The truncated total a partial first bucket produced.
        store.value = 240
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        XCTAssertEqual(try measurements.intervalRecords(metricId: MetricID.steps).first?.value, 240)

        // The repair: Health is re-read over a day-aligned window and hands back the real total.
        store.value = 11_400
        _ = try pipeline.ingest(from: store, range: range)

        let rows = try measurements.intervalRecords(metricId: MetricID.steps)
        XCTAssertEqual(rows.count, 1, "the repair must correct the day in place, not add a second row")
        XCTAssertEqual(rows.first?.value, 11_400,
                       "a re-read that disagrees with the stored value must win — this is the only "
                           + "path by which an INGESTION-02 day is recoverable")
    }

    // MARK: - Fixtures

    /// One recomputed daily total for a fixed day, whose value the test can change between syncs —
    /// standing in for Health answering the same day-keyed query differently on a later read.
    private final class DailyTotalStore: HealthStorePort {
        var value: Double = 0
        let dayStart: Date
        init(dayStart: Date) { self.dayStart = dayStart }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_steps", displayName: "Phone", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
            [IntervalDTO(metricId: MetricID.steps, value: value, unit: "count",
                         start: dayStart, end: dayStart.addingTimeInterval(86_400), tz: "UTC",
                         aggregation: .sum, sourceId: "src_steps", deviceId: nil,
                         // The stable day-keyed identity every cumulative read emits — the reason a
                         // re-read addresses the same row instead of inserting beside it.
                         externalId: "healthkit-steps-\(DayAttribution.localDayKey(dayStart, tz: "UTC"))",
                         qualityFlags: [], isRecomputedDailyTotal: true)]
        }
    }

    /// One heart-rate sample, then (once `phase` flips) its deletion — never both at once, like
    /// a real anchored-query delta across two syncs.
    private final class DeletableHeartRateStore: HealthStorePort {
        var phase = 0
        let start: Date
        let externalId = "hk-uuid-fixed-1"

        init(start: Date) { self.start = start }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_hk", displayName: "HK", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
            guard phase == 0 else { return [] }
            return [SampleDTO(metricId: MetricID.heartRate, value: 70, unit: "bpm", start: start,
                              tz: "UTC", sourceId: "src_hk", externalId: externalId)]
        }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
        func deletions(_ range: HealthDateRange) -> HealthStoreDeletions {
            guard phase == 1 else { return HealthStoreDeletions() }
            return HealthStoreDeletions(samples: [DeletedExternalRecord(metricId: MetricID.heartRate, externalId: externalId)])
        }
    }

    /// Simulates `HealthKitAdapter`'s night-rebuild seam (BUG-11): the identity is night-keyed
    /// (`"healthkit-sleep-<sourceId>-<night>"`, mirroring the real adapter after this fix), and
    /// each ingest returns the FULL current picture for the night — never just a delta — exactly
    /// what a correct night-rebuilding adapter must hand the pipeline.
    private final class NightRebuildSleepStore: HealthStorePort {
        var phase = 0
        let night: String
        let tz: String
        let nightEnd: Date
        let sourceId = "src_watch_test"

        init(night: String, tz: String, nightEnd: Date) {
            self.night = night; self.tz = tz; self.nightEnd = nightEnd
        }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: sourceId, displayName: "Test Watch", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            let externalId = "healthkit-sleep-\(sourceId)-\(night)"
            let session: SessionDTO
            switch phase {
            case 0:
                // First half only: 2h asleep -> nap.
                let start = nightEnd.addingTimeInterval(-2 * 3600)
                session = SessionDTO(kind: .sleepNap, start: start, end: nightEnd, tz: tz, sourceId: sourceId,
                                     externalId: externalId, timeAsleepSeconds: 2 * 3600, timeInBedSeconds: 2 * 3600)
            default:
                // Full night, once the rest has synced: 8h asleep -> primary.
                let start = nightEnd.addingTimeInterval(-8 * 3600)
                session = SessionDTO(kind: .sleepPrimary, start: start, end: nightEnd, tz: tz, sourceId: sourceId,
                                     externalId: externalId, timeAsleepSeconds: 8 * 3600, timeInBedSeconds: 8 * 3600)
            }
            return [session].filter { $0.end >= range.start && $0.end <= range.end }
        }
    }

    /// Counts `commitPendingAnchors()` calls; every other read is empty.
    private final class CountingCommitStore: HealthStorePort {
        private(set) var commitCount = 0
        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_x", displayName: "X", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
        func commitPendingAnchors() { commitCount += 1 }
    }

    /// Every family EPIC-01/EPIC-03 added, delivered in one pass, counting
    /// `commitPendingAnchors()` calls. Values mirror what `HKTypeMap` says each type is read in
    /// (note SpO2 and body fat arrive as `fraction`, the `HKUnit.percent()` shape).
    private final class WidenedFamiliesStore: HealthStorePort {
        private(set) var commitCount = 0
        let now: Date

        init(now: Date) { self.now = now }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_widened", displayName: "Widened", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
            [(MetricID.heartRate, 68.0, "bpm"), (MetricID.spo2, 0.97, "fraction"),
             (MetricID.weight, 79.4, "kg"), (MetricID.bodyFatPercentage, 0.183, "fraction"),
             (MetricID.leanMass, 58.2, "kg")].enumerated().map { i, spec in
                SampleDTO(metricId: spec.0, value: spec.1, unit: spec.2,
                          start: now.addingTimeInterval(Double(-i) * 60), tz: "UTC",
                          sourceId: "src_widened", externalId: "widened-sample-\(i)")
            }
        }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] {
            [(MetricID.restingHeartRate, 56.0, "bpm", Aggregation.mean),
             (MetricID.hrv, 42.5, "ms", .mean),
             (MetricID.respiratoryRate, 14.2, "breaths/min", .mean),
             (MetricID.vo2Max, 48.6, "mL/kg/min", .latest),
             (MetricID.activeEnergy, 500, "kcal", .sum),
             (MetricID.restingEnergy, 1_600, "kcal", .sum),
             (MetricID.distance, 6_500, "m", .sum),
             (MetricID.floors, 12, "count", .sum)].enumerated().map { i, spec in
                IntervalDTO(metricId: spec.0, value: spec.1, unit: spec.2,
                            start: now.addingTimeInterval(Double(-i) * 3600),
                            end: now.addingTimeInterval(Double(-i) * 3600 + 3600), tz: "UTC",
                            aggregation: spec.3, sourceId: "src_widened",
                            externalId: "widened-interval-\(i)")
            }
        }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            [SessionDTO(kind: .sleepPrimary, start: now.addingTimeInterval(-8 * 3600), end: now,
                        tz: "UTC", sourceId: "src_widened", externalId: "widened-sleep",
                        timeAsleepSeconds: 7 * 3600, timeInBedSeconds: 8 * 3600)]
        }
        func readWorkouts(_ range: HealthDateRange) -> [WorkoutDTO] {
            [WorkoutDTO(activityType: "running", start: now.addingTimeInterval(-3600), end: now,
                        tz: "UTC", sourceId: "src_widened", externalId: "widened-workout",
                        sourceWorkoutUUID: "uuid-widened-workout",
                        totals: WorkoutTotals(energyKcal: 420, distanceMeters: 8_000))]
        }
        func commitPendingAnchors() { commitCount += 1 }
    }

    /// (INGESTION-01) One night reported by two sources — a watch and a phone sleep app — with
    /// `withDescriptors` switching between the live-sync shape (descriptors supplied) and the
    /// historical-import shape (`sourceDescriptors()` deliberately empty, as
    /// `HistoricalHealthKitReader` returns).
    ///
    /// Neither descriptor carries an explicit `priority`, so the tiers come from the same
    /// name-keyword inference the stored catalog has to reproduce: "Apple Watch" -> 2,
    /// "iPhone" -> 1. The phone's cluster fully contains the watch's, so they overlap 1.0 and
    /// exactly one of them survives — priority decides which, unless every source ties at 0, at
    /// which point duration decides and the phone takes the night.
    private struct TwoSourceNightStore: HealthStorePort {
        static let watchSource = "src_watch_ing01"
        static let phoneSource = "src_phone_ing01"
        static let watchAsleepSeconds: Double = 7 * 3600 + 5 * 60   // 7h05m
        static let phoneAsleepSeconds: Double = 8 * 3600 + 20 * 60  // 8h20m

        let night: String
        let tz: String
        let nightEnd: Date
        let withDescriptors: Bool

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            guard withDescriptors else { return [] }
            return [
                SourceDescriptor(id: Self.watchSource, displayName: "Apple Watch", type: .healthkit,
                                 deviceId: "dev_watch_ing01", deviceName: "Apple Watch",
                                 deviceModel: "Watch7,1", priority: 0),
                SourceDescriptor(id: Self.phoneSource, displayName: "Sleep App", type: .healthkit,
                                 deviceId: "dev_phone_ing01", deviceName: "iPhone",
                                 deviceModel: "iPhone16,1", priority: 0),
            ]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            // The phone's in-bed cluster brackets the watch's, so overlap is 1.0 both ways.
            [SessionDTO(kind: .sleepPrimary,
                        start: nightEnd.addingTimeInterval(-Self.watchAsleepSeconds), end: nightEnd,
                        tz: tz, sourceId: Self.watchSource, deviceId: "dev_watch_ing01",
                        externalId: "healthkit-sleep-\(Self.watchSource)-\(night)",
                        timeAsleepSeconds: Self.watchAsleepSeconds,
                        timeInBedSeconds: Self.watchAsleepSeconds),
             SessionDTO(kind: .sleepPrimary,
                        start: nightEnd.addingTimeInterval(-Self.phoneAsleepSeconds - 600),
                        end: nightEnd.addingTimeInterval(-600),
                        tz: tz, sourceId: Self.phoneSource, deviceId: "dev_phone_ing01",
                        externalId: "healthkit-sleep-\(Self.phoneSource)-\(night)",
                        timeAsleepSeconds: Self.phoneAsleepSeconds,
                        timeInBedSeconds: Self.phoneAsleepSeconds)]
                .filter { $0.end >= range.start && $0.end <= range.end }
        }
    }

    /// (SLEEP-H1) One source, one night, two DISJOINT primary clusters — the split night the
    /// adapter really produces when a wake gap exceeds `sleepClusterGapSeconds` and both halves
    /// clear the 3h `sleepPrimaryMinSeconds` bar. They do not overlap, so `DedupLite` suppresses
    /// neither and both are live rows for the same `local_night`.
    private struct SplitNightSleepStore: HealthStorePort {
        static let firstAsleep: Double = 5 * 3600
        static let secondAsleep: Double = 3.5 * 3600
        let sourceId = "src_split_h1"

        let night: String
        let tz: String
        let nightEnd: Date

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: sourceId, displayName: "Split Watch", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            let secondStart = nightEnd.addingTimeInterval(-Self.secondAsleep)
            let firstEnd = secondStart.addingTimeInterval(-4 * 3600) // a 4h gap: two clusters
            return [SessionDTO(kind: .sleepPrimary,
                               start: firstEnd.addingTimeInterval(-Self.firstAsleep), end: firstEnd,
                               tz: tz, sourceId: sourceId,
                               externalId: "healthkit-sleep-\(sourceId)-\(night)",
                               timeAsleepSeconds: Self.firstAsleep, timeInBedSeconds: Self.firstAsleep),
                    SessionDTO(kind: .sleepPrimary, start: secondStart, end: nightEnd,
                               tz: tz, sourceId: sourceId,
                               externalId: "healthkit-sleep-\(sourceId)-\(night)-1",
                               timeAsleepSeconds: Self.secondAsleep, timeInBedSeconds: Self.secondAsleep)]
                .filter { $0.end >= range.start && $0.end <= range.end }
        }
    }

    /// (SLEEP-H2) The trailing-cluster deletion, in the shape a real full-night rebuild produces:
    /// phase 0 emits the night plus an afternoon nap (`base` and `base-1`, the positional ids
    /// `disambiguateWithinNight` mints), phase 1 emits only the night because the nap was deleted
    /// in Health. It claims the rebuild the way `HealthKitAdapter` does, so the pipeline may hold
    /// the stored night to what it just handed over.
    ///
    /// `claimsRebuilds` turns the claim off, standing in for a port that cannot distinguish "no
    /// sleep here" from "I could not read this night" — that port must never trigger a prune.
    private final class RebuiltNightStore: HealthStorePort, SleepNightRebuilding {
        static let nightAsleep: Double = 7 * 3600
        static let napAsleep: Double = 45 * 60

        var phase = 0
        var claimsRebuilds = true
        let sourceId = "src_rebuild_h2"
        let night: String
        let tz: String
        let nightEnd: Date

        init(night: String, tz: String, nightEnd: Date) {
            self.night = night; self.tz = tz; self.nightEnd = nightEnd
        }

        var nightExternalId: String { "healthkit-sleep-\(sourceId)-\(night)" }
        /// The positional suffix `disambiguateWithinNight` gives the night's second cluster — and
        /// precisely the id the rebuild stops emitting once that cluster is gone.
        var napExternalId: String { "\(nightExternalId)-1" }

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: sourceId, displayName: "Rebuild Watch", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            // The night ends in the morning; the nap sits well after it, same local night.
            let nightStart = nightEnd.addingTimeInterval(-Self.nightAsleep)
            var out = [SessionDTO(kind: .sleepPrimary, start: nightStart, end: nightEnd, tz: tz,
                                  sourceId: sourceId, externalId: nightExternalId,
                                  timeAsleepSeconds: Self.nightAsleep, timeInBedSeconds: Self.nightAsleep)]
            if phase == 0 {
                let napStart = nightEnd.addingTimeInterval(4 * 3600)
                out.append(SessionDTO(kind: .sleepNap, start: napStart,
                                      end: napStart.addingTimeInterval(Self.napAsleep), tz: tz,
                                      sourceId: sourceId, externalId: napExternalId,
                                      timeAsleepSeconds: Self.napAsleep, timeInBedSeconds: Self.napAsleep))
            }
            return out.filter { $0.end >= range.start && $0.end <= range.end }
        }
        func rebuiltSleepNights(_ range: HealthDateRange) -> Set<String> {
            claimsRebuilds ? [night] : []
        }
    }

    /// One heart-rate sample carrying `.tzAssumed`, as a real adapter would when its per-sample
    /// timezone lookup fell back to the device clock.
    private struct TzAssumedSampleStore: HealthStorePort {
        let start: Date
        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_tz", displayName: "TZ", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] {
            [SampleDTO(metricId: MetricID.heartRate, value: 65, unit: "bpm", start: start, tz: "UTC",
                      sourceId: "src_tz", externalId: "tz-sample-1", qualityFlags: [.tzAssumed])]
        }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    }
}
