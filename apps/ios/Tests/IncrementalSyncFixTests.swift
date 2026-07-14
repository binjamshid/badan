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

    // MARK: - Fixtures

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
