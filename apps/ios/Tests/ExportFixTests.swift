import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 export fixes: CSV formula-injection
/// sanitization (DATA-13), non-exponential decimal formatting (DATA-14), the custom-range
/// end-of-day/invalid-range helpers (DATA-04), and the new events.csv log projection (DATA-03).
final class ExportFixTests: XCTestCase {

    // MARK: - DATA-13: formula injection sanitization

    func testSanitizeTextNeutralizesFormulaTriggers() {
        XCTAssertEqual(CSVWriter.sanitizeText("=cmd()"), "'=cmd()")
        XCTAssertEqual(CSVWriter.sanitizeText("+1+1"), "'+1+1")
        XCTAssertEqual(CSVWriter.sanitizeText("-1"), "'-1")
        XCTAssertEqual(CSVWriter.sanitizeText("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(CSVWriter.sanitizeText("\tleading tab"), "'\tleading tab")
        XCTAssertEqual(CSVWriter.sanitizeText("\rleading cr"), "'\rleading cr")
    }

    func testSanitizeTextLeavesOrdinaryTextUntouched() {
        XCTAssertEqual(CSVWriter.sanitizeText("My Watch"), "My Watch")
        XCTAssertEqual(CSVWriter.sanitizeText(""), "")
        XCTAssertEqual(CSVWriter.sanitizeText("Apple Health"), "Apple Health")
    }

    /// End-to-end through `line(_:)`: the free-text `metric_display`/`source_app`/
    /// `source_device` columns get sanitized, but the numeric `value`/`canonical_value` columns
    /// (which can legitimately start with `-`) must not be touched.
    func testLineSanitizesFreeTextColumnsOnlyNotNumericColumns() {
        let writer = CSVWriter()
        let row = ExportRow(recordId: "r1", recordKind: "sample", metricId: "vitals.hr",
                            metricDisplay: "=cmd()", value: "-5", unit: "bpm",
                            canonicalValue: "-5", canonicalUnit: "bpm", valueType: "raw",
                            isDerived: false, timestampStart: "2026-01-01T00:00:00+00:00",
                            timezone: "UTC", recordedAt: "2026-01-01T00:00:00+00:00",
                            sourceApp: "=evil", sourceDevice: "+device", ingestionPath: "manual")
        let line = writer.line(row)
        XCTAssertTrue(line.contains("'=cmd()"), "metric_display must be sanitized")
        XCTAssertTrue(line.contains("'=evil"), "source_app must be sanitized")
        XCTAssertTrue(line.contains("'+device"), "source_device must be sanitized")
        XCTAssertTrue(line.contains(",-5,"), "numeric value/canonical_value columns must stay unprefixed")
    }

    // MARK: - DATA-14: non-exponential decimal formatting

    func testDecimalNeverEmitsScientificNotationForHugeMagnitude() {
        XCTAssertFalse(CSVWriter.decimal(1e16).lowercased().contains("e"))
    }

    func testDecimalNeverEmitsScientificNotationForLargeNonInteger() {
        // >= 1e9 and non-integer — the rounding pass is skipped, so this exercises the
        // fallthrough formatter directly.
        XCTAssertFalse(CSVWriter.decimal(1_234_567_890.123456).lowercased().contains("e"))
    }

    func testDecimalPreservesNormalMagnitudePrecision() {
        XCTAssertEqual(CSVWriter.decimal(3.14), "3.14")
        XCTAssertEqual(CSVWriter.decimal(5.0), "5")
        XCTAssertEqual(CSVWriter.decimal(0.333333), "0.333333")
    }

    func testDecimalHandlesLargeIntegerMagnitudeWithoutExponent() {
        let large = 1_000_000_000_000_000.0 // 1e15 — >= the integer fast path's own bound
        let rendered = CSVWriter.decimal(large)
        XCTAssertFalse(rendered.lowercased().contains("e"))
        XCTAssertEqual(rendered, "1000000000000000")
    }

    // MARK: - DATA-04: custom-range helpers

    func testEndOfDayBoundIsNextMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midAfternoon = cal.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 15, minute: 30))!

        let bound = ExportCenterScreen.endOfDayBound(for: midAfternoon, calendar: cal)
        let expectedNextMidnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        XCTAssertEqual(bound, expectedNextMidnight)
    }

    func testRangeInvalidWhenStartAfterEnd() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 20))!
        let end = cal.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        XCTAssertTrue(ExportCenterScreen.isRangeInvalid(start: start, end: end, calendar: cal))
    }

    func testRangeValidWhenStartBeforeOrEqualEnd() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        XCTAssertFalse(ExportCenterScreen.isRangeInvalid(start: day, end: day, calendar: cal))
        let later = cal.date(from: DateComponents(year: 2026, month: 7, day: 20))!
        XCTAssertFalse(ExportCenterScreen.isRangeInvalid(start: day, end: later, calendar: cal))
    }

    // MARK: - DATA-03: events.csv row mapping (end-to-end)

    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-fix-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCSVExportIncludesEventsFileWithMappedRows() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let now = clock.now()

        try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: "headache", severity: 6,
                                               occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId))

        let regimen = MedicationRegimen(id: ULID.newID(), name: "Vitamin D", schedule: .asNeeded,
                                        startedAt: now, updatedAt: now, originDeviceId: deviceId)
        try logging.upsertRegimen(regimen)
        try logging.insertAdherence(AdherenceEvent(id: ULID.newID(), regimenId: regimen.id, kind: .taken,
                                                    scheduledFor: now, occurredAt: now, tzId: "UTC",
                                                    updatedAt: now, originDeviceId: deviceId))

        try logging.upsertWorkout(WorkoutEntry(id: ULID.newID(), activityType: "Run",
                                               startAt: now.addingTimeInterval(-1800), endAt: now,
                                               tzId: "UTC", energyKcal: 250, updatedAt: now, originDeviceId: deviceId))

        // A canonical-key water entry (EDGE-17) — must render as "Water" in an English export.
        try logging.upsertNutrition(NutritionEntry(id: ULID.newID(), description: WaterEntryIdentity.canonicalKey,
                                                   mealType: .drink, waterMl: 300, occurredAt: now, tzId: "UTC",
                                                   updatedAt: now, originDeviceId: deviceId))

        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main), logging: logging,
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)

        var scope = ExportScope.everything
        scope.includeSensitive = true
        scope.language = .en
        let result = try runner.run(scope: scope, format: .csv)

        let eventsURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "events.csv" },
                                     "CSV export must produce an events.csv file")
        let text = try String(contentsOf: eventsURL, encoding: .utf8)

        XCTAssertTrue(text.contains("symptoms.entry"), "symptom entries must appear as events")
        XCTAssertTrue(text.contains("medications.adherence"), "adherence events must appear as events")
        XCTAssertTrue(text.contains("Vitamin D"), "adherence row must show the regimen's own name")
        XCTAssertTrue(text.contains("activity.workout"), "workouts must appear as events")
        XCTAssertTrue(text.contains("nutrition.entry"), "nutrition entries must appear as events")
        XCTAssertTrue(text.contains("Water"),
                     "canonical water key must render as localized 'Water' in an English-scope export")

        XCTAssertNotNil(result.job.manifest?.checksums["events.csv"],
                        "events.csv must be checksummed in the manifest, same as raw.csv/derived.csv")
    }

    func testCSVExportOmitsSensitiveEventsWhenSensitiveNotIncluded() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let now = clock.now()
        try logging.insertSymptom(SymptomEntry(id: ULID.newID(), symptomId: "migraine", severity: 8,
                                               occurredAt: now, tzId: "UTC", updatedAt: now, originDeviceId: deviceId))

        let runner = ExportRunner(measurements: MeasurementRepository(db.main),
                                  derivation: DerivationRepository(db.main), logging: logging,
                                  exportJobs: ExportJobRepository(db.main), registry: .shared,
                                  clock: clock, appVersion: "test", deviceId: deviceId)

        var scope = ExportScope.everything
        scope.includeSensitive = false
        let result = try runner.run(scope: scope, format: .csv)
        let eventsURL = try XCTUnwrap(result.fileURLs.first { $0.lastPathComponent == "events.csv" })
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        XCTAssertFalse(text.contains("symptoms.entry"),
                       "sensitive-class logs must be excluded from events.csv without includeSensitive")
    }
}
