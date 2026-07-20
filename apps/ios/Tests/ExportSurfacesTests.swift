import XCTest
@testable import BADAN

/// EPIC-09/10/11/16 — the iOS export *surfaces* (Quick Export, advanced builder, template
/// manager, Export Health), as opposed to `ExportTemplateSystemTests` which pins the domain layer.
///
/// The load-bearing tests here are:
///  - `testOutcomePlainLanguageNeverLeaksARawToken` is the §16 rule in test form: the user must
///    never see `skippedLocked`/`failedDelivery`, so every enum the health surfaces render is
///    checked to produce non-empty en+ar copy that is not its own raw case name.
///  - `testRunRecordsALedgerRow` / `testSensitiveTemplateRunIsRefusedAndLeavesALedgerRow` are the
///    anti-HAE thesis for the *attended* run path: an export that runs (or refuses) leaves
///    evidence either way.
///  - `testQuickExportRangeMapsToNonSensitivePreset` is the structural guarantee that the casual
///    3-tap path can never widen into the sensitive namespace or routes.
@MainActor
final class ExportSurfacesTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-surfaces-\(UUID().uuidString)", isDirectory: true)
        let db = try Database(directory: tempDir)
        env = AppEnvironment(database: db, clock: clock)
    }

    override func tearDownWithError() throws {
        env = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var service: ExportManageService { ExportManageService(env: env) }
    private var runsRepo: ExportRunRepository { ExportRunRepository(env.database.main) }

    // MARK: - Plain-language mapping (§16: never show a raw token)

    func testOutcomePlainLanguageNeverLeaksARawToken() {
        for outcome in ExportOutcome.allCases {
            let label = ExportRunPresentation.label(outcome)
            XCTAssertFalse(label.en.isEmpty, "\(outcome) has empty en label")
            XCTAssertFalse(label.ar.isEmpty, "\(outcome) has empty ar label")
            XCTAssertNotEqual(label.en, outcome.rawValue, "\(outcome) leaked its raw token to the user")
            XCTAssertFalse(ExportRunPresentation.icon(outcome).isEmpty)
        }
    }

    func testEveryRenderedEnumHasNonEmptyBilingualCopy() {
        for code in ExportErrorCode.allCases {
            let l = ExportRunPresentation.errorLabel(code)
            XCTAssertFalse(l.en.isEmpty); XCTAssertFalse(l.ar.isEmpty)
            XCTAssertNotEqual(l.en, code.rawValue)
        }
        for trigger in ExportTrigger.allCases {
            let l = ExportRunPresentation.triggerLabel(trigger)
            XCTAssertFalse(l.en.isEmpty); XCTAssertFalse(l.ar.isEmpty)
            XCTAssertNotEqual(l.en, trigger.rawValue)
        }
        for stage in ExportStage.allCases {
            let l = ExportRunPresentation.stageLabel(stage)
            XCTAssertFalse(l.en.isEmpty); XCTAssertFalse(l.ar.isEmpty)
        }
        for outcome in BackgroundRunOutcome.allCases {
            let l = ExportRunPresentation.backgroundOutcomeLabel(outcome)
            XCTAssertFalse(l.en.isEmpty); XCTAssertFalse(l.ar.isEmpty)
            XCTAssertNotEqual(l.en, outcome.rawValue)
        }
        for kind in BackgroundRunKind.allCases {
            let l = ExportRunPresentation.backgroundKindLabel(kind)
            XCTAssertFalse(l.en.isEmpty); XCTAssertFalse(l.ar.isEmpty)
        }
    }

    /// A failure outcome must read as `attention`; the benign skips must not — otherwise the amber
    /// "something's off" tone loses all meaning (the whole point of `ExportOutcome.isFailure`).
    func testToneMatchesFailurePredicate() {
        for outcome in ExportOutcome.allCases {
            let tone = ExportRunPresentation.tone(outcome)
            if outcome.isFailure {
                XCTAssertEqual(tone, .attention, "\(outcome) is a failure but not toned for attention")
            } else {
                XCTAssertNotEqual(tone, .attention, "\(outcome) is benign but toned as a problem")
            }
        }
    }

    func testRangeRuleLabelLocalizesDigits() {
        let format = env.format
        XCTAssertEqual(ExportRunPresentation.rangeRuleLabel(.lastNDays(7), format: format).en, "Last 7 days")
        XCTAssertFalse(ExportRunPresentation.rangeRuleLabel(.allTime, format: format).ar.isEmpty)
        XCTAssertFalse(ExportRunPresentation.rangeRuleLabel(.sinceLastRun, format: format).en.isEmpty)
    }

    // MARK: - Quick Export structural exclusion

    func testQuickExportRangeMapsToNonSensitivePreset() {
        let expected: [(QuickExportRange, ExportFormat, QuickExportPreset)] = [
            (.last7, .csv, .last7CSV), (.last7, .json, .last7JSON),
            (.last30, .csv, .last30CSV), (.last30, .json, .last30JSON),
            (.all, .csv, .allTimeCSV), (.all, .json, .allTimeJSON),
        ]
        for (range, format, preset) in expected {
            XCTAssertEqual(range.preset(format), preset)
            // The structural guarantee: no Quick Export selection can widen into sensitive data or
            // suppressed duplicates.
            let scope = preset.template(now: clock.now(), originDeviceId: deviceId).scope
            XCTAssertFalse(scope.includeSensitive, "\(preset) preset scope opted into sensitive data")
            XCTAssertFalse(scope.includeSuppressed, "\(preset) preset scope opted into suppressed rows")
        }
    }

    // MARK: - Builder range mapping

    func testBuilderRangeRoundTripsRepresentableRules() {
        let now = clock.now()
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .lastNDays(30), scope: ExportScope(), now: now).0, .last30)
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .lastNDays(90), scope: ExportScope(), now: now).0, .last90)
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .allTime, scope: ExportScope(), now: now).0, .all)
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .fixed, scope: ExportScope(), now: now).0, .custom)
        // A rule the builder can't represent as one of its segments still maps to a usable one.
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .lastNDays(45), scope: ExportScope(), now: now).0, .custom)
        XCTAssertEqual(AdvancedExportBuilderScreen.range(from: .sinceLastRun, scope: ExportScope(), now: now).0, .all)
    }

    // MARK: - Window resolution

    func testResolvedWindowMatchesRule() {
        let now = clock.now()
        let all = service.resolvedWindow(for: template(rule: .allTime), now: now)
        XCTAssertNil(all.start); XCTAssertNil(all.end); XCTAssertNil(all.notice)

        let last7 = service.resolvedWindow(for: template(rule: .lastNDays(7)), now: now)
        XCTAssertNotNil(last7.start)
        XCTAssertEqual(last7.end, now)
        XCTAssertNil(last7.notice)

        // §12 EPIC-09: sinceLastRun with no cursor falls back to a bounded window WITH a notice.
        let since = service.resolvedWindow(for: template(rule: .sinceLastRun), now: now)
        XCTAssertNotNil(since.start)
        XCTAssertNotNil(since.notice)
    }

    // MARK: - Seeding + CRUD

    func testEnsureSeededSeedsPresetsAndShareSheet() throws {
        service.ensureSeeded()
        XCTAssertEqual(service.presets().count, QuickExportPreset.allCases.count)
        let dest = try XCTUnwrap(ExportDestinationRepository(env.database.main)
            .destination(id: ExportDestination.shareSheetId))
        XCTAssertEqual(dest.kind, .shareSheet)
        // Idempotent.
        service.ensureSeeded()
        XCTAssertEqual(service.presets().count, QuickExportPreset.allCases.count)
    }

    func testCreateThenNameCollisionIsRefused() throws {
        _ = try service.createTemplate(name: "Weekly vitals", scope: ExportScope(),
                                       rangeRule: .lastNDays(7), format: .csv)
        XCTAssertFalse(service.isNameAvailable("Weekly vitals", excludingId: nil))
        XCTAssertThrowsError(try service.createTemplate(name: "Weekly vitals", scope: ExportScope(),
                                                        rangeRule: .lastNDays(7), format: .csv)) { error in
            XCTAssertEqual(error as? ExportTemplateError, .nameTaken("Weekly vitals"))
        }
    }

    func testDeleteRemovesFromUserTemplates() throws {
        let created = try service.createTemplate(name: "Throwaway", scope: ExportScope(),
                                                 rangeRule: .allTime, format: .json)
        XCTAssertTrue(service.userTemplates().contains { $0.id == created.id })
        try service.deleteTemplate(id: created.id)
        XCTAssertFalse(service.userTemplates().contains { $0.id == created.id })
    }

    func testPresetsAreNotEditable() throws {
        service.ensureSeeded()
        let preset = try XCTUnwrap(service.presets().first)
        XCTAssertThrowsError(try service.deleteTemplate(id: preset.id))
    }

    // MARK: - Run ledger

    func testRunRecordsALedgerRow() async throws {
        service.ensureSeeded()
        let preset = try XCTUnwrap(service.template(id: QuickExportPreset.last7CSV.id))
        // No data seeded → a successful "nothing to export" outcome, still recorded.
        _ = try await service.run(template: preset, passphrase: nil, consent: nil)
        let runs = try runsRepo.recent(templateId: preset.id, limit: 10)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outcome, .skippedNoData)
        XCTAssertEqual(runs.first?.trigger, .manual)
        XCTAssertEqual(runs.first?.templateId, preset.id)
    }

    func testRunWithDataRecordsSuccess() async throws {
        try seedOneSample()
        service.ensureSeeded()
        let preset = try XCTUnwrap(service.template(id: QuickExportPreset.last7CSV.id))
        let result = try await service.run(template: preset, passphrase: nil, consent: nil)
        XCTAssertGreaterThan(result.rowCount, 0)
        XCTAssertFalse(result.files.isEmpty)
        XCTAssertEqual(service.lastRun(templateId: preset.id)?.outcome, .success)
        // Clean up the temp export folder this produced.
        for folder in Set(result.files.map { $0.deletingLastPathComponent().path }) {
            env.exporter.deleteExportedFiles(at: folder)
        }
    }

    func testSensitiveTemplateRunIsRefusedAndLeavesALedgerRow() async throws {
        let sensitive = try service.createTemplate(
            name: "Meds", scope: ExportScope(includeSensitive: true),
            rangeRule: .lastNDays(7), format: .csv)
        // No consent → a thrown refusal AND a recorded failedGeneration.
        do {
            _ = try await service.run(template: sensitive, passphrase: nil, consent: nil)
            XCTFail("sensitive run without consent should have thrown")
        } catch {
            XCTAssertTrue(error is ExportTemplateRunRefusal)
        }
        let runs = try runsRepo.recent(templateId: sensitive.id, limit: 10)
        XCTAssertEqual(runs.first?.outcome, .failedGeneration)
        XCTAssertEqual(runs.first?.errorCode, .sensitiveConfirmationMissing)
    }

    // MARK: - Fixtures

    private func template(rule: ExportRangeRule) -> ExportTemplate {
        ExportTemplate(id: ULID.newID(), name: "T-\(rule.storageValue)", scope: ExportScope(),
                       rangeRule: rule, format: .csv, destinationId: ExportDestination.shareSheetId,
                       createdAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId)
    }

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
}
