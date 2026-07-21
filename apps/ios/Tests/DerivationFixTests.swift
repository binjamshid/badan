import XCTest
@testable import BADAN

/// Regression coverage for the panel-review 2026-07-14 data-correctness fixes: DATA-01
/// (sleep rollup day attribution), DATA-02 (percent/registry unit completeness), DATA-05
/// (stale rollup superseded on a dedup winner flip), DATA-10 (baseline window excludes the
/// evaluation day), and FIX-08 (Arabic insight rendering uses Arabic tokens, not Latin ones).
final class DerivationFixTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-derivation-fix-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - DATA-02: percent conversion + registry-canonical completeness

    func testPercentUnitConvertsAsFraction() throws {
        // Registry canonicals spell this "percent" (SpO2, body fat %, sleep efficiency); a
        // 97% SpO2 reading must round-trip through the fraction base without throwing or
        // silently falling back to `.estimate`.
        XCTAssertEqual(try Units.convert(97, from: "percent", to: "fraction"), 0.97, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(0.55, from: "fraction", to: "percent"), 55, accuracy: 0.0001)
        // "%" and "percent" must agree — both spellings appear across the codebase/registry.
        XCTAssertEqual(try Units.convert(42, from: "percent", to: "%"), 42, accuracy: 0.0001)
    }

    func testRegistryCanonicalAndDisplayUnitsAreAllKnown() throws {
        // Loads the registry the same way `MetricRegistry` does (bundled registry.json via
        // `MetricRegistry.shared`), then asserts `Units.unknownUnits` — previously a dead
        // guard with zero callers — is empty over every canonical AND display unit any
        // metric actually declares. A gap here means that metric's ingestion would silently
        // fall back to `.estimate` for any raw value in a non-matching unit.
        let registry = MetricRegistry.shared
        var allUnits = Set<String>()
        for def in registry.all {
            allUnits.insert(def.canonicalUnit)
            allUnits.formUnion(def.displayUnits)
        }
        allUnits.remove("") // a few fallback/empty-unit metrics are legitimately unitless
        let unknown = Units.unknownUnits(in: allUnits)
        XCTAssertTrue(unknown.isEmpty, "registry units missing from Units.table: \(unknown.sorted())")
    }

    // MARK: - DATA-01: sleep rollup is attributed to the night it ends, not the bedtime evening

    func testSleepRollupSurfacesOnTheNightItEnds() throws {
        let tz = "UTC"
        // Bedtime the evening before, waking up the next morning — the classic cross-midnight
        // sleep session whose rollup must land on the WAKE morning ("the night"), not the
        // bedtime evening.
        // 1_800_000_000 is 08:00 UTC — shift to 22:00 UTC so bedtime + 7h genuinely crosses midnight.
        let bedtime = Date(timeIntervalSince1970: 1_800_000_000 + 14 * 3600)
        let wake = bedtime.addingTimeInterval(7 * 3600)
        let night = DayAttribution.localNight(sessionEnd: wake, tz: tz)
        let bedtimeDay = DayAttribution.localDayKey(bedtime, tz: tz)
        XCTAssertNotEqual(night, bedtimeDay, "test fixture must actually cross a local-day boundary")

        let store = SingleSleepSessionStore(bedtime: bedtime, wake: wake, tz: tz)
        let pipeline = IngestionPipeline(measurements: MeasurementRepository(db.main),
                                         catalog: CatalogRepository(db.main),
                                         reconciliation: ReconciliationRepository(db.main),
                                         registry: .shared, clock: FixedClock(wake), deviceId: deviceId)
        let range = HealthDateRange(start: bedtime.addingTimeInterval(-3600), end: wake.addingTimeInterval(3600))
        _ = try pipeline.ingest(from: store, range: range)

        let measurements = MeasurementRepository(db.main)
        let records = try measurements.intervalRecords(metricId: MetricID.timeAsleep,
                                                        from: bedtime.addingTimeInterval(-2 * 86_400),
                                                        to: wake.addingTimeInterval(2 * 86_400))
        let record = try XCTUnwrap(records.first, "the nightly sleep rollup should have been created")
        XCTAssertEqual(DayAttribution.localDayKey(record.startAt, tz: record.tzId), night,
                       "the rollup's own day-bucketing key (startAt) must equal the night it summarizes, " +
                       "matching the contract in DayAttribution.localNight")
        // Real bedtime lineage must still be recoverable via provenance, even though the row's
        // own startAt is now day-anchored rather than clock-anchored.
        XCTAssertEqual(record.provenance.measuredAt, bedtime,
                       "provenance.measuredAt should still carry the real bedtime for lineage/provenance UI")
    }

    // MARK: - DATA-05: a dedup winner flip must supersede, not duplicate, the prior rollup

    func testStaleSleepRollupSupersededOnDedupWinnerFlip() throws {
        let tz = "UTC"
        let bedtime = Date(timeIntervalSince1970: 1_800_000_000)
        let wake = bedtime.addingTimeInterval(7 * 3600)
        let range = HealthDateRange(start: bedtime.addingTimeInterval(-3600), end: wake.addingTimeInterval(3600))
        let dayStart = try XCTUnwrap(DayAttribution.date(fromDayKey: DayAttribution.localNight(sessionEnd: wake, tz: tz), tz: tz))
        let dayEnd = DayAttribution.addingDays(1, to: dayStart, tz: tz)

        let measurements = MeasurementRepository(db.main)
        let pipeline = IngestionPipeline(measurements: measurements, catalog: CatalogRepository(db.main),
                                         reconciliation: ReconciliationRepository(db.main),
                                         registry: .shared, clock: FixedClock(wake), deviceId: deviceId)

        // Round 1: source A outranks source B.
        _ = try pipeline.ingest(from: TwoSourceSleepStore(aWins: true, bedtime: bedtime, wake: wake, tz: tz), range: range)
        let afterFirst = try measurements.intervalRecords(metricId: MetricID.timeAsleep, from: dayStart, to: dayEnd)
        XCTAssertEqual(afterFirst.count, 1, "exactly one visible nightly rollup after the first ingest")
        XCTAssertEqual(afterFirst.first?.provenance.sourceId, "src_A")

        // Round 2: same night, same sessions, but B now outranks A (e.g. a device-priority
        // change) — the dedup winner flips.
        _ = try pipeline.ingest(from: TwoSourceSleepStore(aWins: false, bedtime: bedtime, wake: wake, tz: tz), range: range)
        let afterFlip = try measurements.intervalRecords(metricId: MetricID.timeAsleep, from: dayStart, to: dayEnd)
        XCTAssertEqual(afterFlip.count, 1,
                       "DATA-05: a dedup winner flip must not leave two visible rollups for the same night")
        XCTAssertEqual(afterFlip.first?.provenance.sourceId, "src_B", "the new winner's rollup should be the visible one")

        let allRows = try measurements.intervalRecords(metricId: MetricID.timeAsleep, from: dayStart, to: dayEnd,
                                                        includeSuppressed: true)
        XCTAssertEqual(allRows.count, 2, "the old winner's rollup should be suppressed, not deleted (INVARIANT I3)")
    }

    // MARK: - DATA-10: the evaluation day is excluded from its own baseline window

    func testBaselineWindowExcludesEvaluationDay() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let todayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let measurements = MeasurementRepository(db.main)
        let derivation = DerivationRepository(db.main)

        func insertRHR(daysAgo: Int, value: Double) throws {
            let day = DayAttribution.addingDays(-daysAgo, to: todayStart, tz: tz)
            let record = IntervalRecord(
                id: ULID.newID(), metricId: MetricID.restingHeartRate, value: value, unit: "bpm",
                startAt: day, endAt: DayAttribution.addingDays(1, to: day, tz: tz), tzId: tz, aggregation: .mean,
                provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, measuredAt: day,
                                      measuredTimezone: tz, recordedAt: day, ingestedAt: day),
                updatedAt: day, originDeviceId: deviceId)
            try measurements.upsertIntervalRecord(record)
        }

        // 14 prior days at a steady 50 bpm, then TODAY's own wild outlier.
        for daysAgo in 1...14 { try insertRHR(daysAgo: daysAgo, value: 50) }
        try insertRHR(daysAgo: 0, value: 500)

        let engine = BaselineEngine(derivation: derivation, measurements: measurements,
                                    registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
        try engine.recompute(metricId: MetricID.restingHeartRate, asOf: asOf, tz: tz)

        let baseline = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate))
        XCTAssertEqual(baseline.nPoints, 14, "only the 14 prior days should feed the band, not today's own value")
        XCTAssertEqual(baseline.center, 50, accuracy: 0.001,
                       "today's own outlier must not be able to drag the band it's then judged against")
        XCTAssertEqual(baseline.position(of: 500), .above,
                       "today's outlier should read as clearly outside a band that excludes it")
    }

    // MARK: - FIX-08: Arabic insight rendering uses Arabic duration/unit tokens

    func testArabicInsightRenderingUsesArabicTokensNotLatin() throws {
        let tz = "UTC"
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)

        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        let insights = InsightRepository(db.main)

        // A confident baseline centered exactly on today's own value -> `.within` -> the
        // "vitals_within_band" template, which fills both {value} and {baseline}.
        try derivation.upsertBaseline(Baseline(
            id: ULID.newID(), metricId: MetricID.restingHeartRate, windowDays: 14, center: 60,
            spread: 1, bandLow: 55, bandHigh: 65, nPoints: 14, provisional: false,
            algorithmVersion: BaselineEngine.baselineAlgorithm.id, validFrom: asOf, computedAt: asOf, unit: "bpm"))

        let record = IntervalRecord(
            id: ULID.newID(), metricId: MetricID.restingHeartRate, value: 60, unit: "bpm",
            startAt: dayStart, endAt: DayAttribution.addingDays(1, to: dayStart, tz: tz), tzId: tz, aggregation: .mean,
            provenance: Provenance(sourceId: "src", ingestionPath: .platformStore, measuredAt: dayStart,
                                  measuredTimezone: tz, recordedAt: dayStart, ingestedAt: dayStart),
            updatedAt: dayStart, originDeviceId: deviceId)
        try measurements.upsertIntervalRecord(record)

        try InsightEngine(insights: insights, derivation: derivation, measurements: measurements,
                          templates: .shared, registry: .shared, clock: FixedClock(asOf), deviceId: deviceId)
            .generate(forDay: asOf, tz: tz)

        let generated = try insights.recent(limit: 20).filter { $0.metricIds.contains(MetricID.restingHeartRate) }
        let insight = try XCTUnwrap(generated.first)

        XCTAssertTrue(insight.renderedText.en.contains("bpm"), "English rendering keeps the Latin unit token")
        XCTAssertFalse(insight.renderedText.ar.contains("bpm"),
                       "FIX-08: Arabic rendering must not bake in the Latin unit abbreviation")
        XCTAssertTrue(insight.renderedText.ar.contains("ن/د"),
                       "FIX-08: Arabic rendering should use the Arabic bpm abbreviation")
    }

    // MARK: - FINDING #1 (audit 2026-07-20): baselines are append-only, even at a repeated valid_from

    /// The retry-overwrite regression. A persisted score-backfill that is interrupted and retried
    /// re-runs with a FIXED `window.to`, so after an interleaved ingest it recomputes a DIFFERENT
    /// band at the SAME (metric_id, covariate_context, window_days, valid_from). Before migration 6
    /// that natural key was UNIQUE and `upsertBaseline` used `INSERT OR REPLACE`, so the second
    /// write DELETED the first — an in-place overwrite of history, violating I2 on the flagship
    /// auditability differentiator. This asserts both appended rows survive and the newer
    /// `computed_at` reads as current. Confirmed to FAIL (count == 1) against the old
    /// `INSERT OR REPLACE` + unique `idx_baseline_identity`; passes (count == 2) after the fix.
    func testBaselineAppendsAtRepeatedValidFromInsteadOfOverwriting() throws {
        let derivation = DerivationRepository(db.main)
        let validFrom = Date(timeIntervalSince1970: 1_800_000_000)

        func makeBaseline(id: String, center: Double, band: (Double, Double), computedAt: Date) -> Baseline {
            Baseline(id: id, metricId: MetricID.restingHeartRate, windowDays: 14, center: center,
                     spread: 1, bandLow: band.0, bandHigh: band.1, nPoints: 14, provisional: false,
                     algorithmVersion: BaselineEngine.baselineAlgorithm.id, validFrom: validFrom,
                     computedAt: computedAt, unit: "bpm")
        }

        // First backfill pass writes a band centered on 50.
        try derivation.upsertBaseline(makeBaseline(id: ULID.newID(), center: 50, band: (48, 52), computedAt: validFrom))
        // Interrupted-then-retried pass recomputes a DIFFERENT band (an ingest landed between the
        // two attempts) at the SAME natural key, one hour later — a distinct ULID `id`, newer
        // `computed_at`. This is the exact write that `INSERT OR REPLACE` used to delete row #1 for.
        let laterComputedAt = validFrom.addingTimeInterval(3600)
        try derivation.upsertBaseline(makeBaseline(id: ULID.newID(), center: 60, band: (58, 62), computedAt: laterComputedAt))

        // Both rows must remain — nothing is overwritten (I2).
        let rows = try db.main.query(
            "SELECT COUNT(*) AS c FROM baselines WHERE metric_id = ? AND covariate_context = ? AND window_days = ? AND valid_from = ?;",
            [.text(MetricID.restingHeartRate), .text("default"), .int(14), .date(validFrom)])
        XCTAssertEqual(Int(rows.first?.int("c") ?? 0), 2,
                       "a retried backfill must APPEND at a repeated valid_from, not overwrite the prior row")

        // The freshest belief (newer computed_at) is what a reader sees; the older row is retained.
        let latest = try XCTUnwrap(try derivation.latestBaseline(metricId: MetricID.restingHeartRate))
        XCTAssertEqual(latest.center, 60, accuracy: 1e-9,
                       "latestBaseline breaks a shared valid_from by newest computed_at")
        XCTAssertEqual(latest.computedAt, laterComputedAt,
                       "the retained older row must not be able to read as current")
    }

    // MARK: - Fixtures

    /// A single primary-sleep session crossing local midnight, from one source.
    private struct SingleSleepSessionStore: HealthStorePort {
        let bedtime: Date
        let wake: Date
        let tz: String

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [SourceDescriptor(id: "src_solo", displayName: "Solo Source", type: .healthkit, priority: 100)]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            [SessionDTO(kind: .sleepPrimary, start: bedtime, end: wake, tz: tz, sourceId: "src_solo",
                       externalId: "solo-sleep", timeAsleepSeconds: 6 * 3600, timeInBedSeconds: 7 * 3600)]
                .filter { $0.end >= range.start && $0.end <= range.end }
        }
    }

    /// Two heavily-overlapping primary-sleep sessions from two sources, with the winner
    /// controlled by `aWins` — lets a test re-ingest the same night with the dedup priority
    /// order flipped, to exercise DATA-05.
    private struct TwoSourceSleepStore: HealthStorePort {
        let aWins: Bool
        let bedtime: Date
        let wake: Date
        let tz: String

        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] {
            [
                SourceDescriptor(id: "src_A", displayName: "Source A", type: .healthkit, priority: aWins ? 100 : 10),
                SourceDescriptor(id: "src_B", displayName: "Source B", type: .healthkit, priority: aWins ? 50 : 90),
            ]
        }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] {
            [
                SessionDTO(kind: .sleepPrimary, start: bedtime, end: wake, tz: tz, sourceId: "src_A",
                          externalId: "sess-A", timeAsleepSeconds: 6 * 3600, timeInBedSeconds: 7 * 3600),
                // Inset by a minute on each side: near-total overlap (>>70% threshold) so one
                // side is always suppressed regardless of which wins.
                SessionDTO(kind: .sleepPrimary, start: bedtime.addingTimeInterval(60), end: wake.addingTimeInterval(-60),
                          tz: tz, sourceId: "src_B", externalId: "sess-B",
                          timeAsleepSeconds: 6 * 3600, timeInBedSeconds: 7 * 3600 - 120),
            ].filter { $0.end >= range.start && $0.end <= range.end }
        }
    }
}
