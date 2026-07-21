package net.albayyan.badan

import net.albayyan.badan.domain.derivation.SleepSpec
import net.albayyan.badan.features.metricdetail.needRangeDisplay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-24 — the surface's reconstruction of the published sleep-need RANGE from the stored centre +
 * confidence. It must reproduce the engine's band (no fake-exact minutes, plan §4 principle 9), widen
 * as confidence falls, and never claim a range when the constants failed to load. Mirror of the iOS
 * `SleepSectionPresentationTests`.
 */
class SleepSectionPresentationTest {

    private val center = 8.0 * 3600.0   // an 8-hour need centre

    @Test
    fun low_confidence_shows_a_range_high_confidence_does_not() {
        val spec = SleepSpec.default()
        assertTrue("spec must load for this test", spec.isLoaded)
        // Just below the published threshold → a range; comfortably above → a single figure.
        val low = needRangeDisplay(center, spec.lowConfidenceThreshold - 0.01, spec)
        val high = needRangeDisplay(center, minOf(1.0, spec.lowConfidenceThreshold + 0.5), spec)
        assertTrue("low confidence must render as a range", low.showRange)
        assertFalse("high confidence must render a single figure", high.showRange)
    }

    @Test
    fun the_band_widens_as_confidence_falls() {
        val spec = SleepSpec.default()
        val confident = needRangeDisplay(center, 0.9, spec)
        val unsure = needRangeDisplay(center, 0.2, spec)
        val confidentWidth = confident.highSeconds - confident.lowSeconds
        val unsureWidth = unsure.highSeconds - unsure.lowSeconds
        assertTrue("a less certain estimate must look less certain", unsureWidth > confidentWidth)
        // The centre is unchanged by confidence — only the band around it moves.
        assertEquals(center, confident.centerSeconds, 1e-6)
        assertEquals(center, unsure.centerSeconds, 1e-6)
    }

    @Test
    fun the_low_bound_never_goes_negative() {
        val spec = SleepSpec.default()
        // A tiny centre with wide, low-confidence band would push low below zero without the clamp.
        val range = needRangeDisplay(centerSeconds = 60.0, confidence = 0.0, spec = spec)
        assertTrue(range.lowSeconds >= 0.0)
    }

    @Test
    fun an_unloaded_spec_shows_the_centre_alone_never_an_invented_range() {
        val range = needRangeDisplay(center, confidence = 0.1, spec = SleepSpec.unavailable)
        assertFalse(range.showRange)
        assertEquals(center, range.lowSeconds, 1e-9)
        assertEquals(center, range.highSeconds, 1e-9)
        assertEquals(center, range.centerSeconds, 1e-9)
    }
}
