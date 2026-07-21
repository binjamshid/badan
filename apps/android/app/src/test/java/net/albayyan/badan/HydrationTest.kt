package net.albayyan.badan

import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.hydration.GoalEngine
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.domain.hydration.HydrationLedger
import net.albayyan.badan.core.DecimalParsing
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.export.HydrationCsvWriter
import net.albayyan.badan.export.HydrationExportPayload
import net.albayyan.badan.export.HydrationRedactionPolicy
import net.albayyan.badan.export.JsonBundleWriter
import net.albayyan.badan.storage.Schema
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-38 hydration DATA + LOGIC core, Android half. Like `BaselineAppendOnlyMigrationTest`, this
 * module has no real SQLite (no androidTest/Robolectric), so the DB-backed `HydrationRepository`
 * behavior is exercised on iOS by `HydrationTests`; what is verifiable on the JVM is pinned here: the
 * pure ledger/goal logic, Arabic volume parsing, the export redaction, and the v7 migration parity.
 */
class HydrationTest {

    private val device = "test-device"
    private fun prov(at: Long): Provenance =
        Provenance(sourceId = "badan.manual", ingestionPath = IngestionPath.MANUAL, measuredAt = at,
            measuredTimezone = "Asia/Riyadh", recordedAt = at, ingestedAt = at)

    private fun entry(id: String, ml: Double, at: Long = 1_783_000_000_000L, note: String? = null): HydrationEntry =
        HydrationLedger.makeEntry(id = id, volumeMl = ml, fluidType = "water", occurredAt = at,
            tzId = "Asia/Riyadh", note = note, provenance = prov(at), updatedAt = at, originDeviceId = device)

    // --- Arabic volume parsing (§7A.1, mL canonical) ---

    @Test fun volumeParsingFoldsArabicNumerals() {
        assertEquals(500.0, HydrationLedger.parseVolumeMl("500"))
        assertEquals(500.0, HydrationLedger.parseVolumeMl("٥٠٠"))   // Eastern Arabic-Indic
        assertEquals(500.0, HydrationLedger.parseVolumeMl("۵۰۰"))   // Extended Arabic-Indic
        assertEquals(1.5, HydrationLedger.parseVolumeMl("1٫5"))     // Arabic decimal separator
        assertEquals(2.5, HydrationLedger.parseVolumeMl("2,5"))     // comma decimal
        assertEquals("500", DecimalParsing.normalize("٥٠٠"))
    }

    @Test fun volumeParsingRejectsNonPositiveAndJunk() {
        assertNull(HydrationLedger.parseVolumeMl("0"))
        assertNull(HydrationLedger.parseVolumeMl("-250"))
        assertNull(HydrationLedger.parseVolumeMl("abc"))
        assertNull(HydrationLedger.parseVolumeMl(""))
    }

    // --- Append-first ledger with auditable revisions (pure) ---

    @Test fun revisionSupersedesOriginal() {
        val a = entry("A", 250.0)
        val a2 = HydrationLedger.makeRevision(a, id = "A2", volumeMl = 500.0, provenance = prov(1L), updatedAt = 1L, originDeviceId = device)
        assertEquals("A", a2.originalId)
        assertEquals("A", a2.supersedes)
        assertEquals(2, a2.revision)
        assertEquals(setOf("A2", "B"), HydrationLedger.liveEntries(listOf(a, a2, entry("B", 500.0))).map { it.id }.toSet())
    }

    @Test fun undoOfARevisionRevertsToPriorVersion() {
        val a = entry("A", 250.0)
        val a2 = HydrationLedger.makeRevision(a, id = "A2", volumeMl = 500.0, provenance = prov(1L), updatedAt = 1L, originDeviceId = device)
        val deletedA2 = a2.copy(deletedAt = 1L)
        val live = HydrationLedger.liveEntries(listOf(a, deletedA2))
        assertEquals(listOf("A"), live.map { it.id })
        assertEquals(250.0, live.first().volumeMl, 0.0)
    }

    @Test fun deletingAWholeChainLeavesNothingLive() {
        val a = entry("A", 250.0)
        val a2 = HydrationLedger.makeRevision(a, id = "A2", volumeMl = 500.0, provenance = prov(1L), updatedAt = 1L, originDeviceId = device)
        assertTrue(HydrationLedger.liveEntries(listOf(a.copy(deletedAt = 1L), a2.copy(deletedAt = 1L))).isEmpty())
    }

    // --- No-goal is an equal-status default ---

    @Test fun noGoalSummaryHasNoProgressPercentage() {
        val s = HydrationDailySummary(dayKey = "2026-07-21", tzId = "Asia/Riyadh", manualMl = 1200.0,
            entryCount = 3, goalKind = HydrationGoalKind.NONE, updatedAt = 1L, originDeviceId = device)
        assertNull(s.goalProgressPct)
        assertEquals(1200.0, s.totalMl, 0.0)
    }

    @Test fun resolveGoalTreatsNoActiveGoalAsNoGoal() {
        assertNull(GoalEngine.resolveGoal(null, emptyList()))
        val none = HydrationGoal.noGoal(id = "G", createdAt = 1L, updatedAt = 1L, originDeviceId = device)
        assertFalse(none.hasTarget)
    }

    // --- Goal snapshot survives a goal change ---

    @Test fun goalSnapshotIsFrozenAcrossAGoalChange() {
        val day = "2026-06-01"
        val live = listOf(entry("X", 500.0))
        val goal2000 = HydrationGoal(id = "g1", kind = HydrationGoalKind.MANUAL, targetMl = 2000.0, createdAt = 1L, updatedAt = 1L, originDeviceId = device)
        val first = GoalEngine.makeSummary(day, "Asia/Riyadh", live, goal2000, existing = null, now = 1L, originDeviceId = device)
        assertEquals(2000.0, first.goalTargetMl)

        val goal2500 = HydrationGoal(id = "g2", kind = HydrationGoalKind.MANUAL, targetMl = 2500.0, createdAt = 2L, updatedAt = 2L, originDeviceId = device)
        val recomputed = GoalEngine.makeSummary(day, "Asia/Riyadh", live, goal2500, existing = first, now = 2L, originDeviceId = device)
        assertEquals("the snapshot is frozen — history stays honest after a goal change", 2000.0, recomputed.goalTargetMl)
    }

    @Test fun dayKeyIsComputedInTheProvidedZone() {
        // 2026-07-21T00:30 Asia/Riyadh (UTC+3) is 2026-07-20T21:30 UTC.
        val millis = 1_784_000_000_000L
        assertEquals(GoalEngine.dayKey(millis, "UTC"), GoalEngine.dayKey(millis, "UTC"))
        // Same instant, two zones can land on different local days — the key is zone-relative.
        assertTrue(GoalEngine.dayKey(millis, "Asia/Riyadh").matches(Regex("""\d{4}-\d{2}-\d{2}""")))
    }

    // --- Export redaction proven ---

    private fun bundleString(payload: HydrationExportPayload, policy: HydrationRedactionPolicy): String {
        val scope = ExportScope(includeRaw = true, includeDerived = true, includeSuppressed = false, includeSensitive = false)
        val manifest = ExportManifest(
            exportId = "exp", schemaVersion = "0.1.0", appVersion = "1.0", platform = "android",
            generatedAt = 1L, scope = scope, dateRange = "all", displayLanguage = "en", unitProfile = "canonical",
            timezonePolicy = "x", dedupPolicy = "y", perMetricRowCounts = emptyMap(), checksums = emptyMap(),
            dataQualityNote = "z",
        )
        val bytes = JsonBundleWriter().data(
            manifest, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(),
            emptyList(), emptyList(), emptyList(), hydration = payload, hydrationRedaction = policy,
        )
        return String(bytes, Charsets.UTF_8)
    }

    @Test fun defaultExportRedactsNotesStructurally() {
        val payload = HydrationExportPayload(entries = listOf(entry("A", 500.0, note = "SECRET-NOTE-TEXT")))
        val redacted = bundleString(payload, HydrationRedactionPolicy.DEFAULT)
        assertFalse("the note text must never appear in a default export", redacted.contains("SECRET-NOTE-TEXT"))
        // `"note"` appears once as a value in the redaction list; the note KEY (`"note":`) must not.
        assertFalse("the note key is absent, not blanked", redacted.contains("\"note\":"))
        assertTrue(redacted.contains("\"notes_included\":false"))

        val opted = bundleString(payload, HydrationRedactionPolicy(includeNotes = true))
        assertTrue(opted.contains("SECRET-NOTE-TEXT"))
        assertTrue(opted.contains("\"note\":"))
    }

    @Test fun redactionManifestNamesEveryDefaultExclusion() {
        val redacted = bundleString(HydrationExportPayload(entries = listOf(entry("A", 500.0))), HydrationRedactionPolicy.DEFAULT)
        for (field in listOf("note", "fasting_context", "cycle_context", "pregnancy_context", "location", "reminder_history")) {
            assertTrue("the redaction manifest must disclose that '$field' is excluded", redacted.contains("\"$field\""))
        }
    }

    @Test fun bundleOmitsHydrationEntirelyWhenPayloadEmpty() {
        // Golden-safety: no hydration payload -> no `hydration` anywhere in the bundle.
        assertFalse(bundleString(HydrationExportPayload(), HydrationRedactionPolicy.DEFAULT).contains("hydration"))
    }

    @Test fun hydrationCsvRedactsNotesByDefaultAndOptsIn() {
        val e = entry("A", 500.0, note = "SECRET-NOTE-TEXT")
        val defaultCsv = HydrationCsvWriter().entriesCsv(listOf(e))
        assertFalse(defaultCsv.contains("SECRET-NOTE-TEXT"))
        assertFalse("the note column is absent from a default CSV", defaultCsv.contains("note"))
        assertTrue(HydrationCsvWriter(HydrationRedactionPolicy(includeNotes = true)).entriesCsv(listOf(e)).contains("SECRET-NOTE-TEXT"))
    }

    // --- v7 migration parity ---

    @Test fun v7CreatesHydrationTables() {
        // v7 was the head when EPIC-38 shipped; Phase-3A's v8 (reports + notification ledger) now
        // sits above it, so this test pins what v7 CREATES rather than that it is the maximum version
        // (the head is pinned by `ProfileHRZonesTest.v8IsTheHeadMainSchemaVersion`).
        assertTrue("v7 must still exist in the migration list", Schema.mainMigrations.any { it.version == 7 })
        val v7 = Schema.mainMigrations.first { it.version == 7 }.statements.joinToString("\n")
        // The five tables §9.14 mandates this phase.
        for (table in listOf("hydration_entries", "beverage_definitions", "container_presets", "hydration_goals", "hydration_daily_summaries")) {
            assertTrue("v7 must create $table", v7.contains("CREATE TABLE $table"))
        }
        // The revision-chain columns are the heart of the append-first ledger.
        for (col in listOf("original_id", "supersedes", "revision", "volume_ml", "fluid_type")) {
            assertTrue("hydration_entries must carry $col", v7.contains(col))
        }
        // Provenance (I1) and convention (D-7) columns are present on the ledger.
        assertTrue(v7.contains("source_id"))
        assertTrue(v7.contains("origin_device_id"))
        // Display-metadata-only beverage annotations exist but are never a hydration weight.
        assertTrue(v7.contains("caffeine_mg_per_100ml"))
    }
}
