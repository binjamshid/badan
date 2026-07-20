package net.albayyan.badan

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.domain.QuickExportPreset
import net.albayyan.badan.features.export.ExportOutcomeCopy
import net.albayyan.badan.features.export.ExportRange
import net.albayyan.badan.features.export.HealthChipStyle
import net.albayyan.badan.features.export.QuickRange
import net.albayyan.badan.features.export.builderRangeFor
import net.albayyan.badan.features.export.builderRangeRule
import net.albayyan.badan.features.export.endOfDayBound
import net.albayyan.badan.features.export.isCustomRangeInvalid
import net.albayyan.badan.features.export.quickExportPreset
import net.albayyan.badan.features.export.quickExportScope
import net.albayyan.badan.features.export.resolveTemplateRunScope
import net.albayyan.badan.features.export.startOfDayMillis
import net.albayyan.badan.features.export.triggerLabel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Compose export surfaces' pure decisions (EPIC-10/11/09/16). Same scope caveat as
 * `ExportTemplateSystemTest`: this module has no `androidTest`/Robolectric source set, so nothing
 * here renders a composable — what is covered is every choice that lives in a pure function the
 * screens delegate to: Quick Export's preset resolution and its structural exclusion, the advanced
 * builder's range math, the template run-scope resolution, and Export Health's plain-language
 * outcome mapping.
 */
class ExportSurfacesTest {

    private val now = 1_783_000_000_000L
    private val day = 86_400_000L
    private val deviceId = "test-device"

    // MARK: - Quick Export (EPIC-10)

    @Test fun quickRangeAndFormatResolveToTheMatchingSeededPreset() {
        assertEquals(QuickExportPreset.LAST_7_CSV, quickExportPreset(QuickRange.LAST_7, ExportFormat.CSV))
        assertEquals(QuickExportPreset.LAST_7_JSON, quickExportPreset(QuickRange.LAST_7, ExportFormat.JSON))
        assertEquals(QuickExportPreset.LAST_30_CSV, quickExportPreset(QuickRange.LAST_30, ExportFormat.CSV))
        assertEquals(QuickExportPreset.LAST_30_JSON, quickExportPreset(QuickRange.LAST_30, ExportFormat.JSON))
        assertEquals(QuickExportPreset.ALL_TIME_CSV, quickExportPreset(QuickRange.ALL, ExportFormat.CSV))
        assertEquals(QuickExportPreset.ALL_TIME_JSON, quickExportPreset(QuickRange.ALL, ExportFormat.JSON))
    }

    /**
     * §12 EPIC-10: a quick export can never widen to sensitive data or routes, and there is no
     * parameter through which [quickExportScope] could. Every preset resolves to the same narrow
     * scope regardless of range.
     */
    @Test fun everyQuickExportScopeExcludesSensitiveAndSuppressed() {
        for (range in QuickRange.entries) {
            for (format in ExportFormat.entries) {
                val preset = quickExportPreset(range, format)
                val scope = quickExportScope(preset, AppLanguage.EN, now, deviceId)
                assertFalse("quick export must never include sensitive", scope.includeSensitive)
                assertFalse("quick export must never include suppressed", scope.includeSuppressed)
                // Raw data is never withheld and the derived values make the file legible.
                assertTrue(scope.includeRaw)
                assertTrue(scope.includeDerived)
            }
        }
    }

    @Test fun quickExportFreezesTheRollingWindowAndClearsItForAllTime() {
        val last7 = quickExportScope(QuickExportPreset.LAST_7_CSV, AppLanguage.EN, now, deviceId)
        assertEquals(now - 7 * day, last7.startDate)
        assertNull(last7.endDate)

        val all = quickExportScope(QuickExportPreset.ALL_TIME_JSON, AppLanguage.AR, now, deviceId)
        assertNull("all time leaves the window open", all.startDate)
        assertEquals(AppLanguage.AR, all.language)
    }

    // MARK: - Advanced builder range math (EPIC-11, mirror iOS DATA-04)

    @Test fun customRangeIsInvalidOnlyWhenStartDayIsAfterEndDay() {
        assertTrue(isCustomRangeInvalid(startMillis = now, endMillis = now - day))
        assertFalse(isCustomRangeInvalid(startMillis = now - day, endMillis = now))
        // Same calendar day, different times, is valid — start-of-day equality is not "after".
        assertFalse(isCustomRangeInvalid(startMillis = now, endMillis = now + 1))
    }

    @Test fun endOfDayBoundIsTheNextMidnightSoTheFinalDayIsIncluded() {
        val startOfDay = startOfDayMillis(now)
        val bound = endOfDayBound(now)
        assertTrue("bound is strictly after the day it bounds", bound > now)
        assertEquals(day, bound - startOfDay)
    }

    @Test fun builderRangeRuleRoundTripsThroughTheEditPrefill() {
        // The four builder options must survive save → reopen without drifting.
        for (range in listOf(ExportRange.LAST30, ExportRange.LAST90, ExportRange.ALL)) {
            val rule = builderRangeRule(range)
            assertEquals(range, builderRangeFor(rule, ExportScope()))
        }
        // Custom saves as Fixed; it reads back as CUSTOM only when the scope actually pins dates.
        assertEquals(ExportRangeRule.Fixed, builderRangeRule(ExportRange.CUSTOM))
        assertEquals(
            ExportRange.CUSTOM,
            builderRangeFor(ExportRangeRule.Fixed, ExportScope(startDate = now - day, endDate = now)),
        )
        // A delta rule can't be represented by the builder — it must widen to ALL, never narrow.
        assertEquals(ExportRange.ALL, builderRangeFor(ExportRangeRule.SinceLastRun, ExportScope()))
    }

    // MARK: - Template run-scope resolution (EPIC-09)

    @Test fun templateRunScopeAppliesTheRangeRuleAgainstTheClock() {
        val base = ExportScope(startDate = 1L, endDate = 2L, language = AppLanguage.EN)

        val lastN = resolveTemplateRunScope(template(ExportRangeRule.LastNDays(14)), base, now)
        assertEquals(now - 14 * day, lastN.startDate)
        assertNull(lastN.endDate)

        val all = resolveTemplateRunScope(template(ExportRangeRule.AllTime), base, now)
        assertNull(all.startDate)
        assertNull(all.endDate)

        val fixed = resolveTemplateRunScope(template(ExportRangeRule.Fixed), base, now)
        assertEquals(1L, fixed.startDate)
        assertEquals(2L, fixed.endDate)

        // sinceLastRun with no cursor here must fall back to a rolling window (§12), never all-time.
        val delta = resolveTemplateRunScope(template(ExportRangeRule.SinceLastRun), base, now)
        assertEquals(now - 30 * day, delta.startDate)
    }

    // MARK: - Export Health plain-language mapping (EPIC-16)

    @Test fun everyOutcomeHasABilingualLabelAndAStyle() {
        for (outcome in ExportOutcome.entries) {
            val label = ExportOutcomeCopy.label(outcome)
            assertTrue("${outcome.name} needs English copy", label.en.isNotBlank())
            assertTrue("${outcome.name} needs Arabic copy", label.ar.isNotBlank())
        }
    }

    @Test fun onlyRealFailuresStyleAsProblemsAndSuccessAsSuccess() {
        assertEquals(HealthChipStyle.SUCCESS, ExportOutcomeCopy.style(ExportOutcome.SUCCESS))
        for (failure in listOf(ExportOutcome.FAILED_GENERATION, ExportOutcome.FAILED_DELIVERY, ExportOutcome.PARTIAL)) {
            assertEquals("${failure.name} must read as a problem", HealthChipStyle.PROBLEM, ExportOutcomeCopy.style(failure))
        }
        // Locked / no-data / throttled / cancelled are ordinary — never styled as a problem.
        for (ordinary in listOf(
            ExportOutcome.SKIPPED_LOCKED, ExportOutcome.SKIPPED_NO_DATA,
            ExportOutcome.THROTTLED, ExportOutcome.CANCELLED,
        )) {
            assertEquals("${ordinary.name} must read as neutral", HealthChipStyle.NEUTRAL, ExportOutcomeCopy.style(ordinary))
        }
    }

    @Test fun everyTriggerHasABilingualLabel() {
        for (trigger in ExportTrigger.entries) {
            val label = triggerLabel(trigger)
            assertTrue("${trigger.name} needs English copy", label.en.isNotBlank())
            assertTrue("${trigger.name} needs Arabic copy", label.ar.isNotBlank())
        }
    }

    private fun template(rule: ExportRangeRule): ExportTemplate = ExportTemplate(
        id = "T1", name = "Weekly", scope = ExportScope(), rangeRule = rule,
        format = ExportFormat.CSV, createdAt = now, updatedAt = now, originDeviceId = deviceId,
    )
}
