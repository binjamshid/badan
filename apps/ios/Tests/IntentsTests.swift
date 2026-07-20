import XCTest
@testable import BADAN

/// EPIC-19 — the App Intents layer.
///
/// The intent types themselves are thin (resolve a parameter, hand off, format a reply); the
/// substance is in the three services and the honesty properties they enforce, so that is what
/// these tests pin:
///  - `testSensitiveTemplateIsRefusedAndLeavesALedgerRow` is the load-bearing one. An unattended
///    export path that could emit meds/symptoms would break I7 and the whole point of the epic —
///    it must refuse *and* leave evidence it refused.
///  - `testLatestScoreIsHonestlyEmptyWhenNothingIsDerived` is the "return honestly-empty rather
///    than fabricated values" rule from the task in test form.
///  - `testRunWritesAShortcutTriggeredLedgerRow` is the anti-HAE thesis: every run, including a
///    zero-row one, leaves a row tagged as Shortcuts-triggered, never as BADAN's own background.
@MainActor
final class IntentsTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-intents-test-\(UUID().uuidString)", isDirectory: true)
        let db = try Database(directory: tempDir)
        env = AppEnvironment(database: db, clock: clock)
        // The query and the entity resolve through the shared registration, so point it at this
        // test's environment rather than the real on-device one.
        IntentEnvironment.register(env)
    }

    override func tearDownWithError() throws {
        env = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private var templates: ExportTemplateRepository { ExportTemplateRepository(env.database.main) }
    private var runs: ExportRunRepository { ExportRunRepository(env.database.main) }
    private var service: IntentExportService { IntentExportService(env: env) }

    private func makeTemplate(id: String = ULID.newID(), name: String,
                              rangeRule: ExportRangeRule = .lastNDays(7),
                              includeSensitive: Bool = false) -> ExportTemplate {
        let scope = ExportScope(includeRaw: true, includeDerived: true,
                                includeSuppressed: false, includeSensitive: includeSensitive)
        return ExportTemplate(id: id, name: name, scope: scope, rangeRule: rangeRule, format: .csv,
                              destinationId: ExportDestination.shareSheetId,
                              createdAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId)
    }

    /// One real raw sample inside the last-7-days window so a run has something to export.
    private func seedOneSample() throws {
        let now = clock.now()
        let sample = RawSample(
            id: ULID.newID(), metricId: MetricID.steps, value: 4200, unit: "steps",
            originalValue: 4200, originalUnit: "steps", startAt: now.addingTimeInterval(-3600),
            tzId: "UTC",
            provenance: Provenance(sourceId: deviceId, deviceId: deviceId, ingestionPath: .manual,
                                   measuredAt: now.addingTimeInterval(-3600), measuredTimezone: "UTC",
                                   recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: deviceId)
        _ = try MeasurementRepository(env.database.main).upsertRawSample(sample)
    }

    // MARK: - Template name resolution (ExportTemplateQuery / IntentExportService)

    func testExactNameMatchWinsOverFuzzy() throws {
        try templates.insert(makeTemplate(name: "Weekly vitals"))
        try templates.insert(makeTemplate(name: "Weekly vitals extended"))
        let matches = service.templates(matching: "Weekly vitals")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.name, "Weekly vitals")
    }

    func testFuzzyMatchIsCaseInsensitiveAndSubstring() throws {
        try templates.insert(makeTemplate(name: "Morning Export"))
        // Case-insensitive substring, Latin diacritics folded ("é" → "e").
        XCTAssertEqual(service.templates(matching: "morning").first?.name, "Morning Export")
        // Arabic substring match — a spoken fragment still finds the full template name.
        try templates.insert(makeTemplate(name: "تصدير الصباح"))
        XCTAssertFalse(service.templates(matching: "الصباح").isEmpty)
    }

    func testQueryByIdReturnsNothingForADeletedTemplate() async throws {
        let t = makeTemplate(id: "T-GONE", name: "Temp")
        try templates.insert(t)
        try templates.softDelete(id: "T-GONE", at: clock.now())
        let query = ExportTemplateQuery()
        let found = try await query.entities(for: ["T-GONE"])
        XCTAssertTrue(found.isEmpty, "a deleted template must not resolve — the intent then reports notFound")
    }

    // MARK: - Running: the ledger

    func testRunWritesAShortcutTriggeredLedgerRow() throws {
        let t = makeTemplate(name: "Steps 7d")
        try templates.insert(t)
        try seedOneSample()

        let outcome = try service.run(template: t)
        XCTAssertGreaterThan(outcome.rowCount, 0)

        let ledger = try runs.recent(templateId: t.id)
        XCTAssertEqual(ledger.count, 1)
        let row = try XCTUnwrap(ledger.first)
        XCTAssertEqual(row.trigger, .shortcut, "a Shortcut/Siri run must never masquerade as background")
        XCTAssertEqual(row.outcome, .success)
        XCTAssertNotNil(row.jobId)
        // The ledger must carry no per-metric breakdown that would disclose what the user tracks.
        XCTAssertNil(row.rowCounts)
    }

    func testEmptyRangeIsRecordedAsSkippedNoDataNotAFailure() throws {
        // No samples seeded → nothing in range.
        let t = makeTemplate(name: "Empty")
        try templates.insert(t)
        let outcome = try service.run(template: t)
        XCTAssertEqual(outcome.rowCount, 0)
        let row = try XCTUnwrap(try runs.recent(templateId: t.id).first)
        XCTAssertEqual(row.outcome, .skippedNoData)
        XCTAssertFalse(row.outcome.isFailure)
    }

    // MARK: - Honesty: sensitive templates cannot run unattended

    func testSensitiveTemplateIsRefusedAndLeavesALedgerRow() throws {
        let t = makeTemplate(name: "Everything incl meds", includeSensitive: true)
        try templates.insert(t)

        XCTAssertThrowsError(try service.run(template: t)) { error in
            XCTAssertEqual(error as? IntentExportRefusal, .sensitiveTemplateNeedsTheApp(templateId: t.id))
        }
        let row = try XCTUnwrap(try runs.recent(templateId: t.id).first)
        XCTAssertEqual(row.outcome, .failedGeneration)
        XCTAssertEqual(row.errorCode, .sensitiveConfirmationMissing)
        XCTAssertNil(row.jobId, "the run must refuse BEFORE generating any artifact")
    }

    // MARK: - Range rules

    func testSinceLastRunFallsBackToAWindowWithANotice() throws {
        let t = makeTemplate(name: "Since last", rangeRule: .sinceLastRun)
        try templates.insert(t)
        try seedOneSample()
        let outcome = try service.run(template: t)
        XCTAssertNotNil(outcome.notice, "the sinceLastRun fallback must tell the user the window wasn't literal")
    }

    // MARK: - Artifact naming (house scheme)

    func testFilenamesFollowTheHouseScheme() throws {
        let t = makeTemplate(name: "Weekly vitals")
        try templates.insert(t)
        try seedOneSample()
        let outcome = try service.run(template: t)
        XCTAssertFalse(outcome.files.isEmpty)
        for file in outcome.files {
            XCTAssertTrue(file.filename.hasPrefix("BADAN_Weekly-vitals_"),
                          "unexpected name: \(file.filename)")
            // CSV run produces raw/derived/events/manifest — each keeps its role, none collide.
            XCTAssertTrue(file.filename.hasSuffix(".csv") || file.filename.hasSuffix(".json"))
        }
        let names = Set(outcome.files.map(\.filename))
        XCTAssertEqual(names.count, outcome.files.count, "every artifact gets a distinct name")
    }

    func testArabicTemplateNameSlugFallsBackRatherThanEmpty() throws {
        let t = makeTemplate(name: "تصدير")
        try templates.insert(t)
        try seedOneSample()
        let outcome = try service.run(template: t)
        // An all-Arabic name folds to nothing under an ASCII filter; the slug must not be empty.
        for file in outcome.files {
            XCTAssertTrue(file.filename.hasPrefix("BADAN_export_"), "unexpected name: \(file.filename)")
        }
    }

    // MARK: - Latest score honesty

    func testLatestScoreIsHonestlyEmptyWhenNothingIsDerived() {
        let score = IntentScoreService(env: env)
        XCTAssertNil(score.latest(.readiness), "no derived score yet → nil, never a fabricated number")
        XCTAssertNil(score.latest(.sleepEfficiency))
    }

    func testLatestScoreReadsARealDerivedValue() throws {
        let now = clock.now()
        let manifest = InputManifest(id: ULID.newID(), inputs: [])
        try env.derivation.insertManifest(manifest)
        try env.derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: "readiness.score", value: 72, unit: "score_0_100",
            periodKey: "day:" + DayAttribution.localDayKey(now, tz: TimeZone.current.identifier),
            provisional: true, algorithmId: "composite.readiness_score", algorithmVersion: "1.0.0",
            inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))

        let reading = try XCTUnwrap(IntentScoreService(env: env).latest(.readiness))
        XCTAssertEqual(reading.value, 72)
        XCTAssertTrue(reading.provisional)
    }

    // MARK: - Water quick-log

    func testLogWaterWritesADrinkNutritionEntryAndBumpsGeneration() throws {
        let before = env.dataGeneration
        let water = IntentWaterService(env: env)
        let logged = try water.log(milliliters: 500)
        XCTAssertEqual(logged, 500)
        XCTAssertEqual(env.dataGeneration, before + 1, "a quick water log must signal loaded screens (BUG-12/13)")

        let entries = try env.logging.nutrition(from: Date(timeIntervalSince1970: 0),
                                                to: clock.now().addingTimeInterval(86_400))
        let waterEntries = entries.filter { WaterEntryIdentity.matches($0.description) }
        XCTAssertEqual(waterEntries.count, 1)
        XCTAssertEqual(waterEntries.first?.mealType, .drink)
        XCTAssertEqual(waterEntries.first?.waterMl, 500)
    }

    func testLogWaterRejectsImplausibleAmounts() {
        let water = IntentWaterService(env: env)
        XCTAssertThrowsError(try water.log(milliliters: 0)) {
            XCTAssertEqual($0 as? IntentWaterRefusal, .amountOutOfRange)
        }
        XCTAssertThrowsError(try water.log(milliliters: 9000)) {
            XCTAssertEqual($0 as? IntentWaterRefusal, .amountOutOfRange)
        }
    }

    // MARK: - Environment registration

    func testIntentEnvironmentResolvesTheRegisteredEnvironment() {
        XCTAssertTrue(IntentEnvironment.resolve() === env)
    }
}
