package net.albayyan.badan

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.designsystem.components.CalibrationProgress
import net.albayyan.badan.designsystem.components.calibrationDayLabel
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.BaselineMethod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-23/§16 — the pure calibration-progress model behind the cold-start "Day 9 of 14" state. The
 * day count, fraction and label must not depend on the view. Mirror of the iOS `CalibrationStateTests`.
 */
class CalibrationStateTest {

    private fun baseline(nPoints: Int, windowDays: Int) = Baseline(
        id = "b", metricId = "heart.rhr", windowDays = windowDays, method = BaselineMethod.MEDIAN_MAD,
        center = 60.0, spread = 2.0, bandLow = 55.0, bandHigh = 65.0, nPoints = nPoints,
        provisional = nPoints < windowDays, algorithmVersion = "baseline.rolling_median_mad@2.0.0",
        validFrom = 0L, computedAt = 0L, unit = "bpm",
    )

    @Test
    fun mid_calibration_reports_the_day_and_fraction() {
        val p = CalibrationProgress(nPoints = 9, windowDays = 14)
        assertEquals(9, p.dayOf)
        assertEquals(9f / 14f, p.fraction, 1e-6f)
        assertFalse(p.isComplete)
    }

    @Test
    fun the_day_count_is_capped_at_the_window() {
        val p = CalibrationProgress(nPoints = 21, windowDays = 14)
        assertEquals("copy must read Day 14 of 14, never Day 21 of 14", 14, p.dayOf)
        assertEquals(1f, p.fraction, 1e-6f)
        assertTrue(p.isComplete)
    }

    @Test
    fun day_one_is_zero_not_an_error() {
        val p = CalibrationProgress(nPoints = 0, windowDays = 14)
        assertEquals(0, p.dayOf)
        assertEquals(0f, p.fraction, 1e-6f)
        assertFalse(p.isComplete)
    }

    @Test
    fun a_degenerate_window_never_divides_by_zero() {
        val p = CalibrationProgress(nPoints = 5, windowDays = 0)
        assertEquals(0, p.dayOf)
        assertEquals(0f, p.fraction, 1e-6f)
        assertFalse(p.isComplete)
    }

    @Test
    fun a_null_baseline_reads_as_zero_of_the_fallback_window() {
        val p = CalibrationProgress.from(baseline = null, windowDaysFallback = 14)
        assertEquals(0, p.nPoints)
        assertEquals(14, p.windowDays)
    }

    @Test
    fun a_baseline_carries_its_own_points_and_window() {
        val p = CalibrationProgress.from(baseline(nPoints = 5, windowDays = 28), windowDaysFallback = 14)
        assertEquals(5, p.nPoints)
        assertEquals(28, p.windowDays)
    }

    @Test
    fun label_is_bilingual() {
        val p = CalibrationProgress(nPoints = 9, windowDays = 14)
        assertEquals("Day 9 of 14", calibrationDayLabel(p, AppLanguage.EN, arabicDigits = false))
        assertEquals("اليوم 9 من 14", calibrationDayLabel(p, AppLanguage.AR, arabicDigits = false))
    }
}
