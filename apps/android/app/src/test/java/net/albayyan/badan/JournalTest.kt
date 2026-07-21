package net.albayyan.badan

import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.domain.journal.ContextAnnotator
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.ContextStatusKind
import net.albayyan.badan.domain.journal.JournalLog
import net.albayyan.badan.export.BackupBundle
import net.albayyan.badan.export.JournalExportPayload
import net.albayyan.badan.export.JsonBundleWriter
import net.albayyan.badan.ontology.BehaviorDefinition
import net.albayyan.badan.ontology.BehaviorDictionary
import net.albayyan.badan.storage.Schema
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-29 data + logic core, Android half: the behavior dictionary, the journal/context entities,
 * the interval semantics of a [ContextStatus], and the sensitive-plus export gating at the writer
 * layer.
 *
 * Scope, stated honestly (as `BaselineAppendOnlyMigrationTest` does): this module has no
 * `androidTest` source set and no Robolectric, so nothing here opens a real SQLite database. The
 * DB-backed halves — repository round-trip, backdated window reads, `purgeSensitiveNamespace()`
 * removing journal rows, and `ExportRunner.run`'s consent gate — are exercised on iOS by
 * `JournalTests`, which runs against a real connection. What IS verifiable on the JVM is pinned
 * here: the shared dictionary parses into the shared model, the domain semantics both platforms
 * depend on, the sensitive-DB placement of the two tables (asserted against the migration lists),
 * and the writer's absent-when-empty behavior for both journal keys.
 */
class JournalTest {

    private val device = "test-device"
    private val at = 1_784_000_000_000L

    private fun prov(occurredAt: Long = at, recordedAt: Long = at, tz: String = "UTC"): Provenance =
        Provenance(
            sourceId = device, deviceId = device, ingestionPath = IngestionPath.MANUAL,
            measuredAt = occurredAt, measuredTimezone = tz, recordedAt = recordedAt, ingestedAt = recordedAt,
        )

    private fun status(
        id: String,
        kind: ContextStatusKind? = null,
        customLabel: String? = null,
        startAt: Long,
        endAt: Long? = null,
    ): ContextStatus = ContextStatus(
        id = id, statusId = kind?.code, customLabel = customLabel, startAt = startAt, endAt = endAt,
        tzId = "UTC", provenance = prov(), updatedAt = at, originDeviceId = device,
    )

    // ===== Behavior dictionary =====

    @Serializable
    private data class BehaviorsFile(val behaviors: List<BehaviorDefinition> = emptyList())

    // Hoisted rather than built per call: a `Json {}` block allocates a fresh serializers module
    // every time, which the Kotlin compiler flags as redundant. Same shape and same name the
    // correlation goldens use, so the dictionary-reading tests stay uniform.
    private val lenient = Json { ignoreUnknownKeys = true }

    private fun canonicalDictionary(): List<BehaviorDefinition> {
        val text = File("../../../packages/contracts/dictionaries/behaviors.json").readText()
        return lenient.decodeFromString<BehaviorsFile>(text).behaviors
    }

    /**
     * The dictionary as authored in `packages/` — the file both platforms mirror — decoded through
     * the SHARED model, so a field iOS reads and Kotlin cannot (or vice versa) fails here rather
     * than at runtime on one platform only.
     */
    @Test fun behaviorDictionaryIsBilingualSensitivePlusAndWellFormed() {
        val behaviors = canonicalDictionary()
        assertTrue("the journal needs a usable chip vocabulary", behaviors.size >= 20)

        val ids = mutableSetOf<String>()
        for (b in behaviors) {
            assertTrue("duplicate behavior id ${b.id} — ids are the join key", ids.add(b.id))
            assertTrue("${b.id} carries English", b.nameEn.isNotEmpty())
            assertTrue("${b.id} carries Arabic", b.nameAr.isNotEmpty())
            assertNotEquals(
                "${b.id}: the Arabic name must be real Arabic, not the English string copied over",
                b.nameEn, b.nameAr,
            )
            assertTrue("${b.id} carries a category", b.category.isNotEmpty())
            assertEquals(
                "${b.id}: every behavior is sensitive-plus (I7) — the file states it per row so no " +
                    "entry can be added at a lower class",
                SensitiveClass.SENSITIVE_PLUS, b.sensitiveClass,
            )
            when (b.valueKind) {
                BehaviorValueKind.QUANTITY -> assertTrue(
                    "${b.id}: a quantity behavior must name its unit — an amount with no unit is unreadable",
                    !b.unit.isNullOrEmpty(),
                )
                BehaviorValueKind.BOOLEAN, BehaviorValueKind.COUNT -> assertNull(
                    "${b.id}: ${b.valueKind.code} carries no physical unit", b.unit,
                )
            }
        }
        // The behaviors named in the plan's own examples, so the shipped vocabulary can't quietly
        // drop the cases the correlation feature was specified around.
        for (expected in listOf("caffeine", "alcohol", "late_meal", "screen_in_bed", "nap", "intense_training")) {
            assertTrue("behaviors.json must offer $expected", expected in ids)
        }
    }

    /** The asset mirror must not drift from the canonical file — same check `AlgorithmRegistryTest` makes. */
    @Test fun bundledBehaviorAssetMatchesTheCanonicalDictionary() {
        val canonical = File("../../../packages/contracts/dictionaries/behaviors.json")
        val asset = File("src/main/assets/behaviors.json")
        assertTrue("behaviors.json must be mirrored into assets/ by scripts/sync_android_assets.sh", asset.exists())
        assertEquals(
            "assets/behaviors.json has drifted from packages/contracts/dictionaries/behaviors.json — " +
                "run scripts/sync_android_assets.sh",
            canonical.readText(), asset.readText(),
        )
    }

    @Test fun behaviorDictionaryResolvesNamesAndKindsWithHonestFallbacks() {
        val dictionary = BehaviorDictionary(canonicalDictionary())
        assertTrue(dictionary.allAreSensitivePlus)
        assertEquals("Caffeine", dictionary.definition("caffeine")?.displayName?.resolved(AppLanguage.EN))
        assertTrue(dictionary.definition("caffeine")!!.displayName.resolved(AppLanguage.AR).isNotEmpty())
        assertEquals(BehaviorValueKind.QUANTITY, dictionary.valueKind("nap"))
        // An id the dictionary doesn't know must not render blank — a journal row written by a
        // newer build still has to display.
        assertEquals("not-a-behavior", dictionary.displayName("not-a-behavior", null).resolved(AppLanguage.EN))
        assertEquals(BehaviorValueKind.BOOLEAN, dictionary.valueKind("not-a-behavior"))
        assertEquals("my own tag", dictionary.displayName(null, "my own tag").resolved(AppLanguage.AR))
    }

    // ===== Journal entry semantics =====

    /**
     * A count of zero is an assertion that the behavior did NOT happen — real information the user
     * can enter. Folding it into the "with" arm would poison every correlation built on it.
     */
    @Test fun explicitZeroCountIsAnAbsenceNotAPresence() {
        val none = JournalLog.entry(
            id = "J-0", behaviorId = "caffeine", valueKind = BehaviorValueKind.COUNT, value = 0.0,
            occurredAt = at, tzId = "UTC", sourceId = device, now = at, originDeviceId = device,
        )
        val some = none.copy(id = "J-2", value = 2.0)
        val tag = JournalLog.entry(
            id = "J-3", behaviorId = "screen_in_bed", valueKind = BehaviorValueKind.BOOLEAN,
            occurredAt = at, tzId = "UTC", sourceId = device, now = at, originDeviceId = device,
        )
        assertFalse(none.isPresent)
        assertTrue(some.isPresent)
        assertTrue("a boolean tag's existence IS the assertion", tag.isPresent)
    }

    /**
     * Yesterday-recall is a first-class path: the entry files under the day it HAPPENED, while
     * provenance keeps the truth about when it was typed.
     */
    @Test fun yesterdayRecallFilesUnderTheDayItHappenedAndDisclosesTheRecall() {
        val yesterday = JournalLog.yesterday(at, "UTC")
        val recalled = JournalLog.recalledEntry(
            id = "J-RECALL", behaviorId = "alcohol", valueKind = BehaviorValueKind.COUNT, value = 2.0,
            occurredAt = yesterday, tzId = "UTC", sourceId = device, now = at, originDeviceId = device,
        )
        val live = JournalLog.entry(
            id = "J-LIVE", behaviorId = "alcohol", valueKind = BehaviorValueKind.BOOLEAN,
            occurredAt = at, tzId = "UTC", sourceId = device, now = at, originDeviceId = device,
        )
        assertTrue("an entry logged a day later must disclose that it was recalled", recalled.isRecalled)
        assertFalse("a same-moment entry is not a recall", live.isRecalled)
        assertEquals("I1: recorded_at stays honest about when the user typed it", at, recalled.provenance.recordedAt)
        assertEquals(yesterday, recalled.occurredAt)
        assertNotEquals(
            "a recalled entry belongs to yesterday's bucket, not today's",
            live.dayKey(), recalled.dayKey(),
        )
    }

    /**
     * Calendar arithmetic, not a fixed 86 400 000 millis: across a DST boundary the naive
     * subtraction lands an hour off and files the entry under the wrong local day.
     */
    @Test fun yesterdayCrossesADstBoundaryByCalendarNotByMillis() {
        val london = ZoneId.of("Europe/London")
        // 2026-03-29 09:00 London — the morning BST begins (clocks go forward at 01:00), so the
        // previous local day is still on GMT and "same time yesterday" is 23 hours back, not 24.
        val reference = ZonedDateTime.of(2026, 3, 29, 9, 0, 0, 0, london).toInstant().toEpochMilli()

        val yesterday = JournalLog.yesterday(reference, "Europe/London")
        val parts = java.time.Instant.ofEpochMilli(yesterday).atZone(london)
        assertEquals(28, parts.dayOfMonth)
        assertEquals("same wall-clock time on the previous local day, DST included", 9, parts.hour)
        assertNotEquals(
            "a fixed 24h subtraction is exactly the bug this guards",
            reference - 86_400_000L, yesterday,
        )
    }

    @Test fun dayKeyIsComputedInTheEntrysOwnTimeZone() {
        // 22:30 in Riyadh (UTC+3) is 19:30 UTC the same day; 01:30 Riyadh is the previous UTC day.
        val riyadh = ZoneId.of("Asia/Riyadh")
        val lateNight = ZonedDateTime.of(2026, 7, 21, 1, 30, 0, 0, riyadh).toInstant().toEpochMilli()
        val entry = JournalLog.entry(
            id = "J-TZ", behaviorId = "late_meal", valueKind = BehaviorValueKind.BOOLEAN,
            occurredAt = lateNight, tzId = "Asia/Riyadh", sourceId = device, now = lateNight,
            originDeviceId = device,
        )
        assertEquals("2026-07-21", entry.dayKey())
        assertEquals(
            "an unresolvable zone falls back to UTC, matching how such a row's timestamp renders",
            "2026-07-20", entry.copy(tzId = "Not/AZone").dayKey(),
        )
    }

    // ===== Context status interval semantics =====

    @Test fun openEndedStatusIsActiveUntilItIsClosed() {
        val start = at - 86_400_000L
        val open = status("C-TRAVEL", ContextStatusKind.TRAVEL, startAt = start)
        assertTrue(open.isOpenEnded)
        assertTrue(open.isActive(at))
        assertFalse(open.isActive(start - 1))

        val closed = open.copy(endAt = at)
        assertFalse("membership is half-open — the end instant is outside", closed.isActive(at))
        assertTrue(closed.isActive(at - 1))
    }

    @Test fun backToBackStatusesDoNotBothClaimTheSharedInstant() {
        val first = status("C-1", ContextStatusKind.TRAVEL, startAt = at - 3_600_000L, endAt = at)
        val second = status("C-2", ContextStatusKind.ILLNESS, startAt = at)
        assertFalse(first.isActive(at))
        assertTrue(second.isActive(at))
    }

    @Test fun overlapAnswersTheWindowQuestionANightlyScoreAsks() {
        val s = status("C-3", ContextStatusKind.ALTITUDE, startAt = at - 1_800_000L, endAt = at + 1_800_000L)
        assertTrue(
            "a status covering half the window still means the window wasn't ordinary",
            s.overlaps(at - 7_200_000L, at),
        )
        assertFalse(s.overlaps(at + 7_200_000L, at + 10_800_000L))
    }

    /**
     * §9.10's behavioural rule. A status may annotate confidence and copy; it may never alter a
     * stored value — and this type gives no way to try. There is no API here that accepts or
     * returns a measurement, so the only thing a test can apply an annotation to is a number the
     * caller already had.
     */
    @Test fun aContextStatusCanOnlyLowerConfidence() {
        val annotation = ContextAnnotator.annotation(at, listOf(status("C-4", ContextStatusKind.TRAVEL, startAt = at - 60_000L)))
        assertFalse(annotation.isEmpty)
        assertEquals(1, annotation.caveats.size)
        assertTrue(annotation.caveats[0].resolved(AppLanguage.EN).isNotEmpty())
        assertTrue(annotation.caveats[0].resolved(AppLanguage.AR).isNotEmpty())
        assertNotEquals(
            "the caveat must be real Arabic, not the English sentence repeated",
            annotation.caveats[0].resolved(AppLanguage.EN), annotation.caveats[0].resolved(AppLanguage.AR),
        )
        assertEquals(ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, annotation.applyingTo(0.95)!!, 1e-9)
        assertEquals("an already-low confidence is not raised", 0.2, annotation.applyingTo(0.2)!!, 1e-9)
        assertNull(annotation.applyingTo(null))
    }

    /**
     * Two active statuses are one reason to read the day carefully, not twice the uncertainty. A
     * compounding ceiling would invent a number nothing supports.
     */
    @Test fun ceilingsDoNotCompoundAcrossStatuses() {
        val one = ContextAnnotator.annotation(at, listOf(status("a", ContextStatusKind.TRAVEL, startAt = at - 60_000L)))
        val two = ContextAnnotator.annotation(
            at,
            listOf(
                status("a", ContextStatusKind.TRAVEL, startAt = at - 60_000L),
                status("b", ContextStatusKind.ILLNESS, startAt = at - 60_000L),
            ),
        )
        assertEquals(one.confidenceCeiling, two.confidenceCeiling, 1e-9)
        assertEquals("each active status still contributes its own sentence", 2, two.caveats.size)
    }

    @Test fun aCustomStatusStillAnnotatesAndNamesItself() {
        val custom = status("C-5", customLabel = "Ramadan night shift", startAt = at - 60_000L)
        assertNull(custom.kind)
        assertEquals("Ramadan night shift", custom.displayLabel.resolved(AppLanguage.EN))
        val annotation = ContextAnnotator.annotation(at, listOf(custom))
        assertTrue(annotation.caveats[0].resolved(AppLanguage.EN).contains("Ramadan night shift"))
        assertTrue(annotation.caveats[0].resolved(AppLanguage.AR).contains("Ramadan night shift"))
    }

    /**
     * Cross-platform parity anchors. Both platforms hard-code the same wire codes and the same
     * confidence ceiling; each asserts its own copy, so a rename on one side fails there rather
     * than silently producing rows the other cannot read.
     */
    @Test fun wireCodesAndCeilingMatchTheIosAnchors() {
        assertEquals(listOf("boolean", "count", "quantity"), BehaviorValueKind.entries.map { it.code })
        assertEquals(
            listOf("travel", "illness", "fasting", "altitude", "injury"),
            ContextStatusKind.entries.map { it.code },
        )
        assertEquals(0.7, ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, 1e-9)
        assertEquals(BehaviorValueKind.BOOLEAN, BehaviorValueKind.fromCode("not-a-kind"))
        assertNull(ContextStatusKind.fromCode("not-a-status"))
    }

    // ===== I7: sensitive placement =====

    /**
     * The structural half of I7: both tables are created by the SENSITIVE migration list and by no
     * main-DB migration, so `purgeSensitiveNamespace()` — a file deletion — covers them by
     * construction, with no per-table purge list to keep in sync.
     */
    @Test fun journalTablesAreCreatedOnlyBySensitiveMigrations() {
        val mainSql = Schema.mainMigrations.flatMap { it.statements }.joinToString("\n")
        val sensitiveSql = Schema.sensitiveMigrations.flatMap { it.statements }.joinToString("\n")
        for (table in listOf("journal_entries", "context_statuses")) {
            assertTrue("$table must be created in badan_sensitive.db", sensitiveSql.contains("CREATE TABLE $table"))
            assertFalse(
                "$table is sensitive-plus (I7) and must never be created in badan.db — " +
                    "purgeSensitiveNamespace() only deletes the sensitive file",
                mainSql.contains(table),
            )
        }
    }

    // ===== Export representation (writer layer) =====

    private fun manifest(): ExportManifest = ExportManifest(
        exportId = "EXPORT-JOURNAL", schemaVersion = "1.0.0", appVersion = "test", platform = "Android",
        generatedAt = at, scope = ExportScope(), dateRange = "all", displayLanguage = "en",
        unitProfile = "canonical", timezonePolicy = "t", dedupPolicy = "d", perMetricRowCounts = emptyMap(),
        checksums = emptyMap(), dataQualityNote = "test",
    )

    private fun bundle(journal: JournalExportPayload?): String = String(
        JsonBundleWriter().data(
            manifest = manifest(), rawSamples = emptyList(), intervalRecords = emptyList(),
            sessions = emptyList(), derivedValues = emptyList(), baselines = emptyList(),
            symptoms = emptyList(), adherence = emptyList(), workouts = emptyList(),
            nutrition = emptyList(), journal = journal,
        ),
        Charsets.UTF_8,
    )

    private fun populated(): JournalExportPayload = JournalExportPayload(
        entries = listOf(
            // Backdated by two hours, so the exported `recalled` flag is exercised rather than
            // always false — the yesterday-recall path is what a real journal export mostly holds.
            JournalLog.recalledEntry(
                id = "J-EXPORT", behaviorId = "caffeine", valueKind = BehaviorValueKind.COUNT, value = 2.0,
                occurredAt = at - 7_200_000L, tzId = "UTC", note = "JOURNAL-NOTE-TRIPWIRE",
                sourceId = device, deviceId = device, now = at, originDeviceId = device,
            ),
        ),
        statuses = listOf(status("C-EXPORT", ContextStatusKind.TRAVEL, startAt = at - 3_600_000L)),
    )

    /**
     * Absent, not empty. A bundle written with no journal payload carries neither key — an empty
     * array would both assert "this user logged no behaviors" and disclose that a sensitive log was
     * read at all, and it would break the byte-pinned pre-EPIC-29 goldens.
     */
    @Test fun aBundleWithoutAJournalPayloadCarriesNeitherKey() {
        val json = bundle(null)
        assertFalse("\"journal\"" in json)
        assertFalse("\"context_statuses\"" in json)
        assertFalse("logs.journal" in json)
        // Same for a payload that exists but caught nothing.
        val empty = bundle(JournalExportPayload())
        assertFalse("\"journal\"" in empty)
        assertFalse("\"context_statuses\"" in empty)
    }

    @Test fun aBundleWithAJournalPayloadCarriesBothFamiliesAndTheirCounts() {
        val json = bundle(populated())
        assertTrue("\"journal\"" in json)
        assertTrue("\"context_statuses\"" in json)
        assertTrue("J-EXPORT" in json)
        assertTrue("C-EXPORT" in json)
        assertTrue("\"behavior_id\":\"caffeine\"" in json)
        assertTrue("\"value_kind\":\"count\"" in json)
        assertTrue("\"recalled\":true" in json)
        // An ongoing status exports with a null end — never a fabricated one.
        assertTrue("\"open_ended\":true" in json)
        assertTrue("\"end_at\":null" in json)
        assertTrue("\"logs.journal\":1" in json)
        assertTrue("\"logs.context_statuses\":1" in json)
        // The note travels only because the caller already passed the sensitive gate to build the
        // payload; there is no second redaction layer to mistake for one.
        assertTrue("JOURNAL-NOTE-TRIPWIRE" in json)
    }

    /** Each key is independent: statuses without chips must not synthesize an empty `journal`. */
    @Test fun eachJournalKeyIsAddedOnlyWhenItsOwnArrayHasRows() {
        val statusesOnly = bundle(JournalExportPayload(statuses = populated().statuses))
        assertTrue("\"context_statuses\"" in statusesOnly)
        assertFalse("\"journal\"" in statusesOnly)

        val entriesOnly = bundle(JournalExportPayload(entries = populated().entries))
        assertTrue("\"journal\"" in entriesOnly)
        assertFalse("\"context_statuses\"" in entriesOnly)
    }

    /**
     * A backup whose ONLY sensitive content is a behavior journal must still make the restore
     * screen ask. Before EPIC-29 `sensitivePresent` was `symptoms > 0 || adherence > 0`, so such a
     * bundle would have restored its journal without the receiving device ever offering the consent
     * toggle (§12 EPIC-18 requirement 5).
     */
    @Test fun restorePreviewTreatsAJournalOnlyBundleAsSensitive() {
        val bundleJson = Json.parseToJsonElement(
            """
            {"logs":{"symptoms":[],"adherence":[],"workouts":[],"nutrition":[],
              "journal":[{"record_id":"J-BACKUP"}],
              "context_statuses":[{"record_id":"C-BACKUP"}]}}
            """.trimIndent(),
        ).jsonObject
        val restore = BackupBundle.RestoreBundle(
            schemaVersion = "1.0.0", createdAt = "2026-07-21T00:00:00+00:00", originPlatform = "android",
            originAppVersion = "test", encrypted = false, logicalFiles = emptyList(), bundle = bundleJson,
        )
        val preview = BackupBundle.preview(restore)

        assertEquals(1, preview.namespaceCounts["logs.journal"])
        assertEquals(1, preview.namespaceCounts["logs.context_statuses"])
        assertTrue(
            "a journal-only backup is still an I7 bundle — the restore must re-ask",
            preview.sensitivePresent,
        )

        val denied = BackupBundle.plan(
            preview, BackupBundle.RestoreConsent(includeSensitive = false), "B-1", "b.json", at,
        )
        assertEquals("default deny zeroes the journal namespace", 0, denied.counts["logs.journal"])
        assertEquals(0, denied.counts["logs.context_statuses"])
        assertFalse(denied.includesSensitive)

        val granted = BackupBundle.plan(
            preview, BackupBundle.RestoreConsent(includeSensitive = true), "B-2", "b.json", at,
        )
        assertEquals(1, granted.counts["logs.journal"])
        assertTrue(granted.includesSensitive)
    }

    private fun assertNotEquals(message: String, unexpected: Any?, actual: Any?) {
        org.junit.Assert.assertNotEquals(message, unexpected, actual)
    }
}
