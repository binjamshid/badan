package net.albayyan.badan

import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.hydration.BeverageDefinition
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.domain.hydration.HydrationLedger
import net.albayyan.badan.export.HydrationCsvWriter
import net.albayyan.badan.export.HydrationExportPayload
import net.albayyan.badan.export.HydrationRedactionPolicy
import net.albayyan.badan.export.JsonBundleWriter
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-38 — the export INCLUSION contract, Android half. `HydrationTest` proves the redaction and the
 * absent-when-empty golden safety; this pins the other half — the one an independent audit found
 * broken: a drink the user logged is actually written to the real export, so the module's copy
 * ("... left out of the default export", which implies the drink itself is IN it) is true rather than
 * a silent broken promise. Raw data is never paywalled — a logged drink is the user's own data.
 *
 * Verified at the writer layer, which is what the JVM source set can reach (no androidTest /
 * Robolectric, so `ExportRunner.run`'s DB-backed gather is exercised on iOS, the same split
 * `ExportRunnerTemplateTest` documents). The runner feeds the SAME [HydrationExportPayload] this test
 * builds to both writers, so pinning the writers' output pins what the export actually contains.
 */
class HydrationExportInclusionTest {

    private val device = "test-device"
    private val at = 1_783_000_000_000L

    private fun prov(): Provenance = Provenance(
        sourceId = "badan.manual", ingestionPath = IngestionPath.MANUAL, measuredAt = at,
        measuredTimezone = "Asia/Riyadh", recordedAt = at, ingestedAt = at,
    )

    private fun entry(id: String, ml: Double, note: String? = null): HydrationEntry =
        HydrationLedger.makeEntry(
            id = id, volumeMl = ml, fluidType = "water", occurredAt = at, tzId = "Asia/Riyadh",
            note = note, provenance = prov(), updatedAt = at, originDeviceId = device,
        )

    /** A payload shaped like a real export slice: one drink, its day summary, a goal, a custom drink. */
    private fun populatedPayload(): HydrationExportPayload = HydrationExportPayload(
        entries = listOf(entry("HYD-ENTRY-ONE", 512.0, note = "PRIVATE-NOTE-XYZ")),
        summaries = listOf(
            HydrationDailySummary(
                dayKey = "2026-07-21", tzId = "Asia/Riyadh", manualMl = 512.0, entryCount = 1,
                goalKind = HydrationGoalKind.MANUAL, goalTargetMl = 2000.0, updatedAt = at,
                originDeviceId = device,
            ),
        ),
        goals = listOf(
            HydrationGoal(
                id = "HYD-GOAL-ONE", kind = HydrationGoalKind.MANUAL, targetMl = 2000.0,
                createdAt = at, updatedAt = at, originDeviceId = device,
            ),
        ),
        beverages = listOf(
            BeverageDefinition(
                id = "HYD-BEV-ONE", nameEn = "Karak", nameAr = "كرك", fluidType = "tea",
                updatedAt = at, originDeviceId = device,
            ),
        ),
    )

    private fun manifest(): ExportManifest {
        val scope = ExportScope(includeRaw = true, includeDerived = true, includeSuppressed = false, includeSensitive = false)
        return ExportManifest(
            exportId = "exp", schemaVersion = "0.1.0", appVersion = "1.0", platform = "android",
            generatedAt = at, scope = scope, dateRange = "all", displayLanguage = "en",
            unitProfile = "canonical", timezonePolicy = "x", dedupPolicy = "y",
            perMetricRowCounts = emptyMap(), checksums = emptyMap(), dataQualityNote = "z",
        )
    }

    private fun bundleString(payload: HydrationExportPayload, policy: HydrationRedactionPolicy = HydrationRedactionPolicy.DEFAULT): String {
        val bytes = JsonBundleWriter().data(
            manifest(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(),
            emptyList(), emptyList(), emptyList(), hydration = payload, hydrationRedaction = policy,
        )
        return String(bytes, Charsets.UTF_8)
    }

    // --- JSON bundle: the logs.hydration block carries the logged drink ---

    @Test fun jsonExportCarriesTheLoggedDrinkAndItsContext() {
        val json = bundleString(populatedPayload())
        assertTrue("the logs.hydration block must be present", json.contains("\"hydration\""))
        assertTrue("the drink itself must be exported", json.contains("HYD-ENTRY-ONE"))
        assertTrue("the day summary must be exported", json.contains("\"summaries\""))
        assertTrue("the goal must be exported", json.contains("HYD-GOAL-ONE"))
        assertTrue("the custom beverage must be exported so a reader can name the drink", json.contains("HYD-BEV-ONE"))
        assertTrue("the per-class row count must tally the drinks", json.contains("\"logs.hydration\""))
    }

    @Test fun jsonExportRedactsTheNoteByDefaultButNotTheDrink() {
        val redacted = bundleString(populatedPayload())
        assertTrue("the drink is present", redacted.contains("HYD-ENTRY-ONE"))
        assertFalse("the note text must never appear in a default export", redacted.contains("PRIVATE-NOTE-XYZ"))
        assertTrue("the redaction manifest discloses the default", redacted.contains("\"notes_included\":false"))

        val opted = bundleString(populatedPayload(), HydrationRedactionPolicy(includeNotes = true))
        assertTrue("opting in surfaces the note", opted.contains("PRIVATE-NOTE-XYZ"))
    }

    // --- CSV set: the drink ledger is written as its own self-describing tables ---

    @Test fun csvExportWritesTheFullHydrationFileSetWithTheDrink() {
        val files = HydrationCsvWriter().files(populatedPayload())
        for (name in listOf(
            "hydration_entries.csv", "hydration_summaries.csv", "hydration_goals.csv",
            "hydration_sources.csv", "hydration_redaction.json",
        )) {
            assertTrue("the CSV export must include $name", files.containsKey(name))
        }
        val entriesCsv = files.getValue("hydration_entries.csv")
        assertTrue("the drink must appear in the CSV", entriesCsv.contains("HYD-ENTRY-ONE"))
        assertFalse("the note is excluded from the default CSV", entriesCsv.contains("PRIVATE-NOTE-XYZ"))
        assertTrue("the goal must appear in the goals CSV", files.getValue("hydration_goals.csv").contains("HYD-GOAL-ONE"))
    }

    @Test fun csvExportOptsTheNoteBackInOnRequest() {
        val opted = HydrationCsvWriter(HydrationRedactionPolicy(includeNotes = true)).files(populatedPayload())
        assertTrue(opted.getValue("hydration_entries.csv").contains("PRIVATE-NOTE-XYZ"))
    }

    // --- Golden safety: the guard the runner keys off to keep no-hydration exports byte-stable ---

    @Test fun anEmptyPayloadReportsEmptySoTheRunnerOmitsTheBlockAndFiles() {
        // `ExportRunner.gatherHydration` returns null on an empty result, and the JSON writer skips
        // the block for a null/empty payload — together that is what keeps a pre-hydration export
        // byte-identical. Both key off `isEmpty`, so pin the contract here.
        assertTrue(HydrationExportPayload().isEmpty)
        assertFalse(populatedPayload().isEmpty)
        assertFalse("no payload -> no hydration anywhere in the bundle", bundleString(HydrationExportPayload()).contains("hydration"))
    }
}
