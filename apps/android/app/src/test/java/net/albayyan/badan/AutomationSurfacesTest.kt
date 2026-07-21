package net.albayyan.badan

import net.albayyan.badan.domain.automation.AutomationCadence
import net.albayyan.badan.domain.automation.AutomationSchedule
import net.albayyan.badan.domain.automation.AutomationTier
import net.albayyan.badan.features.export.AutomationPresentation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-15 — the PURE automation-surface copy mapping (the wizard's honesty labels + the schedule
 * list's chips). This module's JVM test source set cannot open a database (as `ExportRunnerTemplateTest`
 * documents), so the DB-backed schedule CRUD is tested on iOS; here we pin the closed-vocabulary
 * mapping every Android surface renders — the §16 "never a raw token" rule and the scheduling-honesty
 * rule that "next run" is always estimate language.
 */
class AutomationSurfacesTest {

    private val now = 1_783_000_000_000L

    private fun schedule(
        tier: AutomationTier = AutomationTier.OPPORTUNISTIC_BACKGROUND,
        cadence: AutomationCadence = AutomationCadence.DAILY_BEST_EFFORT,
        enabled: Boolean = true,
        consecutiveFailures: Int = 0,
        nextExpectedWindow: Long? = null,
    ) = AutomationSchedule(
        id = "s",
        templateId = "t",
        tier = tier,
        desiredCadence = cadence,
        enabled = enabled,
        consecutiveFailures = consecutiveFailures,
        nextExpectedWindow = nextExpectedWindow,
        createdAt = now,
        updatedAt = now,
        originDeviceId = "test-device",
    )

    @Test
    fun everyTierAndCadenceHasBilingualCopyThatIsNeverARawToken() {
        for (tier in AutomationTier.entries) {
            for (label in listOf(
                AutomationPresentation.tierLabel(tier),
                AutomationPresentation.tierTitle(tier),
                AutomationPresentation.tierChip(tier),
            )) {
                assertTrue("$tier has empty en copy", label.en.isNotEmpty())
                assertTrue("$tier has empty ar copy", label.ar.isNotEmpty())
                assertFalse("$tier leaked its raw token", label.en == tier.code)
            }
        }
        for (cadence in AutomationCadence.entries) {
            for (label in listOf(
                AutomationPresentation.cadenceLabel(cadence),
                AutomationPresentation.cadenceHint(cadence),
            )) {
                assertTrue("$cadence has empty en copy", label.en.isNotEmpty())
                assertTrue("$cadence has empty ar copy", label.ar.isNotEmpty())
                assertFalse("$cadence leaked its raw token", label.en == cadence.code)
            }
        }
    }

    @Test
    fun noAutomationSurfaceStringPromisesAWallClockTimeOrGuarantee() {
        // The anti-HAE honesty rule (§13.7 / §16), broadened past the tier labels: NO rendered
        // automation string may promise a wall-clock appointment ("every day at", "each hour",
        // "exactly"), claim a "guaranteed" run, or leak the scheduler word "cron". Broadened three
        // ways from the old tier-only/en-only check — every surface (tiers, cadences, statuses, the
        // paused reason, and the next-run estimates), in BOTH languages, so a promise can't slip into
        // the Arabic copy alone or into a cadence/next-run string the old test never looked at.
        // English promises plus their Arabic equivalents — "مضمون" (guaranteed) and "كل يوم في"
        // (a daily wall-clock time), mirroring iOS AutomationSurfacesTests. Without the Arabic
        // tokens the loop below scans the .ar strings but can only ever match English, so an
        // Arabic promise leak would pass silently (the gap the Phase-2B recheck flagged).
        // lowercase() leaves Arabic unchanged, so contains() over `lower` still matches these.
        val banned = listOf("cron", "guaranteed", "every day at", "each hour", "exactly", "مضمون", "كل يوم في")
        val strings = buildList {
            for (tier in AutomationTier.entries) {
                for (l in listOf(
                    AutomationPresentation.tierLabel(tier),
                    AutomationPresentation.tierTitle(tier),
                    AutomationPresentation.tierChip(tier),
                )) { add(l.en); add(l.ar) }
            }
            for (cadence in AutomationCadence.entries) {
                for (l in listOf(
                    AutomationPresentation.cadenceLabel(cadence),
                    AutomationPresentation.cadenceHint(cadence),
                )) { add(l.en); add(l.ar) }
            }
            for (status in AutomationPresentation.StatusKind.entries) {
                val l = AutomationPresentation.statusLabel(status); add(l.en); add(l.ar)
            }
            AutomationPresentation.pausedReason("3").let { add(it.en); add(it.ar) }
            // Both the un-anchored fallback and the estimate that embeds a (caveated) wall-clock time:
            // neither may read as an appointment.
            for (kind in AutomationPresentation.NextWindow.entries) {
                for (dateText in listOf(null, "3:00 PM")) {
                    val l = AutomationPresentation.nextWindowLabel(kind, dateText); add(l.en); add(l.ar)
                }
            }
        }
        for (s in strings) {
            val lower = s.lowercase()
            for (b in banned) {
                assertFalse("an automation surface string promised '$b': \"$s\"", lower.contains(b))
            }
        }
    }

    @Test
    fun statusReflectsEnabledAndFailureBudget() {
        assertEquals(AutomationPresentation.StatusKind.ACTIVE, AutomationPresentation.status(schedule()))
        assertEquals(AutomationPresentation.StatusKind.OFF, AutomationPresentation.status(schedule(enabled = false)))
        assertEquals(
            AutomationPresentation.StatusKind.PAUSED,
            AutomationPresentation.status(schedule(consecutiveFailures = AutomationSchedule.FAILURE_BUDGET)),
        )
        for (status in AutomationPresentation.StatusKind.entries) {
            val label = AutomationPresentation.statusLabel(status)
            assertTrue(label.en.isNotEmpty())
            assertTrue(label.ar.isNotEmpty())
        }
        val paused = AutomationPresentation.pausedReason("3")
        assertTrue(paused.en.contains("3"))
        assertTrue(paused.ar.isNotEmpty())
    }

    @Test
    fun nextRunIsAlwaysEstimateLanguageNeverAWallClockPromise() {
        assertEquals(AutomationPresentation.NextWindow.ON_TAP, AutomationPresentation.nextWindow(schedule(tier = AutomationTier.MANUAL_ONLY)))
        assertEquals(AutomationPresentation.NextWindow.ON_TAP, AutomationPresentation.nextWindow(schedule(tier = AutomationTier.SHORTCUT_DRIVEN)))
        assertEquals(AutomationPresentation.NextWindow.WHEN_NEW_DATA, AutomationPresentation.nextWindow(schedule(cadence = AutomationCadence.ON_NEW_DATA)))
        assertEquals(
            AutomationPresentation.NextWindow.AROUND_ESTIMATE,
            AutomationPresentation.nextWindow(schedule(cadence = AutomationCadence.DAILY_BEST_EFFORT, nextExpectedWindow = now)),
        )
        assertEquals(
            AutomationPresentation.NextWindow.AS_BACKGROUND_ALLOWS,
            AutomationPresentation.nextWindow(schedule(cadence = AutomationCadence.DAILY_BEST_EFFORT, nextExpectedWindow = null)),
        )

        for (kind in AutomationPresentation.NextWindow.entries) {
            val label = AutomationPresentation.nextWindowLabel(kind, dateText = "3 PM")
            assertTrue(label.en.isNotEmpty())
            assertTrue(label.ar.isNotEmpty())
        }
        assertTrue(AutomationPresentation.nextWindowLabel(AutomationPresentation.NextWindow.AROUND_ESTIMATE, "3 PM").en.contains("3 PM"))
        val fallback = AutomationPresentation.nextWindowLabel(AutomationPresentation.NextWindow.AROUND_ESTIMATE, null)
        assertTrue(fallback.en.isNotEmpty())
        assertFalse(fallback.en.endsWith("around "))
    }
}
