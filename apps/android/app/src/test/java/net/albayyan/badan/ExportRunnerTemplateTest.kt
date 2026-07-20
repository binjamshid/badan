package net.albayyan.badan

import net.albayyan.badan.domain.ExportCursor
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.export.ExportRunner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-09/17 — the template-run range/cursor resolution and the incremental-delta inclusion test.
 *
 * Scope, stated honestly (the same caveat `ExportTemplateSystemTest` / `BackgroundSubstrateTest`
 * carry): this module has no `androidTest` source set and no Robolectric, so nothing here opens a
 * database and the full `runTemplate` loop — generation, delivery, the `ExportRun` ledger, the
 * cursor two-phase commit — is covered on iOS by `ExportRunnerTemplateTests`, which runs the
 * identical logic against a real SQLite file. What is covered here is the safety-critical half that
 * lives in pure functions: how a range rule becomes a run window, and the strictly-greater
 * ingested-axis boundary that keeps a delta from skipping or duplicating a row.
 */
class ExportRunnerTemplateTest {

    private val now = 1_783_000_000_000L
    private val dayMs = 86_400_000L

    private fun scope() = ExportScope.everything

    @Test
    fun lastNDaysResolvesABoundedMeasuredWindow() {
        val plan = ExportRunner.resolveRange(ExportRangeRule.LastNDays(7), scope(), null, now)
        assertEquals(now - 7 * dayMs, plan.scope.startDate)
        assertEquals(now, plan.scope.endDate)
        assertNull(plan.ingestedSince)
        assertFalse(plan.fellBackFromSinceLastRun)
    }

    @Test
    fun allTimeClearsTheWindowEntirely() {
        val plan = ExportRunner.resolveRange(ExportRangeRule.AllTime, scope(), null, now)
        assertNull(plan.scope.startDate)
        assertNull(plan.scope.endDate)
        assertNull(plan.ingestedSince)
        assertFalse(plan.fellBackFromSinceLastRun)
    }

    @Test
    fun fixedUsesTheScopeDatesVerbatim() {
        val pinned = ExportScope.everything.copy(startDate = 111L, endDate = 222L)
        val plan = ExportRunner.resolveRange(ExportRangeRule.Fixed, pinned, null, now)
        assertEquals(111L, plan.scope.startDate)
        assertEquals(222L, plan.scope.endDate)
        assertNull(plan.ingestedSince)
        assertFalse(plan.fellBackFromSinceLastRun)
    }

    @Test
    fun sinceLastRunWithCursorIsADeltaOnTheIngestedAxis() {
        val cursor = ExportCursor("T1", "D1", highWatermark = now - 5_000, updatedAt = now)
        val plan = ExportRunner.resolveRange(ExportRangeRule.SinceLastRun, scope(), cursor, now)
        // The measured window is cleared so a late-arriving row (measured before the watermark,
        // ingested after it) is not dropped by a measured-date filter.
        assertNull(plan.scope.startDate)
        assertNull(plan.scope.endDate)
        assertEquals(now - 5_000, plan.ingestedSince)
        assertEquals(now - 5_000, plan.cursorBefore)
        assertFalse(plan.fellBackFromSinceLastRun)
    }

    @Test
    fun sinceLastRunWithoutCursorFallsBackWithNoticeAndNoCheckpoint() {
        val plan = ExportRunner.resolveRange(ExportRangeRule.SinceLastRun, scope(), null, now)
        assertEquals(now - ExportRunner.CURSOR_MISSING_FALLBACK_DAYS * dayMs, plan.scope.startDate)
        assertEquals(now, plan.scope.endDate)
        assertNull(plan.ingestedSince) // not a delta — a measured-axis fallback window
        assertNull(plan.cursorBefore) // no ingested checkpoint is established from a measured window
        assertTrue(plan.fellBackFromSinceLastRun) // the caller surfaces this notice
    }

    @Test
    fun ingestedAfterIsStrictlyGreaterAndNullMeansIncludeEverything() {
        assertTrue("a null watermark includes everything (the plain export path)",
            ExportRunner.ingestedAfter(100, null))
        assertTrue(ExportRunner.ingestedAfter(101, 100))
        // The boundary row equals the watermark and is EXCLUDED, so the next run cannot duplicate
        // the last row the previous run already delivered.
        assertFalse(ExportRunner.ingestedAfter(100, 100))
        assertFalse(ExportRunner.ingestedAfter(99, 100))
    }
}
