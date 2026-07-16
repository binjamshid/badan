package net.albayyan.badan

import net.albayyan.badan.core.Clock
import net.albayyan.badan.domain.QualityFlag
import net.albayyan.badan.platform.health.FakeHealthStore
import net.albayyan.badan.platform.health.HealthDateRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sample data must be recognisable as fabricated everywhere it travels.
 *
 * Android shipped no honesty layer at all: 90 days of invented readings were branded "Apple
 * Watch" and "iPhone" under `com.apple.health` — on an Android device — and presented on every
 * screen exactly as the user's own measurements would be. These lock the two structural halves of
 * the fix (the marker and the identity) at the only seam a pure-JVM test can reach.
 */
class SampleDataHonestyTest {

    private val clock = object : Clock {
        override fun now(): Long = 1_783_000_000_000L
    }

    private fun store() = FakeHealthStore(clock, 30, "UTC")

    private fun fullRange() = HealthDateRange(
        start = clock.now() - 30L * 24 * 60 * 60 * 1000,
        end = clock.now(),
    )

    @Test fun everyFabricatedSampleCarriesTheSampleDataFlag() {
        val samples = store().readSamples(fullRange())
        assertTrue("sanity: the generator produced rows to check", samples.isNotEmpty())
        assertTrue(
            "every fabricated sample must carry SAMPLE_DATA",
            samples.all { QualityFlag.SAMPLE_DATA in it.qualityFlags },
        )
    }

    @Test fun everyFabricatedIntervalCarriesTheSampleDataFlag() {
        val intervals = store().readIntervals(fullRange())
        assertTrue(intervals.isNotEmpty())
        assertTrue(intervals.all { QualityFlag.SAMPLE_DATA in it.qualityFlags })
    }

    @Test fun everyFabricatedSessionCarriesTheSampleDataFlag() {
        val sessions = store().readSessions(fullRange())
        assertTrue(sessions.isNotEmpty())
        assertTrue(sessions.all { QualityFlag.SAMPLE_DATA in it.qualityFlags })
    }

    /** Fabricated data must never claim a platform this device doesn't even run. */
    @Test fun simulatedSourcesDoNotClaimAppleHealthProvenance() {
        val descriptors = store().sourceDescriptors()
        assertTrue(descriptors.isNotEmpty())
        for (d in descriptors) {
            assertNotEquals("sample data must not be attributed to Apple Health", "com.apple.health", d.bundleId)
            assertFalse(
                "a simulated source must not be named after real Apple hardware — got \"${d.displayName}\"",
                d.displayName.contains("Apple", ignoreCase = true) ||
                    d.displayName.contains("iPhone", ignoreCase = true),
            )
            assertTrue(
                "a source the user sees must say it is sample data — got \"${d.displayName}\"",
                d.displayName.contains("sample", ignoreCase = true),
            )
        }
    }

    /**
     * The watch-beats-phone priority gap is why two overlapping sleep sources exist at all; the
     * honesty rename must not flatten the dedup path it feeds.
     */
    @Test fun simulatedSourcesKeepTheirDedupPriorityOrdering() {
        val priorities = store().sourceDescriptors().map { it.priority }
        assertEquals(
            "the wearable/phone priority gap must survive the rename",
            priorities.size, priorities.toSet().size,
        )
    }

    /** The wire code is a cross-platform contract: iOS reads these exports too. */
    @Test fun sampleDataFlagCodeMatchesTheSharedContract() {
        assertEquals("sampleData", QualityFlag.SAMPLE_DATA.code)
        assertEquals(QualityFlag.SAMPLE_DATA, QualityFlag.fromCode("sampleData"))
    }
}
