import XCTest
import Compression
@testable import BADAN

/// Plan §19 — the Apple Health archive importer.
///
/// These assert the properties the importer exists to guarantee, not merely that it parses XML:
/// every row goes through `IngestionPipeline` (never a direct write) carrying import provenance and
/// a batch id, a re-import is a no-op, overlapping live-sync sleep is reconciled by the SAME
/// dedup-lite pass rather than doubled, an import is undoable in one tap (and undo gives back any
/// live row an imported one had out-ranked), and a large archive imports in chunks and resumes.
final class AppleHealthImportTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"
    /// Fixtures are written in GMT so day-keying in assertions is unambiguous.
    let tz = "GMT"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-ahimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private func makePipeline() -> IngestionPipeline {
        IngestionPipeline(measurements: MeasurementRepository(db.main),
                          catalog: CatalogRepository(db.main),
                          reconciliation: ReconciliationRepository(db.main),
                          registry: .shared, clock: clock, deviceId: deviceId,
                          logging: LoggingRepository(main: db.main, sensitive: db.sensitive))
    }

    private func makeImporter(flushThreshold: Int = 5_000,
                              derivation: DerivationCoordinator? = nil) -> AppleHealthArchiveImporter {
        AppleHealthArchiveImporter(pipeline: makePipeline(),
                                   batches: ImportBatchRepository(db.main),
                                   registry: .shared, derivation: derivation, clock: clock,
                                   flushThreshold: flushThreshold)
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
            effort: EffortEngine(derivation: derivation, measurements: measurements, registry: .shared,
                                 clock: clock, deviceId: deviceId))
    }

    private func count(_ table: String, where clause: String = "1=1") throws -> Int {
        Int(try db.main.query("SELECT COUNT(*) AS c FROM \(table) WHERE \(clause);").first?.int("c") ?? 0)
    }

    private func writeXML(_ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("export-\(UUID().uuidString).xml")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        <ExportDate value="\(appleDate(clock.now()))"/>
        \(body)
        </HealthData>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let appleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private func appleDate(_ date: Date) -> String { appleFormatter.string(from: date) }

    private func daysAgo(_ n: Int, hour: Int = 12) -> Date {
        let day = DayAttribution.addingDays(-n, to: DayAttribution.startOfDay(clock.now(), tz: tz), tz: tz)
        return day.addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func record(type: String, value: String, start: Date, end: Date, unit: String,
                        source: String = "Apple Watch",
                        device: String = "&lt;&lt;HKDevice: 0x1&gt;, name:Apple Watch, model:Watch, hardware:Watch6,1&gt;") -> String {
        """
        <Record type="\(type)" sourceName="\(source)" device="\(device)" unit="\(unit)" \
        creationDate="\(appleDate(start))" startDate="\(appleDate(start))" endDate="\(appleDate(end))" value="\(value)"/>
        """
    }

    private func sleepRecord(value: String, start: Date, end: Date, source: String = "Apple Watch") -> String {
        """
        <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="\(source)" \
        creationDate="\(appleDate(start))" startDate="\(appleDate(start))" endDate="\(appleDate(end))" value="\(value)"/>
        """
    }

    /// One night of staged sleep ending on the morning `nightsAgo` days back.
    private func sleepNight(nightsAgo: Int, source: String = "Apple Watch") -> String {
        let morning = DayAttribution.addingDays(-nightsAgo, to: DayAttribution.startOfDay(clock.now(), tz: tz), tz: tz)
        let bedtime = morning.addingTimeInterval(-2 * 3600)          // 22:00 previous evening
        return [
            sleepRecord(value: "HKCategoryValueSleepAnalysisInBed", start: bedtime, end: bedtime.addingTimeInterval(8 * 3600), source: source),
            sleepRecord(value: "HKCategoryValueSleepAnalysisAsleepCore", start: bedtime.addingTimeInterval(600), end: bedtime.addingTimeInterval(4 * 3600), source: source),
            sleepRecord(value: "HKCategoryValueSleepAnalysisAsleepDeep", start: bedtime.addingTimeInterval(4 * 3600), end: bedtime.addingTimeInterval(6 * 3600), source: source),
            sleepRecord(value: "HKCategoryValueSleepAnalysisAsleepREM", start: bedtime.addingTimeInterval(6 * 3600), end: bedtime.addingTimeInterval(7 * 3600 + 1800), source: source),
        ].joined(separator: "\n")
    }

    // MARK: - 1. Everything routes through the pipeline with import provenance

    func testImportStampsImportPathAndBatchIdOnEveryRow() throws {
        let start = daysAgo(10)
        let xml = try writeXML([
            record(type: "HKQuantityTypeIdentifierHeartRate", value: "62", start: start, end: start, unit: "count/min"),
            record(type: "HKQuantityTypeIdentifierHeartRate", value: "70", start: start.addingTimeInterval(60), end: start.addingTimeInterval(60), unit: "count/min"),
            record(type: "HKQuantityTypeIdentifierBodyMass", value: "70", start: start, end: start, unit: "kg"),
            sleepNight(nightsAgo: 9),
        ].joined(separator: "\n"))

        let result = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        XCTAssertGreaterThan(try count("raw_samples"), 0, "heart rate + body mass should land as raw samples")
        XCTAssertEqual(try count("sessions", where: "kind LIKE 'sleep%'"), 1, "one sleep session for the imported night")

        // I1: nothing was written by any path other than the import.
        XCTAssertEqual(try count("raw_samples", where: "ingestion_path <> 'import'"), 0)
        XCTAssertEqual(try count("sessions", where: "ingestion_path <> 'import' AND kind LIKE 'sleep%'"), 0)
        XCTAssertEqual(try count("raw_samples", where: "batch_id <> '\(result.batchId)'"), 0)
        XCTAssertEqual(try count("sessions", where: "batch_id <> '\(result.batchId)' AND kind LIKE 'sleep%'"), 0)

        let batch = try ImportBatchRepository(db.main).find(id: result.batchId)
        XCTAssertEqual(batch?.state, ImportBatch.stateCompleted)
        XCTAssertEqual(batch?.sourceKind, ImportBatch.appleHealthSourceKind)
        XCTAssertEqual(batch?.fileName, "export.zip")
    }

    // MARK: - 2. Re-import is idempotent

    func testReimportingTheSameArchiveWritesNothingNew() throws {
        let start = daysAgo(12)
        let xml = try writeXML([
            record(type: "HKQuantityTypeIdentifierHeartRate", value: "58", start: start, end: start, unit: "count/min"),
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", value: "55", start: start, end: start, unit: "count/min"),
            record(type: "HKQuantityTypeIdentifierStepCount", value: "1200", start: start, end: start.addingTimeInterval(600), unit: "count"),
            sleepNight(nightsAgo: 11),
        ].joined(separator: "\n"))

        let first = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")
        let samplesAfterFirst = try count("raw_samples")
        let intervalsAfterFirst = try count("interval_records")
        let sessionsAfterFirst = try count("sessions")
        XCTAssertGreaterThan(samplesAfterFirst, 0)

        let second = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        XCTAssertEqual(try count("raw_samples"), samplesAfterFirst, "re-import must not duplicate raw samples")
        XCTAssertEqual(try count("interval_records"), intervalsAfterFirst, "re-import must not duplicate intervals")
        XCTAssertEqual(try count("sessions"), sessionsAfterFirst, "re-import must not duplicate sessions")
        XCTAssertEqual(second.counts["samples"], 0, "second pass creates no new sample rows")
        XCTAssertEqual(second.counts["sessions"], 0, "second pass creates no new session rows")
        XCTAssertEqual(second.batchId, first.batchId, "one batch per archive file, so undo still covers everything")
        XCTAssertEqual(try ImportBatchRepository(db.main).all().count, 1)
    }

    // MARK: - 3. Overlapping live-sync sleep is deduped, not doubled

    func testImportedSleepIsReconciledAgainstLiveSyncForTheSameNight() throws {
        // A night already ingested by "live sync" (the platform-store path).
        let night = 6
        let morning = DayAttribution.addingDays(-night, to: DayAttribution.startOfDay(clock.now(), tz: tz), tz: tz)
        let bedtime = morning.addingTimeInterval(-2 * 3600)
        let live = StubLivePort(session: SessionDTO(
            kind: .sleepPrimary, start: bedtime, end: bedtime.addingTimeInterval(8 * 3600), tz: tz,
            sourceId: "com.apple.health", deviceId: "live-watch",
            externalId: "healthkit-sleep-com.apple.health-\(DayAttribution.localNight(sessionEnd: bedtime.addingTimeInterval(8 * 3600), tz: tz))",
            stages: [StageDTO(stage: .light, start: bedtime.addingTimeInterval(600), end: bedtime.addingTimeInterval(7 * 3600))],
            timeAsleepSeconds: 6.5 * 3600, timeInBedSeconds: 8 * 3600))
        _ = try makePipeline().ingest(from: live, range: HealthDateRange(start: bedtime.addingTimeInterval(-86_400),
                                                                        end: clock.now()))
        XCTAssertEqual(try count("sessions", where: "kind LIKE 'sleep%'"), 1)

        // The same night, arriving again from an Apple Health archive.
        let xml = try writeXML(sleepNight(nightsAgo: night))
        _ = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        let nightKey = DayAttribution.localNight(sessionEnd: bedtime.addingTimeInterval(8 * 3600), tz: tz)
        let all = try MeasurementRepository(db.main).allSleepSessions(localNight: nightKey, includeSuppressed: true)
        let live0nly = try MeasurementRepository(db.main).allSleepSessions(localNight: nightKey, includeSuppressed: false)
        XCTAssertEqual(all.count, 2, "both the live and the imported session are kept — dedup suppresses, never deletes (I3)")
        XCTAssertEqual(live0nly.count, 1, "exactly one survives the night, so the night is not double-counted")
        XCTAssertGreaterThan(try count("dedup_decisions"), 0, "the suppression is journaled and reversible")
    }

    // MARK: - 4. One-tap undo

    func testUndoRemovesEverythingTheImportAddedAndRestoresASuppressedLiveRow() throws {
        let night = 5
        let morning = DayAttribution.addingDays(-night, to: DayAttribution.startOfDay(clock.now(), tz: tz), tz: tz)
        let bedtime = morning.addingTimeInterval(-2 * 3600)
        let nightKey = DayAttribution.localNight(sessionEnd: bedtime.addingTimeInterval(8 * 3600), tz: tz)
        let live = StubLivePort(session: SessionDTO(
            kind: .sleepPrimary, start: bedtime, end: bedtime.addingTimeInterval(8 * 3600), tz: tz,
            sourceId: "com.apple.health", deviceId: "live-watch",
            externalId: "healthkit-sleep-com.apple.health-\(nightKey)",
            stages: [StageDTO(stage: .light, start: bedtime.addingTimeInterval(600), end: bedtime.addingTimeInterval(7 * 3600))],
            timeAsleepSeconds: 6.5 * 3600, timeInBedSeconds: 8 * 3600))
        _ = try makePipeline().ingest(from: live, range: HealthDateRange(start: bedtime.addingTimeInterval(-86_400), end: clock.now()))

        let start = daysAgo(5)
        let xml = try writeXML([
            record(type: "HKQuantityTypeIdentifierHeartRate", value: "61", start: start, end: start, unit: "count/min"),
            record(type: "HKQuantityTypeIdentifierStepCount", value: "900", start: start, end: start.addingTimeInterval(600), unit: "count"),
            sleepNight(nightsAgo: night),
        ].joined(separator: "\n"))
        let importer = makeImporter()
        let result = try importer.importExportXML(xmlURL: xml, fileName: "export.zip")

        XCTAssertGreaterThan(try count("raw_samples", where: "batch_id = '\(result.batchId)'"), 0)

        let undo = try importer.undo(batchId: result.batchId)

        // Nothing an undo removed is visible to any read path — every query filters
        // `deleted_at IS NULL`, so "live rows from this batch" is the count that must be zero.
        XCTAssertEqual(try count("raw_samples", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("interval_records", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("sessions", where: "batch_id = '\(result.batchId)' AND deleted_at IS NULL"), 0)
        XCTAssertEqual(try count("raw_samples", where: "ingestion_path = 'import' AND deleted_at IS NULL"), 0)
        XCTAssertGreaterThan(undo.removedSamples + undo.removedSessions + undo.removedIntervals, 0)
        // ...but the rows are TOMBSTONED, not erased, and the batch row survives with them. Both are
        // load-bearing: the tombstone is what lets a delta export report the removal downstream, and
        // the batch row is what a re-import needs to land back on these same rows.
        XCTAssertGreaterThan(try count("raw_samples", where: "batch_id = '\(result.batchId)' AND deleted_at IS NOT NULL"), 0,
                             "undo must leave a tombstone, or the removal is invisible to a delta consumer")
        let batch = try XCTUnwrap(try ImportBatchRepository(db.main).find(id: result.batchId),
                                  "the batch row outlives its rows so a re-import can find them")
        XCTAssertEqual(batch.state, ImportBatch.stateUndone)
        XCTAssertFalse(batch.isTerminal, "an undone import must not offer 'undo' again")

        // The live-sync night is intact and VISIBLE — undoing an import must never leave the user's
        // own device data suppressed behind a winner that no longer exists.
        let surviving = try MeasurementRepository(db.main).allSleepSessions(localNight: nightKey, includeSuppressed: false)
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.provenance.ingestionPath, .platformStore)
        XCTAssertNil(surviving.first?.provenance.suppressedBy)
    }

    // MARK: - 4b. An undo is visible downstream: a tombstone AND a journaled correction

    /// The A4 finding. Undo used to hard-DELETE, which left no `deleted_at` for
    /// `MeasurementRepository.tombstones(since:)` to find — so a store fed by incremental exports
    /// kept every row an undone import had added. And the un-suppression it performs wrote
    /// `suppressed_by = NULL` with no `dedup_decisions` row, so the authority flip that restored the
    /// user's live session reached no consumer either. Both halves are asserted here through the
    /// exact queries a delta export uses, not through the repository's internals.
    func testUndoLeavesATombstoneAndAJournaledCorrectionADeltaCanCarry() throws {
        let night = 6
        let morning = DayAttribution.addingDays(-night, to: DayAttribution.startOfDay(clock.now(), tz: tz), tz: tz)
        let bedtime = morning.addingTimeInterval(-2 * 3600)
        let nightKey = DayAttribution.localNight(sessionEnd: bedtime.addingTimeInterval(8 * 3600), tz: tz)
        let live = StubLivePort(session: SessionDTO(
            kind: .sleepPrimary, start: bedtime, end: bedtime.addingTimeInterval(8 * 3600), tz: tz,
            sourceId: "com.apple.health", deviceId: "live-watch",
            externalId: "healthkit-sleep-com.apple.health-\(nightKey)",
            stages: [StageDTO(stage: .light, start: bedtime.addingTimeInterval(600), end: bedtime.addingTimeInterval(7 * 3600))],
            timeAsleepSeconds: 6.5 * 3600, timeInBedSeconds: 8 * 3600))
        _ = try makePipeline().ingest(from: live, range: HealthDateRange(start: bedtime.addingTimeInterval(-86_400), end: clock.now()))

        let start = daysAgo(6)
        let xml = try writeXML([
            record(type: "HKQuantityTypeIdentifierHeartRate", value: "61", start: start, end: start, unit: "count/min"),
            sleepNight(nightsAgo: night),
        ].joined(separator: "\n"))
        let importer = makeImporter()
        let result = try importer.importExportXML(xmlURL: xml, fileName: "export.zip")

        // The live session lost the night to the imported one, and that decision was journaled.
        let suppressed = try MeasurementRepository(db.main)
            .allSleepSessions(localNight: nightKey, includeSuppressed: true)
            .first { $0.provenance.ingestionPath == .platformStore }
        let loserId = try XCTUnwrap(suppressed?.id)
        XCTAssertNotNil(suppressed?.provenance.suppressedBy, "the fixture must actually suppress the live row")

        // A watermark placed before the undo, exactly as a delta export's cursor would be.
        let watermark = clock.now()
        clock.advance(by: 60)
        _ = try importer.undo(batchId: result.batchId)

        // (1) The removal is reportable: the delta's own tombstone query finds the imported rows.
        let tombstones = try MeasurementRepository(db.main).tombstones(since: watermark)
        XCTAssertFalse(tombstones.isEmpty, "an undone import must produce tombstones a delta can carry")
        XCTAssertTrue(tombstones.contains { $0.entity == "raw_sample" })
        XCTAssertTrue(tombstones.contains { $0.entity == "session" })

        // (2) The un-suppression is reportable: it is journaled as a REVERSAL, so the same query a
        // delta uses for `corrections[]` reports the live row as no longer suppressed (I3 —
        // reversible AND journaled).
        let flips = try ReconciliationRepository(db.main).decisionsChangedSince(watermark)
        let correction = try XCTUnwrap(flips.first { $0.suppressedRecordId == loserId },
                                       "un-suppressing a row must be journaled, not silent")
        XCTAssertTrue(correction.isReversed, "the flip a consumer must apply is 'no longer suppressed'")
        XCTAssertEqual(correction.reversedAt, clock.now())
    }

    /// Undo must be idempotent. A second undo tombstones nothing and re-stamps nothing — otherwise
    /// each call would push an already-reported removal past the cursor again and a delta consumer
    /// would keep re-receiving removals it had already applied.
    func testASecondUndoIsANoOpAndDoesNotReStampTheTombstone() throws {
        let start = daysAgo(4)
        let xml = try writeXML(record(type: "HKQuantityTypeIdentifierHeartRate", value: "61",
                                      start: start, end: start, unit: "count/min"))
        let importer = makeImporter()
        let result = try importer.importExportXML(xmlURL: xml, fileName: "export.zip")

        let first = try importer.undo(batchId: result.batchId)
        XCTAssertGreaterThan(first.removedSamples, 0)
        let deletedAt = try db.main.query("SELECT deleted_at FROM raw_samples LIMIT 1;").first?.date("deleted_at")
        XCTAssertNotNil(deletedAt)

        clock.advance(by: 3_600)
        let second = try importer.undo(batchId: result.batchId)

        XCTAssertEqual(second.removedSamples, 0)
        XCTAssertNil(second.affectedRange, "nothing left to re-derive over")
        XCTAssertEqual(try db.main.query("SELECT deleted_at FROM raw_samples LIMIT 1;").first?.date("deleted_at"),
                       deletedAt, "the tombstone instant must not move on a repeat undo")
    }

    /// The property the old hard-delete existed to protect, kept: undo followed by a re-import of
    /// the same archive brings the data back. It works now because the upserts carry `deleted_at`
    /// across (`MeasurementRepository.upsertRawSample`) and the batch row survives, so the re-import
    /// resumes the SAME batch and revives the very rows the undo tombstoned — rather than leaving
    /// them invisible under a fresh batch that owns nothing.
    func testReImportAfterAnUndoRevivesTheRowsUnderTheSameBatch() throws {
        let start = daysAgo(4)
        let xml = try writeXML(record(type: "HKQuantityTypeIdentifierHeartRate", value: "61",
                                      start: start, end: start, unit: "count/min"))
        let importer = makeImporter()
        let first = try importer.importExportXML(xmlURL: xml, fileName: "export.zip")
        _ = try importer.undo(batchId: first.batchId)
        XCTAssertEqual(try count("raw_samples", where: "deleted_at IS NULL"), 0)

        clock.advance(by: 3_600)
        let again = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        XCTAssertEqual(again.batchId, first.batchId, "a re-import continues the batch it can still find")
        XCTAssertEqual(try count("raw_samples", where: "deleted_at IS NULL"), 1,
                       "re-importing must bring the data back, not leave it tombstoned forever")
        XCTAssertEqual(try count("raw_samples"), 1, "revived in place — never a second row")
        XCTAssertEqual(try ImportBatchRepository(db.main).find(id: first.batchId)?.state,
                       ImportBatch.stateCompleted)
    }

    // MARK: - 5. Cumulative totals share live sync's identity so they collapse rather than double

    func testCumulativeDailyTotalsUseLiveSyncIdentityAndPickTheHighestPriorityDevice() throws {
        let day = daysAgo(8, hour: 9)
        let dayKey = DayAttribution.localDayKey(day, tz: tz)
        let phoneDevice = "&lt;&lt;HKDevice: 0x2&gt;, name:iPhone, model:iPhone, hardware:iPhone14,5&gt;"
        let xml = try writeXML([
            record(type: "HKQuantityTypeIdentifierStepCount", value: "4000", start: day, end: day.addingTimeInterval(600), unit: "count"),
            record(type: "HKQuantityTypeIdentifierStepCount", value: "2000", start: day.addingTimeInterval(3600), end: day.addingTimeInterval(4200), unit: "count"),
            record(type: "HKQuantityTypeIdentifierStepCount", value: "3500", start: day, end: day.addingTimeInterval(600), unit: "count",
                   source: "iPhone", device: phoneDevice),
        ].joined(separator: "\n"))

        _ = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        let rows = try db.main.query("SELECT * FROM interval_records WHERE metric_id = ?;", [.text(MetricID.steps)])
        XCTAssertEqual(rows.count, 1, "one merged daily total, not one per contributing source")
        XCTAssertEqual(rows.first?.string("external_id"), "healthkit-steps-\(dayKey)",
                       "same per-day identity live sync writes, so the two collapse instead of doubling")
        XCTAssertEqual(rows.first?.string("source_id"), "healthkit")
        // Watch (priority 2) beats iPhone (priority 1): 4000 + 2000, never 9500.
        XCTAssertEqual(rows.first?.double("value") ?? 0, 6000, accuracy: 0.001)

        // A later live sync writing the same day lands on the SAME row.
        let liveTotal = IntervalDTO(metricId: MetricID.steps, value: 6250, unit: "count",
                                    start: DayAttribution.startOfDay(day, tz: tz),
                                    end: DayAttribution.addingDays(1, to: DayAttribution.startOfDay(day, tz: tz), tz: tz),
                                    tz: tz, aggregation: .sum, sourceId: "healthkit",
                                    externalId: "healthkit-steps-\(dayKey)", isRecomputedDailyTotal: true)
        _ = try makePipeline().ingest(from: StubLivePort(interval: liveTotal),
                                      range: HealthDateRange(start: day.addingTimeInterval(-86_400), end: clock.now()))
        let after = try db.main.query("SELECT * FROM interval_records WHERE metric_id = ?;", [.text(MetricID.steps)])
        XCTAssertEqual(after.count, 1, "live sync supersedes the imported total in place — never a second row")
        XCTAssertEqual(after.first?.double("value") ?? 0, 6250, accuracy: 0.001)
    }

    // MARK: - 6. Units

    func testUnitsAreCanonicalizedTheSameWayLiveSyncCanonicalizesThem() throws {
        let t = daysAgo(7)
        let xml = try writeXML([
            // Apple exports the FRACTION under unit="%": 0.97 must become 97, not 0.97.
            record(type: "HKQuantityTypeIdentifierOxygenSaturation", value: "0.97", start: t, end: t, unit: "%"),
            // Locale unit honoured: 154 lb -> ~69.85 kg.
            record(type: "HKQuantityTypeIdentifierBodyMass", value: "154", start: t, end: t, unit: "lb"),
            // Respiratory rate exports count/min but the canonical dimension is breaths/min.
            record(type: "HKQuantityTypeIdentifierRespiratoryRate", value: "14", start: t, end: t, unit: "count/min"),
            // Distance in km must reach the canonical metres.
            record(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", value: "2.5", start: t, end: t.addingTimeInterval(600), unit: "km"),
        ].joined(separator: "\n"))

        _ = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        let measurements = MeasurementRepository(db.main)
        let spo2 = try measurements.rawSamples(metricId: MetricID.spo2)
        XCTAssertEqual(spo2.first?.value ?? 0, 97, accuracy: 0.001)
        XCTAssertEqual(spo2.first?.unit, "percent")

        let weight = try measurements.rawSamples(metricId: MetricID.weight)
        XCTAssertEqual(weight.first?.value ?? 0, 69.8531, accuracy: 0.01)
        XCTAssertEqual(weight.first?.originalUnit, "lb", "the source's own unit is preserved (I1)")

        let rr = try measurements.intervalRecords(metricId: MetricID.respiratoryRate)
        XCTAssertEqual(rr.first?.value ?? 0, 14, accuracy: 0.001)
        XCTAssertFalse(rr.first?.provenance.qualityFlags.contains(.estimate) ?? true,
                       "a correct unit label means no fallback .estimate downgrade")

        let distance = try measurements.intervalRecords(metricId: MetricID.distance)
        XCTAssertEqual(distance.first?.value ?? 0, 2500, accuracy: 0.001)
    }

    // MARK: - 7. Chunked + resumable

    func testLargeArchiveFlushesInChunksAndResumesWithoutDoubleImporting() throws {
        let base = daysAgo(15)
        var records: [String] = []
        for i in 0..<120 {
            records.append(record(type: "HKQuantityTypeIdentifierHeartRate", value: "\(60 + i % 20)",
                                  start: base.addingTimeInterval(Double(i) * 60),
                                  end: base.addingTimeInterval(Double(i) * 60), unit: "count/min"))
        }
        let xml = try writeXML(records.joined(separator: "\n"))

        var progressUpdates: [AppleHealthImportProgress] = []
        let result = try makeImporter(flushThreshold: 10)
            .importExportXML(xmlURL: xml, fileName: "export.zip", progress: { progressUpdates.append($0) })

        XCTAssertEqual(try count("raw_samples"), 120)
        XCTAssertEqual(result.recordsProcessed, 120)
        XCTAssertGreaterThan(progressUpdates.count, 5, "a 120-record archive at a 10-record flush reports progress repeatedly")
        let batches = ImportBatchRepository(db.main)
        XCTAssertEqual(try batches.find(id: result.batchId)?.chunkCursor, "120")

        // Simulate an interruption: the batch never reached `completed`.
        try batches.setState(id: result.batchId, ImportBatch.stateRunning)
        let resumed = try makeImporter(flushThreshold: 10).importExportXML(xmlURL: xml, fileName: "export.zip")

        XCTAssertEqual(resumed.batchId, result.batchId, "a resume continues the same batch")
        XCTAssertEqual(try count("raw_samples"), 120, "resuming re-runs idempotently — never a second copy")
        XCTAssertEqual(resumed.counts["samples"], 0)
        XCTAssertEqual(try batches.find(id: result.batchId)?.state, ImportBatch.stateCompleted)
    }

    func testCancellingLeavesTheBatchResumableAndTheResumeCompletesIt() throws {
        let base = daysAgo(16)
        var records: [String] = []
        for i in 0..<60 {
            records.append(record(type: "HKQuantityTypeIdentifierHeartRate", value: "\(60 + i % 10)",
                                  start: base.addingTimeInterval(Double(i) * 60),
                                  end: base.addingTimeInterval(Double(i) * 60), unit: "count/min"))
        }
        let xml = try writeXML(records.joined(separator: "\n"))

        var seen = 0
        XCTAssertThrowsError(try makeImporter(flushThreshold: 5)
            .importExportXML(xmlURL: xml, fileName: "export.zip", isCancelled: { seen += 1; return seen > 20 })) { error in
            XCTAssertEqual(error as? AppleHealthImportError, .cancelled)
        }

        let batches = ImportBatchRepository(db.main)
        let batch = try XCTUnwrap(try batches.all().first)
        XCTAssertEqual(batch.state, ImportBatch.stateRunning, "a cancelled import stays resumable, never 'completed'")
        let partial = try count("raw_samples")

        let resumed = try makeImporter(flushThreshold: 5).importExportXML(xmlURL: xml, fileName: "export.zip")
        XCTAssertEqual(resumed.batchId, batch.id)
        XCTAssertEqual(try count("raw_samples"), 60, "the resume completes the archive")
        XCTAssertLessThanOrEqual(partial, 60)
        XCTAssertEqual(try count("raw_samples", where: "batch_id <> '\(batch.id)'"), 0,
                       "partial + resumed rows all belong to the one undoable batch")
    }

    // MARK: - 8. Backfilled history is scored, and its rows satisfy the retroactive predicate

    /// Asserts what is actually true today, and no more. The import backfills scores over the span
    /// it imported, and every day-keyed `DerivedValue` it produces is one `BaselineEngine
    /// .isRetroactive` recognises — a day scored long after the fact. `QualityFlag.retroactive`
    /// itself is a read-time label (see its doc) that no read or export path attaches yet, so this
    /// deliberately asserts the predicate over the *stored rows* rather than claiming a flag some
    /// surface returns.
    func testImportedHistoryIsScoredAndItsDayRowsSatisfyTheRetroactivePredicate() throws {
        // Enough nights + heart rate for the score pipeline to have something to chew on.
        var body: [String] = []
        for n in 5...25 {
            body.append(sleepNight(nightsAgo: n))
            let day = daysAgo(n, hour: 10)
            for i in 0..<6 {
                body.append(record(type: "HKQuantityTypeIdentifierHeartRate", value: "\(58 + i)",
                                   start: day.addingTimeInterval(Double(i) * 900),
                                   end: day.addingTimeInterval(Double(i) * 900), unit: "count/min"))
            }
            body.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", value: "\(54 + n % 4)",
                               start: day, end: day, unit: "count/min"))
        }
        let xml = try writeXML(body.joined(separator: "\n"))

        let importer = makeImporter(derivation: makeCoordinator())
        let result = try importer.importExportXML(xmlURL: xml, fileName: "export.zip")
        XCTAssertNotNil(result.dateRange, "the importer knows the span it backfilled")

        // The import fed derivation: rows exist for days long before "now".
        XCTAssertGreaterThan(try count("derived_values"), 0, "imported history is scored, not left inert")

        // Read the rows the backfill actually wrote and run the predicate over THEIR own
        // periodKey/computedAt — the two fields the label is derived from (it is not a column).
        let dayRows = try db.main.query("SELECT period_key, computed_at FROM derived_values;")
            .compactMap { row -> (dayKey: String, computedAt: Date)? in
                guard let key = row.string("period_key"), key.hasPrefix("day:"),
                      let computedAt = row.date("computed_at") else { return nil }
                return (String(key.dropFirst("day:".count)), computedAt)
            }
        XCTAssertFalse(dayRows.isEmpty, "the backfill wrote day-keyed scores for the imported span")
        for row in dayRows {
            XCTAssertTrue(BaselineEngine.isRetroactive(periodDayKey: row.dayKey, computedAt: row.computedAt,
                                                       tz: tz, spec: .defaultShared),
                          "a day scored now from history imported weeks after the fact is retroactive (\(row.dayKey))")
        }

        // The predicate has to discriminate, or the assertion above is worthless: a day scored on
        // the day it describes is not retroactive.
        let todayKey = DayAttribution.localDayKey(clock.now(), tz: tz)
        XCTAssertFalse(BaselineEngine.isRetroactive(periodDayKey: todayKey, computedAt: clock.now(),
                                                    tz: tz, spec: .defaultShared),
                       "today's own score is not retroactive")
    }

    // MARK: - 9. Workouts

    func testWorkoutsImportWithTotalsAndAStableIdentity() throws {
        let start = daysAgo(4, hour: 7)
        let xml = try writeXML("""
        <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="32" durationUnit="min" \
        sourceName="Apple Watch" startDate="\(appleDate(start))" endDate="\(appleDate(start.addingTimeInterval(1920)))">
          <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" sum="5.2" unit="km"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" sum="310" unit="kcal"/>
        </Workout>
        """)

        _ = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")

        let workouts = try MeasurementRepository(db.main).sessions(kind: .workout)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.detail.workout?.activityType, "running")
        XCTAssertEqual(workouts.first?.detail.workout?.totals.distanceMeters ?? 0, 5200, accuracy: 0.5)
        XCTAssertEqual(workouts.first?.detail.workout?.totals.energyKcal ?? 0, 310, accuracy: 0.5)
        XCTAssertEqual(workouts.first?.provenance.ingestionPath, .fileImport)

        // Re-import: same content, same identity, no second workout.
        _ = try makeImporter().importExportXML(xmlURL: xml, fileName: "export.zip")
        XCTAssertEqual(try MeasurementRepository(db.main).sessions(kind: .workout).count, 1)
    }

    // MARK: - 10. The zip front-end

    func testExtractsExportXMLFromAStoredZip() throws {
        let payload = "<?xml version=\"1.0\"?><HealthData locale=\"en_US\"></HealthData>"
        let zip = try writeZip(entryName: "apple_health_export/export.xml",
                               payload: Data(payload.utf8), deflate: false)
        let out = tempDir.appendingPathComponent("out-stored.xml")
        try ZipArchiveReader.extract(entryNamed: "export.xml", from: zip, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), payload)
    }

    func testExtractsExportXMLFromADeflatedZip() throws {
        // Repetitive content so DEFLATE actually compresses, exercising the streaming inflate.
        let payload = String(repeating: "<Record type=\"HKQuantityTypeIdentifierHeartRate\" value=\"62\"/>", count: 500)
        let zip = try writeZip(entryName: "apple_health_export/export.xml",
                               payload: Data(payload.utf8), deflate: true)
        let out = tempDir.appendingPathComponent("out-deflated.xml")
        let written = try ZipArchiveReader.extract(entryNamed: "export.xml", from: zip, to: out)
        XCTAssertEqual(written, payload.utf8.count)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), payload)
    }

    /// A damaged archive — one whose directory promises an entry longer than the file itself — must
    /// fail, not spin. Before the truncation guards in `ZipArchiveReader`, the read loops asked for
    /// bytes past EOF, got an empty `Data` back, and never advanced `remaining`: `isLastBlock` stayed
    /// false forever and the import hung with no error the user could act on. Both compression
    /// methods are covered because each has its own read loop.
    ///
    /// The assertion is "throws a `ReaderError`", not a specific case, and the distinction is real:
    /// the stored path runs to EOF and reports `.ioError`, while the deflate path may reject the
    /// corrupt stream as `.inflateFailed` before it ever gets there. Which one surfaces is an
    /// implementation detail of the inflater; that the import terminates with an error is the
    /// property being pinned, and the test finishing at all is what proves it.
    func testAnEntryLongerThanTheFileFailsInsteadOfLoopingForever() throws {
        for deflate in [false, true] {
            let payload = String(repeating: "<Record value=\"62\"/>", count: 400)
            let zip = try writeZip(entryName: "apple_health_export/export.xml", payload: Data(payload.utf8),
                                   deflate: deflate, truncateEntryBy: 64, overstateCompressedSizeBy: 1_000_000)
            let out = tempDir.appendingPathComponent("out-truncated-\(deflate).xml")
            XCTAssertThrowsError(try ZipArchiveReader.extract(entryNamed: "export.xml", from: zip, to: out),
                                 "a \(deflate ? "deflated" : "stored") entry that runs past EOF must throw") { error in
                XCTAssertTrue(error is ZipArchiveReader.ReaderError,
                              "expected a reader error, got \(error)")
            }
        }
    }

    func testAZipWithoutAnExportXMLIsReportedHonestly() throws {
        let zip = try writeZip(entryName: "something_else.txt", payload: Data("hello".utf8), deflate: false)
        XCTAssertThrowsError(try makeImporter().importArchive(zipURL: zip, fileName: "wrong.zip")) { error in
            XCTAssertEqual(error as? AppleHealthImportError, .noExportXML)
        }
    }

    func testAFullArchiveImportsEndToEndThroughTheZipFrontEnd() throws {
        let start = daysAgo(3)
        let inner = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        \(record(type: "HKQuantityTypeIdentifierHeartRate", value: "64", start: start, end: start, unit: "count/min"))
        \(sleepNight(nightsAgo: 3))
        </HealthData>
        """
        let zip = try writeZip(entryName: "apple_health_export/export.xml", payload: Data(inner.utf8), deflate: true)
        let result = try makeImporter().importArchive(zipURL: zip, fileName: "export.zip")

        XCTAssertEqual(try count("raw_samples"), 1)
        XCTAssertEqual(try count("sessions", where: "kind LIKE 'sleep%'"), 1)
        XCTAssertEqual(try count("raw_samples", where: "batch_id = '\(result.batchId)'"), 1)
    }

    // MARK: - 11. The import screen's model

    /// A progress tick that arrives after the run finished must not reopen the spinner. The ticks
    /// hop to the main actor from the import's queue and the last of them are emitted immediately
    /// before the result, so an unguarded assignment could land after `.done` and leave a completed,
    /// undoable import showing "Importing…" forever.
    @MainActor
    func testALateProgressTickCannotOverwriteAFinishedImport() {
        let model = AppleHealthImportModel()

        model.phase = .running(processed: 10, counts: [:])
        model.publishProgress(AppleHealthImportProgress(phase: .parsing, recordsProcessed: 40, counts: ["samples": 4]))
        guard case .running(let processed, _) = model.phase else { return XCTFail("still running") }
        XCTAssertEqual(processed, 40, "ticks apply while the run is in flight")

        model.phase = .done(batchId: "B", counts: ["samples": 9])
        model.publishProgress(AppleHealthImportProgress(phase: .parsing, recordsProcessed: 41, counts: [:]))
        guard case .done(let batchId, _) = model.phase else { return XCTFail("a late tick reopened the spinner") }
        XCTAssertEqual(batchId, "B")

        model.phase = .failed(LocalizedString(en: "x", ar: "س"))
        model.publishProgress(AppleHealthImportProgress(phase: .parsing, recordsProcessed: 42, counts: [:]))
        guard case .failed = model.phase else { return XCTFail("a late tick overwrote the failure") }
    }

    /// The result line distinguishes three different facts and must not blur them: rows written, an
    /// archive BADAN already held in full (counts present, all zero), and a run that recorded no
    /// counts at all.
    func testSummaryLineSeparatesWroteNothingFromKnowsNothing() {
        let wrote = AppleHealthImportScreen.summaryLine(counts: ["samples": 12, "sessions": 2, "workouts": 1],
                                                        language: .en)
        XCTAssertTrue(wrote.contains("12"), "row counts are shown")
        XCTAssertTrue(wrote.contains("3"), "sleep and workout rows share the sessions table and one label")

        let alreadyHeld = AppleHealthImportScreen.summaryLine(counts: ["samples": 0, "sessions": 0], language: .en)
        XCTAssertFalse(alreadyHeld.isEmpty)
        XCTAssertNotEqual(alreadyHeld, "—", "an all-zero run states that the matching worked")

        XCTAssertEqual(AppleHealthImportScreen.summaryLine(counts: [:], language: .en), "—",
                       "no counts at all claims nothing")
    }

    // MARK: - Zip fixture builder

    /// Build a minimal single-entry ZIP (local header + data + central directory + EOCD). CRC is
    /// written as 0 — `ZipArchiveReader` does not verify it, and a real archive's CRC has no bearing
    /// on the offsets/sizes this exercises.
    ///
    /// The two damage knobs build the corrupt archive the truncation test needs, and both are
    /// required: `truncateEntryBy` drops trailing entry bytes (so a deflate stream has no end
    /// marker and cannot terminate cleanly), while `overstateCompressedSizeBy` inflates the size the
    /// headers advertise past the end of the file (so the reader's bounded read actually reaches
    /// EOF instead of quietly consuming the central directory that follows the entry). Zero for both
    /// — the defaults — writes an ordinary, well-formed archive.
    private func writeZip(entryName: String, payload: Data, deflate: Bool,
                          truncateEntryBy: Int = 0, overstateCompressedSizeBy: Int = 0) throws -> URL {
        let full: Data = deflate ? try Self.rawDeflate(payload) : payload
        let stored = full.prefix(max(full.count - truncateEntryBy, 0))
        let declaredCompressed = UInt32(full.count + overstateCompressedSizeBy)
        let method: UInt16 = deflate ? 8 : 0
        let nameBytes = Data(entryName.utf8)

        var out = Data()
        func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func u32(_ v: UInt32) -> Data {
            Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }

        let localOffset = UInt32(out.count)
        out.append(u32(0x0403_4b50)); out.append(u16(20)); out.append(u16(0)); out.append(u16(method))
        out.append(u16(0)); out.append(u16(0)); out.append(u32(0))
        out.append(u32(declaredCompressed)); out.append(u32(UInt32(payload.count)))
        out.append(u16(UInt16(nameBytes.count))); out.append(u16(0))
        out.append(nameBytes)
        out.append(stored)

        let cdOffset = UInt32(out.count)
        out.append(u32(0x0201_4b50)); out.append(u16(20)); out.append(u16(20)); out.append(u16(0))
        out.append(u16(method)); out.append(u16(0)); out.append(u16(0)); out.append(u32(0))
        out.append(u32(declaredCompressed)); out.append(u32(UInt32(payload.count)))
        out.append(u16(UInt16(nameBytes.count))); out.append(u16(0)); out.append(u16(0))
        out.append(u16(0)); out.append(u16(0)); out.append(u32(0)); out.append(u32(localOffset))
        out.append(nameBytes)
        let cdSize = UInt32(out.count) - cdOffset

        out.append(u32(0x0605_4b50)); out.append(u16(0)); out.append(u16(0))
        out.append(u16(1)); out.append(u16(1)); out.append(u32(cdSize)); out.append(u32(cdOffset)); out.append(u16(0))

        let url = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        try out.write(to: url)
        return url
    }

    /// Raw DEFLATE (what a ZIP method-8 entry stores) via the same framework the reader inflates with.
    private static func rawDeflate(_ input: Data) throws -> Data {
        let capacity = max(input.count * 2, 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let written = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(dst, capacity,
                                      raw.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw AppleHealthImportError.cannotReadXML }
        return Data(bytes: dst, count: written)
    }
}

// MARK: - Stubs

/// A minimal live-sync `HealthStorePort` for the overlap tests: it stands in for HealthKit
/// delivering a session (or a merged daily total) through the ordinary platform-store path.
private final class StubLivePort: HealthStorePort {
    private let session: SessionDTO?
    private let interval: IntervalDTO?

    init(session: SessionDTO? = nil, interval: IntervalDTO? = nil) {
        self.session = session
        self.interval = interval
    }

    func availability() -> HealthAvailability { .available }

    func sourceDescriptors() -> [SourceDescriptor] {
        [SourceDescriptor(id: "com.apple.health", displayName: "Apple Watch", type: .healthkit,
                          bundleId: "com.apple.health", deviceId: "live-watch", deviceName: "Apple Watch",
                          deviceModel: "Watch", priority: 2),
         SourceDescriptor(id: "healthkit", displayName: "Apple Health", type: .healthkit,
                          bundleId: "com.apple.health", priority: 80)]
    }

    func readSamples(_ range: HealthDateRange) -> [SampleDTO] { [] }
    func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { interval.map { [$0] } ?? [] }
    func readSessions(_ range: HealthDateRange) -> [SessionDTO] { session.map { [$0] } ?? [] }
}
