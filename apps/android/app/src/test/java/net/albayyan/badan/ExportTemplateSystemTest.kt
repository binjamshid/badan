package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.CredentialRef
import net.albayyan.badan.domain.ExportAggregation
import net.albayyan.badan.domain.ExportAggregationMethod
import net.albayyan.badan.domain.ExportBucket
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorDetail
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportLayout
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportRowCounts
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportStage
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.ExportTemplateRunRefusal
import net.albayyan.badan.domain.ExportTlsPolicy
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.domain.ManifestDigest
import net.albayyan.badan.domain.QuickExportPreset
import net.albayyan.badan.domain.SensitiveRunConsent
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.repositories.ExportCursorRepository
import net.albayyan.badan.storage.repositories.ExportTemplateRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-09 — the export template system's domain layer.
 *
 * Scope, stated honestly (the same caveat `BackgroundSubstrateTest` carries): this module has no
 * `androidTest` source set and no Robolectric, so nothing here touches a real database. The
 * repositories' SQL and transaction behaviour are covered on iOS by
 * `ExportTemplateSystemTests`, which runs the identical statements against a real SQLite file;
 * what is covered here is every decision that lives in a pure function — the storage codecs, the
 * preset definitions and their structural exclusions, the run-time sensitive gate, the
 * value-freeness of the ledger's JSON columns, and the two `DELETE` bounds.
 */
class ExportTemplateSystemTest {

    private val now = 1_783_000_000_000L
    private val deviceId = "test-device"

    private fun template(
        id: String = "T1",
        scope: ExportScope = ExportScope.everything,
    ) = ExportTemplate(
        id = id, name = "Weekly vitals", scope = scope,
        rangeRule = ExportRangeRule.LastNDays(7), format = ExportFormat.CSV,
        aggregation = ExportAggregation.Raw, layout = ExportLayout.WIDE,
        includeSchemaDocs = true, destinationId = ExportDestination.SHARE_SHEET_ID,
        createdAt = now, updatedAt = now, originDeviceId = deviceId,
    )

    // MARK: - Quick Export presets (§12 EPIC-10)

    @Test fun presetsCoverEveryRangeAndFormatCombination() {
        assertEquals(6, QuickExportPreset.entries.size)
        assertEquals(
            setOf(
                "lastNDays:7/csv", "lastNDays:7/json",
                "lastNDays:30/csv", "lastNDays:30/json",
                "allTime/csv", "allTime/json",
            ),
            QuickExportPreset.entries.map { "${it.rangeRule.storageValue}/${it.format.code}" }.toSet(),
        )
    }

    /**
     * The preset ids are the cross-platform contract: seeding writes the same primary keys on both
     * platforms, so a fixture can diff two devices' `export_templates` tables row for row. Pinned
     * literally here (rather than derived) because that is what a contract test is for.
     */
    @Test fun presetIdsMatchTheIOSConstantsExactly() {
        assertEquals("0000000000PRESET7CSV000000", QuickExportPreset.LAST_7_CSV.id)
        assertEquals("0000000000PRESET7JSN000000", QuickExportPreset.LAST_7_JSON.id)
        assertEquals("0000000000PRESET30CSV00000", QuickExportPreset.LAST_30_CSV.id)
        assertEquals("0000000000PRESET30JSN00000", QuickExportPreset.LAST_30_JSON.id)
        assertEquals("0000000000PRESETMAXCSV0000", QuickExportPreset.ALL_TIME_CSV.id)
        assertEquals("0000000000PRESETMAXJSN0000", QuickExportPreset.ALL_TIME_JSON.id)
        assertEquals("0000000000DESTSHARESHEET00", ExportDestination.SHARE_SHEET_ID)
    }

    /**
     * I8: every id is a ULID, including the hand-written ones. A 25-character typo would otherwise
     * persist happily and only surface as a mismatch against some future id validator.
     */
    @Test fun presetIdsAreWellFormedUlids() {
        val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        for (preset in QuickExportPreset.entries) {
            assertEquals("${preset.name} id must be 26 chars", 26, preset.id.length)
            assertTrue("${preset.name} id must be Crockford base32", preset.id.all { alphabet.contains(it) })
            assertNotNull(Ulid.timestampOf(preset.id))
        }
        assertEquals(26, ExportDestination.SHARE_SHEET_ID.length)
        assertTrue(ExportDestination.SHARE_SHEET_ID.all { alphabet.contains(it) })
    }

    /**
     * §12 EPIC-10: presets exclude sensitive namespaces and routes **structurally**.
     *
     * Walks the serialized scope rather than asserting two named fields, so this also covers
     * permissions that do not exist yet: if `ExportScope` gains an `includeRoutes` (or any other
     * `include*` widening flag) and `QuickExportPreset.presetScope` is not updated to deny it, this
     * fails without anyone having to remember to come back here.
     */
    @Test fun presetScopesGrantNoWideningPermission() {
        // Raw and derived are the two permissions a preset is *supposed* to grant: raw data is
        // never withheld, and the derived values are what make the file legible.
        val allowed = setOf("includeRaw", "includeDerived")
        var checked = 0

        for (preset in QuickExportPreset.entries) {
            val scope = preset.template(now, deviceId).scope
            val json = Json.parseToJsonElement(JsonCoding.encode(scope)).jsonObject
            for ((key, element) in json) {
                if (!key.startsWith("include") || key in allowed) continue
                checked += 1
                assertEquals(
                    "preset ${preset.name} must not grant $key",
                    "false", (element as JsonPrimitive).content,
                )
            }
        }

        // Guards against the test silently becoming vacuous if the `include*` naming convention
        // changes — `includeSensitive` and `includeSuppressed` are both expected to be found.
        assertTrue(checked >= 2 * QuickExportPreset.entries.size)
    }

    @Test fun presetTemplatesAreRecognisedAsPresetsAndUserTemplatesAreNot() {
        for (preset in QuickExportPreset.entries) {
            assertTrue(preset.template(now, deviceId).isPreset)
        }
        assertFalse(template().isPreset)
    }

    @Test fun presetStorageNamesAreStableAndDistinct() {
        assertEquals("Quick Export — Last 7 days (CSV)", QuickExportPreset.LAST_7_CSV.storageName)
        assertEquals("Quick Export — All time (JSON)", QuickExportPreset.ALL_TIME_JSON.storageName)
        assertEquals(
            QuickExportPreset.entries.size,
            QuickExportPreset.entries.map { it.storageName }.toSet().size,
        )
    }

    /** Quick Export goes to the share sheet, which is a real destination row, never a null one. */
    @Test fun presetsTargetTheSeededShareSheetDestination() {
        for (preset in QuickExportPreset.entries) {
            assertEquals(ExportDestination.SHARE_SHEET_ID, preset.template(now, deviceId).destinationId)
        }
    }

    // MARK: - Sensitive re-confirmation at run time (§9.3 privacy)

    @Test fun nonSensitiveTemplateNeedsNoConfirmation() {
        val t = template()
        assertFalse(t.requiresSensitiveConfirmation)
        assertEquals(t.scope, t.scopeForRun(consent = null, now = now))
    }

    @Test fun sensitiveTemplateRefusesToRunWithoutConfirmation() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        assertTrue(t.requiresSensitiveConfirmation)
        assertThrows(ExportTemplateRunRefusal.SensitiveConfirmationRequired::class.java) {
            t.scopeForRun(consent = null, now = now)
        }
    }

    @Test fun freshConfirmationForThisTemplateUnlocksTheSensitiveScope() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        val resolved = t.scopeForRun(SensitiveRunConsent("T1", now), now + 30_000L)
        assertTrue(resolved.includeSensitive)
    }

    /**
     * A confirmation is per-template. Reusing the one the user gave for a different template would
     * let a template they never confirmed export their meds and symptoms.
     */
    @Test fun confirmationForAnotherTemplateIsRefused() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        assertThrows(ExportTemplateRunRefusal.SensitiveConfirmationForDifferentTemplate::class.java) {
            t.scopeForRun(SensitiveRunConsent("OTHER", now), now)
        }
    }

    @Test fun staleConfirmationIsRefused() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        assertThrows(ExportTemplateRunRefusal.SensitiveConfirmationExpired::class.java) {
            t.scopeForRun(SensitiveRunConsent("T1", now), now + SensitiveRunConsent.VALIDITY_WINDOW_MS + 1)
        }
    }

    /**
     * A clock moving backwards (timezone change, NTP correction, a user setting the date) must not
     * turn into an indefinitely-valid confirmation.
     */
    @Test fun confirmationTimestampedInTheFutureIsRefused() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        assertThrows(ExportTemplateRunRefusal.SensitiveConfirmationExpired::class.java) {
            t.scopeForRun(SensitiveRunConsent("T1", now + 600_000L), now)
        }
    }

    /**
     * A refusal is never a quiet downgrade: the sensitive scope either runs confirmed or does not
     * run. Returning `includeSensitive = false` would produce a file missing exactly the records
     * the user asked for, with nothing in it saying so.
     */
    @Test fun refusalNeverSilentlyNarrowsTheScope() {
        val t = template(scope = ExportScope.everything.copy(includeSensitive = true))
        val returned = runCatching { t.scopeForRun(consent = null, now = now) }.getOrNull()
        assertNull(returned)
    }

    // MARK: - The ledger is value-free by construction (§9.5)

    /**
     * The `ExportRun` counterpart of `BackgroundSubstrateTest.workDoneCarriesNoValues`. Both JSON
     * columns the ledger writes must contain only integer counts and closed-enum tokens — a
     * SQLite or Health Connect exception message quoting row content is exactly how a health value
     * would otherwise reach a table the Export Health dashboard displays.
     */
    @Test fun ledgerJsonColumnsCarryNoValues() {
        val encodings = listOf(
            JsonCoding.encode(
                ExportRowCounts(measurements = 900, intervals = 12, sessions = 3, logs = 7, derived = 30, suppressed = 2),
            ),
            JsonCoding.encode(
                ExportErrorDetail(stage = ExportStage.WRITING, filesWritten = 2, filesExpected = 5, attempt = 1),
            ),
        )

        for (encoded in encodings) {
            val obj: JsonObject = Json.parseToJsonElement(encoded).jsonObject
            assertTrue("the column must not encode as an empty object", obj.isNotEmpty())
            for ((key, element) in obj) {
                if (element == JsonNull) continue
                val primitive = element as? JsonPrimitive
                assertNotNull("$key must be a scalar — no nested objects or arrays", primitive)
                primitive!!
                if (primitive.isString) {
                    // The only string permitted anywhere in these columns is a closed-enum token.
                    assertTrue(
                        "$key may only hold a known enum token, never free text",
                        ExportStage.entries.any { JsonCoding.encode(it).trim('"') == primitive.content },
                    )
                    continue
                }
                assertNotNull(
                    "$key must be an integer count — a fractional number is a measurement, not a count",
                    primitive.content.toLongOrNull(),
                )
            }
        }
    }

    /**
     * Counts are by record class, never by metric id — a per-metric map in a durable, backed-up,
     * screenshot-able log is a standing record of which metrics this person tracks (the same
     * disclosure `BackgroundWorkDone` refuses for `unmappedMetricIds`).
     */
    @Test fun rowCountsNameNoMetrics() {
        val encoded = JsonCoding.encode(ExportRowCounts(measurements = 5)).lowercase()
        assertFalse(encoded.contains("metric"))
        assertFalse(encoded.contains("vitals."))
    }

    @Test fun rowCountsTotalCoversEveryField() {
        val counts = ExportRowCounts(1, 2, 3, 4, 5, 6)
        assertEquals(21, counts.total)
        assertTrue(ExportRowCounts().isEmpty)
    }

    @Test fun onlyRealFailuresReadAsFailures() {
        assertTrue(ExportOutcome.FAILED_GENERATION.isFailure)
        assertTrue(ExportOutcome.FAILED_DELIVERY.isFailure)
        assertTrue(ExportOutcome.PARTIAL.isFailure)
        // Locked, no-data, throttled and cancelled are the scheduler and the user behaving
        // normally — styling them as errors would be both alarming and false.
        for (ordinary in listOf(
            ExportOutcome.SUCCESS, ExportOutcome.SKIPPED_LOCKED,
            ExportOutcome.SKIPPED_NO_DATA, ExportOutcome.THROTTLED, ExportOutcome.CANCELLED,
        )) {
            assertFalse("${ordinary.name} must not read as a failure", ordinary.isFailure)
        }
    }

    /** An unknown row must never be rounded up into a claim that the export worked. */
    @Test fun unreadableLedgerCodesFallBackToTheCautiousReading() {
        assertEquals(ExportOutcome.FAILED_GENERATION, ExportOutcome.fromCode("teleported"))
        assertEquals(ExportTrigger.MANUAL, ExportTrigger.fromCode("astrology"))
        assertEquals(ExportDestinationKind.SHARE_SHEET, ExportDestinationKind.fromCode("carrierPigeon"))
        assertEquals(ExportDestinationStatus.DISABLED, ExportDestinationStatus.fromCode("vibes"))
    }

    // MARK: - Destinations and credentials (§9.4)

    /**
     * The point of [CredentialRef]: the only strings it accepts are keys BADAN minted. A pasted
     * bearer token, a JWT, a password and a raw URL all fail — which is what makes "credentials
     * never go in the database" a property of the type rather than a review convention.
     */
    @Test fun credentialRefRejectsThingsThatLookLikeSecrets() {
        assertNull(CredentialRef.of("Bearer sk-live-9f8a7b6c5d4e3f2a1b0c"))
        assertNull(CredentialRef.of("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.abc"))
        assertNull(CredentialRef.of("hunter2"))
        assertNull(CredentialRef.of("https://example.test/?token=abc123"))
        assertNull("a bare namespace references nothing", CredentialRef.of(CredentialRef.NAMESPACE))
        assertNull(CredentialRef.of(CredentialRef.NAMESPACE + "a".repeat(200)))
        assertNull(CredentialRef.of(CredentialRef.NAMESPACE + "has space"))
        assertNull(CredentialRef.of(null))

        assertNotNull(CredentialRef.forDestination("01HZY6K3QW9V2N8T4M0X7RBCDE"))
    }

    /**
     * The config column's typed shape is the other half of the same guarantee: there is no field on
     * [ExportDestinationConfig] a header *value*, token or password fits into.
     */
    @Test fun destinationConfigHasNoFieldASecretFitsIn() {
        val fields = Json.parseToJsonElement(JsonCoding.encode(ExportDestinationConfig()))
            .jsonObject.keys
        for (forbidden in listOf("token", "secret", "password", "apiKey", "authorization", "headers", "cookie")) {
            assertFalse("ExportDestinationConfig must not expose $forbidden", fields.contains(forbidden))
        }
        assertTrue("headers are referenced by template id only", fields.contains("headerTemplateIds"))
    }

    /** An on-device destination does not claim a transport policy it never exercises. */
    @Test fun tlsPolicyDefaultsFromTheDestinationKind() {
        val folder = ExportDestination(
            id = "D1", kind = ExportDestinationKind.FILE_FOLDER, displayName = "Documents",
            createdAt = now, updatedAt = now, originDeviceId = deviceId,
        )
        val api = ExportDestination(
            id = "D2", kind = ExportDestinationKind.REST_API, displayName = "My server",
            createdAt = now, updatedAt = now, originDeviceId = deviceId,
        )
        assertEquals(ExportTlsPolicy.NOT_APPLICABLE, folder.tlsPolicy)
        assertEquals(ExportTlsPolicy.HTTPS_ONLY, api.tlsPolicy)
        assertFalse(ExportDestinationKind.SHARE_SHEET.leavesDevice)
        assertTrue(ExportDestinationKind.CLOUD_DRIVE.leavesDevice)
    }

    @Test fun manifestDigestAcceptsOnlySha256Hex() {
        assertNotNull(ManifestDigest.of("0".repeat(64)))
        assertEquals("a".repeat(64), ManifestDigest.of("A".repeat(64))?.hex)
        assertNull(ManifestDigest.of("a".repeat(63)))
        assertNull(ManifestDigest.of("not a digest"))
        assertNull(ManifestDigest.of(null))
    }

    // MARK: - Storage codecs (§9.3)

    @Test fun rangeRuleStorageRoundTrips() {
        val rules = listOf(
            ExportRangeRule.Fixed, ExportRangeRule.LastNDays(7), ExportRangeRule.LastNDays(365),
            ExportRangeRule.SinceLastRun, ExportRangeRule.AllTime,
        )
        for (rule in rules) {
            assertEquals(rule, ExportRangeRule.fromStorage(rule.storageValue))
        }
        // A zero-day window would export nothing and read as data loss.
        assertEquals(ExportRangeRule.LastNDays(1), ExportRangeRule.fromStorage("lastNDays:0"))
        assertEquals(ExportRangeRule.AllTime, ExportRangeRule.fromStorage("lastNDays:banana"))
        assertEquals(ExportRangeRule.AllTime, ExportRangeRule.fromStorage("who knows"))
        assertEquals(ExportRangeRule.AllTime, ExportRangeRule.fromStorage(null))
    }

    @Test fun aggregationStorageRoundTrips() {
        assertEquals(ExportAggregation.Raw, ExportAggregation.from("raw", null))
        assertNull(ExportAggregation.Raw.storageMethod)
        assertEquals("raw", ExportAggregation.Raw.storageGranularity)

        val bucketed = ExportAggregation.Bucketed(ExportBucket.DAY, ExportAggregationMethod.MEAN)
        assertEquals(bucketed, ExportAggregation.from("day", "mean"))
        assertEquals("day", bucketed.storageGranularity)
        assertEquals("mean", bucketed.storageMethod)

        // A bucket without a method cannot be represented, so it degrades to raw rather than
        // inventing an aggregation the user never chose.
        assertEquals(ExportAggregation.Raw, ExportAggregation.from("day", null))
        assertEquals(ExportAggregation.Raw, ExportAggregation.from("fortnight", "mean"))
    }

    // MARK: - Repository SQL bounds

    /**
     * The name lookup must repeat the partial index's predicate. Without it a deleted template's
     * name stays reserved forever — the exact bug `idx_export_templates_name`'s
     * `WHERE deleted_at IS NULL` was written to avoid.
     */
    @Test fun nameLookupHonoursThePartialUniqueIndexPredicate() {
        assertTrue(ExportTemplateRepository.NAME_LOOKUP_SQL.contains("deleted_at IS NULL"))
        assertEquals(1, ExportTemplateRepository.NAME_LOOKUP_SQL.count { it == '?' })
    }

    /**
     * Both cursor deletes are bounded. An unbounded `DELETE FROM export_cursors` would silently
     * reset every template's incremental progress, and nothing user-visible would distinguish that
     * from a normal re-export.
     */
    @Test fun cursorDeletesAreBounded() {
        assertTrue(ExportCursorRepository.RESET_SQL.contains("WHERE template_id = ? AND destination_id = ?"))
        assertEquals(2, ExportCursorRepository.RESET_SQL.count { it == '?' })
        assertTrue(ExportCursorRepository.RESET_ALL_SQL.contains("WHERE template_id = ?"))
        assertEquals(1, ExportCursorRepository.RESET_ALL_SQL.count { it == '?' })
    }
}
