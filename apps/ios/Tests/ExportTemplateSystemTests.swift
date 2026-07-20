import XCTest
@testable import BADAN

/// EPIC-09 — the export template system's domain layer over migration v4's tables.
///
/// Three of these tests are load-bearing rather than incidental, and should be treated as the
/// reason the file exists:
///  - `testExportRunLedgerCarriesNoHealthValues` is the `ExportRun` analogue of
///    `DiagnosticsTests.testPlainTextContainsNoHealthData`. The ledger is displayed in Export
///    Health and rides along in a full backup, so a health value reaching it is a leak.
///  - `testPresetScopesGrantNoWideningPermission` reflects over the preset scope instead of
///    naming fields, so a future `includeRoutes` (or any other widening flag) added to
///    `ExportScope` is covered on the day it lands.
///  - `testCredentialRefRejectsThingsThatLookLikeSecrets` is what makes "credentials never go in
///    the database" a property of the type rather than a note in a doc comment.
final class ExportTemplateSystemTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!

    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-export-domain-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var templates: ExportTemplateRepository { ExportTemplateRepository(db.main) }
    private var destinations: ExportDestinationRepository { ExportDestinationRepository(db.main) }
    private var runs: ExportRunRepository { ExportRunRepository(db.main) }
    private var cursors: ExportCursorRepository { ExportCursorRepository(db.main) }

    private func makeTemplate(id: String = "T1", name: String = "Weekly vitals",
                              scope: ExportScope = .everything,
                              rangeRule: ExportRangeRule = .lastNDays(7),
                              aggregation: ExportAggregation = .raw) -> ExportTemplate {
        ExportTemplate(id: id, name: name, scope: scope, rangeRule: rangeRule, format: .csv,
                       aggregation: aggregation, layout: .wide, includeSchemaDocs: true,
                       destinationId: ExportDestination.shareSheetId,
                       createdAt: now, updatedAt: now, originDeviceId: deviceId)
    }

    // MARK: - ExportTemplate persistence (§9.3)

    func testTemplateRoundTripsEveryField() throws {
        let template = makeTemplate(aggregation: .bucketed(.day, method: .minAvgMax))
        try templates.insert(template)

        let loaded = try XCTUnwrap(templates.template(id: "T1"))
        XCTAssertEqual(loaded, template)
        XCTAssertEqual(loaded.aggregation, .bucketed(.day, method: .minAvgMax))
        XCTAssertEqual(loaded.rangeRule, .lastNDays(7))
        XCTAssertEqual(loaded.layout, .wide)
        XCTAssertTrue(loaded.includeSchemaDocs)
    }

    /// The nullable `aggregation_method` column, exercised from both sides: `.raw` must write a
    /// NULL and read back as `.raw`, which is the invariant `ExportAggregation`'s enum shape
    /// exists to guarantee.
    func testRawAggregationStoresNullMethod() throws {
        try templates.insert(makeTemplate(aggregation: .raw))

        let row = try XCTUnwrap(db.main.query("SELECT * FROM export_templates WHERE id = 'T1';").first)
        XCTAssertEqual(row.string("aggregation"), "raw")
        XCTAssertNil(row.string("aggregation_method"))
        XCTAssertEqual(try templates.template(id: "T1")?.aggregation, .raw)
    }

    func testDuplicateLiveNameIsRefused() throws {
        try templates.insert(makeTemplate(id: "T1", name: "Weekly vitals"))

        XCTAssertThrowsError(try templates.insert(makeTemplate(id: "T2", name: "Weekly vitals"))) { error in
            XCTAssertEqual(error as? ExportTemplateError, .nameTaken("Weekly vitals"))
        }
    }

    /// The partial index (`WHERE deleted_at IS NULL`) exists so a deleted template stops squatting
    /// on its name. A user who deletes "Weekly vitals" and recreates it must not hit a constraint
    /// failure over a row they can no longer see.
    func testDeletedTemplateFreesItsName() throws {
        try templates.insert(makeTemplate(id: "T1", name: "Weekly vitals"))
        try templates.softDelete(id: "T1", at: now)

        XCTAssertTrue(try templates.isNameAvailable("Weekly vitals", excludingId: nil))
        XCTAssertNoThrow(try templates.insert(makeTemplate(id: "T2", name: "Weekly vitals")))
        XCTAssertNil(try templates.template(id: "T1"))
        XCTAssertEqual(try templates.all().count, 1)
    }

    func testRenamingATemplateToItsOwnNameIsAllowed() throws {
        try templates.insert(makeTemplate(id: "T1", name: "Weekly vitals"))
        var updated = makeTemplate(id: "T1", name: "Weekly vitals")
        updated.layout = .tidy
        XCTAssertNoThrow(try templates.update(updated))
        XCTAssertEqual(try templates.template(id: "T1")?.layout, .tidy)
    }

    func testUpdatingAMissingTemplateIsRefused() {
        XCTAssertThrowsError(try templates.update(makeTemplate(id: "ghost"))) { error in
            XCTAssertEqual(error as? ExportTemplateError, .notFound(id: "ghost"))
        }
    }

    // MARK: - Quick Export presets (§12 EPIC-10)

    func testSeedingPresetsIsIdempotent() throws {
        let first = try templates.seedPresets(now: now, originDeviceId: deviceId)
        XCTAssertEqual(first, QuickExportPreset.allCases.count)

        let second = try templates.seedPresets(now: now.addingTimeInterval(86_400), originDeviceId: deviceId)
        XCTAssertEqual(second, 0, "re-seeding must insert nothing")
        XCTAssertEqual(try templates.all().count, QuickExportPreset.allCases.count)
    }

    func testPresetsCoverEveryRangeAndFormatCombination() {
        XCTAssertEqual(QuickExportPreset.allCases.count, 6)
        let combinations = Set(QuickExportPreset.allCases.map { "\($0.rangeRule.storageValue)/\($0.format.rawValue)" })
        XCTAssertEqual(combinations, ["lastNDays:7/csv", "lastNDays:7/json",
                                      "lastNDays:30/csv", "lastNDays:30/json",
                                      "allTime/csv", "allTime/json"])
    }

    /// I8: every id is a ULID, including the hand-written preset ids. A 25-character typo would
    /// otherwise persist happily and only surface as a mismatch against some future id validator.
    func testPresetIdsAreWellFormedULIDs() {
        for preset in QuickExportPreset.allCases {
            XCTAssertEqual(preset.id.count, 26, "\(preset) id must be 26 chars")
            XCTAssertTrue(preset.id.allSatisfy { ULID.alphabet.contains($0) },
                          "\(preset) id must be Crockford base32")
            XCTAssertNotNil(ULID.timestamp(of: preset.id))
        }
        XCTAssertEqual(ExportDestination.shareSheetId.count, 26)
        XCTAssertTrue(ExportDestination.shareSheetId.allSatisfy { ULID.alphabet.contains($0) })
    }

    /// §12 EPIC-10: presets exclude sensitive namespaces and routes **structurally**.
    ///
    /// Reflects over the built scope rather than asserting two named fields, so this test also
    /// covers permissions that do not exist yet: if `ExportScope` gains an `includeRoutes` (or
    /// any other `include*` widening flag) and `QuickExportPreset.presetScope` is not updated to
    /// deny it, this fails without anyone having to remember to come back here.
    func testPresetScopesGrantNoWideningPermission() {
        // Raw and derived are the two permissions a preset is *supposed* to grant: raw data is
        // never withheld, and the derived values are what make the file legible.
        let allowed: Set<String> = ["includeRaw", "includeDerived"]
        var checked = 0

        for preset in QuickExportPreset.allCases {
            let scope = preset.template(now: now, originDeviceId: deviceId).scope
            for child in Mirror(reflecting: scope).children {
                guard let label = child.label, label.hasPrefix("include"),
                      let granted = child.value as? Bool, !allowed.contains(label) else { continue }
                checked += 1
                XCTAssertFalse(granted, "preset \(preset) must not grant \(label)")
            }
        }

        // Guards against the test silently becoming vacuous if the `include*` naming convention
        // changes — `includeSensitive` and `includeSuppressed` are both expected to be found.
        XCTAssertGreaterThanOrEqual(checked, 2 * QuickExportPreset.allCases.count)
    }

    func testPresetsAreReadOnly() throws {
        try templates.seedPresets(now: now, originDeviceId: deviceId)
        let preset = try XCTUnwrap(templates.template(id: QuickExportPreset.last7CSV.id))
        XCTAssertTrue(preset.isPreset)

        var edited = preset
        edited.scope.includeSensitive = true
        XCTAssertThrowsError(try templates.update(edited)) { error in
            XCTAssertEqual(error as? ExportTemplateError, .presetIsReadOnly(id: preset.id))
        }
        XCTAssertThrowsError(try templates.softDelete(id: preset.id, at: now)) { error in
            XCTAssertEqual(error as? ExportTemplateError, .presetIsReadOnly(id: preset.id))
        }
        XCTAssertEqual(try templates.template(id: preset.id)?.scope.includeSensitive, false)
    }

    func testUserTemplatesAreNotPresets() {
        XCTAssertFalse(makeTemplate().isPreset)
    }

    // MARK: - Sensitive re-confirmation at run time (§9.3 privacy)

    func testNonSensitiveTemplateNeedsNoConfirmation() throws {
        let template = makeTemplate()
        XCTAssertFalse(template.requiresSensitiveConfirmation)
        XCTAssertEqual(try template.scopeForRun(consent: nil, now: now), template.scope)
    }

    func testSensitiveTemplateRefusesToRunWithoutConfirmation() {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)

        XCTAssertTrue(template.requiresSensitiveConfirmation)
        XCTAssertThrowsError(try template.scopeForRun(consent: nil, now: now)) { error in
            XCTAssertEqual(error as? ExportTemplateRunRefusal, .sensitiveConfirmationRequired(templateId: "T1"))
        }
    }

    func testFreshConfirmationForThisTemplateUnlocksTheSensitiveScope() throws {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)
        let consent = SensitiveRunConsent(templateId: "T1", confirmedAt: now)

        let resolved = try template.scopeForRun(consent: consent, now: now.addingTimeInterval(30))
        XCTAssertTrue(resolved.includeSensitive)
    }

    /// A confirmation is per-template. Reusing the one the user gave for a different template
    /// would let a template they never confirmed export their meds and symptoms.
    func testConfirmationForAnotherTemplateIsRefused() {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)
        let consent = SensitiveRunConsent(templateId: "OTHER", confirmedAt: now)

        XCTAssertThrowsError(try template.scopeForRun(consent: consent, now: now)) { error in
            XCTAssertEqual(error as? ExportTemplateRunRefusal,
                           .sensitiveConfirmationForDifferentTemplate(expected: "T1", received: "OTHER"))
        }
    }

    func testStaleConfirmationIsRefused() {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)
        let consent = SensitiveRunConsent(templateId: "T1", confirmedAt: now)
        let later = now.addingTimeInterval(SensitiveRunConsent.validityWindow + 1)

        XCTAssertThrowsError(try template.scopeForRun(consent: consent, now: later)) { error in
            XCTAssertEqual(error as? ExportTemplateRunRefusal, .sensitiveConfirmationExpired(templateId: "T1"))
        }
    }

    /// A clock moving backwards (timezone change, NTP correction, a user setting the date) must
    /// not turn into an indefinitely-valid confirmation.
    func testConfirmationTimestampedInTheFutureIsRefused() {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)
        let consent = SensitiveRunConsent(templateId: "T1", confirmedAt: now.addingTimeInterval(600))

        XCTAssertThrowsError(try template.scopeForRun(consent: consent, now: now))
    }

    /// A refusal is never a quiet downgrade: the sensitive scope either runs confirmed or does
    /// not run. Handing back `includeSensitive = false` would produce a file missing exactly the
    /// records the user asked for, with nothing in it saying so.
    func testRefusalNeverSilentlyNarrowsTheScope() {
        var scope = ExportScope.everything
        scope.includeSensitive = true
        let template = makeTemplate(scope: scope)

        var returned: ExportScope?
        returned = try? template.scopeForRun(consent: nil, now: now)
        XCTAssertNil(returned)
    }

    // MARK: - ExportRun, the trust ledger (§9.5)

    private func makeRun(id: String = "R1", templateId: String? = "T1", jobId: String? = "J1",
                         outcome: ExportOutcome = .success,
                         destinationId: String? = ExportDestination.shareSheetId,
                         startedAt: Date? = nil) -> ExportRun {
        ExportRun(id: id, templateId: templateId, jobId: jobId, trigger: .scheduledOpportunistic,
                  startedAt: startedAt ?? now, finishedAt: (startedAt ?? now).addingTimeInterval(12),
                  outcome: outcome, errorCode: outcome.isFailure ? .writeFailed : nil,
                  errorDetail: outcome.isFailure
                      ? ExportErrorDetail(stage: .writing, filesWritten: 2, filesExpected: 5, attempt: 1)
                      : nil,
                  bytesWritten: 40_960,
                  rowCounts: ExportRowCounts(measurements: 900, intervals: 12, sessions: 3,
                                             logs: 7, derived: 30, suppressed: 2),
                  destinationId: destinationId,
                  deliveredAt: (startedAt ?? now).addingTimeInterval(13),
                  cursorBefore: now.addingTimeInterval(-86_400), cursorAfter: now,
                  manifestSha256: ManifestDigest(hex: String(repeating: "a", count: 64)))
    }

    func testRunRoundTripsEveryField() throws {
        let run = makeRun(outcome: .partial)
        try runs.insert(run)
        XCTAssertEqual(try runs.recent().first, run)
    }

    /// The ledger must never be able to carry a health value. This is the `ExportRun` counterpart
    /// of `DiagnosticsTests.testPlainTextContainsNoHealthData`, and it checks the property two
    /// ways: no leak-shaped token anywhere in the serialized row, and — the structural half —
    /// every value inside the two JSON columns is a number or a known enum token, never free text.
    func testExportRunLedgerCarriesNoHealthValues() throws {
        let run = makeRun(outcome: .failedDelivery)
        try runs.insert(run)
        let loaded = try XCTUnwrap(runs.recent().first)
        let encoded = JSONCoding.encode(loaded).lowercased()

        for leak in ["bpm", "heart", "sleep", "weight", "medication", "symptom", "steps", "mmhg"] {
            XCTAssertFalse(encoded.contains(leak), "the run ledger must carry no health data — found \"\(leak)\"")
        }

        for column in ["row_counts", "error_detail"] {
            let json = try XCTUnwrap(db.main.query("SELECT * FROM export_runs WHERE id = 'R1';")
                .first?.string(column))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertFalse(object.isEmpty)
            for (key, value) in object {
                if let number = value as? NSNumber {
                    XCTAssertEqual(number.doubleValue, number.doubleValue.rounded(),
                                   "\(key) must be a whole count — a fractional number is a measurement")
                } else if let text = value as? String {
                    // The only string permitted anywhere in these columns is a closed-enum token.
                    XCTAssertNotNil(ExportStage(rawValue: text),
                                    "\(key) may only hold a known enum token, never free text")
                } else {
                    XCTFail("\(key) must be a count or an enum token, not \(type(of: value))")
                }
            }
        }
    }

    /// `ExportRowCounts` counts by record class, never by metric id — a per-metric map in a
    /// durable, backed-up, screenshot-able log is a standing record of which metrics this person
    /// tracks (the same disclosure Android's `BackgroundWorkDone` refuses).
    func testRowCountsNameNoMetrics() {
        let encoded = JSONCoding.encode(ExportRowCounts(measurements: 5))
        XCTAssertFalse(encoded.lowercased().contains("metric"))
        XCTAssertFalse(encoded.contains("vitals."))
    }

    func testRecentByTemplateIsNewestFirst() throws {
        try runs.insert(makeRun(id: "R1", startedAt: now.addingTimeInterval(-3_600)))
        try runs.insert(makeRun(id: "R2", startedAt: now))
        try runs.insert(makeRun(id: "R3", templateId: "T2", startedAt: now))

        XCTAssertEqual(try runs.recent(templateId: "T1").map(\.id), ["R2", "R1"])
        XCTAssertEqual(try runs.lastRun(templateId: "T1")?.id, "R2")
    }

    /// A partial run's watermark must never be treated as a resume point — the rows it failed to
    /// write would then never appear in any later export.
    func testLastSuccessIgnoresPartialRuns() throws {
        try runs.insert(makeRun(id: "R1", outcome: .success, startedAt: now.addingTimeInterval(-7_200)))
        try runs.insert(makeRun(id: "R2", outcome: .partial, startedAt: now))

        let last = try runs.lastSuccess(templateId: "T1", destinationId: ExportDestination.shareSheetId)
        XCTAssertEqual(last?.id, "R1")
    }

    func testOutcomeCountsAreGroupedInEnumOrder() throws {
        try runs.insert(makeRun(id: "R1", outcome: .success))
        try runs.insert(makeRun(id: "R2", outcome: .success))
        try runs.insert(makeRun(id: "R3", outcome: .throttled))

        let counts = try runs.outcomeCounts(since: now.addingTimeInterval(-86_400))
        XCTAssertEqual(counts.map(\.outcome), [.success, .throttled])
        XCTAssertEqual(counts.map(\.count), [2, 1])
    }

    /// The ledger's own completeness check: a job that produced no run row is an export that
    /// happened with nothing recorded about how it ended.
    func testJobsWithoutARunAreSurfaced() throws {
        let job = ExportJob(id: "J-orphan", scope: .everything, format: .csv, createdAt: now)
        try ExportJobRepository(db.main).insert(job)
        try ExportJobRepository(db.main).insert(ExportJob(id: "J1", scope: .everything, format: .csv,
                                                          createdAt: now))
        try runs.insert(makeRun(jobId: "J1"))

        XCTAssertEqual(try runs.jobIdsWithoutRun(), ["J-orphan"])
    }

    // MARK: - ExportDestination (§9.4)

    func testDestinationRoundTripsAndDefaultsTlsPolicyByKind() throws {
        let folder = ExportDestination(id: "D1", kind: .fileFolder, displayName: "Documents",
                                       config: ExportDestinationConfig(folderBookmarkRef: "bookmark-key"),
                                       createdAt: now, updatedAt: now, originDeviceId: deviceId)
        let api = ExportDestination(id: "D2", kind: .restApi, displayName: "My server",
                                    config: ExportDestinationConfig(endpointURL: "https://example.test/ingest",
                                                                    httpMethod: "POST",
                                                                    headerTemplateIds: ["h1"]),
                                    credentialRef: CredentialRef.forDestination(id: "D2"),
                                    createdAt: now, updatedAt: now, originDeviceId: deviceId)
        try destinations.upsert(folder)
        try destinations.upsert(api)

        XCTAssertEqual(try destinations.destination(id: "D1"), folder)
        XCTAssertEqual(try destinations.destination(id: "D2"), api)
        // A folder write exercises no transport, so it does not claim one.
        XCTAssertEqual(folder.tlsPolicy, .notApplicable)
        XCTAssertEqual(api.tlsPolicy, .httpsOnly)
    }

    func testSeedingShareSheetDestinationIsIdempotent() throws {
        XCTAssertTrue(try destinations.seedShareSheet(now: now, originDeviceId: deviceId))
        XCTAssertFalse(try destinations.seedShareSheet(now: now, originDeviceId: deviceId))
        XCTAssertEqual(try destinations.all().count, 1)
    }

    func testStatusUpdateOnlyAdvancesLastVerifiedOnSuccess() throws {
        try destinations.seedShareSheet(now: now, originDeviceId: deviceId)
        let later = now.addingTimeInterval(3_600)

        try destinations.updateStatus(id: ExportDestination.shareSheetId, status: .ok, checkedAt: now)
        XCTAssertEqual(try destinations.destination(id: ExportDestination.shareSheetId)?.lastVerifiedAt, now)

        try destinations.updateStatus(id: ExportDestination.shareSheetId, status: .unreachable, checkedAt: later)
        let after = try XCTUnwrap(destinations.destination(id: ExportDestination.shareSheetId))
        XCTAssertEqual(after.status, .unreachable)
        XCTAssertEqual(after.lastVerifiedAt, now, "a failed check must not look like a fresh verification")
    }

    /// The point of `CredentialRef`: the only strings it accepts are keys BADAN minted. A pasted
    /// bearer token, a JWT, a password and a raw URL all fail — which is what makes "credentials
    /// never go in the database" a property of the type rather than a review convention.
    func testCredentialRefRejectsThingsThatLookLikeSecrets() {
        XCTAssertNil(CredentialRef(key: "Bearer sk-live-9f8a7b6c5d4e3f2a1b0c"))
        XCTAssertNil(CredentialRef(key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc"))
        XCTAssertNil(CredentialRef(key: "hunter2"))
        XCTAssertNil(CredentialRef(key: "https://example.test/?token=abc123"))
        XCTAssertNil(CredentialRef(key: CredentialRef.namespace), "a bare namespace references nothing")
        XCTAssertNil(CredentialRef(key: CredentialRef.namespace + String(repeating: "a", count: 200)))
        XCTAssertNil(CredentialRef(key: CredentialRef.namespace + "has space"))

        XCTAssertNotNil(CredentialRef.forDestination(id: "01HZY6K3QW9V2N8T4M0X7RBCDE"))
    }

    /// Reading back is validated too, so a hand-edited row cannot smuggle a token out of the
    /// column and into memory as a "credential ref".
    func testCredentialRefIsValidatedOnRead() throws {
        try destinations.seedShareSheet(now: now, originDeviceId: deviceId)
        try db.main.run("UPDATE export_destinations SET credential_ref = ? WHERE id = ?;",
                        [.text("Bearer sk-live-abc"), .text(ExportDestination.shareSheetId)])

        XCTAssertNil(try destinations.destination(id: ExportDestination.shareSheetId)?.credentialRef)
    }

    /// The config column's typed shape is the other half of the same guarantee: there is no field
    /// on `ExportDestinationConfig` a header *value*, token or password fits into.
    func testDestinationConfigHasNoFieldASecretFitsIn() {
        let fields = Set(Mirror(reflecting: ExportDestinationConfig()).children.compactMap(\.label))
        for forbidden in ["token", "secret", "password", "apiKey", "authorization", "headers", "cookie"] {
            XCTAssertFalse(fields.contains(forbidden), "ExportDestinationConfig must not expose \(forbidden)")
        }
        XCTAssertTrue(fields.contains("headerTemplateIds"), "headers are referenced by template id only")
    }

    func testUnparseableDestinationKindReadsAsTheHarmlessOne() throws {
        try destinations.seedShareSheet(now: now, originDeviceId: deviceId)
        try db.main.run("UPDATE export_destinations SET kind = ? WHERE id = ?;",
                        [.text("carrierPigeon"), .text(ExportDestination.shareSheetId)])

        let loaded = try XCTUnwrap(destinations.destination(id: ExportDestination.shareSheetId))
        XCTAssertEqual(loaded.kind, .shareSheet)
        XCTAssertFalse(loaded.kind.leavesDevice)
    }

    // MARK: - ExportCursor (§9.6)

    func testCursorAdvancesOnlyForward() throws {
        let watermark = now
        XCTAssertTrue(try cursors.advance(templateId: "T1", destinationId: "D1", to: watermark,
                                          lastRunId: "R1", manifestSha: nil, now: now))

        // An out-of-order retry reporting an older watermark must not move the cursor: forward
        // motion past unexported rows is how a delta export loses data permanently.
        XCTAssertFalse(try cursors.advance(templateId: "T1", destinationId: "D1",
                                           to: watermark.addingTimeInterval(-3_600),
                                           lastRunId: "R2", manifestSha: nil, now: now))
        XCTAssertEqual(try cursors.cursor(templateId: "T1", destinationId: "D1")?.highWatermark, watermark)
        XCTAssertEqual(try cursors.cursor(templateId: "T1", destinationId: "D1")?.lastRunId, "R1")

        XCTAssertTrue(try cursors.advance(templateId: "T1", destinationId: "D1",
                                          to: watermark.addingTimeInterval(60),
                                          lastRunId: "R3", manifestSha: nil, now: now))
    }

    func testRewindIsExplicitAndReExports() throws {
        try cursors.advance(templateId: "T1", destinationId: "D1", to: now, lastRunId: "R1",
                            manifestSha: nil, now: now)
        let earlier = now.addingTimeInterval(-30 * 86_400)
        try cursors.rewind(templateId: "T1", destinationId: "D1", to: earlier, now: now)

        XCTAssertEqual(try cursors.cursor(templateId: "T1", destinationId: "D1")?.highWatermark, earlier)
    }

    func testResetRemovesTheCheckpointEntirely() throws {
        try cursors.advance(templateId: "T1", destinationId: "D1", to: now, lastRunId: "R1",
                            manifestSha: nil, now: now)
        try cursors.reset(templateId: "T1", destinationId: "D1")
        XCTAssertNil(try cursors.cursor(templateId: "T1", destinationId: "D1"))
    }

    /// One template can hold a separate checkpoint per destination — the PK is the pair, and
    /// sending to a folder must not mark rows as already delivered to a server.
    func testCursorsAreKeyedByTemplateAndDestination() throws {
        try cursors.advance(templateId: "T1", destinationId: "D1", to: now, lastRunId: "R1",
                            manifestSha: nil, now: now)
        try cursors.advance(templateId: "T1", destinationId: "D2",
                            to: now.addingTimeInterval(-86_400), lastRunId: "R2",
                            manifestSha: nil, now: now)

        XCTAssertEqual(try cursors.all().count, 2)
        XCTAssertEqual(try cursors.cursor(templateId: "T1", destinationId: "D2")?.highWatermark,
                       now.addingTimeInterval(-86_400))

        try cursors.resetAll(templateId: "T1")
        XCTAssertTrue(try cursors.all().isEmpty)
    }

    func testCursorPersistsTheManifestDigest() throws {
        let digest = try XCTUnwrap(ManifestDigest(hex: String(repeating: "b", count: 64)))
        try cursors.advance(templateId: "T1", destinationId: "D1", to: now, lastRunId: "R1",
                            manifestSha: digest, now: now)
        XCTAssertEqual(try cursors.cursor(templateId: "T1", destinationId: "D1")?.lastManifestSha, digest)
    }

    // MARK: - Value types

    func testRangeRuleStorageRoundTrips() {
        for rule: ExportRangeRule in [.fixed, .lastNDays(7), .lastNDays(365), .sinceLastRun, .allTime] {
            XCTAssertEqual(ExportRangeRule(storageValue: rule.storageValue), rule)
        }
        // A zero-day window would export nothing and read as data loss.
        XCTAssertEqual(ExportRangeRule(storageValue: "lastNDays:0"), .lastNDays(1))
        XCTAssertEqual(ExportRangeRule(storageValue: "lastNDays:banana"), .allTime)
        XCTAssertEqual(ExportRangeRule(storageValue: "who knows"), .allTime)
    }

    func testAggregationStorageRoundTrips() {
        XCTAssertEqual(ExportAggregation.from(granularity: "raw", method: nil), .raw)
        XCTAssertEqual(ExportAggregation.from(granularity: "day", method: "mean"),
                       .bucketed(.day, method: .mean))
        // A bucket without a method cannot be represented, so it degrades to raw rather than
        // inventing an aggregation the user never chose.
        XCTAssertEqual(ExportAggregation.from(granularity: "day", method: nil), .raw)
        XCTAssertEqual(ExportAggregation.from(granularity: "fortnight", method: "mean"), .raw)
    }

    func testManifestDigestAcceptsOnlySha256Hex() {
        XCTAssertNotNil(ManifestDigest(hex: String(repeating: "0", count: 64)))
        XCTAssertEqual(ManifestDigest(hex: String(repeating: "A", count: 64))?.hex,
                       String(repeating: "a", count: 64))
        XCTAssertNil(ManifestDigest(hex: String(repeating: "a", count: 63)))
        XCTAssertNil(ManifestDigest(hex: "not a digest"))
    }

    func testOnlyRealFailuresReadAsFailures() {
        XCTAssertTrue(ExportOutcome.failedGeneration.isFailure)
        XCTAssertTrue(ExportOutcome.failedDelivery.isFailure)
        XCTAssertTrue(ExportOutcome.partial.isFailure)
        // Locked, no-data, throttled and cancelled are the scheduler and the user behaving
        // normally — styling them as errors would be both alarming and false.
        for ordinary: ExportOutcome in [.success, .skippedLocked, .skippedNoData, .throttled, .cancelled] {
            XCTAssertFalse(ordinary.isFailure, "\(ordinary) must not read as a failure")
        }
    }
}
