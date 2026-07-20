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
