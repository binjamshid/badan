package net.albayyan.badan

import kotlinx.coroutines.runBlocking
import net.albayyan.badan.platform.background.IncrementalClassification
import net.albayyan.badan.platform.health.BackfillWindow
import net.albayyan.badan.platform.health.HealthPage
import net.albayyan.badan.platform.health.WindowedTypeRead
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The changes-cursor safety rule, pinned (audit finding #3).
 *
 * The bug this file exists for: `HealthConnectAdapter.readType` staged a fresh changes token before
 * starting a full windowed read and kept it no matter what happened, while the page loop underneath
 * treated "could not read this page" and "there are no more pages" as the same thing and quietly
 * `break`ed. A provider hiccup on page two therefore committed a cursor positioned *after* records
 * that were never ingested, recorded the whole window as covered, and finished the run as COMPLETED.
 * Health Connect's changes feed cannot be resumed from before its most recent token, so that was
 * permanent data loss until the token expired roughly thirty days later — with nothing anywhere
 * saying so.
 *
 * Why the tests are shaped like this: `HealthConnectAdapter` needs a `Context`, an installed
 * provider and a live `HealthConnectClient`, and is not JVM testable — the same constraint that
 * `HcTypeMap` and `StopReasonMapping` were carved out of. `WindowedTypeRead` is the carve-out for
 * the page loop, and it holds the whole rule: nothing advances unless the last page was read.
 */
class HealthConnectCursorTest {

    /**
     * A page source that serves [pages] in order and then fails, so a read is forced to end
     * mid-pagination exactly the way an exhausted retry budget in `readPageWithRetry` ends one
     * (it returns null for a page it could not read).
     */
    private class FailingPageSource(private val pages: List<List<String>>) {
        var pagesServed = 0
            private set

        fun page(pageToken: String?): HealthPage<String>? {
            val index = pageToken?.toInt() ?: 0
            if (index >= pages.size) return null
            pagesServed += 1
            // A next-page token is always handed back: this source never reports the end of the
            // window, so the only way the loop can terminate is the failure on the page after the
            // last one it can serve. That is what makes "did not finish" unambiguous here.
            return HealthPage(pages[index], (index + 1).toString())
        }
    }

    /** Records what a read committed, standing in for `pendingTokens` and `readWindows`. */
    private class CommitSpy {
        val stagedTokens = mutableMapOf<String, String>()
        var coverageClaimed: Boolean? = null
        val emitted = mutableListOf<String>()

        fun read(source: FailingPageSource, platformType: String = "StepsRecord") =
            WindowedTypeRead<String>(
                fetchPage = { source.page(it) },
                emit = { emitted.add(it) },
                stageToken = { stagedTokens[platformType] = it },
                claimCoverage = { coverageClaimed = it },
            )
    }

    // MARK: - The regression

    /**
     * The finding, stated as a test: a read that fails on page two must leave the stored cursor
     * exactly as it was and must not claim the window.
     */
    @Test fun aReadThatFailsOnPageTwoStagesNoTokenAndClaimsNoCoverage() {
        val spy = CommitSpy()
        // A token is already on disk from a previous sync. Modelled as the map's starting state,
        // because "unchanged" is the assertion and an empty map could not tell an untouched cursor
        // apart from one that was cleared.
        spy.stagedTokens["StepsRecord"] = "cursor-from-last-sync"
        val source = FailingPageSource(listOf(listOf("a", "b")))

        val complete = runBlocking { spy.read(source).run(freshToken = "cursor-minted-this-sync") }

        assertFalse("a read that could not finish must not report success", complete)
        assertEquals(
            "the fresh cursor must not be staged over the stored one — staging it is the data loss",
            "cursor-from-last-sync",
            spy.stagedTokens["StepsRecord"],
        )
        assertEquals(
            "a window that was only partly read must not be recorded as covered",
            false,
            spy.coverageClaimed,
        )
    }

    /**
     * Page one's records are still handed to the pipeline. This is the deliberate divergence from
     * iOS's `runAnchoredQuery`, which drops the whole result on error: `emit` streams so peak memory
     * is one page rather than the entire result set (the plan's 100k-record criterion), and
     * buffering to make the read all-or-nothing would undo that. It is safe only because the cursor
     * did not move — the assertion above — so the next sync re-reads the same window and every write
     * is idempotent by (metric, external_id, source_id).
     */
    @Test fun recordsReadBeforeTheFailureAreStillEmitted() {
        val spy = CommitSpy()
        val source = FailingPageSource(listOf(listOf("a", "b"), listOf("c")))

        runBlocking { spy.read(source).run(freshToken = "fresh") }

        assertEquals(listOf("a", "b", "c"), spy.emitted)
        assertTrue("staging a token here would strand exactly these records", spy.stagedTokens.isEmpty())
    }

    /**
     * The failure must be terminal, not a skipped page. Continuing past an unreadable page would
     * leave a hole in the middle of the window while every page after it arrived normally — the
     * worst shape of all, because the result looks complete.
     */
    @Test fun aFailedPageStopsTheReadRatherThanSkippingIt() {
        val spy = CommitSpy()
        var attempts = 0
        // Page two is unreadable; page three is fine. Only a loop that resumes past a failure could
        // ever reach "c", so its absence is the assertion.
        val read = WindowedTypeRead<String>(
            fetchPage = {
                attempts += 1
                when (attempts) {
                    1 -> HealthPage(listOf("a"), "2")
                    2 -> null
                    else -> HealthPage(listOf("c"), null)
                }
            },
            emit = { spy.emitted.add(it) },
            stageToken = { spy.stagedTokens["StepsRecord"] = it },
            claimCoverage = { spy.coverageClaimed = it },
        )

        assertFalse(runBlocking { read.run(freshToken = "fresh") })

        assertEquals("the loop must not resume past the page it could not read", 2, attempts)
        assertEquals(listOf("a"), spy.emitted)
        assertEquals(false, spy.coverageClaimed)
    }

    // MARK: - The path that must keep working

    /** A read that reaches the last page is exactly when the cursor may advance. */
    @Test fun aCompleteReadStagesTheTokenAndClaimsCoverage() {
        val spy = CommitSpy()
        var served = 0
        val read = WindowedTypeRead<String>(
            fetchPage = {
                served += 1
                if (served == 1) HealthPage(listOf("a", "b"), "next") else HealthPage(listOf("c"), null)
            },
            emit = { spy.emitted.add(it) },
            stageToken = { spy.stagedTokens["StepsRecord"] = it },
            claimCoverage = { spy.coverageClaimed = it },
        )

        val complete = runBlocking { read.run(freshToken = "fresh") }

        assertTrue(complete)
        assertEquals("fresh", spy.stagedTokens["StepsRecord"])
        assertEquals(true, spy.coverageClaimed)
        assertEquals(listOf("a", "b", "c"), spy.emitted)
    }

    /**
     * With no anchor store wired (`HealthConnectAdapter`'s `anchors` is nullable and defaults to
     * null for preview/permission-check construction sites) there is no token to stage, but the
     * window was still genuinely read and must still be reported.
     */
    @Test fun aCompleteReadWithNoTokenStillClaimsCoverage() {
        val spy = CommitSpy()
        val read = WindowedTypeRead<String>(
            fetchPage = { HealthPage(listOf("a"), null) },
            emit = { spy.emitted.add(it) },
            stageToken = { spy.stagedTokens["StepsRecord"] = it },
            claimCoverage = { spy.coverageClaimed = it },
        )

        assertTrue(runBlocking { read.run(freshToken = null) })
        assertTrue(spy.stagedTokens.isEmpty())
        assertEquals(true, spy.coverageClaimed)
    }

    /** An empty window is a complete read of nothing, not a failure. */
    @Test fun anEmptyWindowIsCompleteNotFailed() {
        val spy = CommitSpy()
        val read = WindowedTypeRead<String>(
            fetchPage = { HealthPage(emptyList<String>(), null) },
            emit = { spy.emitted.add(it) },
            stageToken = { spy.stagedTokens["StepsRecord"] = it },
            claimCoverage = { spy.coverageClaimed = it },
        )

        assertTrue(runBlocking { read.run(freshToken = "fresh") })
        assertEquals("fresh", spy.stagedTokens["StepsRecord"])
        assertEquals(true, spy.coverageClaimed)
    }

    // MARK: - Diagnostics honesty (audit finding #4)

    private fun window(platformType: String, incremental: Boolean) = BackfillWindow(
        platformType = platformType,
        requestedStart = 0L,
        achievableStart = 0L,
        end = 1L,
        incremental = incremental,
    )

    /**
     * `BackgroundWorkDone.incremental` was never assigned anywhere in the tree, so every Android
     * background run reported `incremental = false` — Diagnostics stated as fact that every sync was
     * a full-window read when, after the first one, essentially none are.
     */
    @Test fun aRunWhereEveryTypeUsedItsTokenIsReportedIncremental() {
        assertTrue(
            IncrementalClassification.wasIncremental(
                listOf(window("StepsRecord", true), window("HeartRateRecord", true)),
            ),
        )
    }

    /**
     * One boolean cannot describe a run where some types resumed from a token and others fell back
     * to a windowed re-read. Of the two available lies the conservative one is better: reporting a
     * 30-day re-walk as "incremental" would make it look cheap in exactly the diagnostics someone
     * opens to explain a battery complaint.
     */
    @Test fun aMixedRunIsNotReportedIncremental() {
        assertFalse(
            IncrementalClassification.wasIncremental(
                listOf(window("StepsRecord", true), window("HeartRateRecord", false)),
            ),
        )
    }

    /** A run that covered no types measured nothing, so it cannot claim to have been incremental. */
    @Test fun aRunThatCoveredNothingIsNotIncrementalByVacuity() {
        assertFalse(IncrementalClassification.wasIncremental(emptyList()))
    }
}
