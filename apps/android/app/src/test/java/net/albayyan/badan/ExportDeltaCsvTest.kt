package net.albayyan.badan

import net.albayyan.badan.domain.ExportSuppressionCorrection
import net.albayyan.badan.domain.ExportTombstone
import net.albayyan.badan.export.ExportDeltaCsvWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-17 (§22.6) — the CSV delta's two reconciliation tables, at the WRITER level.
 *
 * Why these exist at all: the delta reconciliation queries used to run only for JSON, while the
 * cursor advance is format-blind. A CSV `sinceLastRun` template therefore emitted no removals, no
 * corrections, and still closed its window — so a store fed by those files kept rows BADAN had
 * deleted, with nothing saying so. `deletions.csv` / `corrections.csv` are the CSV projection of the
 * bundle's `deletions[]` / `corrections[]`, and these tests pin the shape and the ORDER, because
 * order is the half a parsed comparison would let drift.
 *
 * Scope, stated honestly (the same caveat `ExportDeltaBundleTest` carries): this module has no
 * `androidTest` source set and no Robolectric, so nothing here opens a database. The DB-backed half
 * — gathering tombstones and dedup flips out of the store, writing the two files into a real delta
 * run and checksumming them into the manifest — is covered on iOS by `ExportRunnerTemplateTests`
 * against a real SQLite file. What is covered here is the serialization contract both platforms must
 * agree on.
 */
class ExportDeltaCsvTest {

    private val writer = ExportDeltaCsvWriter()

    // The exact §22.1 renderings of the instants used below (numeric offset, never "Z").
    private val t1 = 1_783_000_000_000L
    private val t1Utc = "2026-07-02T13:46:40+00:00"
    private val t2 = 1_783_500_000_000L
    private val t2Utc = "2026-07-08T08:40:00+00:00"

    private fun lines(csv: String) = csv.split("\r\n").filter { it.isNotEmpty() }

    // ===== deletions.csv =====

    @Test
    fun deletionsCarryRecordIdEntityAndDeletedAtInTheRowsOwnTimezone() {
        val csv = writer.deletionsCsv(
            listOf(ExportTombstone("01J8ZKB00000000000000000001", "raw_sample", t1, "Asia/Dubai")),
        )
        val rows = lines(csv)
        assertEquals("record_id,entity,deleted_at", rows[0])
        // Dubai is +04:00 — the offset is CARRIED, never normalized to UTC, exactly as the bundle
        // renders the same tombstone.
        assertEquals("01J8ZKB00000000000000000001,raw_sample,2026-07-02T17:46:40+04:00", rows[1])
    }

    /**
     * Ordering is `ExportTombstone.exportSorted`, the same comparator the JSON writer uses, so the
     * two formats list the same removals in the same sequence regardless of gather order.
     */
    @Test
    fun deletionsAreOrderedByRecordIdRegardlessOfInputOrder() {
        val csv = writer.deletionsCsv(
            listOf(
                ExportTombstone("01J8ZKC00000000000000000001", "session", t2, "UTC"),
                ExportTombstone("01J8ZKA00000000000000000001", "raw_sample", t1, "UTC"),
                ExportTombstone("01J8ZKB00000000000000000001", "interval_record", t1, "UTC"),
            ),
        )
        val ids = lines(csv).drop(1).map { it.substringBefore(",") }
        assertEquals(
            listOf(
                "01J8ZKA00000000000000000001",
                "01J8ZKB00000000000000000001",
                "01J8ZKC00000000000000000001",
            ),
            ids,
        )
    }

    /**
     * A header-only file is an affirmative "nothing was removed", not an empty artifact. The CSV
     * manifest carries no `is_delta` flag, so the file's PRESENCE is what marks a delta — and a
     * consumer must be able to tell "no removals" from "this exporter never reports removals".
     */
    @Test
    fun anEmptyDeletionsTableIsStillAWellFormedSelfDescribingFile() {
        val csv = writer.deletionsCsv(emptyList())
        assertEquals("record_id,entity,deleted_at\r\n", csv)
        assertEquals(1, lines(csv).size)
    }

    // ===== corrections.csv =====

    @Test
    fun correctionsCarryRecordIdSuppressedByAndChangedAtInUtc() {
        val csv = writer.correctionsCsv(
            listOf(
                ExportSuppressionCorrection(
                    "01J8ZKA00000000000000000001", "01J8ZKWINNER0000000000001", t1,
                ),
            ),
        )
        val rows = lines(csv)
        assertEquals("record_id,suppressed_by,changed_at", rows[0])
        assertEquals("01J8ZKA00000000000000000001,01J8ZKWINNER0000000000001,$t1Utc", rows[1])
    }

    /**
     * A CLEARED suppression writes an empty `suppressed_by` cell — the record wins again. CSV has no
     * null and the column is a record id, so empty can only mean "no longer suppressed"; the JSON
     * bundle says the same thing as an explicit `null`.
     */
    @Test
    fun aClearedSuppressionWritesAnEmptyCellRatherThanOmittingTheRow() {
        val csv = writer.correctionsCsv(
            listOf(ExportSuppressionCorrection("01J8ZKA00000000000000000001", null, t2)),
        )
        assertEquals("01J8ZKA00000000000000000001,,$t2Utc", lines(csv)[1])
    }

    /**
     * One record CAN flip twice inside a single delta window (suppressed by A, then by B once a
     * source-priority change re-ran dedup). The order must be the order the flips happened in, or a
     * consumer applying the rows in order ends up holding the intermediate verdict as final — the
     * same total order `ExportSuppressionCorrection.exportSorted` gives the JSON array.
     */
    @Test
    fun repeatedFlipsForOneRecordAreOrderedByChangedAt() {
        val csv = writer.correctionsCsv(
            listOf(
                // Supplied newest-first: the writer, not the caller, owns the order.
                ExportSuppressionCorrection("01J8ZKA00000000000000000001", "01J8ZKWINNERB00000000001", t2),
                ExportSuppressionCorrection("01J8ZKA00000000000000000001", "01J8ZKWINNERA00000000001", t1),
            ),
        )
        assertEquals(
            listOf(
                "01J8ZKA00000000000000000001,01J8ZKWINNERA00000000001,$t1Utc",
                "01J8ZKA00000000000000000001,01J8ZKWINNERB00000000001,$t2Utc",
            ),
            lines(csv).drop(1),
        )
    }

    @Test
    fun anEmptyCorrectionsTableIsStillAWellFormedSelfDescribingFile() {
        assertEquals("record_id,suppressed_by,changed_at\r\n", writer.correctionsCsv(emptyList()))
    }

    // ===== The file set =====

    @Test
    fun bothFilesAreAlwaysProducedTogether() {
        val files = writer.files(emptyList(), emptyList())
        assertEquals(setOf("deletions.csv", "corrections.csv"), files.keys)
        assertTrue(files.values.all { it.endsWith("\r\n") })
    }
}
