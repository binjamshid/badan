import XCTest
@testable import BADAN

/// EPIC-09/13/14/15/17 — the template-run orchestration wired into `ExportRunner`: resolve a
/// template → generate → deliver → record an `ExportRun`, with the incremental cursor's two-phase
/// commit, run-time sensitive re-confirmation, and retry idempotency.
///
/// These are the DB-backed behavioural tests for the whole run loop. Their Android counterpart
/// (`ExportRunnerTemplateTest`) covers only the pure decision functions, because that module's JVM
/// test source set cannot open a database — the same split `ExportTemplateSystemTest` documents.
/// Everything asserted here about the ledger and the cursor is the cross-platform contract the two
/// runners share decision-for-decision.
final class ExportRunnerTemplateTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-runner-template-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private var runsRepo: ExportRunRepository { ExportRunRepository(db.main) }
    private var cursorsRepo: ExportCursorRepository { ExportCursorRepository(db.main) }
    private var destinationsRepo: ExportDestinationRepository { ExportDestinationRepository(db.main) }
    private var jobsRepo: ExportJobRepository { ExportJobRepository(db.main) }

    private func makeRunner(deliverers: [ExportDestinationDelivering] = []) -> ExportRunner {
        ExportRunner(
            measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            exportJobs: ExportJobRepository(db.main), registry: .shared, clock: clock,
            appVersion: "test", deviceId: deviceId,
            templates: ExportTemplateRepository(db.main), destinations: ExportDestinationRepository(db.main),
            runs: ExportRunRepository(db.main), cursors: ExportCursorRepository(db.main),
            routes: RouteRepository(db.main), deliverers: deliverers)
    }

    private var now: Date { clock.now() }

    /// A folder destination whose delivery is handled by whatever `StubDeliverer` the test registers.
    private let folderDestId = "0000000000DESTFOLDER000001"

    private func seedFolderDestination() throws {
        try destinationsRepo.upsert(ExportDestination(
            id: folderDestId, kind: .fileFolder, displayName: "Folder",
            config: ExportDestinationConfig(folderBookmarkRef: "badan.folder.ref"),
            createdAt: now, updatedAt: now, originDeviceId: deviceId))
    }

    private func seedShareSheet() throws {
        try destinationsRepo.seedShareSheet(now: now, originDeviceId: deviceId)
    }

    @discardableResult
    private func insertSample(ingestedAt: Date, measuredAt: Date? = nil) throws -> RawSample {
        let m = measuredAt ?? ingestedAt
        let prov = Provenance(sourceId: "watch", deviceId: "watch", ingestionPath: .platformStore,
                              measuredAt: m, measuredTimezone: "UTC", recordedAt: m, ingestedAt: ingestedAt)
        let sample = RawSample(id: ULID.newID(), metricId: "heart.rhr", value: 58, unit: "count/min",
                               originalValue: 58, originalUnit: "count/min", startAt: m, tzId: "UTC",
                               provenance: prov, updatedAt: ingestedAt, originDeviceId: deviceId)
        try MeasurementRepository(db.main).upsertRawSample(sample)
        return sample
    }

    private func template(id: String = "T1", scope: ExportScope = .everything,
                          rangeRule: ExportRangeRule = .allTime,
                          destinationId: String? = ExportDestination.shareSheetId) -> ExportTemplate {
        ExportTemplate(id: id, name: "Test template", scope: scope, rangeRule: rangeRule,
                       format: .csv, aggregation: .raw, layout: .tidy,
                       destinationId: destinationId, createdAt: now, updatedAt: now, originDeviceId: deviceId)
    }

    // MARK: - 1. Template run end to end

    func testTemplateRunEndToEndRecordsSuccessAndLinksAJob() async throws {
        try seedShareSheet()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        let runner = makeRunner()

        let outcome = await runner.runTemplate(template(rangeRule: .allTime), trigger: .manual)

        XCTAssertEqual(outcome.run.outcome, .success)
        XCTAssertNotNil(outcome.result, "a successful run must return its artifact")
        XCTAssertGreaterThanOrEqual(outcome.result?.rowCount ?? 0, 1)
        // Every run writes exactly one ledger row, linked to the job it produced.
        let recorded = try XCTUnwrap(runsRepo.recent().first)
        XCTAssertEqual(recorded.id, outcome.run.id)
        XCTAssertEqual(recorded.outcome, .success)
        XCTAssertEqual(recorded.jobId, outcome.result?.job.id)
        XCTAssertNotNil(recorded.rowCounts, "a delivered run records its per-class row counts")
        XCTAssertNotNil(recorded.manifestSha256)
        // The job the run points at actually exists and completed.
        XCTAssertEqual(try jobsRepo.recent().first(where: { $0.id == recorded.jobId })?.status, .completed)
    }

    // MARK: - 2. A failure is recorded in the ledger

    func testFailedDeliveryIsRecordedInTheLedger() async throws {
        try seedFolderDestination()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .failure(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .allTime, destinationId: folderDestId), trigger: .scheduledWork)

        XCTAssertEqual(outcome.run.outcome, .failedDelivery)
        XCTAssertEqual(outcome.run.errorCode, .destinationUnreachable)
        // Generation still happened, so the ledger row is linked to a real job — the failure was in
        // delivery, not generation.
        XCTAssertNotNil(outcome.run.jobId)
        XCTAssertNil(outcome.run.deliveredAt, "nothing arrived, so there is no delivery instant")
        XCTAssertEqual(try runsRepo.recent().first?.outcome, .failedDelivery)
    }

    func testMissingDestinationFailsBeforeGenerationButIsStillRecorded() async throws {
        // The template points at a destination row that does not exist. Fail loudly in the ledger
        // rather than silently redirecting the user's data.
        let runner = makeRunner()
        let outcome = await runner.runTemplate(
            template(rangeRule: .allTime, destinationId: "0000000000DESTGONE0000001"), trigger: .manual)

        XCTAssertEqual(outcome.run.outcome, .failedGeneration)
        XCTAssertEqual(outcome.run.errorCode, .destinationUnreachable)
        XCTAssertNil(outcome.run.jobId, "a refusal before generation produced no job")
        XCTAssertEqual(try runsRepo.recent().count, 1, "the refusal is still one ledger row")
    }

    // MARK: - 3. Cursor is not advanced on a failed delivery

    func testCursorIsNotAdvancedWhenDeliveryFails() async throws {
        try seedFolderDestination()
        let watermark = now.addingTimeInterval(-10_000)
        try cursorsRepo.advance(templateId: "T1", destinationId: folderDestId, to: watermark,
                                lastRunId: "seed", manifestSha: nil, now: now)
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000)) // ahead of the watermark
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .failure(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, destinationId: folderDestId), trigger: .scheduledWork)

        XCTAssertEqual(outcome.run.outcome, .failedDelivery)
        // The watermark must NOT move past rows a failed delivery never handed off — the two-phase
        // commit / DATA-08 discipline this whole subsystem turns on.
        XCTAssertEqual(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId)?.highWatermark,
                       watermark, "a failed delivery must leave the cursor exactly where it was")
        XCTAssertNil(outcome.run.cursorAfter, "a failed run records no advanced watermark")
    }

    // MARK: - 4. Retry idempotency (same cursor window)

    func testRetryReusesTheSameCursorWindowThenAdvancesOnSuccess() async throws {
        try seedFolderDestination()
        let watermark = now.addingTimeInterval(-10_000)
        try cursorsRepo.advance(templateId: "T1", destinationId: folderDestId, to: watermark,
                                lastRunId: "seed", manifestSha: nil, now: now)
        let sample = try insertSample(ingestedAt: now.addingTimeInterval(-1_000))

        // First attempt: delivery fails. The cursor stays put, so the window is preserved.
        let failing = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .failure(now))])
        let firstAttempt = await failing.runTemplate(
            template(rangeRule: .sinceLastRun, destinationId: folderDestId), trigger: .scheduledWork)
        XCTAssertEqual(firstAttempt.run.outcome, .failedDelivery)
        XCTAssertEqual(firstAttempt.run.cursorBefore, watermark)

        // Retry: it re-reads the SAME watermark (the failed run did not move it), so it re-exports
        // the SAME window — no skip, no duplicate — and only NOW advances the cursor.
        let succeeding = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])
        let retry = await succeeding.runTemplate(
            template(rangeRule: .sinceLastRun, destinationId: folderDestId), trigger: .retry, attempt: 1)

        XCTAssertEqual(retry.run.outcome, .success)
        XCTAssertEqual(retry.run.cursorBefore, watermark,
                       "the retry must resume from the same watermark the failed run started from")
        XCTAssertEqual(retry.run.cursorAfter, sample.provenance.ingestedAt)
        XCTAssertEqual(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId)?.highWatermark,
                       sample.provenance.ingestedAt, "the cursor advances only after the delivered success")
    }

    // MARK: - 5. Sensitive re-confirmation enforced at run time

    func testSensitiveTemplateWithoutConsentIsRefusedAndRecorded() async throws {
        try seedShareSheet()
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let runner = makeRunner()

        let outcome = await runner.runTemplate(template(scope: scope), trigger: .manual, consent: nil)

        XCTAssertEqual(outcome.run.outcome, .failedGeneration)
        XCTAssertEqual(outcome.run.errorCode, .sensitiveConfirmationMissing)
        XCTAssertNil(outcome.result, "a refused sensitive run produces no artifact")
        XCTAssertNil(outcome.run.jobId)
        XCTAssertEqual(try runsRepo.recent().count, 1, "the refusal is recorded, not swallowed")
    }

    func testSensitiveTemplateWithFreshConsentAndPassphraseRuns() async throws {
        try seedShareSheet()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let runner = makeRunner()
        let consent = SensitiveRunConsent(templateId: "T1", confirmedAt: now)

        let outcome = await runner.runTemplate(template(scope: scope), trigger: .manual,
                                               consent: consent, passphrase: "correct horse battery staple")

        XCTAssertEqual(outcome.run.outcome, .success)
        XCTAssertEqual(outcome.result?.job.manifest?.encrypted, true,
                       "a sensitive run is encrypted (ADR-0008), consent and passphrase both satisfied")
    }

    // MARK: - 6. sinceLastRun with no cursor: bounded fallback WITH a notice, no silent checkpoint

    // MARK: - Ad-hoc builder export records a run (BUG-EXPORT-P1a)

    /// The Advanced Export Builder's ad-hoc path must leave a ledger row, not a bare job. Before
    /// the fix, `ExportCenterViewModel.run` called `ExportRunner.run` directly and wrote only an
    /// `ExportJob`; `jobIdsWithoutRun` then counted that job and Export Health reported the
    /// *successful* export as "started but left no record — likely closed mid-export". This drives
    /// the real `runAdHoc` entry point the view model now calls and asserts the gap query is empty.
    func testAdHocBuilderExportRecordsASuccessRunAndLeavesNoOrphanJob() async throws {
        try seedShareSheet()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        let runner = makeRunner()

        let result = try runner.runAdHoc(scope: .everything, format: .csv, trigger: .manual)

        let recorded = try XCTUnwrap(runsRepo.recent().first, "an ad-hoc export must write a run")
        XCTAssertEqual(recorded.outcome, .success)
        XCTAssertNil(recorded.templateId, "an ad-hoc builder run has no template")
        XCTAssertEqual(recorded.jobId, result.job.id, "the run links the job it produced")
        // The exact defect: no job may be left without a ledger row, or Export Health slanders it.
        XCTAssertEqual(try runsRepo.jobIdsWithoutRun(), [], "a recorded export leaves no orphan job")
    }

    func testSinceLastRunWithNoCursorFallsBackWithNotice() async throws {
        try seedFolderDestination()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, destinationId: folderDestId), trigger: .manual)

        XCTAssertTrue(outcome.cursorFallbackNotice, "a no-cursor sinceLastRun must surface the fallback")
        XCTAssertEqual(outcome.run.outcome, .success)
        // The notice is durable on the (successful) row, machine-readable, never free text.
        XCTAssertEqual(outcome.run.errorCode, .cursorMissing)
        // The bounded, measured-axis fallback must NOT establish an ingested-axis checkpoint — doing
        // so could skip a historical row ingested recently but measured outside the window.
        XCTAssertNil(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId),
                     "the fallback run must not silently create a delta cursor")
    }
}

// MARK: - Test double

/// A programmable `ExportDestinationDelivering` so a test can drive delivery to a chosen outcome
/// without a real filesystem provider. `FileFolderDestination`'s own real-delivery behaviour is
/// covered by `ExportDestinationsTests`; this stub is only about the runner's reaction to a receipt.
private final class StubDeliverer: ExportDestinationDelivering {
    let kind: ExportDestinationKind
    private let receipt: ExportDeliveryReceipt
    init(kind: ExportDestinationKind, receipt: ExportDeliveryReceipt) {
        self.kind = kind
        self.receipt = receipt
    }

    func verify(_ destination: ExportDestination, now: Date) async -> ExportDestinationProbe {
        ExportDestinationProbe(status: .ok, checkedAt: now, message: LocalizedString(en: "ok", ar: "ok"))
    }

    func deliver(_ request: ExportDeliveryRequest, now: Date) async -> ExportDeliveryReceipt { receipt }
}

private extension ExportDeliveryReceipt {
    static func success(_ now: Date) -> ExportDeliveryReceipt {
        ExportDeliveryReceipt(outcome: .success, errorDetail: ExportErrorDetail(stage: .delivering),
                              bytesDelivered: 1_024, deliveredAt: now, destinationStatus: .ok,
                              relativePath: "BADAN/Exports/2026/07",
                              message: LocalizedString(en: "saved", ar: "saved"))
    }

    static func failure(_ now: Date) -> ExportDeliveryReceipt {
        ExportDeliveryReceipt(outcome: .failedDelivery, errorCode: .destinationUnreachable,
                              errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0, filesExpected: 2),
                              bytesDelivered: 0, deliveredAt: nil, destinationStatus: .unreachable,
                              message: LocalizedString(en: "unreachable", ar: "unreachable"), needsRepick: true)
    }
}
