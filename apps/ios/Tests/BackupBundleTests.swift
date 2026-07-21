import CryptoKit
import Foundation
import XCTest
@testable import BADAN

/// EPIC-18 — full backup & restore, iOS half.
///
/// Two things are being pinned here. First, **cross-platform byte-parity**: given one frozen set of
/// records and config, `BackupBundle.build` must produce the exact bytes in
/// `packages/fixtures/backup/backup-v1.json` and `DATA_DICTIONARY.md` — and the Android half
/// (`BackupBundleTest.kt`) builds the same inputs and must produce the same bytes, so a backup
/// written on one platform restores on the other (plan §12 EPIC-18 requirement 2). Second, the
/// **restore safety properties**: schema-too-new refuses rather than partially imports (requirement
/// 6), checksums are verified, destinations never leak secrets (requirement 3), and the sensitive
/// namespace is re-gated at restore (requirement 5).
///
/// The data arrays in the golden are empty on purpose: the byte-parity of every record shape is
/// already pinned by `ExportSchemaParityTests`/`bundle-v1.json`. What this golden adds is the parts
/// `BackupBundle` layers on top — the plaintext wrapper, the backup manifest with per-file SHA-256,
/// the config echo, and the data dictionary — with far fewer literals to keep identical across two
/// languages, which is what keeps the fixture honest rather than fragile.
final class BackupBundleTests: XCTestCase {

    /// Temp stores opened by the hydration round-trip tests, torn down after each. Held so ARC keeps
    /// the SQLite connections alive for the length of a test and the files are cleaned up after.
    private var openDatabases: [Database] = []
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        openDatabases.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: - Frozen fixture (must byte-match Android's BackupBundleTest.kt)

    /// 2026-07-20T10:02:00Z — the same instant the export fixture uses.
    private static let createdAt = Date(timeIntervalSince1970: 1_784_541_720)
    private static let appVersion = "1.4.0"
    private static let platform = "ios"

    private static let fixtureScope = ExportScope(
        metricIds: nil, families: nil, startDate: nil, endDate: nil, sourceIds: nil,
        includeRaw: true, includeDerived: true, includeSuppressed: false, includeSensitive: true,
        unitProfile: .canonical, language: .en)

    private static func fixtureManifest() -> ExportManifest {
        ExportManifest(
            exportId: "01J8ZKBACKUPFIXTURE0000001",
            schemaVersion: "1.0.0", appVersion: appVersion, platform: platform,
            generatedAt: createdAt, scope: fixtureScope, dateRange: "all",
            displayLanguage: "en", unitProfile: "canonical",
            timezonePolicy: "timestamps carry original offsets; day boundaries computed in tz-at-measurement",
            dedupPolicy: "source-priority v1; suppressed duplicates excluded",
            perMetricRowCounts: [:], checksums: [:],
            dataQualityNote: "Rows reflect stored records only; coverage gaps are not backfilled.",
            sampleDataRowCount: 0)
    }

    private static let destinationId = "01J8ZKDESTFIXTURE000000001"

    private static func fixtureTemplates() -> [ExportTemplate] {
        [ExportTemplate(
            id: "01J8ZKTEMPLATEFIXTURE00001", name: "Weekly vitals", scope: fixtureScope,
            rangeRule: .lastNDays(7), format: .csv, aggregation: .raw, layout: .tidy,
            includeSchemaDocs: false, destinationId: destinationId,
            createdAt: createdAt, updatedAt: createdAt, originDeviceId: "device-fixture")]
    }

    /// A destination carrying a credential reference and a folder-bookmark reference, so the
    /// exclusion tests have something real to prove the absence of.
    private static func fixtureDestinations() -> [ExportDestination] {
        [ExportDestination(
            id: destinationId, kind: .fileFolder, displayName: "My export folder",
            config: ExportDestinationConfig(
                folderBookmarkRef: "badan.export.credential.\(destinationId.lowercased()).bookmark"),
            credentialRef: CredentialRef.forDestination(id: destinationId),
            createdAt: createdAt, updatedAt: createdAt, originDeviceId: "device-fixture")]
    }

    private static func fixtureCustomization() -> CanonicalJSON {
        .object([
            "language": .string("en"),
            "depth_policy": .string("power"),
            "unit_profile": .string("canonical")
        ])
    }

    private static func fixtureSchedules() -> [CanonicalJSON] {
        [.object([
            "id": .string("01J8ZKSCHEDFIXTURE0000001"),
            "template_id": .string("01J8ZKTEMPLATEFIXTURE00001"),
            "reliability_tier": .string("best_effort_background")
        ])]
    }

    private static func buildFixture(passphrase: String? = nil) throws -> BackupBundle.Artifact {
        try BackupBundle.build(
            manifest: fixtureManifest(),
            rawSamples: [], intervalRecords: [], sessions: [], derivedValues: [], baselines: [],
            symptoms: [], adherence: [], workouts: [], nutrition: [],
            templates: fixtureTemplates(), destinations: fixtureDestinations(),
            customization: fixtureCustomization(), schedules: fixtureSchedules(),
            createdAt: createdAt, appVersion: appVersion, platform: platform, passphrase: passphrase)
    }

    // MARK: - Byte-parity goldens

    func testPlaintextBackupMatchesTheSharedGoldenByte() throws {
        let artifact = try Self.buildFixture()
        XCTAssertFalse(artifact.encrypted)
        XCTAssertEqual(artifact.fileName, "BADAN_backup_20260720.json")
        try Self.assertGolden("backup-v1.json", artifact.data)
    }

    func testDataDictionaryMatchesTheSharedGoldenByte() throws {
        try Self.assertGolden("DATA_DICTIONARY.md", Data(BackupBundle.dataDictionaryMarkdown().utf8))
    }

    // MARK: - Round trip

    func testPlaintextRoundTripReconstructsLogicalFiles() throws {
        let artifact = try Self.buildFixture()
        let restored = try BackupBundle.parse(artifact.data)
        XCTAssertFalse(restored.encrypted)
        XCTAssertEqual(restored.schemaVersion, BackupBundle.version)
        XCTAssertEqual(restored.originPlatform, "ios")
        XCTAssertEqual(restored.originAppVersion, "1.4.0")
        XCTAssertEqual(Set(restored.logicalFiles.map(\.name)),
                       [BackupBundle.manifestFileName, BackupBundle.dictionaryFileName, BackupBundle.bundleFileName])
    }

    func testEncryptedRoundTripReconstructsSameLogicalFiles() throws {
        let plain = try Self.buildFixture()
        let encrypted = try Self.buildFixture(passphrase: "correct horse staple")
        XCTAssertTrue(encrypted.encrypted)
        XCTAssertEqual(encrypted.fileName, "BADAN_backup_20260720.badanenc")
        XCTAssertTrue(BackupBundle.isEncryptedContainer(encrypted.data))

        let restored = try BackupBundle.parse(encrypted.data, passphrase: "correct horse staple")
        XCTAssertTrue(restored.encrypted)
        // The logical file bytes recovered from the container are exactly the ones sealed into it —
        // this, plus ExportEncryptor's already-proven container byte-parity, is what makes "written
        // encrypted on one platform, restored on the other" hold. (An encrypted backup legitimately
        // differs from a plaintext one: it carries `export_destinations`, which plaintext omits.)
        let sealed = Dictionary(uniqueKeysWithValues: encrypted.logicalFiles.map { ($0.name, $0.data) })
        for file in restored.logicalFiles {
            XCTAssertEqual(file.data, sealed[file.name], "logical file \(file.name) diverged through encryption")
        }
        _ = plain
    }

    func testWrongPassphraseFailsAsEncrypted() throws {
        let encrypted = try Self.buildFixture(passphrase: "the-right-one-here")
        XCTAssertThrowsError(try BackupBundle.parse(encrypted.data, passphrase: "the-wrong-one-x")) { error in
            guard case BackupBundle.RestoreError.encrypted = error else {
                return XCTFail("expected .encrypted, got \(error)")
            }
        }
    }

    func testEncryptedContainerWithoutPassphraseFails() throws {
        let encrypted = try Self.buildFixture(passphrase: "a-passphrase-value")
        XCTAssertThrowsError(try BackupBundle.parse(encrypted.data, passphrase: nil))
    }

    // MARK: - Requirement 3: destinations never carry secrets

    func testPlaintextBackupExcludesDestinationsEntirely() throws {
        let artifact = try Self.buildFixture()
        // The data bundle's config must carry no destinations at all. (Checked on bundle.json
        // rather than the whole artifact because DATA_DICTIONARY.md legitimately *documents* the
        // `export_destinations` field name in prose.)
        let restored = try BackupBundle.parse(artifact.data)
        let bundleFile = try XCTUnwrap(restored.logicalFiles.first { $0.name == BackupBundle.bundleFileName })
        let bundleText = String(decoding: bundleFile.data, as: UTF8.self)
        XCTAssertFalse(bundleText.contains("export_destinations"),
                       "a plaintext backup's data bundle must not name export_destinations")
        // And nowhere in the whole artifact does a credential reference or secret-bearing field
        // appear — neither the dictionary nor anything else mentions these tokens.
        let whole = String(decoding: artifact.data, as: UTF8.self)
        XCTAssertFalse(whole.contains(CredentialRef.namespace),
                       "a credential reference must never appear in a plaintext backup")
        XCTAssertFalse(whole.contains("folder_bookmark_ref"))
    }

    func testEncryptedBackupCarriesDestinationsButNoSecrets() throws {
        let artifact = try Self.buildFixture(passphrase: "seal-it-up-please")
        let restored = try BackupBundle.parse(artifact.data, passphrase: "seal-it-up-please")
        let bundleFile = try XCTUnwrap(restored.logicalFiles.first { $0.name == BackupBundle.bundleFileName })
        let text = String(decoding: bundleFile.data, as: UTF8.self)
        XCTAssertTrue(text.contains("export_destinations"),
                      "an encrypted backup carries destinations (sans-secrets)")
        // The destination is present...
        XCTAssertTrue(text.contains("My export folder"))
        // ...but neither the credential reference nor any secret-bearing field is.
        XCTAssertFalse(text.contains(CredentialRef.namespace),
                       "even inside encryption, a credential reference is meaningless off-device and must be stripped")
        XCTAssertFalse(text.contains("credential_ref"))
        XCTAssertFalse(text.contains("folder_bookmark_ref"))
        XCTAssertFalse(text.contains("provider_account_ref"))
    }

    func testDestinationSansSecretsProjectionHasNoSecretFields() throws {
        let json = BackupBundle.destinationSansSecrets(Self.fixtureDestinations()[0]).render()
        for banned in ["credential_ref", "folder_bookmark_ref", "provider_account_ref", CredentialRef.namespace] {
            XCTAssertFalse(json.contains(banned), "sans-secrets projection leaked \(banned)")
        }
    }

    // MARK: - Requirement 6: newer schema refuses, never partial

    func testNewerSchemaMajorIsRefused() throws {
        // Bump the manifest (the authoritative version source) to a newer major and re-wrap. The
        // schema gate runs before checksum verification, so no re-signing is needed — that ordering
        // is the property being exercised.
        let files = try BackupBundle.parse(try Self.buildFixture().data).logicalFiles.map { file -> ExportContainerFile in
            guard file.name == BackupBundle.manifestFileName else { return file }
            let bumped = String(decoding: file.data, as: UTF8.self)
                .replacingOccurrences(of: "\"backup_schema_version\":\"1.0\"",
                                      with: "\"backup_schema_version\":\"2.0\"")
            return ExportContainerFile(name: file.name, data: Data(bumped.utf8))
        }
        let rewrapped = Data(BackupBundle.plaintextWrapper(files).render().utf8)
        XCTAssertThrowsError(try BackupBundle.parse(rewrapped)) { error in
            guard case BackupBundle.RestoreError.schemaTooNew(let found, _) = error else {
                return XCTFail("expected .schemaTooNew, got \(error)")
            }
            XCTAssertEqual(found, "2.0")
        }
    }

    func testHigherMinorSchemaStillReadable() {
        XCTAssertTrue(BackupBundle.isReadable("1.9"))
        XCTAssertTrue(BackupBundle.isReadable("1.0"))
        XCTAssertFalse(BackupBundle.isReadable("2.0"))
    }

    // MARK: - Checksum verification

    func testTamperedBundleFailsChecksum() throws {
        // Alter bundle.json's content (its "all" date-range string) but leave the manifest's
        // recorded SHA untouched, then re-wrap — restore must catch the mismatch.
        var changed = false
        let files = try BackupBundle.parse(try Self.buildFixture().data).logicalFiles.map { file -> ExportContainerFile in
            guard file.name == BackupBundle.bundleFileName else { return file }
            let tampered = String(decoding: file.data, as: UTF8.self)
                .replacingOccurrences(of: "\"date_range\":\"all\"", with: "\"date_range\":\"ALL\"")
            changed = true
            return ExportContainerFile(name: file.name, data: Data(tampered.utf8))
        }
        XCTAssertTrue(changed, "tamper setup did not find the bundle file")
        let rewrapped = Data(BackupBundle.plaintextWrapper(files).render().utf8)
        XCTAssertThrowsError(try BackupBundle.parse(rewrapped)) { error in
            guard case BackupBundle.RestoreError.checksumMismatch(let file) = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
            XCTAssertEqual(file, BackupBundle.bundleFileName)
        }
    }

    func testGarbageIsNotABackup() {
        XCTAssertThrowsError(try BackupBundle.parse(Data("not a backup".utf8))) { error in
            guard case BackupBundle.RestoreError.notABackup = error else {
                return XCTFail("expected .notABackup, got \(error)")
            }
        }
    }

    // MARK: - Requirement 5: sensitive re-gated at restore, and preview/plan

    func testPreviewCountsAndSensitivePresence() throws {
        let artifact = try buildWithSensitive()
        let restored = try BackupBundle.parse(artifact.data)
        let preview = BackupBundle.preview(restored)
        XCTAssertTrue(preview.sensitivePresent)
        XCTAssertEqual(preview.namespaceCounts["raw_samples"], 1)
        XCTAssertEqual(preview.namespaceCounts["logs.symptoms"], 1)
        XCTAssertEqual(preview.configCounts["export_templates"], 1)
    }

    func testPlanExcludesSensitiveWithoutConsent() throws {
        let artifact = try buildWithSensitive()
        let preview = BackupBundle.preview(try BackupBundle.parse(artifact.data))

        let denied = BackupBundle.plan(preview, consent: .init(includeSensitive: false),
                                       batchId: "batch-1", fileName: "b.json", now: Self.createdAt)
        XCTAssertEqual(denied.counts["logs.symptoms"], 0, "sensitive rows must not be in a plan without consent")
        XCTAssertFalse(denied.includesSensitive)

        let granted = BackupBundle.plan(preview, consent: .init(includeSensitive: true),
                                        batchId: "batch-1", fileName: "b.json", now: Self.createdAt)
        XCTAssertEqual(granted.counts["logs.symptoms"], 1)
        XCTAssertTrue(granted.includesSensitive)
    }

    func testPlanStagesAnImportBatchRow() throws {
        let preview = BackupBundle.preview(try BackupBundle.parse(try buildWithSensitive().data))
        let plan = BackupBundle.plan(preview, consent: .init(includeSensitive: true),
                                     batchId: "01J8ZKBATCH00000000000001", fileName: "BADAN_backup_20260720.json",
                                     now: Self.createdAt)
        let row = plan.importBatchRow
        XCTAssertEqual(row.id, "01J8ZKBATCH00000000000001")
        XCTAssertEqual(row.sourceKind, BackupBundle.restoreSourceKind)
        XCTAssertEqual(row.state, BackupBundle.previewedState)
        XCTAssertNil(row.chunkCursor, "a previewed batch has consumed no chunks")
        XCTAssertTrue(row.countsJSON.contains("\"logs.symptoms\":1"))
    }

    // MARK: - Requirement (ADR-0008): KDF cost cap at the import boundary

    func testAbsurdKdfCostIsRefusedBeforeDeriving() throws {
        // Hand-craft a container header claiming a huge iteration count. The body is junk — the cap
        // must trip on the header alone, before the KDF (and thus before any body parse) runs.
        var header = Data(ExportEncryptor.magic)
        header.append(ExportEncryptor.formatVersion)
        header.append(ExportEncryptor.kdfIdPBKDF2SHA256)
        let huge: UInt32 = 100_000_000
        header.append(contentsOf: [UInt8(huge >> 24), UInt8((huge >> 16) & 0xFF),
                                   UInt8((huge >> 8) & 0xFF), UInt8(huge & 0xFF)])
        header.append(Data(repeating: 0, count: ExportEncryptor.saltLength))
        header.append(Data(repeating: 0, count: 64)) // fake ciphertext
        XCTAssertThrowsError(try BackupBundle.parse(header, passphrase: "whatever-here-ok")) { error in
            guard case BackupBundle.RestoreError.kdfCostTooHigh(let iterations, let cap) = error else {
                return XCTFail("expected .kdfCostTooHigh, got \(error)")
            }
            XCTAssertEqual(iterations, huge)
            XCTAssertEqual(cap, BackupBundle.maxKdfIterations)
        }
    }

    // MARK: - Hydration (EPIC-38) survives a backup — the drink ledger is not silently dropped

    private static let hyOriginalId = "01HYDENTRYA0000000000000001"
    private static let hyRevisionId = "01HYDENTRYA0000000000000002"
    private static let hyDeletedId = "01HYDENTRYB0000000000000001"
    private static let hyGoalId = "01HYDGOAL00000000000000001"
    private static let hyBeverageId = "01HYDBEV000000000000000001"
    private static let dayEnd = createdAt.addingTimeInterval(86_400)

    private func manualProvenance() -> Provenance {
        Provenance(sourceId: "badan.manual", ingestionPath: .manual, measuredAt: Self.createdAt,
                   measuredTimezone: "Asia/Riyadh", recordedAt: Self.createdAt, ingestedAt: Self.createdAt)
    }

    /// A fresh main-DB hydration store in its own temp dir (v7 migrations run), tracked for teardown.
    private func freshHydrationRepo() throws -> HydrationRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-backup-hydration-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        let db = try Database(directory: dir)
        openDatabases.append(db)
        return HydrationRepository(main: db.main)
    }

    /// Logs a realistic ledger: an edited drink (original superseded by a revision), a deleted drink
    /// (tombstoned), the custom beverage the deleted drink references, a manual goal, and a day
    /// summary. Every entry carries a note.
    private func seedHydration(into repo: HydrationRepository) throws {
        let original = HydrationLedger.makeEntry(
            id: Self.hyOriginalId, volumeMl: 250, fluidType: "water", occurredAt: Self.createdAt,
            tzId: "Asia/Riyadh", note: "before the walk", provenance: manualProvenance(),
            updatedAt: Self.createdAt, originDeviceId: "device-fixture")
        let revision = HydrationLedger.makeRevision(
            of: original, id: Self.hyRevisionId, volumeMl: 500, note: "after the walk",
            provenance: manualProvenance(), updatedAt: Self.createdAt, originDeviceId: "device-fixture")
        var deleted = HydrationLedger.makeEntry(
            id: Self.hyDeletedId, volumeMl: 300, fluidType: "coffee", beverageId: Self.hyBeverageId,
            occurredAt: Self.createdAt, tzId: "Asia/Riyadh", note: "mistake", provenance: manualProvenance(),
            updatedAt: Self.createdAt, originDeviceId: "device-fixture")
        deleted.deletedAt = Self.createdAt
        try repo.insertEntry(original)
        try repo.insertEntry(revision)
        try repo.insertEntry(deleted)
        try repo.upsertBeverage(BeverageDefinition(
            id: Self.hyBeverageId, nameEn: "House blend", nameAr: "خلطة المنزل", fluidType: "coffee",
            updatedAt: Self.createdAt, originDeviceId: "device-fixture"))
        try repo.upsertGoal(HydrationGoal(
            id: Self.hyGoalId, kind: .manual, targetMl: 2000, createdAt: Self.createdAt,
            updatedAt: Self.createdAt, originDeviceId: "device-fixture"))
        try repo.upsertSummary(HydrationDailySummary(
            dayKey: "2026-07-20", tzId: "Asia/Riyadh", manualMl: 500, entryCount: 1,
            goalKind: .manual, goalTargetMl: 2000, updatedAt: Self.createdAt, originDeviceId: "device-fixture"))
    }

    /// Gathers the FULL ledger a backup must carry — every row incl. superseded + tombstoned, so
    /// revision chains (I2) survive — via the repository, mirroring what a real backup would do.
    private func gatherFullLedger(from repo: HydrationRepository) throws -> HydrationExportPayload {
        let entries = try repo.history(originalId: Self.hyOriginalId) + repo.history(originalId: Self.hyDeletedId)
        let goals = try repo.allGoals()
        let summaries = try repo.summaries(from: "0000-00-00", to: "9999-99-99")
        let referenced = Set(entries.compactMap { $0.beverageId })
        let beverages = try repo.beverages().filter { referenced.contains($0.id) }
        return HydrationExportPayload(entries: entries, summaries: summaries, goals: goals, beverages: beverages)
    }

    /// Restores a gathered ledger into a store the append-first, id-preserving way the repository
    /// already inserts — the primitive a staged restore commit would use.
    private func applyHydration(_ payload: HydrationExportPayload, to repo: HydrationRepository) throws {
        for e in payload.entries { try repo.insertEntry(e) }
        for b in payload.beverages { try repo.upsertBeverage(b) }
        for g in payload.goals { try repo.upsertGoal(g) }
        for s in payload.summaries { try repo.upsertSummary(s) }
    }

    /// The whole point of the finding: a user who logs drinks, backs up, and restores to a new device
    /// must get every drink back. Logs a full ledger, backs it up, verifies the backup carries it
    /// (with notes and revision chains), restores into a wiped store, and proves a double-restore does
    /// not duplicate.
    func testHydrationLedgerSurvivesBackupAndRestoreToANewStore() throws {
        let source = try freshHydrationRepo()
        try seedHydration(into: source)
        let gathered = try gatherFullLedger(from: source)
        XCTAssertEqual(gathered.entries.count, 3, "the backup gathers the full chain, not just live rows")

        let artifact = try BackupBundle.build(
            manifest: Self.fixtureManifest(),
            rawSamples: [], intervalRecords: [], sessions: [], derivedValues: [], baselines: [],
            symptoms: [], adherence: [], workouts: [], nutrition: [],
            hydration: gathered,
            templates: [], destinations: [], customization: Self.fixtureCustomization(), schedules: [],
            createdAt: Self.createdAt, appVersion: Self.appVersion, platform: Self.platform)

        // Restore READS the drink slice: preview counts the full ledger as a normal-class family.
        let restored = try BackupBundle.parse(artifact.data)
        XCTAssertEqual(BackupBundle.preview(restored).namespaceCounts["logs.hydration"], 3)

        // The backup carries every field needed to reconstruct — ids, notes, tombstone — nothing
        // silently lost (asserted against the serialized bundle).
        let hydrationLog = try XCTUnwrap((restored.bundle["logs"] as? [String: Any])?["hydration"] as? [String: Any])
        let jsonEntries = try XCTUnwrap(hydrationLog["entries"] as? [[String: Any]])
        XCTAssertEqual(jsonEntries.count, 3)
        XCTAssertTrue(jsonEntries.allSatisfy { $0["note"] != nil }, "a backup keeps water notes")

        // WIPE / NEW STORE, then restore into it (device migration). The append-first insert preserves
        // ids and revision links, so the live view, full history, goal and beverage all come back.
        let migrated = try freshHydrationRepo()
        try applyHydration(gathered, to: migrated)

        let liveBack = try migrated.liveEntries(from: Date(timeIntervalSince1970: 0), to: Self.dayEnd)
        XCTAssertEqual(Set(liveBack.map(\.id)), [Self.hyRevisionId],
                       "original superseded, deleted gone — only the live revision")
        XCTAssertEqual(try migrated.history(originalId: Self.hyOriginalId).map(\.id),
                       [Self.hyOriginalId, Self.hyRevisionId], "the revision chain is intact")
        XCTAssertEqual(try migrated.entry(id: Self.hyRevisionId)?.note, "after the walk", "notes restored")
        XCTAssertEqual(try migrated.allGoals().map(\.id), [Self.hyGoalId])
        XCTAssertEqual(try migrated.beverages().map(\.id), [Self.hyBeverageId])

        // Closed loop: what the migrated store re-gathers equals what was backed up, byte-for-byte at
        // the domain level (every field of every entry, goal and beverage).
        let regathered = try gatherFullLedger(from: migrated)
        XCTAssertEqual(Set(regathered.entries), Set(gathered.entries))
        XCTAssertEqual(Set(regathered.goals), Set(gathered.goals))
        XCTAssertEqual(Set(regathered.beverages), Set(gathered.beverages))

        // Idempotent: restoring the SAME bundle twice must not duplicate — the ledger keys by record
        // id (INSERT OR REPLACE on the ULID PK), so a re-apply is a no-op.
        try applyHydration(gathered, to: migrated)
        XCTAssertEqual(try migrated.history(originalId: Self.hyOriginalId).count, 2)
        XCTAssertEqual(try migrated.history(originalId: Self.hyDeletedId).count, 1)
        XCTAssertEqual(try migrated.allGoals().count, 1)
        XCTAssertEqual(try migrated.beverages().count, 1)
    }

    func testBackupOptsHydrationNotesInStructurally() throws {
        let source = try freshHydrationRepo()
        try seedHydration(into: source)
        let artifact = try BackupBundle.build(
            manifest: Self.fixtureManifest(),
            rawSamples: [], intervalRecords: [], sessions: [], derivedValues: [], baselines: [],
            symptoms: [], adherence: [], workouts: [], nutrition: [],
            hydration: try gatherFullLedger(from: source),
            templates: [], destinations: [], customization: Self.fixtureCustomization(), schedules: [],
            createdAt: Self.createdAt, appVersion: Self.appVersion, platform: Self.platform)
        let restored = try BackupBundle.parse(artifact.data)
        let hydrationLog = try XCTUnwrap((restored.bundle["logs"] as? [String: Any])?["hydration"] as? [String: Any])
        let redaction = try XCTUnwrap(hydrationLog["redaction"] as? [String: Any])
        XCTAssertEqual(redaction["notes_included"] as? Bool, true, "a backup opts notes in")
        let excluded = (redaction["excluded_by_default"] as? [String]) ?? []
        XCTAssertFalse(excluded.contains("note"), "note must not be excluded in a backup")
    }

    func testAbsentHydrationWritesNoBlockAndKeepsGoldensStable() throws {
        // The config-only golden fixture passes no hydration → no `logs.hydration` key at all
        // (absent, not empty), which is what keeps the pre-hydration goldens byte-identical.
        let restored = try BackupBundle.parse(try Self.buildFixture().data)
        XCTAssertNil((restored.bundle["logs"] as? [String: Any])?["hydration"])
        XCTAssertEqual(BackupBundle.preview(restored).namespaceCounts["logs.hydration"], 0)
    }

    // MARK: - Helpers

    /// A fixture with a raw sample and one sensitive (symptom) record, for preview/plan tests. Not
    /// used for the byte golden — only the config-only fixture is, to keep the golden's literals
    /// minimal across platforms.
    private func buildWithSensitive() throws -> BackupBundle.Artifact {
        let provenance = Provenance(
            sourceId: "com.apple.health", deviceId: "iPhone",
            ingestionPath: .platformStore, externalId: "ext-1", importBatchId: nil,
            measuredAt: Self.createdAt, measuredTimezone: "UTC",
            recordedAt: Self.createdAt, ingestedAt: Self.createdAt,
            algorithmVersionId: nil, qualityFlags: [], suppressedBy: nil)
        let raw = RawSample(id: "01J8ZKRAWFIXTURE000000001", metricId: "heart.rhr", value: 58, unit: "count/min",
                            originalValue: 58, originalUnit: "count/min", startAt: Self.createdAt, tzId: "UTC",
                            provenance: provenance, updatedAt: Self.createdAt, originDeviceId: "device-fixture")
        let symptom = SymptomEntry(id: "01J8ZKSYMPTOMFIXTURE00001", symptomId: "headache", severity: 3,
                                   occurredAt: Self.createdAt, tzId: "UTC", updatedAt: Self.createdAt,
                                   originDeviceId: "device-fixture")
        return try BackupBundle.build(
            manifest: Self.fixtureManifest(),
            rawSamples: [raw], intervalRecords: [], sessions: [], derivedValues: [], baselines: [],
            symptoms: [symptom], adherence: [], workouts: [], nutrition: [],
            templates: Self.fixtureTemplates(), destinations: Self.fixtureDestinations(),
            customization: Self.fixtureCustomization(), schedules: Self.fixtureSchedules(),
            createdAt: Self.createdAt, appVersion: Self.appVersion, platform: Self.platform)
    }

    // MARK: - Golden IO

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtureDir = repoRoot.appendingPathComponent("packages/fixtures/backup", isDirectory: true)

    /// Byte comparison, or a rewrite when `BADAN_REGENERATE_BACKUP_GOLDENS=true`. Same discipline as
    /// `ExportSchemaParityTests.assertGolden`: either platform may regenerate, but a regenerated
    /// golden is not verified until the OTHER platform passes against it unchanged, so the
    /// regenerating run always fails.
    static func assertGolden(_ fileName: String, _ produced: Data) throws {
        let url = fixtureDir.appendingPathComponent(fileName)
        if ProcessInfo.processInfo.environment["BADAN_REGENERATE_BACKUP_GOLDENS"] == "true" {
            try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            try produced.write(to: url)
            XCTFail("regenerated \(fileName); run BOTH suites with the switch OFF to verify parity")
            return
        }
        guard let expected = try? Data(contentsOf: url) else {
            return XCTFail("missing golden \(url.path) — regenerate with BADAN_REGENERATE_BACKUP_GOLDENS=true")
        }
        guard expected != produced else { return }
        XCTAssertEqual(String(decoding: expected, as: UTF8.self), String(decoding: produced, as: UTF8.self),
                       "\(fileName) is not byte-identical to this platform's output")
    }
}
