package net.albayyan.badan

import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.automation.AutomationBudget
import net.albayyan.badan.domain.automation.AutomationCadence
import net.albayyan.badan.domain.automation.AutomationDueEvaluator
import net.albayyan.badan.domain.automation.AutomationDueVerdict
import net.albayyan.badan.domain.automation.AutomationOutcomeKind
import net.albayyan.badan.domain.automation.AutomationSchedule
import net.albayyan.badan.domain.automation.AutomationSkipReason
import net.albayyan.badan.domain.automation.AutomationTier
import net.albayyan.badan.domain.automation.QuietHours
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * EPIC-15 — the PURE scheduling decisions (the due-gate and the failure budget), which are the
 * cross-platform contract iOS's DB-backed `AutomationEngineTests` share decision-for-decision. This
 * module's JVM test source set cannot open a database, so — exactly as `ExportRunnerTemplateTest`
 * documents — the full engine loop (runs through the real runner, records an `ExportRun`) is tested
 * on iOS; here we pin the decisions both engines are built on.
 */
class AutomationEngineTest {

    private val utc = ZoneId.of("UTC")
    private val now = 1_783_000_000_000L // 2026-07-05T13:46:40Z (minute-of-day 826)

    private fun schedule(
        tier: AutomationTier = AutomationTier.OPPORTUNISTIC_BACKGROUND,
        cadence: AutomationCadence = AutomationCadence.DAILY_BEST_EFFORT,
        quietHours: QuietHours? = null,
        enabled: Boolean = true,
        consecutiveFailures: Int = 0,
        lastSuccessAt: Long? = null,
    ) = AutomationSchedule(
        id = "S", templateId = "T", tier = tier, desiredCadence = cadence, quietHours = quietHours,
        enabled = enabled, consecutiveFailures = consecutiveFailures, lastSuccessAt = lastSuccessAt,
        createdAt = now, updatedAt = now, originDeviceId = "dev",
    )

    private fun verdict(s: AutomationSchedule, hasNewData: Boolean = false) =
        AutomationDueEvaluator.verdict(s, now, hasNewData, utc)

    // -- Due gates --

    @Test fun neverSucceededTimeCadenceIsDue() {
        assertEquals(AutomationDueVerdict.Due, verdict(schedule()))
    }

    @Test fun disabledPausedAndWrongTierAreSkipped() {
        assertEquals(AutomationDueVerdict.Skip(AutomationSkipReason.DISABLED), verdict(schedule(enabled = false)))
        assertEquals(AutomationDueVerdict.Skip(AutomationSkipReason.PAUSED), verdict(schedule(consecutiveFailures = 3)))
        assertEquals(
            AutomationDueVerdict.Skip(AutomationSkipReason.NOT_BACKGROUND_TIER),
            verdict(schedule(tier = AutomationTier.SHORTCUT_DRIVEN)),
        )
    }

    @Test fun timeCadenceRespectsElapsedInterval() {
        // 1h ago is not enough for a daily cadence.
        assertEquals(
            AutomationDueVerdict.Skip(AutomationSkipReason.CADENCE_NOT_ELAPSED),
            verdict(schedule(lastSuccessAt = now - 3_600_000L)),
        )
        // >1 day ago is due.
        assertEquals(AutomationDueVerdict.Due, verdict(schedule(lastSuccessAt = now - 90_000_000L)))
    }

    @Test fun hourlySlackAllowsASlightlyEarlyWake() {
        // 58 minutes since last success: under an hour, but within the 5-minute slack, so due.
        val s = schedule(cadence = AutomationCadence.HOURLY_BEST_EFFORT, lastSuccessAt = now - 58 * 60_000L)
        assertEquals(AutomationDueVerdict.Due, verdict(s))
        // 50 minutes: outside the slack, not yet due.
        val early = schedule(cadence = AutomationCadence.HOURLY_BEST_EFFORT, lastSuccessAt = now - 50 * 60_000L)
        assertEquals(AutomationDueVerdict.Skip(AutomationSkipReason.CADENCE_NOT_ELAPSED), verdict(early))
    }

    @Test fun onNewDataIsGatedOnData() {
        val s = schedule(cadence = AutomationCadence.ON_NEW_DATA)
        assertEquals(AutomationDueVerdict.Skip(AutomationSkipReason.NO_NEW_DATA), verdict(s, hasNewData = false))
        assertEquals(AutomationDueVerdict.Due, verdict(s, hasNewData = true))
    }

    @Test fun quietHoursIsAHardGate() {
        // now is 13:46:40 UTC → inside a 13:00-14:00 window.
        val s = schedule(quietHours = QuietHours.of(13, 0, 14, 0))
        assertEquals(AutomationDueVerdict.Skip(AutomationSkipReason.QUIET_HOURS), verdict(s))
        // Outside the window, the same schedule is due.
        val awake = schedule(quietHours = QuietHours.of(22, 0, 23, 0))
        assertEquals(AutomationDueVerdict.Due, verdict(awake))
    }

    // -- Failure budget --

    @Test fun thirdFailurePausesAndFlagsTheTransition() {
        val s = schedule(consecutiveFailures = 2)
        val update = AutomationBudget.applyOutcome(ExportOutcome.FAILED_DELIVERY, s, now)
        assertEquals(AutomationOutcomeKind.FAILURE, update.kind)
        assertEquals(3, update.consecutiveFailures)
        assertTrue("crossing the budget flags the pause transition", update.didJustPause)
    }

    @Test fun anAlreadyPausedScheduleDoesNotReflagOnFurtherFailure() {
        val s = schedule(consecutiveFailures = 3)
        val update = AutomationBudget.applyOutcome(ExportOutcome.FAILED_GENERATION, s, now)
        assertEquals(4, update.consecutiveFailures)
        assertFalse("already paused — no second notification", update.didJustPause)
    }

    @Test fun successAndSkippedNoDataResetTheCounter() {
        val s = schedule(consecutiveFailures = 2)
        for (outcome in listOf(ExportOutcome.SUCCESS, ExportOutcome.SKIPPED_NO_DATA)) {
            val update = AutomationBudget.applyOutcome(outcome, s, now)
            assertEquals(AutomationOutcomeKind.SUCCESS, update.kind)
            assertEquals(0, update.consecutiveFailures)
            assertEquals(now, update.lastSuccessAt)
        }
    }

    @Test fun throttledAndLockedAreNeutral() {
        val s = schedule(consecutiveFailures = 1)
        for (outcome in listOf(ExportOutcome.THROTTLED, ExportOutcome.SKIPPED_LOCKED, ExportOutcome.CANCELLED)) {
            val update = AutomationBudget.applyOutcome(outcome, s, now)
            assertEquals(AutomationOutcomeKind.NEUTRAL, update.kind)
            assertEquals(1, update.consecutiveFailures)
            assertNull(update.lastSuccessAt)
        }
    }

    // -- QuietHours + cadence value types --

    @Test fun quietHoursStorageRoundTripsAndWraps() {
        val wrap = QuietHours.of(22, 0, 7, 0)
        assertEquals("22:00-07:00", wrap.storageString)
        assertEquals(wrap, QuietHours.fromStorage("22:00-07:00"))
        assertTrue(wrap.contains(millisAt(23, 0), utc))
        assertTrue(wrap.contains(millisAt(3, 0), utc))
        assertFalse(wrap.contains(millisAt(12, 0), utc))
        // A malformed or zero-length window is inert, never a silent all-day suppressor.
        assertNull(QuietHours.fromStorage("notatime"))
        assertFalse(QuietHours.of(9, 0, 9, 0).contains(millisAt(9, 0), utc))
    }

    @Test fun cadenceIntervalsAndEstimate() {
        assertEquals(3_600_000L, AutomationCadence.HOURLY_BEST_EFFORT.minimumIntervalMillis)
        assertEquals(86_400_000L, AutomationCadence.DAILY_BEST_EFFORT.minimumIntervalMillis)
        assertEquals(604_800_000L, AutomationCadence.WEEKLY_BEST_EFFORT.minimumIntervalMillis)
        assertEquals(0L, AutomationCadence.ON_NEW_DATA.minimumIntervalMillis)
        assertEquals(now + 86_400_000L, AutomationCadence.DAILY_BEST_EFFORT.estimatedNextWindow(now))
        // onNewData has no time to estimate; a never-run cadence has nothing to anchor from.
        assertNull(AutomationCadence.ON_NEW_DATA.estimatedNextWindow(now))
        assertNull(AutomationCadence.DAILY_BEST_EFFORT.estimatedNextWindow(null))
    }

    @Test fun tierAndCadenceCodesMatchIosRawValues() {
        // The stored strings must equal iOS's `rawValue`s for a config backup to be portable.
        assertEquals("opportunisticBackground", AutomationTier.OPPORTUNISTIC_BACKGROUND.code)
        assertEquals("manualOnly", AutomationTier.MANUAL_ONLY.code)
        assertEquals("onNewData", AutomationCadence.ON_NEW_DATA.code)
        assertEquals("dailyBestEffort", AutomationCadence.DAILY_BEST_EFFORT.code)
        // An unparseable tier degrades to the most conservative (never auto-run) tier.
        assertEquals(AutomationTier.MANUAL_ONLY, AutomationTier.fromCode("bogus"))
    }

    private fun millisAt(hour: Int, minute: Int): Long =
        Instant.parse("2026-01-01T%02d:%02d:00Z".format(hour, minute)).toEpochMilli()
}
