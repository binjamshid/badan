import XCTest
import CryptoKit
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

    private var reconciliationRepo: ReconciliationRepository { ReconciliationRepository(db.main) }

    private func makeRunner(deliverers: [ExportDestinationDelivering] = []) -> ExportRunner {
        ExportRunner(
            measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            exportJobs: ExportJobRepository(db.main), registry: .shared, clock: clock,
            appVersion: "test", deviceId: deviceId,
            templates: ExportTemplateRepository(db.main), destinations: ExportDestinationRepository(db.main),
            runs: ExportRunRepository(db.main), cursors: ExportCursorRepository(db.main),
            routes: RouteRepository(db.main), deliverers: deliverers,
            reconciliation: ReconciliationRepository(db.main))
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
    private func insertSample(ingestedAt: Date, measuredAt: Date? = nil,
                              externalId: String? = nil) throws -> RawSample {
        let m = measuredAt ?? ingestedAt
        let prov = Provenance(sourceId: "watch", deviceId: "watch", ingestionPath: .platformStore,
                              externalId: externalId,
                              measuredAt: m, measuredTimezone: "UTC", recordedAt: m, ingestedAt: ingestedAt)
        let sample = RawSample(id: ULID.newID(), metricId: "heart.rhr", value: 58, unit: "count/min",
                               originalValue: 58, originalUnit: "count/min", startAt: m, tzId: "UTC",
                               provenance: prov, updatedAt: ingestedAt, originDeviceId: deviceId)
        try MeasurementRepository(db.main).upsertRawSample(sample)
        return sample
    }

    private func template(id: String = "T1", scope: ExportScope = .everything,
                          rangeRule: ExportRangeRule = .allTime,
                          format: ExportFormat = .csv,
                          destinationId: String? = ExportDestination.shareSheetId) -> ExportTemplate {
        ExportTemplate(id: id, name: "Test template", scope: scope, rangeRule: rangeRule,
                       format: format, aggregation: .raw, layout: .tidy,
                       destinationId: destinationId, createdAt: now, updatedAt: now, originDeviceId: deviceId)
    }

    // MARK: - Delta helpers (EPIC-17)

    /// The parsed `bundle.json` a JSON template run produced. Read off disk rather than off an
    /// in-memory structure so these assertions describe the FILE a consumer actually receives —
    /// the same reason the parity fixtures compare bytes.
    private func bundleObject(_ result: ExportRunner.ExportResult?) throws -> [String: Any] {
        let urls = try XCTUnwrap(result?.fileURLs)
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == "bundle.json" },
                                "a JSON template run must write bundle.json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func manifestObject(_ result: ExportRunner.ExportResult?) throws -> [String: Any] {
        try XCTUnwrap(try bundleObject(result)["manifest"] as? [String: Any])
    }

    /// sha256 of the bundle file exactly as a consumer would recompute it — the value the NEXT
    /// delta must carry as `previous_manifest_sha` (§22.6).
    private func bundleFileSha(_ result: ExportRunner.ExportResult?) throws -> String {
        let urls = try XCTUnwrap(result?.fileURLs)
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == "bundle.json" })
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// One CSV artifact split into cells, read off disk for the same reason `bundleObject` is: these
    /// assertions must describe the FILE a consumer receives. No RFC-4180 quote handling — every
    /// cell in the two reconciliation tables is a ULID or a timestamp, neither of which can contain
    /// a comma or a quote, and a naive split failing loudly if that ever changes is the point.
    private func csvRows(_ result: ExportRunner.ExportResult?, named name: String) throws -> [[String]] {
        let urls = try XCTUnwrap(result?.fileURLs)
        let url = try XCTUnwrap(urls.first { $0.lastPathComponent == name },
                                "a CSV delta run must write \(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: ",") }
    }

    private func parseISO(_ value: Any?) throws -> Date {
        let string = try XCTUnwrap(value as? String, "expected an ISO-8601 timestamp, got \(value ?? "nil")")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: string), "unparseable timestamp: \(string)")
    }

    /// Seed a delta checkpoint. A `sinceLastRun` template deliberately never creates its own first
    /// cursor (the no-cursor run falls back WITH a notice and establishes nothing — see
    /// `resolveRange`), so every delta test starts from an explicit checkpoint, exactly as the
    /// pre-existing cursor tests do.
    @discardableResult
    private func seedCursor(at watermark: Date, sha: ManifestDigest? = nil,
                            destinationId: String? = nil) throws -> Date {
        try cursorsRepo.advance(templateId: "T1", destinationId: destinationId ?? folderDestId,
                                to: watermark, lastRunId: "seed", manifestSha: sha, now: now)
        return watermark
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

    // MARK: - 7. EPIC-17: the delta manifest (§22.5/§22.6)

    /// A delta bundle must SAY it is a delta and carry the window it covered. Without these fields
    /// a consumer cannot tell an incremental file from a full one, and would either double-apply a
    /// full export or treat a delta as the complete picture.
    func testDeltaManifestCarriesIsDeltaAndBothCursors() async throws {
        try seedFolderDestination()
        let watermark = try seedCursor(at: now.addingTimeInterval(-10_000))
        let fresh = try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        XCTAssertEqual(outcome.run.outcome, .success)
        let manifest = try manifestObject(outcome.result)
        XCTAssertEqual(manifest["is_delta"] as? Bool, true, "a delta run must declare itself a delta")
        XCTAssertEqual(try parseISO(manifest["cursor_before"]), watermark,
                       "cursor_before is the watermark the delta started from")
        XCTAssertEqual(try parseISO(manifest["cursor_after"]), fresh.provenance.ingestedAt,
                       "cursor_after is the watermark this file's rows advance the cursor to")
        // The chain root: no prior delta, so no link to point at — null, never a fabricated sha.
        XCTAssertNil(manifest["previous_manifest_sha"] as? String,
                     "the first delta in a chain has no predecessor")
        // The manifest's cursor_after must equal what the cursor ACTUALLY advanced to, or the file
        // describes a window the ledger disagrees with.
        XCTAssertEqual(outcome.run.cursorAfter, fresh.provenance.ingestedAt)
    }

    /// A NON-delta run must stay exactly as it was: `is_delta: false`, null cursors, no chain link.
    /// This is what keeps every existing export (and the byte-pinned parity golden) unchanged.
    ///
    /// Run WITH a checkpoint already on disk, which is the case that can actually go wrong: the run
    /// still computes a max `ingested_at` (the two-phase commit needs it) and `runTemplate` still
    /// reads the cursor's stored chain link, so nothing but an explicit gate stops a whole-window
    /// export from publishing `is_delta: false` beside a populated `cursor_after` and a
    /// `previous_manifest_sha` pointing at a delta it does not continue — a file that would read as
    /// a link in an incremental chain it has no business being part of.
    func testFullRunCarriesNoDeltaMetadata() async throws {
        try seedShareSheet()
        try seedCursor(at: now.addingTimeInterval(-7_200),
                       sha: ManifestDigest(hex: String(repeating: "c", count: 64)),
                       destinationId: ExportDestination.shareSheetId)
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        let runner = makeRunner()

        let outcome = await runner.runTemplate(template(rangeRule: .allTime, format: .json),
                                               trigger: .manual)

        let manifest = try manifestObject(outcome.result)
        XCTAssertEqual(manifest["is_delta"] as? Bool, false)
        XCTAssertTrue(manifest["cursor_before"] is NSNull)
        XCTAssertTrue(manifest["cursor_after"] is NSNull)
        XCTAssertTrue(manifest["previous_manifest_sha"] is NSNull)
        // Absent, not empty: a full run makes no claim about dedup flips, so the key is missing.
        XCTAssertNil(try bundleObject(outcome.result)["corrections"],
                     "a non-delta bundle carries no corrections key at all")
    }

    // MARK: - 8. EPIC-17: manifest chain integrity across two delta runs

    /// The acceptance case: two consecutive deltas, where the second's `previous_manifest_sha` is
    /// exactly `sha256(<the first bundle file>)`. That equality is what lets a consumer (and
    /// `scripts/verify_export_chain.py`) prove no delta in the sequence went missing.
    func testTwoRunDeltaSequenceChainsByBundleSha() async throws {
        try seedFolderDestination()
        let watermark = try seedCursor(at: now.addingTimeInterval(-10_000))
        let first = try insertSample(ingestedAt: now.addingTimeInterval(-5_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])
        let jsonTemplate = template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId)

        // Run 1 — the chain root.
        let run1 = await runner.runTemplate(jsonTemplate, trigger: .scheduledWork)
        XCTAssertEqual(run1.run.outcome, .success)
        let run1Sha = try bundleFileSha(run1.result)
        // The cursor stores the BUNDLE's sha (not the manifest struct's), which is what the next
        // run carries forward and what a consumer recomputes from the file.
        let cursorAfterRun1 = try XCTUnwrap(cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId))
        XCTAssertEqual(cursorAfterRun1.lastManifestSha?.hex, run1Sha,
                       "the cursor's chain link must be sha256(bundle.json)")
        XCTAssertEqual(cursorAfterRun1.highWatermark, first.provenance.ingestedAt)

        // Run 2 — a second delta over a newly-arrived row.
        let second = try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let run2 = await runner.runTemplate(jsonTemplate, trigger: .scheduledWork)
        XCTAssertEqual(run2.run.outcome, .success)

        let manifest2 = try manifestObject(run2.result)
        XCTAssertEqual(manifest2["previous_manifest_sha"] as? String, run1Sha,
                       "run 2 must chain to run 1 by its bundle sha — the whole point of the chain")
        // Contiguous window: run 2 opens exactly where run 1 closed. No gap, no overlap.
        XCTAssertEqual(try parseISO(manifest2["cursor_before"]), first.provenance.ingestedAt)
        XCTAssertEqual(try parseISO(manifest2["cursor_after"]), second.provenance.ingestedAt)
        let manifest1 = try manifestObject(run1.result)
        XCTAssertEqual(manifest2["cursor_before"] as? String, manifest1["cursor_after"] as? String,
                       "cursor_before[n] must equal cursor_after[n-1] — what the chain verifier checks")

        // Delta means DELTA: run 2 carries only the newly-arrived row, not the one run 1 delivered.
        let rawIds = (try bundleObject(run2.result)["raw_samples"] as? [[String: Any]] ?? [])
            .compactMap { $0["record_id"] as? String }
        XCTAssertEqual(rawIds, [second.id], "a delta exports only rows ingested after the cursor")
        XCTAssertFalse(rawIds.contains(first.id), "run 1's row must not be re-exported")
        _ = watermark
    }

    /// A failed delivery must not advance the cursor OR break the chain: the retry re-reads the
    /// same watermark AND re-emits the same `previous_manifest_sha`, so the retried delta is
    /// idempotent — the same window, chained at the same place. This is the manifest-level twin of
    /// the DATA-08 two-phase-commit guard `testRetryReusesTheSameCursorWindow…` covers for rows.
    func testRetriedDeltaReusesTheSameWindowAndChainLink() async throws {
        try seedFolderDestination()
        let seedSha = ManifestDigest(hex: String(repeating: "a", count: 64))
        let watermark = try seedCursor(at: now.addingTimeInterval(-10_000), sha: seedSha)
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let jsonTemplate = template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId)

        let failing = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .failure(now))])
        let attempt1 = await failing.runTemplate(jsonTemplate, trigger: .scheduledWork)
        XCTAssertEqual(attempt1.run.outcome, .failedDelivery)
        let manifest1 = try manifestObject(attempt1.result)

        let succeeding = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])
        let retry = await succeeding.runTemplate(jsonTemplate, trigger: .retry, attempt: 1)
        XCTAssertEqual(retry.run.outcome, .success)
        let manifest2 = try manifestObject(retry.result)

        XCTAssertEqual(manifest1["previous_manifest_sha"] as? String, seedSha?.hex)
        XCTAssertEqual(manifest2["previous_manifest_sha"] as? String, seedSha?.hex,
                       "a retry must chain at the same place — the failed attempt moved nothing")
        XCTAssertEqual(manifest1["cursor_before"] as? String, manifest2["cursor_before"] as? String,
                       "a retry must re-export the same window")
        XCTAssertEqual(try parseISO(manifest2["cursor_before"]), watermark)
    }

    // MARK: - 9. EPIC-17: deletions[] — tombstones since the cursor

    /// A delta that only ever ADDS rows can never tell a downstream store a record went away. The
    /// tombstone section is what closes that: a row soft-deleted after the last cursor is reported
    /// by id + `deleted_at`, even though the delta's own gather (live rows only) never sees it.
    func testDeltaEmitsDeletionsForRowsTombstonedSinceTheCursor() async throws {
        try seedFolderDestination()
        // A row exported by an earlier run (ingested BEFORE the watermark), then deleted after it.
        let doomed = try insertSample(ingestedAt: now.addingTimeInterval(-20_000), externalId: "hk-doomed-1")
        let watermark = try seedCursor(at: now.addingTimeInterval(-10_000))
        let deletedAt = now.addingTimeInterval(-2_000) // after the watermark
        XCTAssertTrue(try MeasurementRepository(db.main).softDelete(
            table: "raw_samples", metricId: "heart.rhr", externalId: "hk-doomed-1",
            sourceId: "watch", updatedAt: deletedAt), "the fixture row must actually be tombstoned")
        // Plus one genuinely new row, so this is a normal delta and not an empty one.
        let fresh = try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        let bundle = try bundleObject(outcome.result)
        let deletions = try XCTUnwrap(bundle["deletions"] as? [[String: Any]])
        let tombstone = try XCTUnwrap(deletions.first { $0["record_id"] as? String == doomed.id },
                                      "the row deleted since the cursor must appear in deletions[]")
        XCTAssertEqual(tombstone["entity"] as? String, "raw_sample")
        XCTAssertEqual(try parseISO(tombstone["deleted_at"]), deletedAt)
        // The deleted row must NOT come back as live data — it is a removal, not an addition.
        let rawIds = (bundle["raw_samples"] as? [[String: Any]] ?? []).compactMap { $0["record_id"] as? String }
        XCTAssertFalse(rawIds.contains(doomed.id), "a tombstoned row is reported, never re-delivered as live")
        XCTAssertEqual(rawIds, [fresh.id])
        _ = watermark
    }

    // MARK: - 10. EPIC-17: corrections[] — suppression flips since the cursor

    /// The subtle one. A downstream store already holds the losing row as authoritative. When dedup
    /// later decides the OTHER row wins, an add-only delta says nothing and the two stores silently
    /// diverge forever. The correction record is the fix, and this is the test that it fires.
    func testDeltaEmitsCorrectionWhenDedupSuppressesARowSinceTheCursor() async throws {
        try seedFolderDestination()
        let loser = try insertSample(ingestedAt: now.addingTimeInterval(-20_000))
        let winner = try insertSample(ingestedAt: now.addingTimeInterval(-19_000))
        try seedCursor(at: now.addingTimeInterval(-10_000))
        // The flip happens AFTER the cursor: dedup suppresses the row already delivered as live.
        let decidedAt = now.addingTimeInterval(-3_000)
        try MeasurementRepository(db.main).setSuppressed(table: "raw_samples", recordId: loser.id,
                                                         by: winner.id, updatedAt: decidedAt)
        try reconciliationRepo.insert(ReconciliationDecision(
            id: ULID.newID(), rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: winner.id, suppressedRecordId: loser.id, decidedAt: decidedAt))
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        let corrections = try XCTUnwrap(try bundleObject(outcome.result)["corrections"] as? [[String: Any]],
                                        "a dedup flip since the cursor must emit corrections[]")
        let correction = try XCTUnwrap(corrections.first { $0["record_id"] as? String == loser.id })
        XCTAssertEqual(correction["suppressed_by"] as? String, winner.id,
                       "the correction names the record that now wins")
        XCTAssertEqual(try parseISO(correction["changed_at"]), decidedAt)
    }

    /// The reverse flip, which is the one an add-only delta corrupts most quietly: a suppression is
    /// REVERSED, so a row the consumer holds as suppressed is authoritative again. `suppressed_by`
    /// must be null — explicitly "no longer suppressed", not merely absent.
    func testDeltaEmitsCorrectionWhenASuppressionIsReversedSinceTheCursor() async throws {
        try seedFolderDestination()
        let revived = try insertSample(ingestedAt: now.addingTimeInterval(-20_000))
        let other = try insertSample(ingestedAt: now.addingTimeInterval(-19_000))
        let decidedAt = now.addingTimeInterval(-18_000) // suppressed BEFORE the cursor
        let decisionId = ULID.newID()
        try reconciliationRepo.insert(ReconciliationDecision(
            id: decisionId, rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: other.id, suppressedRecordId: revived.id, decidedAt: decidedAt))
        try seedCursor(at: now.addingTimeInterval(-10_000))
        // ...and reversed AFTER it: the consumer's copy is now wrong and nothing else would say so.
        let reversedAt = now.addingTimeInterval(-2_000)
        try reconciliationRepo.markReversed(id: decisionId, at: reversedAt)
        try MeasurementRepository(db.main).setSuppressed(table: "raw_samples", recordId: revived.id,
                                                         by: nil, updatedAt: reversedAt)
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        let corrections = try XCTUnwrap(try bundleObject(outcome.result)["corrections"] as? [[String: Any]])
        let correction = try XCTUnwrap(corrections.first { $0["record_id"] as? String == revived.id },
                                       "a reversal since the cursor must be corrected downstream")
        XCTAssertTrue(correction["suppressed_by"] is NSNull,
                      "a cleared suppression reports null — the record wins again")
        XCTAssertEqual(try parseISO(correction["changed_at"]), reversedAt,
                       "changed_at is the reversal instant, the most recent flip")
    }

    /// A flip that happened BEFORE the cursor was already reflected in an earlier export, so
    /// re-sending it would be noise. Only changes since the watermark are corrections.
    func testFlipsOlderThanTheCursorAreNotReEmitted() async throws {
        try seedFolderDestination()
        let loser = try insertSample(ingestedAt: now.addingTimeInterval(-30_000))
        let winner = try insertSample(ingestedAt: now.addingTimeInterval(-29_000))
        try reconciliationRepo.insert(ReconciliationDecision(
            id: ULID.newID(), rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: winner.id, suppressedRecordId: loser.id,
            decidedAt: now.addingTimeInterval(-25_000)))            // before the cursor
        try seedCursor(at: now.addingTimeInterval(-10_000))
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        XCTAssertNil(try bundleObject(outcome.result)["corrections"],
                     "a flip older than the cursor is already downstream — absent, not an empty array")
    }

    /// One record can flip TWICE inside a single delta window (suppressed by A, then by B once a
    /// source-priority change re-ran dedup). Both corrections share a `record_id`, so the array's
    /// order falls to `changed_at` — and it must be the order the flips happened in, or a consumer
    /// applying the array in order ends up holding the intermediate verdict as final.
    ///
    /// This is also the only tie in `corrections[]` that a `record_id`-only comparator would leave
    /// to the sort's own discretion, and Swift's `sorted(by:)` is explicitly not guaranteed stable
    /// while Kotlin's is — so without the tiebreaker the two platforms could order the same pair
    /// differently and the byte-parity claim would fail silently, on real data only.
    func testRepeatedFlipsForOneRecordAreOrderedByChangedAt() async throws {
        try seedFolderDestination()
        let contested = try insertSample(ingestedAt: now.addingTimeInterval(-30_000))
        let winnerA = try insertSample(ingestedAt: now.addingTimeInterval(-29_000))
        let winnerB = try insertSample(ingestedAt: now.addingTimeInterval(-28_000))
        try seedCursor(at: now.addingTimeInterval(-10_000))
        // Both flips land after the cursor. Journaled newest-first so the ordering under test cannot
        // be satisfied by insertion order alone.
        let secondFlip = now.addingTimeInterval(-2_000)
        let firstFlip = now.addingTimeInterval(-6_000)
        try reconciliationRepo.insert(ReconciliationDecision(
            id: ULID.newID(), rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: winnerB.id, suppressedRecordId: contested.id, decidedAt: secondFlip))
        try reconciliationRepo.insert(ReconciliationDecision(
            id: ULID.newID(), rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: winnerA.id, suppressedRecordId: contested.id, decidedAt: firstFlip))
        try MeasurementRepository(db.main).setSuppressed(table: "raw_samples", recordId: contested.id,
                                                         by: winnerB.id, updatedAt: secondFlip)
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000)) // a normal delta, not an empty one
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId),
            trigger: .scheduledWork)

        let corrections = try XCTUnwrap(try bundleObject(outcome.result)["corrections"] as? [[String: Any]])
        let forRecord = corrections.filter { $0["record_id"] as? String == contested.id }
        XCTAssertEqual(forRecord.count, 2, "both flips in the window are reported, not just the last")
        XCTAssertEqual(try parseISO(forRecord[0]["changed_at"]), firstFlip)
        XCTAssertEqual(forRecord[0]["suppressed_by"] as? String, winnerA.id)
        XCTAssertEqual(try parseISO(forRecord[1]["changed_at"]), secondFlip)
        XCTAssertEqual(forRecord[1]["suppressed_by"] as? String, winnerB.id,
                       "applied in array order, the last correction leaves the record's CURRENT winner")
    }

    // MARK: - 10b. EPIC-17: the CSV delta carries the same reconciliation the JSON one does

    /// The A1 finding, in test form. The delta reconciliation queries used to run only for JSON,
    /// while the cursor advance is format-blind — so a CSV `sinceLastRun` template emitted no
    /// removals, no corrections, and STILL closed its window. A downstream store fed by those files
    /// kept rows BADAN had deleted, forever, with nothing saying so.
    func testCSVDeltaEmitsDeletionsAndCorrectionsAndStillAdvancesTheCursor() async throws {
        try seedFolderDestination()
        let doomed = try insertSample(ingestedAt: now.addingTimeInterval(-20_000), externalId: "hk-doomed-csv")
        let loser = try insertSample(ingestedAt: now.addingTimeInterval(-19_000))
        let winner = try insertSample(ingestedAt: now.addingTimeInterval(-18_000))
        try seedCursor(at: now.addingTimeInterval(-10_000))

        let deletedAt = now.addingTimeInterval(-3_000)
        XCTAssertTrue(try MeasurementRepository(db.main).softDelete(
            table: "raw_samples", metricId: "heart.rhr", externalId: "hk-doomed-csv",
            sourceId: "watch", updatedAt: deletedAt))
        let decidedAt = now.addingTimeInterval(-2_500)
        try MeasurementRepository(db.main).setSuppressed(table: "raw_samples", recordId: loser.id,
                                                         by: winner.id, updatedAt: decidedAt)
        try reconciliationRepo.insert(ReconciliationDecision(
            id: ULID.newID(), rule: "heart.rhr.overlap.v1", ruleVersion: "1.0.0",
            keptRecordId: winner.id, suppressedRecordId: loser.id, decidedAt: decidedAt))
        let fresh = try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .csv, destinationId: folderDestId),
            trigger: .scheduledWork)

        let deletions = try csvRows(outcome.result, named: "deletions.csv")
        XCTAssertEqual(deletions.first, ["record_id", "entity", "deleted_at"])
        let tombstone = try XCTUnwrap(deletions.dropFirst().first { $0.first == doomed.id },
                                      "a CSV delta must report the row deleted since the cursor")
        XCTAssertEqual(tombstone[1], "raw_sample")
        XCTAssertEqual(try parseISO(tombstone[2]), deletedAt)

        let corrections = try csvRows(outcome.result, named: "corrections.csv")
        XCTAssertEqual(corrections.first, ["record_id", "suppressed_by", "changed_at"])
        let correction = try XCTUnwrap(corrections.dropFirst().first { $0.first == loser.id },
                                       "a CSV delta must report the dedup flip since the cursor")
        XCTAssertEqual(correction[1], winner.id)
        XCTAssertEqual(try parseISO(correction[2]), decidedAt)

        // Both files are checksummed like every other CSV, so truncation/tampering is detectable.
        let checksums = try XCTUnwrap(outcome.result?.job.manifest?.checksums)
        XCTAssertNotNil(checksums["deletions.csv"])
        XCTAssertNotNil(checksums["corrections.csv"])

        // And the watermark still moves — which is only honest now that the removals travelled.
        XCTAssertEqual(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId)?.highWatermark,
                       fresh.provenance.ingestedAt)
    }

    /// A delta with nothing to reconcile still writes both tables, header-only. A CSV manifest
    /// carries no `is_delta` flag, so the files' PRESENCE is what marks the artifact as a delta and
    /// an empty table is the affirmative "nothing was removed" — otherwise a consumer cannot tell
    /// that apart from "this exporter never reports removals".
    func testCSVDeltaWritesBothTablesEvenWhenThereIsNothingToReport() async throws {
        try seedFolderDestination()
        try seedCursor(at: now.addingTimeInterval(-10_000))
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .csv, destinationId: folderDestId),
            trigger: .scheduledWork)

        XCTAssertEqual(try csvRows(outcome.result, named: "deletions.csv").count, 1,
                       "header only — an affirmative 'nothing was removed'")
        XCTAssertEqual(try csvRows(outcome.result, named: "corrections.csv").count, 1)
    }

    /// The other half of the rule: a NON-delta CSV export must be byte-identical to what it always
    /// was. Writing empty reconciliation tables into a full-window export would make a plain
    /// "export everything" file read as a link in an incremental chain.
    func testNonDeltaCSVExportWritesNeitherReconciliationTable() async throws {
        try seedShareSheet()
        try insertSample(ingestedAt: now.addingTimeInterval(-1_000))
        let runner = makeRunner()

        let outcome = await runner.runTemplate(template(rangeRule: .allTime, format: .csv),
                                               trigger: .manual)

        let names = Set((outcome.result?.fileURLs ?? []).map { $0.lastPathComponent })
        XCTAssertFalse(names.contains("deletions.csv"))
        XCTAssertFalse(names.contains("corrections.csv"))
        XCTAssertNil(outcome.result?.job.manifest?.checksums["deletions.csv"])
    }

    /// A delta whose ONLY content is a removal must stay `skippedNoData` and leave the cursor alone.
    /// If tombstones counted as exported rows the run would look like it moved data, and the closed
    /// window would stop the removal being re-reported to a consumer that missed this file.
    func testADeletionsOnlyCSVDeltaDoesNotCountAsRowsAndDoesNotAdvanceTheCursor() async throws {
        try seedFolderDestination()
        try insertSample(ingestedAt: now.addingTimeInterval(-20_000), externalId: "hk-only-deleted")
        let watermark = try seedCursor(at: now.addingTimeInterval(-10_000))
        XCTAssertTrue(try MeasurementRepository(db.main).softDelete(
            table: "raw_samples", metricId: "heart.rhr", externalId: "hk-only-deleted",
            sourceId: "watch", updatedAt: now.addingTimeInterval(-2_000)))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])

        let outcome = await runner.runTemplate(
            template(rangeRule: .sinceLastRun, format: .csv, destinationId: folderDestId),
            trigger: .scheduledWork)

        XCTAssertEqual(outcome.result?.rowCount, 0, "a tombstone is a record going away, not one exported")
        XCTAssertEqual(outcome.run.outcome, .skippedNoData)
        XCTAssertEqual(try csvRows(outcome.result, named: "deletions.csv").count, 2,
                       "the removal is still reported — header + one row")
        XCTAssertEqual(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId)?.highWatermark,
                       watermark, "the window stays open so the removal is re-reported next time")
    }

    // MARK: - 11. EPIC-17: cursor reset ("re-export everything")

    /// The §12 edge rule. After a reset the next `sinceLastRun` run must stop filtering by the old
    /// watermark and re-export — surfacing the fallback notice rather than silently continuing the
    /// old chain, and starting a fresh chain (no `previous_manifest_sha`).
    func testResetCursorMakesTheNextRunReExportAndStartANewChain() async throws {
        try seedFolderDestination()
        let old = try insertSample(ingestedAt: now.addingTimeInterval(-5_000))
        try seedCursor(at: now.addingTimeInterval(-4_000),
                       sha: ManifestDigest(hex: String(repeating: "b", count: 64)))
        let runner = makeRunner(deliverers: [StubDeliverer(kind: .fileFolder, receipt: .success(now))])
        let jsonTemplate = template(rangeRule: .sinceLastRun, format: .json, destinationId: folderDestId)

        // Before the reset: a delta that skips the already-delivered row.
        let before = await runner.runTemplate(jsonTemplate, trigger: .scheduledWork)
        let beforeIds = (try bundleObject(before.result)["raw_samples"] as? [[String: Any]] ?? [])
            .compactMap { $0["record_id"] as? String }
        XCTAssertFalse(beforeIds.contains(old.id), "the delta correctly skips the pre-cursor row")

        XCTAssertTrue(runner.resetCursor(templateId: "T1", destinationId: folderDestId))
        XCTAssertNil(try cursorsRepo.cursor(templateId: "T1", destinationId: folderDestId),
                     "reset drops the checkpoint outright")

        // After the reset: the run re-exports (the row is back) and says so via the notice.
        let after = await runner.runTemplate(jsonTemplate, trigger: .manual)
        XCTAssertTrue(after.cursorFallbackNotice, "a re-export must disclose it lost its checkpoint")
        XCTAssertEqual(after.run.errorCode, .cursorMissing)
        let afterIds = (try bundleObject(after.result)["raw_samples"] as? [[String: Any]] ?? [])
            .compactMap { $0["record_id"] as? String }
        XCTAssertTrue(afterIds.contains(old.id), "after a reset the previously-skipped row is re-exported")
        let manifest = try manifestObject(after.result)
        XCTAssertEqual(manifest["is_delta"] as? Bool, false, "a post-reset run is a full window, not a delta")
        XCTAssertTrue(manifest["previous_manifest_sha"] is NSNull,
                      "a reset starts a NEW chain — it must not claim to continue the old one")
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
