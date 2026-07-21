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
    private var cursors: ExportCursorRepository { ExportCursorRepository(env.database.main) }
    private var service: IntentExportService { IntentExportService(env: env) }

    /// One raw sample with an explicit `ingested_at`, so a delta test can place rows on either side
    /// of a checkpoint. `measured_at` is deliberately much older than `ingested_at` in these tests:
    /// a delta filters on the INGESTED axis, and a row measured before a watermark but stored after
    /// it must still be delivered (the DATA-08 hazard).
    @discardableResult
    private func seedSample(ingestedAt: Date) throws -> RawSample {
        let measured = ingestedAt.addingTimeInterval(-86_400 * 45)
        let sample = RawSample(
            id: ULID.newID(), metricId: MetricID.steps, value: 4200, unit: "steps",
            originalValue: 4200, originalUnit: "steps", startAt: measured, tzId: "UTC",
            provenance: Provenance(sourceId: deviceId, deviceId: deviceId, ingestionPath: .manual,
                                   measuredAt: measured, measuredTimezone: "UTC",
                                   recordedAt: measured, ingestedAt: ingestedAt),
            updatedAt: ingestedAt, originDeviceId: deviceId)
        _ = try MeasurementRepository(env.database.main).upsertRawSample(sample)
        return sample
    }

    /// The `record_id` column of every row a CSV intent run wrote to `raw.csv`, read off the file on
    /// disk — these assertions must describe the artifact the Shortcut actually receives.
    private func exportedRecordIds(_ outcome: IntentExportService.RunOutcome) throws -> [String] {
        guard let raw = outcome.files.first(where: { $0.url.lastPathComponent == "raw.csv" }) else { return [] }
        let text = try String(contentsOf: raw.url, encoding: .utf8)
        return text.components(separatedBy: "\r\n").dropFirst()
            .compactMap { $0.isEmpty ? nil : String($0.prefix(while: { $0 != "," })) }
    }

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

    func testSinceLastRunFallsBackToAWindowWithANoticeWhenThereIsNoCursor() throws {
        let t = makeTemplate(name: "Since last", rangeRule: .sinceLastRun)
        try templates.insert(t)
        try seedOneSample()
        let outcome = try service.run(template: t)
        XCTAssertNotNil(outcome.notice, "the sinceLastRun fallback must tell the user the window wasn't literal")
        let row = try XCTUnwrap(try runs.recent(templateId: t.id).first)
        XCTAssertEqual(row.errorCode, .cursorMissing,
                       "the fallback must be durable in the ledger, not only in the Shortcut's reply")
        XCTAssertFalse(row.outcome.isFailure, "falling back is a note on a successful run, not a failure")
        // A fallback run establishes nothing: `resolveRange` deliberately does not create a first
        // cursor, so the next run is still a disclosed fallback rather than a silent delta.
        XCTAssertNil(try cursors.cursor(templateId: t.id, destinationId: ExportDestination.shareSheetId),
                     "the fallback run must not silently create a delta cursor")
    }

    // MARK: - EPIC-17: a Shortcut run of a sinceLastRun template takes the REAL delta

    /// The behavioural half of the A3 finding. Before this, a `sinceLastRun` template run from a
    /// Shortcut took a fixed 30-day window and ignored `export_cursors` entirely, while the very
    /// same template run by `ExportRunner.runTemplate` took the delta — so the two entry points
    /// exported different rows from the same saved configuration and nothing said so.
    func testShortcutRunOfASinceLastRunTemplateTakesTheDeltaAndAdvancesTheCursor() throws {
        let t = makeTemplate(name: "Since last", rangeRule: .sinceLastRun)
        try templates.insert(t)
        let now = clock.now()
        // One row already delivered (ingested before the checkpoint) and one that arrived after it.
        let old = try seedSample(ingestedAt: now.addingTimeInterval(-20_000))
        try cursors.advance(templateId: t.id, destinationId: ExportDestination.shareSheetId,
                            to: now.addingTimeInterval(-10_000), lastRunId: "seed",
                            manifestSha: nil, now: now)
        let fresh = try seedSample(ingestedAt: now.addingTimeInterval(-1_000))

        let outcome = try service.run(template: t)

        XCTAssertNil(outcome.notice, "a run WITH a checkpoint is a real delta — there is nothing to disclose")
        let ids = try exportedRecordIds(outcome)
        XCTAssertTrue(ids.contains(fresh.id), "the row ingested after the checkpoint must be exported")
        XCTAssertFalse(ids.contains(old.id), "a delta must not re-send a row an earlier run delivered")

        // Two-phase commit: the checkpoint moved, and only to the max ingested_at actually written.
        let cursor = try XCTUnwrap(try cursors.cursor(templateId: t.id,
                                                      destinationId: ExportDestination.shareSheetId))
        XCTAssertEqual(cursor.highWatermark, fresh.provenance.ingestedAt)
        let row = try XCTUnwrap(try runs.recent(templateId: t.id).first)
        XCTAssertEqual(row.cursorAfter, fresh.provenance.ingestedAt,
                       "the ledger records where the run closed its window")
        XCTAssertNil(row.errorCode, "a real delta is not a fallback")
    }

    /// The cursor is keyed `(template, destination)`. A Shortcut hands its files to Shortcuts, not
    /// to whatever folder/endpoint the template pins — so it must continue the share-sheet chain and
    /// leave the pinned destination's chain untouched. Advancing that one would tell the automation
    /// its folder had received rows it was never sent, and the automation's next delta would skip
    /// them forever: the same silent desync, arriving from the other side.
    func testShortcutRunNeverTouchesAPinnedDestinationsCursor() throws {
        let folderId = "0000000000DESTFOLDER000001"
        var t = makeTemplate(name: "Pinned", rangeRule: .sinceLastRun)
        t.destinationId = folderId
        try templates.insert(t)
        let now = clock.now()
        let watermark = now.addingTimeInterval(-10_000)
        try cursors.advance(templateId: t.id, destinationId: folderId, to: watermark,
                            lastRunId: "seed", manifestSha: nil, now: now)
        _ = try seedSample(ingestedAt: now.addingTimeInterval(-1_000))

        let outcome = try service.run(template: t)

        XCTAssertNotNil(outcome.notice,
                        "the share-sheet chain has no checkpoint yet, so this run discloses a fallback")
        XCTAssertEqual(try cursors.cursor(templateId: t.id, destinationId: folderId)?.highWatermark,
                       watermark, "the pinned destination's checkpoint must not move")
    }

    /// A delta that found nothing must not close the window. `skippedNoData` is a successful answer
    /// to "is there anything new", but advancing on it would step the watermark past rows a later
    /// arrival could still land behind — the same rule `runTemplate` applies.
    func testADeltaThatFoundNothingLeavesTheCursorWhereItWas() throws {
        let t = makeTemplate(name: "Since last", rangeRule: .sinceLastRun)
        try templates.insert(t)
        let now = clock.now()
        _ = try seedSample(ingestedAt: now.addingTimeInterval(-20_000))
        let watermark = now.addingTimeInterval(-10_000)
        try cursors.advance(templateId: t.id, destinationId: ExportDestination.shareSheetId,
                            to: watermark, lastRunId: "seed", manifestSha: nil, now: now)

        let outcome = try service.run(template: t)

        XCTAssertEqual(outcome.rowCount, 0)
        XCTAssertEqual(try runs.recent(templateId: t.id).first?.outcome, .skippedNoData)
        XCTAssertEqual(try cursors.cursor(templateId: t.id,
                                          destinationId: ExportDestination.shareSheetId)?.highWatermark,
                       watermark, "an empty delta closes no window")
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
