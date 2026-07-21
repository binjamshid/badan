package net.albayyan.badan

import net.albayyan.badan.domain.HRZone
import net.albayyan.badan.domain.HRZoneModel
import net.albayyan.badan.domain.HRZones
import net.albayyan.badan.domain.derivation.EffortEngine
import net.albayyan.badan.domain.derivation.EffortGuidanceBand
import net.albayyan.badan.domain.derivation.EffortSpec
import net.albayyan.badan.domain.derivation.HrSample
import net.albayyan.badan.ontology.AlgorithmRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-26 — the pure-JVM half of the Effort engine, and the parity anchor for the iOS
 * `EffortEngineTests` goldens. Android has no DB-backed test harness (see `BaselineEngineGoldenTest`'s
 * note), so the DB orchestration (windowing, the reduced-input branch, append-only backfill
 * supersession) is exercised on iOS; what runs here is the pure math + zone classification + curve
 * properties + contract resolution, asserted against the SAME published constants (loaded from the
 * classpath contract exactly as the app loads it) and the SAME expected numbers as iOS. A drift in
 * either the constants or the math on one platform breaks one of the two suites.
 */
class EffortEngineGoldenTest {

    /** The real published contract, via the same classpath route EffortEngine's default uses. */
    private val spec: EffortSpec = EffortSpec.load(AlgorithmRegistry.fromClasspath())

    // --- Contract wiring ---

    @Test fun specLoadsPublishedConstants() {
        assertTrue(spec.isLoaded)
        assertEquals("effort.day@0.1.0", spec.dayAlgorithm.id)
        assertEquals("effort.workout@0.1.0", spec.workoutAlgorithm.id)
        val p = spec.params
        assertEquals(100.0, p.scaleMax, 1e-9)
        assertEquals(listOf(1.0, 1.6, 2.6, 4.2, 6.8), p.zoneWeights)
        assertEquals(0.045, p.logCurveK, 1e-9)
        assertEquals(listOf(50.0, 60.0, 70.0, 80.0, 90.0), p.zoneFloorPcts)
        assertEquals(208.0, p.hrMaxConstant, 1e-9)
        assertEquals(0.7, p.hrMaxAgeCoefficient, 1e-9)
        assertEquals(0.5, p.sparseHrMinSamplesPerMinute, 1e-9)
        assertTrue(p.algorithmProvisional)
        assertEquals(120.0, p.maxAttributableGapSeconds, 1e-9)
    }

    @Test fun workoutCurveMatchesDayCurve() {
        val registry = AlgorithmRegistry.fromClasspath()
        assertEquals(registry.param("effort.day", "scaleMax"), registry.param("effort.workout", "scaleMax"))
        assertEquals(registry.param("effort.day", "logCurveK"), registry.param("effort.workout", "logCurveK"))
    }

    // --- Pure goldens (identical to EffortEngineTests.swift) ---

    @Test fun effortScoreGoldens() {
        val p = spec.params
        assertEquals(0.0, EffortEngine.effortScore(0.0, p), 1e-9)
        assertEquals(36.2371848378227, EffortEngine.effortScore(10.0, p), 1e-9)
        assertEquals(59.3430340259401, EffortEngine.effortScore(20.0, p), 1e-9)
        assertEquals(68.9633058734515, EffortEngine.effortScore(26.0, p), 1e-9)
        assertEquals(98.8891003461758, EffortEngine.effortScore(100.0, p), 1e-9)
        // At extreme load the exponential underflows to 0 and the score reaches scaleMax exactly
        // (float64), so the bound is `<=`; a realistic load (100 above) stays strictly below it.
        assertTrue(EffortEngine.effortScore(100_000.0, p) <= p.scaleMax)
    }

    @Test fun zoneClassificationGoldens() {
        val model = HRZoneModel.resolve(null, 200.0, null, spec.params)!!
        assertEquals(listOf(100.0, 120.0, 140.0, 160.0, 180.0), model.floorsBpm)
        assertEquals(0, model.zoneIndex(90.0))
        assertEquals(1, model.zoneIndex(100.0))
        assertEquals(1, model.zoneIndex(119.9))
        assertEquals(2, model.zoneIndex(120.0))
        assertEquals(4, model.zoneIndex(179.0))
        assertEquals(5, model.zoneIndex(180.0))
        assertEquals(5, model.zoneIndex(260.0))
    }

    @Test fun effectiveHrMaxPrecedenceAndAgeDefault() {
        assertEquals(185.0, HRZoneModel.effectiveHrMax(185.0, 30, spec.params))
        assertEquals(194.0, HRZoneModel.effectiveHrMax(null, 20, spec.params)!!, 1e-9)
        assertNull(HRZoneModel.effectiveHrMax(null, null, spec.params))
        assertNull(HRZoneModel.resolve(null, null, null, spec.params))
    }

    @Test fun storedOverrideWinsOverDerivedZones() {
        val override = HRZones(
            listOf(
                HRZone(95, 109), HRZone(110, 124), HRZone(125, 139), HRZone(140, 154), HRZone(155, 190),
            ),
        )
        val model = HRZoneModel.resolve(override, 200.0, null, spec.params)!!
        assertEquals(listOf(95.0, 110.0, 125.0, 140.0, 155.0), model.floorsBpm)
        // A malformed override (wrong count) falls through to the derived zones.
        val bad = HRZones(override.zones.dropLast(1))
        assertEquals(listOf(100.0, 120.0, 140.0, 160.0, 180.0), HRZoneModel.resolve(bad, 200.0, null, spec.params)!!.floorsBpm)
    }

    @Test fun accumulateGoldenAndGapClamp() {
        val p = spec.params
        val model = HRZoneModel(listOf(100.0, 120.0, 140.0, 160.0, 180.0))
        val a = (0 until 10).map { HrSample(it * 60.0, 150.0) }
        val accA = EffortEngine.accumulate(a, 600.0, model, p)
        assertEquals(600.0, accA.coveredSeconds, 1e-9)
        assertEquals(listOf(0.0, 0.0, 10.0, 0.0, 0.0), accA.minutesPerZone)
        assertEquals(26.0, accA.load, 1e-9)
        assertEquals(68.9633058734515, EffortEngine.effortScore(accA.load, p), 1e-9)

        val b = listOf(HrSample(0.0, 150.0), HrSample(10.0, 150.0), HrSample(3610.0, 150.0))
        val accB = EffortEngine.accumulate(b, 3670.0, model, p)
        assertEquals(190.0, accB.coveredSeconds, 1e-9)
        assertEquals(8.2333333333333, accB.load, 1e-9)
    }

    // --- Curve properties (the A3 mandate: monotonic + diminishing) ---

    @Test fun effortScoreIsMonotonicAndDiminishing() {
        val p = spec.params
        var prev = -1.0
        var prevMarginal = Double.MAX_VALUE
        var load = 0.0
        while (load <= 300.0) {
            val s = EffortEngine.effortScore(load, p)
            assertTrue("monotonic at L=$load", s > prev)
            if (load > 0.0) {
                val marginal = s - EffortEngine.effortScore(load - 0.5, p)
                assertTrue("diminishing at L=$load", marginal < prevMarginal + 1e-12)
                prevMarginal = marginal
            }
            prev = s
            load += 0.5
        }
    }

    @Test fun weightedMinutesMonotonicInTimeAndIntensity() {
        val w = spec.params.zoneWeights
        assertTrue(
            EffortEngine.weightedZoneMinutes(listOf(5.0, 5.0, 6.0, 0.0, 0.0), w) >
                EffortEngine.weightedZoneMinutes(listOf(5.0, 5.0, 5.0, 0.0, 0.0), w),
        )
        assertTrue(
            EffortEngine.weightedZoneMinutes(listOf(0.0, 0.0, 0.0, 0.0, 10.0), w) >
                EffortEngine.weightedZoneMinutes(listOf(10.0, 0.0, 0.0, 0.0, 0.0), w),
        )
    }

    // --- Sparse detection + guidance ---

    @Test fun sparseDetectionGates() {
        val p = spec.params
        assertEquals(3.0, EffortEngine.hrDensityPerMinute(30, 600.0), 1e-9)
        assertTrue(EffortEngine.hrDensityPerMinute(2, 3600.0) < p.sparseHrMinSamplesPerMinute)
        assertTrue(EffortEngine.hrDensityPerMinute(60, 3600.0) >= p.sparseHrMinSamplesPerMinute)
    }

    @Test fun guidanceBandThirds() {
        assertEquals(EffortGuidanceBand.GENTLER, EffortEngine.guidanceBand(10.0))
        assertEquals(EffortGuidanceBand.GENTLER, EffortEngine.guidanceBand(33.0))
        assertEquals(EffortGuidanceBand.TYPICAL, EffortEngine.guidanceBand(50.0))
        assertEquals(EffortGuidanceBand.TYPICAL, EffortEngine.guidanceBand(66.0))
        assertEquals(EffortGuidanceBand.HEADROOM, EffortEngine.guidanceBand(67.0))
        assertEquals(EffortGuidanceBand.HEADROOM, EffortEngine.guidanceBand(95.0))
    }

    @Test fun defaultZonesSeedIsWellFormed() {
        val zones = HRZoneModel.defaultZones(200.0, spec.params)
        assertEquals(HRZones.ZONE_COUNT, zones.zones.size)
        assertTrue(zones.isWellFormed)
        assertEquals(100, zones.zones[0].lowerBpm)
        assertNotNull(zones)
    }
}
