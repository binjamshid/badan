package net.albayyan.badan

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.ExportAggregation
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportLayout
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.CredentialRef
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.domain.hydration.BeverageDefinition
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.domain.hydration.HydrationLedger
import net.albayyan.badan.export.BackupBundle
import net.albayyan.badan.export.CanonicalJson
import net.albayyan.badan.export.ExportContainerFile
import net.albayyan.badan.export.ExportEncryptor
import net.albayyan.badan.export.HydrationExportPayload
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * EPIC-18 — full backup & restore, Android half. Mirror of iOS `BackupBundleTests`.
 *
 * The frozen fixture below must produce the SAME bytes iOS produces from `BackupBundleTests`'
 * fixture, verified against the shared goldens in `packages/fixtures/backup/`. That equality is the
 * whole point: a backup written on one platform restores on the other (plan §12 EPIC-18
 * requirement 2). The functional tests re-assert the restore safety properties on this platform.
 */
class BackupBundleTest {

    private val fixtureDir = File("../../../packages/fixtures/backup")
    private val regenerating = System.getenv("BADAN_REGENERATE_BACKUP_GOLDENS") == "true"

    // MARK: - Frozen fixture (must byte-match iOS BackupBundleTests.swift)

    private val createdAt = 1_784_541_720_000L
    private val appVersion = "1.4.0"
    private val platform = "ios"
    private val destinationId = "01J8ZKDESTFIXTURE000000001"

    private val fixtureScope = ExportScope(
        metricIds = null, families = null, startDate = null, endDate = null, sourceIds = null,
        includeRaw = true, includeDerived = true, includeSuppressed = false, includeSensitive = true,
        unitProfile = UnitProfileMode.CANONICAL, language = AppLanguage.EN,
    )

    private fun fixtureManifest() = ExportManifest(
        exportId = "01J8ZKBACKUPFIXTURE0000001",
        schemaVersion = "1.0.0", appVersion = appVersion, platform = platform,
        generatedAt = createdAt, scope = fixtureScope, dateRange = "all",
        displayLanguage = "en", unitProfile = "canonical",
        timezonePolicy = "timestamps carry original offsets; day boundaries computed in tz-at-measurement",
        dedupPolicy = "source-priority v1; suppressed duplicates excluded",
        perMetricRowCounts = emptyMap(), checksums = emptyMap(),
        dataQualityNote = "Rows reflect stored records only; coverage gaps are not backfilled.",
    )

    private fun fixtureTemplates() = listOf(
        ExportTemplate(
            id = "01J8ZKTEMPLATEFIXTURE00001", name = "Weekly vitals", scope = fixtureScope,
            rangeRule = ExportRangeRule.LastNDays(7), format = ExportFormat.CSV,
            aggregation = ExportAggregation.Raw, layout = ExportLayout.TIDY,
            includeSchemaDocs = false, destinationId = destinationId,
            createdAt = createdAt, updatedAt = createdAt, originDeviceId = "device-fixture",
        )
    )

    private fun fixtureDestinations() = listOf(
        ExportDestination(
            id = destinationId, kind = ExportDestinationKind.FILE_FOLDER, displayName = "My export folder",
            config = ExportDestinationConfig(
                folderBookmarkRef = "badan.export.credential.${destinationId.lowercase()}.bookmark"),
            credentialRef = CredentialRef.forDestination(destinationId),
            createdAt = createdAt, updatedAt = createdAt, originDeviceId = "device-fixture",
        )
    )

    private fun fixtureCustomization(): CanonicalJson = CanonicalJson.Obj(
        mapOf(
            "language" to CanonicalJson.Str("en"),
            "depth_policy" to CanonicalJson.Str("power"),
            "unit_profile" to CanonicalJson.Str("canonical"),
        )
    )

    private fun fixtureSchedules(): List<CanonicalJson> = listOf(
        CanonicalJson.Obj(
            mapOf(
                "id" to CanonicalJson.Str("01J8ZKSCHEDFIXTURE0000001"),
                "template_id" to CanonicalJson.Str("01J8ZKTEMPLATEFIXTURE00001"),
                "reliability_tier" to CanonicalJson.Str("best_effort_background"),
            )
        )
    )

    private fun buildFixture(passphrase: String? = null): BackupBundle.Artifact = BackupBundle.build(
        manifest = fixtureManifest(),
        rawSamples = emptyList(), intervalRecords = emptyList(), sessions = emptyList(),
        derivedValues = emptyList(), baselines = emptyList(), symptoms = emptyList(),
        adherence = emptyList(), workouts = emptyList(), nutrition = emptyList(),
        templates = fixtureTemplates(), destinations = fixtureDestinations(),
        customization = fixtureCustomization(), schedules = fixtureSchedules(),
        createdAt = createdAt, appVersion = appVersion, platform = platform, passphrase = passphrase,
    )

    // MARK: - Byte-parity goldens

    @Test fun plaintextBackupMatchesTheSharedGoldenByte() {
        val artifact = buildFixture()
        assertFalse(artifact.encrypted)
        assertEquals("BADAN_backup_20260720.json", artifact.fileName)
        assertGolden("backup-v1.json", artifact.data)
    }

    @Test fun dataDictionaryMatchesTheSharedGoldenByte() {
        assertGolden("DATA_DICTIONARY.md", BackupBundle.dataDictionaryMarkdown().toByteArray(Charsets.UTF_8))
    }

    // MARK: - Round trip

    @Test fun plaintextRoundTripReconstructsLogicalFiles() {
        val restored = BackupBundle.parse(buildFixture().data)
        assertFalse(restored.encrypted)
        assertEquals(BackupBundle.VERSION, restored.schemaVersion)
        assertEquals("ios", restored.originPlatform)
        assertEquals(
            setOf(BackupBundle.MANIFEST_FILE_NAME, BackupBundle.DICTIONARY_FILE_NAME, BackupBundle.BUNDLE_FILE_NAME),
            restored.logicalFiles.map { it.name }.toSet(),
        )
    }

    @Test fun encryptedRoundTripReconstructsSameLogicalFiles() {
        val encrypted = buildFixture(passphrase = "correct horse staple")
        assertTrue(encrypted.encrypted)
        assertEquals("BADAN_backup_20260720.badanenc", encrypted.fileName)
        assertTrue(BackupBundle.isEncryptedContainer(encrypted.data))

        val restored = BackupBundle.parse(encrypted.data, passphrase = "correct horse staple")
        assertTrue(restored.encrypted)
        // The recovered files are exactly the ones sealed into the container. (An encrypted backup
        // legitimately differs from a plaintext one: it carries export_destinations.)
        val sealed = encrypted.logicalFiles.associate { it.name to it.data }
        for (file in restored.logicalFiles) {
            assertTrue("logical file ${file.name} diverged through encryption",
                file.data.contentEquals(sealed[file.name]))
        }
    }

    @Test fun wrongPassphraseFailsAsEncrypted() {
        val encrypted = buildFixture(passphrase = "the-right-one-here")
        try {
            BackupBundle.parse(encrypted.data, passphrase = "the-wrong-one-x")
            fail("expected RestoreException.Encrypted")
        } catch (e: BackupBundle.RestoreException.Encrypted) {
            // expected
        }
    }

    @Test fun encryptedContainerWithoutPassphraseFails() {
        val encrypted = buildFixture(passphrase = "a-passphrase-value")
        try {
            BackupBundle.parse(encrypted.data, passphrase = null)
            fail("expected an exception")
        } catch (e: BackupBundle.RestoreException) {
            // expected
        }
    }

    // MARK: - Requirement 3: destinations never carry secrets

    @Test fun plaintextBackupExcludesDestinationsEntirely() {
        val artifact = buildFixture()
        // The data bundle's config must carry no destinations. (Checked on bundle.json, not the
        // whole artifact, because DATA_DICTIONARY.md documents the field name in prose.)
        val restored = BackupBundle.parse(artifact.data)
        val bundleText = String(restored.logicalFiles.first { it.name == BackupBundle.BUNDLE_FILE_NAME }.data, Charsets.UTF_8)
        assertFalse("a plaintext backup's data bundle must not name export_destinations",
            bundleText.contains("export_destinations"))
        val whole = String(artifact.data, Charsets.UTF_8)
        assertFalse("a credential reference must never appear in a plaintext backup",
            whole.contains(CredentialRef.NAMESPACE))
        assertFalse(whole.contains("folder_bookmark_ref"))
    }

    @Test fun encryptedBackupCarriesDestinationsButNoSecrets() {
        val restored = BackupBundle.parse(buildFixture(passphrase = "seal-it-up-please").data, passphrase = "seal-it-up-please")
        val bundleFile = restored.logicalFiles.first { it.name == BackupBundle.BUNDLE_FILE_NAME }
        val text = String(bundleFile.data, Charsets.UTF_8)
        assertTrue(text.contains("export_destinations"))
        assertTrue(text.contains("My export folder"))
        assertFalse(text.contains(CredentialRef.NAMESPACE))
        assertFalse(text.contains("credential_ref"))
        assertFalse(text.contains("folder_bookmark_ref"))
        assertFalse(text.contains("provider_account_ref"))
    }

    @Test fun destinationSansSecretsProjectionHasNoSecretFields() {
        val json = BackupBundle.destinationSansSecrets(fixtureDestinations()[0]).render()
        for (banned in listOf("credential_ref", "folder_bookmark_ref", "provider_account_ref", CredentialRef.NAMESPACE)) {
            assertFalse("sans-secrets projection leaked $banned", json.contains(banned))
        }
    }

    // MARK: - Requirement 6: newer schema refuses, never partial

    @Test fun newerSchemaMajorIsRefused() {
        // Bump the manifest (the authoritative version source) to a newer major and re-wrap. The
        // schema gate runs before checksum verification, so no re-signing is needed.
        val files = BackupBundle.parse(buildFixture().data).logicalFiles.map { file ->
            if (file.name != BackupBundle.MANIFEST_FILE_NAME) file
            else ExportContainerFile(file.name, String(file.data, Charsets.UTF_8)
                .replace("\"backup_schema_version\":\"1.0\"", "\"backup_schema_version\":\"2.0\"")
                .toByteArray(Charsets.UTF_8))
        }
        val rewrapped = BackupBundle.plaintextWrapper(files).render().toByteArray(Charsets.UTF_8)
        try {
            BackupBundle.parse(rewrapped)
            fail("expected SchemaTooNew")
        } catch (e: BackupBundle.RestoreException.SchemaTooNew) {
            assertEquals("2.0", e.found)
        }
    }

    @Test fun higherMinorSchemaStillReadable() {
        assertTrue(BackupBundle.isReadable("1.9"))
        assertTrue(BackupBundle.isReadable("1.0"))
        assertFalse(BackupBundle.isReadable("2.0"))
    }

    // MARK: - Checksum verification

    @Test fun tamperedBundleFailsChecksum() {
        // Alter bundle.json but leave the manifest's recorded SHA untouched, then re-wrap.
        val files = BackupBundle.parse(buildFixture().data).logicalFiles.map { file ->
            if (file.name != BackupBundle.BUNDLE_FILE_NAME) file
            else ExportContainerFile(file.name, String(file.data, Charsets.UTF_8)
                .replace("\"date_range\":\"all\"", "\"date_range\":\"ALL\"")
                .toByteArray(Charsets.UTF_8))
        }
        val rewrapped = BackupBundle.plaintextWrapper(files).render().toByteArray(Charsets.UTF_8)
        try {
            BackupBundle.parse(rewrapped)
            fail("expected ChecksumMismatch")
        } catch (e: BackupBundle.RestoreException.ChecksumMismatch) {
            assertEquals(BackupBundle.BUNDLE_FILE_NAME, e.file)
        }
    }

    @Test fun garbageIsNotABackup() {
        try {
            BackupBundle.parse("not a backup".toByteArray(Charsets.UTF_8))
            fail("expected NotABackup")
        } catch (e: BackupBundle.RestoreException.NotABackup) {
            // expected
        }
    }

    // MARK: - Requirement 5: sensitive re-gated at restore, and preview/plan

    @Test fun previewCountsAndSensitivePresence() {
        val preview = BackupBundle.preview(BackupBundle.parse(buildWithSensitive().data))
        assertTrue(preview.sensitivePresent)
        assertEquals(1, preview.namespaceCounts["raw_samples"])
        assertEquals(1, preview.namespaceCounts["logs.symptoms"])
        assertEquals(1, preview.configCounts["export_templates"])
    }

    @Test fun planExcludesSensitiveWithoutConsent() {
        val preview = BackupBundle.preview(BackupBundle.parse(buildWithSensitive().data))

        val denied = BackupBundle.plan(preview, BackupBundle.RestoreConsent(includeSensitive = false),
            "batch-1", "b.json", createdAt)
        assertEquals(0, denied.counts["logs.symptoms"])
        assertFalse(denied.includesSensitive)

        val granted = BackupBundle.plan(preview, BackupBundle.RestoreConsent(includeSensitive = true),
            "batch-1", "b.json", createdAt)
        assertEquals(1, granted.counts["logs.symptoms"])
        assertTrue(granted.includesSensitive)
    }

    @Test fun planStagesAnImportBatchRow() {
        val preview = BackupBundle.preview(BackupBundle.parse(buildWithSensitive().data))
        val plan = BackupBundle.plan(preview, BackupBundle.RestoreConsent(includeSensitive = true),
            "01J8ZKBATCH00000000000001", "BADAN_backup_20260720.json", createdAt)
        val row = plan.importBatchRow
        assertEquals("01J8ZKBATCH00000000000001", row.id)
        assertEquals(BackupBundle.RESTORE_SOURCE_KIND, row.sourceKind)
        assertEquals(BackupBundle.PREVIEWED_STATE, row.state)
        assertNull(row.chunkCursor)
        assertTrue(row.countsJson.contains("\"logs.symptoms\":1"))
    }

    // MARK: - ADR-0008 KDF cost cap at the import boundary

    @Test fun absurdKdfCostIsRefusedBeforeDeriving() {
        val header = ByteArray(10 + ExportEncryptor.SALT_LENGTH + 64)
        ExportEncryptor.MAGIC.copyInto(header, 0)
        header[4] = ExportEncryptor.FORMAT_VERSION.toByte()
        header[5] = ExportEncryptor.KDF_ID_PBKDF2_SHA256.toByte()
        val huge = 100_000_000L
        header[6] = ((huge shr 24) and 0xFF).toByte()
        header[7] = ((huge shr 16) and 0xFF).toByte()
        header[8] = ((huge shr 8) and 0xFF).toByte()
        header[9] = (huge and 0xFF).toByte()
        try {
            BackupBundle.parse(header, passphrase = "whatever-here-ok")
            fail("expected KdfCostTooHigh")
        } catch (e: BackupBundle.RestoreException.KdfCostTooHigh) {
            assertEquals(huge, e.iterations)
            assertEquals(BackupBundle.MAX_KDF_ITERATIONS, e.cap)
        }
    }

    // MARK: - Hydration (EPIC-38) survives a backup — the drink ledger is not silently dropped

    // Fixed ids so the assertions can name each row and its chain link.
    private val hyOriginalId = "01HYDENTRYA0000000000000001"
    private val hyRevisionId = "01HYDENTRYA0000000000000002"
    private val hyDeletedId = "01HYDENTRYB0000000000000001"
    private val hyGoalId = "01HYDGOAL00000000000000001"
    private val hyBeverageId = "01HYDBEV000000000000000001"

    private fun manualProv() = Provenance(
        sourceId = "badan.manual", ingestionPath = IngestionPath.MANUAL,
        measuredAt = createdAt, measuredTimezone = "Asia/Riyadh",
        recordedAt = createdAt, ingestedAt = createdAt,
    )

    /**
     * A full ledger a real backup would gather: an edited drink (original superseded by a revision),
     * a deleted drink (tombstoned, whole chain), a custom beverage the deleted drink references, a
     * manual goal, and a day summary. Every entry carries a note — a backup keeps them.
     */
    private fun hydrationFixture(): HydrationExportPayload {
        val original = HydrationLedger.makeEntry(
            id = hyOriginalId, volumeMl = 250.0, fluidType = "water", occurredAt = createdAt,
            tzId = "Asia/Riyadh", note = "before the walk", provenance = manualProv(),
            updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        val revision = HydrationLedger.makeRevision(
            live = original, id = hyRevisionId, volumeMl = 500.0, note = "after the walk",
            provenance = manualProv(), updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        val deleted = HydrationLedger.makeEntry(
            id = hyDeletedId, volumeMl = 300.0, fluidType = "coffee", beverageId = hyBeverageId,
            occurredAt = createdAt, tzId = "Asia/Riyadh", note = "mistake", provenance = manualProv(),
            updatedAt = createdAt, originDeviceId = "device-fixture",
        ).copy(deletedAt = createdAt)
        val goal = HydrationGoal(
            id = hyGoalId, kind = HydrationGoalKind.MANUAL, targetMl = 2000.0,
            createdAt = createdAt, updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        val beverage = BeverageDefinition(
            id = hyBeverageId, nameEn = "House blend", nameAr = "خلطة المنزل", fluidType = "coffee",
            updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        val summary = HydrationDailySummary(
            dayKey = "2026-07-20", tzId = "Asia/Riyadh", manualMl = 500.0, entryCount = 1,
            goalKind = HydrationGoalKind.MANUAL, goalTargetMl = 2000.0,
            updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        return HydrationExportPayload(
            entries = listOf(original, revision, deleted), summaries = listOf(summary),
            goals = listOf(goal), beverages = listOf(beverage),
        )
    }

    private fun buildWithHydration(passphrase: String? = null): BackupBundle.Artifact = BackupBundle.build(
        manifest = fixtureManifest(),
        rawSamples = emptyList(), intervalRecords = emptyList(), sessions = emptyList(),
        derivedValues = emptyList(), baselines = emptyList(), symptoms = emptyList(),
        adherence = emptyList(), workouts = emptyList(), nutrition = emptyList(),
        templates = fixtureTemplates(), destinations = fixtureDestinations(),
        customization = fixtureCustomization(), schedules = fixtureSchedules(),
        createdAt = createdAt, appVersion = appVersion, platform = platform,
        hydration = hydrationFixture(), passphrase = passphrase,
    )

    private fun hydrationLog(restored: BackupBundle.RestoreBundle): JsonObject =
        (restored.bundle["logs"] as JsonObject)["hydration"] as JsonObject

    @Test fun backupCarriesFullHydrationLedgerIncludingNotesAndRevisionChain() {
        val restored = BackupBundle.parse(buildWithHydration().data)

        // Restore READS the drink slice: the preview counts it as a normal-class family, staging the
        // full ledger (original + revision + tombstone) exactly like logs.workouts / logs.nutrition.
        assertEquals(3, BackupBundle.preview(restored).namespaceCounts["logs.hydration"])

        val hydration = hydrationLog(restored)
        val entries = (hydration["entries"] as JsonArray).map { it as JsonObject }
        assertEquals(3, entries.size)
        val byId = entries.associateBy { it["record_id"]!!.jsonPrimitive.content }
        assertEquals(setOf(hyOriginalId, hyRevisionId, hyDeletedId), byId.keys)

        // Notes survive a backup (a backup is the user's complete data), unlike the redacted export.
        assertTrue("a backup must keep water notes, like it keeps every other log's notes",
            entries.all { it.containsKey("note") })
        assertEquals("after the walk", byId[hyRevisionId]!!["note"]!!.jsonPrimitive.content)

        // Revision chain (I2) preserved: ids kept, the revision links back to and supersedes the
        // original, and both share the chain's stable original_id.
        val rev = byId[hyRevisionId]!!
        assertEquals(2, rev["revision"]!!.jsonPrimitive.content.toInt())
        assertEquals(hyOriginalId, rev["supersedes"]!!.jsonPrimitive.content)
        assertEquals(hyOriginalId, rev["original_id"]!!.jsonPrimitive.content)
        assertEquals(hyOriginalId, byId[hyOriginalId]!!["original_id"]!!.jsonPrimitive.content)

        // The tombstoned drink is carried, not dropped — a restore can reconcile the removal.
        assertNotNull(byId[hyDeletedId]!!["deleted_at"]!!.jsonPrimitive.contentOrNull)

        // The goal and the custom beverage the deleted drink references travel with the entries.
        assertEquals(1, (hydration["goals"] as JsonArray).size)
        assertEquals(1, (hydration["beverages"] as JsonArray).size)
        assertEquals(1, (hydration["summaries"] as JsonArray).size)
    }

    @Test fun backupHydrationOptsNotesInStructurally() {
        val redaction = hydrationLog(BackupBundle.parse(buildWithHydration().data))["redaction"] as JsonObject
        assertTrue("a backup opts notes in", redaction["notes_included"]!!.jsonPrimitive.boolean)
        val excluded = (redaction["excluded_by_default"] as JsonArray).map { it.jsonPrimitive.content }
        assertFalse("note must not be excluded in a backup", excluded.contains("note"))
    }

    @Test fun hydrationRidesTheStagedPlanAsNormalClass() {
        val preview = BackupBundle.preview(BackupBundle.parse(buildWithHydration().data))
        // Denying sensitive consent must NOT drop hydration — it is normal-class, gated like
        // workouts/nutrition, never behind the meds/symptoms toggle.
        val plan = BackupBundle.plan(
            preview, BackupBundle.RestoreConsent(includeSensitive = false),
            "01J8ZKBATCH00000000000002", "BADAN_backup_20260720.json", createdAt,
        )
        assertEquals(3, plan.counts["logs.hydration"])
        assertTrue(plan.countsJson.contains("\"logs.hydration\":3"))
    }

    @Test fun encryptedBackupCarriesHydrationWhole() {
        val restored = BackupBundle.parse(
            buildWithHydration(passphrase = "seal-the-drinks-please").data,
            passphrase = "seal-the-drinks-please",
        )
        val entries = hydrationLog(restored)["entries"] as JsonArray
        assertEquals(3, entries.size)
        assertTrue(entries.all { (it as JsonObject).containsKey("note") })
    }

    @Test fun absentHydrationWritesNoHydrationBlock() {
        // The config-only fixture carries no drinks: no `logs.hydration` key at all (absent, not
        // empty), which is what keeps the pre-hydration goldens byte-identical.
        val restored = BackupBundle.parse(buildFixture().data)
        assertNull((restored.bundle["logs"] as JsonObject)["hydration"])
        assertEquals(0, BackupBundle.preview(restored).namespaceCounts["logs.hydration"])
    }

    // MARK: - Helpers

    private fun buildWithSensitive(): BackupBundle.Artifact {
        val provenance = Provenance(
            sourceId = "com.apple.health", deviceId = "iPhone", ingestionPath = IngestionPath.PLATFORM_STORE,
            externalId = "ext-1", importBatchId = null, measuredAt = createdAt, measuredTimezone = "UTC",
            recordedAt = createdAt, ingestedAt = createdAt, algorithmVersionId = null,
            qualityFlags = emptyList(), suppressedBy = null,
        )
        val raw = RawSample(
            id = "01J8ZKRAWFIXTURE000000001", metricId = "heart.rhr", value = 58.0, unit = "count/min",
            originalValue = 58.0, originalUnit = "count/min", startAt = createdAt, tzId = "UTC",
            provenance = provenance, updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        val symptom = SymptomEntry(
            id = "01J8ZKSYMPTOMFIXTURE00001", symptomId = "headache", severity = 3, occurredAt = createdAt,
            tzId = "UTC", updatedAt = createdAt, originDeviceId = "device-fixture",
        )
        return BackupBundle.build(
            manifest = fixtureManifest(),
            rawSamples = listOf(raw), intervalRecords = emptyList(), sessions = emptyList(),
            derivedValues = emptyList(), baselines = emptyList(), symptoms = listOf(symptom),
            adherence = emptyList(), workouts = emptyList(), nutrition = emptyList(),
            templates = fixtureTemplates(), destinations = fixtureDestinations(),
            customization = fixtureCustomization(), schedules = fixtureSchedules(),
            createdAt = createdAt, appVersion = appVersion, platform = platform,
        )
    }

    /**
     * Byte comparison, or a rewrite when `BADAN_REGENERATE_BACKUP_GOLDENS=true`. Same discipline as
     * the export parity suite: a regenerated golden is not verified until the OTHER platform passes
     * against it unchanged, so the regenerating run always fails.
     */
    private fun assertGolden(fileName: String, produced: ByteArray) {
        val file = File(fixtureDir, fileName)
        if (regenerating) {
            fixtureDir.mkdirs()
            file.writeBytes(produced)
            fail("regenerated $fileName; run BOTH suites with the switch OFF to verify parity")
            return
        }
        assertTrue("missing golden ${file.path} — regenerate with BADAN_REGENERATE_BACKUP_GOLDENS=true", file.isFile)
        val expected = file.readBytes()
        assertEquals(
            "$fileName is not byte-identical to this platform's output",
            String(expected, Charsets.UTF_8), String(produced, Charsets.UTF_8),
        )
    }
}
