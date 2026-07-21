package net.albayyan.badan

import net.albayyan.badan.domain.derivation.SleepAssembly
import net.albayyan.badan.domain.derivation.SleepIntelligenceEngine
import net.albayyan.badan.domain.derivation.SleepInterval
import net.albayyan.badan.domain.derivation.SleepSessionInput
import net.albayyan.badan.domain.derivation.SleepSessionKind
import net.albayyan.badan.domain.derivation.SleepSpec
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-24 — the pure-JVM half of the sleep intelligence engine, and the parity anchor for the iOS
 * `SleepIntelligenceEngineTests` goldens. Android has no DB-backed test harness (see `FoundationTest`),
 * so the DB orchestration (recompute, append-only writes) is exercised on iOS; what runs here is the
 * pure state machine + the five sub-computations, asserted against the SAME published constants
 * (loaded from the classpath contract exactly as the app loads them) and the SAME expected numbers as
 * iOS. A drift in either the constants or the math on one platform breaks one of the two suites.
 */
class SleepIntelligenceEngineGoldenTest {

    /** The real published contract, via the same classpath route the engine's default spec uses. */
    private val spec: SleepSpec = SleepSpec.load(AlgorithmRegistry.fromClasspath())

    // --- Contract wiring ---

    @Test fun specLoadsEveryConstant() {
        assertTrue("the five sleep.* entries must load from the classpath contract", spec.isLoaded)
        assertEquals("sleep.need@0.1.0", spec.need.algorithm.id)
        assertTrue("seeded constants are provisional → every row is provisional", spec.need.provisional)
        assertEquals(0.35, spec.debtRepaymentFraction, 1e-9)
        assertEquals(4.0, spec.needDebtHalfLifeDays, 1e-9)
        assertEquals(42.0, spec.effortFactorSecondsPerPoint, 1e-9)
        assertEquals(0.5, spec.napCreditFraction, 1e-9)
        assertEquals(7.0, spec.displayDebtHalfLifeDays, 1e-9)
        assertEquals(14, spec.debtLookbackDays)
        assertEquals(14, spec.consistencyWindowDays)
        assertEquals(5, spec.consistencyMinNights)
        assertEquals(300.0, spec.minEpisodeSeconds, 1e-9)
        assertEquals(120.0, spec.mergeGapSeconds, 1e-9)
    }

    // --- Need goldens (identical to iOS) ---

    @Test fun goldenNeedEstablishedWithEffort() {
        val need = SleepIntelligenceEngine.computeNeed(25200.0, 0.0, 10.0, 0.0, 1.0, spec)
        assertEquals(25620.0, need.centerSeconds, 1e-9)
        assertEquals(23820.0, need.lowSeconds, 1e-9)
        assertEquals(27420.0, need.highSeconds, 1e-9)
        assertEquals(1.0, need.confidence, 1e-9)
        assertTrue(need.effortPresent)

        val perf = SleepIntelligenceEngine.computePerformance(24000.0, need, spec)
        assertEquals(93.6768149882904, perf.centerPercent, 1e-9)
        assertEquals(87.527352297593, perf.lowPercent, 1e-9)
        assertEquals(100.75566750629723, perf.highPercent, 1e-9)
        assertFalse("confidence 1.0 ≥ threshold → shown as a point", perf.showRange)
    }

    @Test fun goldenNeedReducedInputNoEffort() {
        val need = SleepIntelligenceEngine.computeNeed(25200.0, 0.0, null, 0.0, 1.0, spec)
        assertEquals(25200.0, need.centerSeconds, 1e-9)
        assertEquals(22500.0, need.lowSeconds, 1e-9)
        assertEquals(27900.0, need.highSeconds, 1e-9)
        assertEquals(0.5, need.confidence, 1e-9)
        assertFalse("the reduced-input variant is flagged, never silently degraded", need.effortPresent)

        val perf = SleepIntelligenceEngine.computePerformance(24000.0, need, spec)
        assertEquals(95.23809523809523, perf.centerPercent, 1e-9)
        assertTrue("confidence 0.5 < 0.6 → shown as a range, no false precision", perf.showRange)
    }

    @Test fun goldenNeedNapCreditSubtracts() {
        val need = SleepIntelligenceEngine.computeNeed(25200.0, 0.0, null, 1800.0, 1.0, spec)
        assertEquals(23400.0, need.centerSeconds, 1e-9)
    }

    @Test fun goldenNeedClampsToFloorAndCeiling() {
        assertEquals(spec.minNeedSeconds, SleepIntelligenceEngine.computeNeed(10000.0, 0.0, null, 0.0, 1.0, spec).centerSeconds, 1e-9)
        assertEquals(spec.maxNeedSeconds, SleepIntelligenceEngine.computeNeed(50000.0, 0.0, null, 0.0, 1.0, spec).centerSeconds, 1e-9)
    }

    // --- Forward-pass goldens: debt accumulation across nights ---

    @Test fun goldenThreeNightForwardDebt() {
        val assembly = makeAssembly(listOf("2026-05-01", "2026-05-02", "2026-05-03"), listOf(18000.0, 25200.0, 25200.0))
        val scores = SleepIntelligenceEngine.score(assembly, 25200.0 to 1.0, emptyMap(), spec)
        assertEquals(3, scores.size)
        assertEquals(25200.0, scores[0].need!!.centerSeconds, 1e-6)
        assertEquals(7200.0, scores[0].debtSeconds!!, 1e-6)
        assertEquals(27319.0589664394, scores[1].need!!.centerSeconds, 1e-6)
        assertEquals(8640.2693491395, scores[1].debtSeconds!!, 1e-6)
        assertEquals(27605.5772695966, scores[2].need!!.centerSeconds, 1e-6)
        assertEquals(10231.2736847264, scores[2].debtSeconds!!, 1e-6)
    }

    // --- All-nighter (missed night is a gap, never a zero) ---

    @Test fun goldenMissedNightIsAGapAndDebtDecaysAcrossIt() {
        val assembly = makeAssembly(listOf("2026-05-01", "2026-05-03"), listOf(18000.0, 25200.0))
        val scores = SleepIntelligenceEngine.score(assembly, 25200.0 to 1.0, emptyMap(), spec)
        assertEquals("the missing night is absent, not scored as zero", 2, scores.size)
        assertEquals(listOf("2026-05-01", "2026-05-03"), scores.map { it.localNight })
        assertEquals(26981.9090885901, scores[1].need!!.centerSeconds, 1e-6)
        assertEquals(7688.3236518451, scores[1].debtSeconds!!, 1e-6)
    }

    @Test fun noBaselineMeansNoNeedButConsistencyStillComputes() {
        val assembly = makeAssembly((1..6).map { "2026-05-%02d".format(it) }, List(6) { 25200.0 })
        val scores = SleepIntelligenceEngine.score(assembly, null, emptyMap(), spec)
        assertTrue(scores.all { it.need == null && it.performance == null && it.debtSeconds == null })
        assertNotNull("consistency does not need a baseline", scores.last().consistency)
    }

    // --- Split night (two clusters, one night) ---

    @Test fun goldenSplitNightMergesAndCountsInterClusterGap() {
        val base = DayAttribution.dateFromDayKey("2026-05-01", "UTC")!! / 1000.0
        val c1 = SleepSessionInput("c1", SleepSessionKind.PRIMARY, base + 23 * 3600, base + 26 * 3600,
            "UTC", 10800.0, 10800.0, emptyList(), hasStages = true)
        val c2 = SleepSessionInput("c2", SleepSessionKind.PRIMARY, base + 26.5 * 3600, base + 30.5 * 3600,
            "UTC", 14400.0, 14400.0, emptyList(), hasStages = true)
        val assembly = SleepIntelligenceEngine.assembleNights(listOf(c2, c1)) // out of order on purpose

        assertEquals("two clusters of one night are one night", 1, assembly.nights.size)
        val night = assembly.nights[0]
        assertEquals("2026-05-02", night.localNight)
        assertEquals("a split night is one night's sleep", 25200.0, night.asleepSeconds, 1e-9)
        assertEquals(listOf("c1", "c2"), night.sessionIds)
        assertEquals("bedtime is the earliest cluster's start (23:00)", 82800.0, night.bedSecondsOfDay, 1e-9)
        assertEquals("wake is the latest cluster's end (06:30)", 23400.0, night.wakeSecondsOfDay, 1e-9)
        assertEquals("the inter-cluster gap is one disturbance", 1,
            SleepIntelligenceEngine.countDisturbances(night.awakeIntervals, spec))
    }

    // --- Disturbance counting ---

    @Test fun goldenDisturbanceMergeAndThreshold() {
        val two = listOf(SleepInterval(1000.0, 1200.0), SleepInterval(1250.0, 1450.0), SleepInterval(3000.0, 3400.0))
        assertEquals(2, SleepIntelligenceEngine.countDisturbances(two, spec))
        val below = listOf(SleepInterval(0.0, 100.0), SleepInterval(150.0, 250.0))
        assertEquals(0, SleepIntelligenceEngine.countDisturbances(below, spec))
    }

    // --- Consistency ---

    @Test fun goldenConsistencyTightWrapAndScattered() {
        assertEquals("identical timing → perfect consistency", 100.0,
            SleepIntelligenceEngine.computeConsistency(List(5) { 82800.0 }, List(5) { 25200.0 }, spec), 1e-9)

        val bed = listOf(86280.0, 600.0, 85980.0, 300.0, 0.0)
        assertEquals(350.679340708859, SleepIntelligenceEngine.circularSpreadSeconds(bed), 1e-6)
        assertEquals(98.37648453375529,
            SleepIntelligenceEngine.computeConsistency(bed, List(5) { 25200.0 }, spec), 1e-6)

        val scattered = listOf(75600.0, 82800.0, 79200.0, 86399.0, 72000.0)
        assertEquals(5090.885989687846, SleepIntelligenceEngine.circularSpreadSeconds(scattered), 1e-6)
        assertEquals(76.43108338107479,
            SleepIntelligenceEngine.computeConsistency(scattered, List(5) { 25200.0 }, spec), 1e-6)
    }

    // --- DST night (wall-clock second-of-day survives the missing hour) ---

    @Test fun goldenDSTWallClockSecondOfDay() {
        assertEquals("07:00 EDT → 25200", 25200.0,
            SleepIntelligenceEngine.localSecondsOfDay(1_772_967_600.0, "America/New_York"), 1e-9)
        assertEquals("00:30 EST → 1800", 1800.0,
            SleepIntelligenceEngine.localSecondsOfDay(1_772_947_800.0, "America/New_York"), 1e-9)
    }

    // --- Travel tz change (the night is computed in the tz at measurement) ---

    @Test fun goldenTravelTimezoneAttributesNightsInTheirOwnZone() {
        val riyadhEnd = 1_781_064_000.0 // 2026-06-10 07:00 Asia/Riyadh
        assertEquals("2026-06-10", DayAttribution.localNight((riyadhEnd * 1000).toLong(), "Asia/Riyadh"))
        assertEquals(25200.0, SleepIntelligenceEngine.localSecondsOfDay(riyadhEnd, "Asia/Riyadh"), 1e-9)
        assertEquals(18000.0, SleepIntelligenceEngine.localSecondsOfDay(riyadhEnd, "Europe/London"), 1e-9)

        val assembly = SleepIntelligenceEngine.assembleNights(
            listOf(
                SleepSessionInput("riyadh", SleepSessionKind.PRIMARY, riyadhEnd - 7 * 3600, riyadhEnd,
                    "Asia/Riyadh", 25200.0, 25200.0),
                SleepSessionInput("london", SleepSessionKind.PRIMARY, 1_781_157_600.0 - 7 * 3600, 1_781_157_600.0,
                    "Europe/London", 25200.0, 25200.0),
            ),
        )
        assertEquals(listOf("2026-06-10", "2026-06-11"), assembly.nights.map { it.localNight })
    }

    // --- Nap attribution through the state machine ---

    @Test fun napCreditFlowsToTheFollowingNight() {
        val base = DayAttribution.dateFromDayKey("2026-05-01", "UTC")!! / 1000.0
        val nap = SleepSessionInput("nap", SleepSessionKind.NAP, base + 14 * 3600, base + 15 * 3600,
            "UTC", 3600.0, 3600.0)
        val night = SleepSessionInput("n", SleepSessionKind.PRIMARY, base + 23 * 3600, base + 31 * 3600,
            "UTC", 25200.0, 28800.0)
        val assembly = SleepIntelligenceEngine.assembleNights(listOf(nap, night))
        assertEquals("nap accrues to its own local day", 3600.0, assembly.napSecondsByDayKey["2026-05-01"]!!, 1e-9)

        val scores = SleepIntelligenceEngine.score(assembly, 25200.0 to 1.0, emptyMap(), spec)
        val night2 = scores.first { it.localNight == "2026-05-02" }
        assertEquals("the prior-day nap lowers this night's need by 0.5·3600", 23400.0, night2.need!!.centerSeconds, 1e-6)
    }

    @Test fun classpathContractLoads() {
        assertNotNull(AlgorithmRegistry.fromClasspath().definition("sleep.need"))
    }

    // --- Fixtures ---

    private fun makeAssembly(days: List<String>, asleep: List<Double>): SleepAssembly {
        val inputs = days.mapIndexed { i, day ->
            val morning = DayAttribution.dateFromDayKey(day, "UTC")!! / 1000.0
            val end = morning + 7 * 3600
            SleepSessionInput("s$i", SleepSessionKind.PRIMARY, end - 8 * 3600, end, "UTC", asleep[i], 28800.0)
        }
        return SleepIntelligenceEngine.assembleNights(inputs)
    }
}
