package net.albayyan.badan

import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportSuppressionCorrection
import net.albayyan.badan.domain.ExportTombstone
import net.albayyan.badan.export.JsonBundleWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-17 (§22.5/§22.6) — the delta bundle's manifest fields, `deletions[]` and `corrections[]`, at
 * the WRITER level.
 *
 * Scope, stated honestly (the same caveat `ExportRunnerTemplateTest` carries): this module has no
 * `androidTest` source set and no Robolectric, so nothing here opens a database. The DB-backed half
 * — gathering tombstones and dedup flips out of the store and threading them into a delta run — is
 * covered on iOS by `ExportRunnerTemplateTests`, against a real SQLite file. What is covered here is
 * the serialization contract both platforms must agree on byte-for-byte: which keys a delta bundle
 * carries, how they are ordered, and — the load-bearing one — that a NON-delta bundle is completely
 * unchanged, which is what keeps the pinned parity golden byte-stable.
 */
class ExportDeltaBundleTest {

    private val generatedAt = 1_784_000_000_000L

    // The exact §22.1 renderings of the instants used below (numeric offset, never "Z").
    private val generatedAtUtc = "2026-07-14T03:33:20+00:00"
    private val cursorBeforeMs = 1_783_000_000_000L
    private val cursorBeforeUtc = "2026-07-02T13:46:40+00:00"
    private val cursorAfterMs = 1_783_500_000_000L
    private val cursorAfterUtc = "2026-07-08T08:40:00+00:00"

    private fun manifest() = ExportManifest(
        exportId = "01J8ZKEXPORT00000000000001",
        schemaVersion = "1.0.0",
        appVersion = "test",
        platform = "Android",
        generatedAt = generatedAt,
        scope = ExportScope.everything,
        dateRange = "all",
        displayLanguage = "en",
        unitProfile = "canonical",
        timezonePolicy = "tz",
        dedupPolicy = "dedup",
        perMetricRowCounts = emptyMap(),
        checksums = emptyMap(),
        dataQualityNote = "note",
    )

    /** Renders an otherwise-empty bundle with whatever delta metadata the case under test needs. */
    private fun render(
        isDelta: Boolean = false,
        cursorBefore: Long? = null,
        cursorAfter: Long? = null,
        previousManifestSha: String? = null,
        deletions: List<ExportTombstone> = emptyList(),
        corrections: List<ExportSuppressionCorrection> = emptyList(),
    ): String = JsonBundleWriter().data(
        manifest = manifest(),
        rawSamples = emptyList(), intervalRecords = emptyList(), sessions = emptyList(),
        derivedValues = emptyList(), baselines = emptyList(),
        symptoms = emptyList(), adherence = emptyList(), workouts = emptyList(), nutrition = emptyList(),
        isDelta = isDelta, cursorBefore = cursorBefore, cursorAfter = cursorAfter,
        previousManifestSha = previousManifestSha,
        additionalDeletions = deletions, corrections = corrections,
    ).toString(Charsets.UTF_8)

    // ===== The delta manifest (§22.5) =====

    @Test
    fun deltaManifestDeclaresItselfAndCarriesBothCursorsAndTheChainLink() {
        val json = render(
            isDelta = true,
            cursorBefore = cursorBeforeMs,
            cursorAfter = cursorAfterMs,
            previousManifestSha = "a".repeat(64),
        )
        assertTrue("a delta must declare itself", json.contains("\"is_delta\":true"))
        assertTrue(json.contains("\"cursor_before\":\"$cursorBeforeUtc\""))
        assertTrue(json.contains("\"cursor_after\":\"$cursorAfterUtc\""))
        assertTrue(
            "the chain link is carried verbatim",
            json.contains("\"previous_manifest_sha\":\"${"a".repeat(64)}\""),
        )
    }

    /**
     * The byte-stability guard. A full (non-delta) run must serialize exactly as it did before
     * EPIC-17: `is_delta:false`, null cursors, null chain link, and NO `corrections` key at all.
     * If this breaks, `packages/fixtures/export/bundle-v1.json` breaks with it.
     */
    @Test
    fun nonDeltaBundleCarriesNullDeltaFieldsAndNoCorrectionsKey() {
        val json = render()
        assertTrue(json.contains("\"is_delta\":false"))
        assertTrue(json.contains("\"cursor_before\":null"))
        assertTrue(json.contains("\"cursor_after\":null"))
        assertTrue(json.contains("\"previous_manifest_sha\":null"))
        assertFalse(
            "absent, not empty — a full run makes no claim about dedup flips",
            json.contains("\"corrections\""),
        )
        // `deletions` stays present-and-empty (it always was) rather than becoming absent.
        assertTrue(json.contains("\"deletions\":[]"))
    }

    // ===== deletions[] (§22.6) =====

    @Test
    fun additionalTombstonesAreEmittedAndSortedByRecordId() {
        val json = render(
            isDelta = true,
            deletions = listOf(
                ExportTombstone("01J8ZKZZZZ0000000000000002", "session", generatedAt, "UTC"),
                ExportTombstone("01J8ZKAAAA0000000000000001", "raw_sample", generatedAt, "UTC"),
            ),
        )
        val first = json.indexOf("01J8ZKAAAA0000000000000001")
        val second = json.indexOf("01J8ZKZZZZ0000000000000002")
        assertTrue("both tombstones must be emitted", first > 0 && second > 0)
        assertTrue("deletions[] is sorted by record_id, so the bytes are gather-order independent",
            first < second)
        assertTrue(json.contains("\"entity\":\"raw_sample\""))
        assertTrue(json.contains("\"entity\":\"session\""))
    }

    // ===== corrections[] (§22.6) =====

    /**
     * A live suppression: the record a consumer already holds as authoritative is now the loser.
     * `suppressed_by` names the winner so the consumer can re-point its own copy.
     */
    @Test
    fun suppressionFlipEmitsACorrectionNamingTheWinner() {
        val json = render(
            isDelta = true,
            corrections = listOf(
                ExportSuppressionCorrection("01J8ZKLOSER000000000000001", "01J8ZKWINNER00000000000001", generatedAt),
            ),
        )
        assertTrue(json.contains("\"corrections\":["))
        assertTrue(json.contains("\"record_id\":\"01J8ZKLOSER000000000000001\""))
        assertTrue(json.contains("\"suppressed_by\":\"01J8ZKWINNER00000000000001\""))
        assertTrue(json.contains("\"changed_at\":\"$generatedAtUtc\""))
    }

    /**
     * The reversal, which is the flip an add-only delta corrupts most quietly. `suppressed_by` must
     * be an explicit JSON null — "no longer suppressed" — never an empty string or a dropped key,
     * or a consumer cannot distinguish it from "unchanged".
     */
    @Test
    fun reversedSuppressionEmitsANullSuppressedBy() {
        val json = render(
            isDelta = true,
            corrections = listOf(ExportSuppressionCorrection("01J8ZKREVIVED0000000000001", null, generatedAt)),
        )
        assertTrue(json.contains("\"suppressed_by\":null"))
        assertTrue(json.contains("\"record_id\":\"01J8ZKREVIVED0000000000001\""))
    }

    @Test
    fun correctionsAreSortedByRecordId() {
        val json = render(
            isDelta = true,
            corrections = listOf(
                ExportSuppressionCorrection("01J8ZKZZZZ0000000000000002", null, generatedAt),
                ExportSuppressionCorrection("01J8ZKAAAA0000000000000001", "01J8ZKW0000000000000000001", generatedAt),
            ),
        )
        val first = json.indexOf("01J8ZKAAAA0000000000000001")
        val second = json.indexOf("01J8ZKZZZZ0000000000000002")
        assertTrue(first > 0 && second > 0)
        assertTrue("corrections[] is sorted by record_id for cross-platform byte stability", first < second)
    }

    /**
     * The tie the `record_id` sort alone cannot break: one record that flipped TWICE inside a single
     * delta window (suppressed by A, then by B after a source-priority change). Both corrections
     * carry the same `record_id`, so ordering falls to `changed_at` — which must put them in the
     * order they happened, or a consumer applying the array in order ends up holding the
     * intermediate state instead of the current one.
     *
     * Cross-platform, this is also the one place the two languages' sorts could legitimately
     * disagree: Kotlin's `sortedWith` is stable, Swift's `sorted(by:)` is documented as not
     * guaranteed to be, so a `record_id`-only comparator would let a tie resolve differently on each
     * platform and the byte-identical claim would stop being true without any test noticing.
     */
    @Test
    fun repeatedFlipsForOneRecordAreOrderedByChangedAt() {
        val later = generatedAt
        val earlier = generatedAt - 3_600_000L
        val earlierUtc = "2026-07-14T02:33:20+00:00"
        val json = render(
            isDelta = true,
            corrections = listOf(
                // Deliberately supplied newest-first: the writer, not the caller, owns the order.
                ExportSuppressionCorrection("01J8ZKA00000000000000000001", "01J8ZKWINNERB000000000001", later),
                ExportSuppressionCorrection("01J8ZKA00000000000000000001", "01J8ZKWINNERA000000000001", earlier),
            ),
        )
        val start = json.indexOf("\"corrections\":[")
        val end = json.indexOf("]", start)
        assertEquals(
            "\"corrections\":[{\"changed_at\":\"$earlierUtc\"," +
                "\"record_id\":\"01J8ZKA00000000000000000001\"," +
                "\"suppressed_by\":\"01J8ZKWINNERA000000000001\"}," +
                "{\"changed_at\":\"$generatedAtUtc\"," +
                "\"record_id\":\"01J8ZKA00000000000000000001\"," +
                "\"suppressed_by\":\"01J8ZKWINNERB000000000001\"}]",
            json.substring(start, end + 1),
        )
    }

    /**
     * Key order across the whole envelope is canonical (sorted), so `corrections` lands between
     * `baselines` and `deletions` on BOTH platforms rather than wherever each language's map
     * iteration happens to put it — the divergence class `packages/fixtures/export/README.md`
     * documents at length.
     */
    @Test
    fun correctionsKeyIsCanonicallyOrderedWithinTheEnvelope() {
        val json = render(
            isDelta = true,
            corrections = listOf(ExportSuppressionCorrection("01J8ZKA00000000000000000001", null, generatedAt)),
        )
        val baselines = json.indexOf("\"baselines\":")
        val corrections = json.indexOf("\"corrections\":")
        val deletions = json.indexOf("\"deletions\":")
        assertTrue(baselines > 0 && corrections > 0 && deletions > 0)
        assertTrue("corrections sorts after baselines", baselines < corrections)
        assertTrue("corrections sorts before deletions", corrections < deletions)
    }

    /**
     * A correction record carries exactly `record_id`, `suppressed_by` and `changed_at`, in
     * canonical key order and with no extra fields — asserted as the literal bytes, because a
     * parsed comparison would pass while key order and timestamp rendering diverged, which is
     * precisely what the cross-platform contract forbids.
     */
    @Test
    fun correctionRecordCarriesExactlyRecordIdSuppressedByAndChangedAt() {
        val json = render(
            isDelta = true,
            corrections = listOf(
                ExportSuppressionCorrection("01J8ZKA00000000000000000001", "01J8ZKB00000000000000000001", generatedAt),
            ),
        )
        val start = json.indexOf("\"corrections\":[")
        val end = json.indexOf("]", start)
        assertEquals(
            "\"corrections\":[{\"changed_at\":\"$generatedAtUtc\"," +
                "\"record_id\":\"01J8ZKA00000000000000000001\"," +
                "\"suppressed_by\":\"01J8ZKB00000000000000000001\"}]",
            json.substring(start, end + 1),
        )
    }
}
