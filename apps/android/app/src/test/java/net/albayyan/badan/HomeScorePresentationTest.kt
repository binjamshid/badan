package net.albayyan.badan

import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.features.home.effortGuidance
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * EPIC-26 — the Home Effort guidance sentence, tied to Readiness. Wellness-safe and never prescriptive;
 * its wording is view-independent. The iOS side asserts the same guidance copy in
 * `EffortEngineTests` / `ScoreSurfacesTests` (there is no standalone iOS presentation-test class).
 */
class HomeScorePresentationTest {

    private fun readiness(value: Double) = DerivedValue(
        id = "d", metricId = MetricId.readinessScore, value = value, unit = "score_0_100",
        periodKey = "day:2026-07-20", confidence = 0.8, provisional = false,
        algorithmId = "composite.readiness_score", algorithmVersion = "2.0.0",
        computedAt = 0L, updatedAt = 0L, originDeviceId = "dev",
    )

    @Test
    fun absent_readiness_frames_the_day_without_advising() {
        assertEquals("Your effort so far today.", effortGuidance(null).en)
    }

    @Test
    fun a_rested_morning_invites_a_fuller_effort() {
        assertEquals("There's room for a fuller effort today.", effortGuidance(readiness(72.0)).en)
    }

    @Test
    fun a_balanced_morning_suggests_a_steady_effort() {
        assertEquals("A steady, moderate effort suits today.", effortGuidance(readiness(50.0)).en)
    }

    @Test
    fun a_low_morning_offers_a_gentler_range_never_a_prohibition() {
        val guidance = effortGuidance(readiness(30.0))
        assertEquals("A gentler range may suit you today.", guidance.en)
        // Wellness-safe: the low-readiness copy must never issue a prohibition.
        assertEquals(false, guidance.en.lowercase().contains("don't") || guidance.en.lowercase().contains("do not"))
        assertEquals(false, guidance.en.lowercase().contains("rest day"))
    }

    @Test
    fun every_band_carries_real_arabic() {
        assertEquals("قد تناسبك وتيرة ألطف اليوم.", effortGuidance(readiness(20.0)).ar)
        assertEquals("هناك متسع لجهد أكبر اليوم.", effortGuidance(readiness(90.0)).ar)
    }
}
