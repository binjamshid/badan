package net.albayyan.badan

import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.derivation.BaselineCalibration
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.derivation.BaselineSpec
import net.albayyan.badan.domain.derivation.BaselineTier
import net.albayyan.badan.domain.derivation.BaselineTransform
import net.albayyan.badan.domain.derivation.BaselineWindowResolution
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.AlgorithmRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-23 — the pure-JVM half of the baseline engine, and the parity anchor for the iOS
 * `BaselineEngineTests` goldens. Android has no DB-backed test harness (see `FoundationTest`'s note),
 * so the DB orchestration (windowing, append-only writes, contexts) is exercised on iOS; what runs
 * here is the pure math + calibration + contract resolution, asserted against the SAME published
 * constants (loaded from the classpath contract exactly as the app loads it) and the SAME expected
 * numbers as iOS. A drift in either the constants or the math on one platform breaks one of the two
 * suites.
 */
class BaselineEngineGoldenTest {

    /** The real published contract, via the same classpath route BaselineEngine's default uses. */
    private val spec: BaselineSpec = BaselineSpec.load(AlgorithmRegistry.fromClasspath())

    // --- Contract wiring ---

    @Test fun specLoadsAndResolvesPerMetricWindows() {
        assertTrue("baseline.rolling_median_mad must load from the classpath contract", spec.isLoaded)
        assertEquals("baseline.rolling_median_mad@2.0.0", spec.algorithm.id)
        assertEquals(28, spec.defaultWindowDays)
        assertEquals(7, spec.minPoints)
        assertEquals(3.5, spec.outlierMadThreshold, 1e-9)

        assertEquals(BaselineWindowResolution(60, BaselineTransform.LOG), spec.resolve(MetricId.hrv))
        assertEquals(BaselineWindowResolution(14, BaselineTransform.IDENTITY), spec.resolve(MetricId.restingHeartRate))
        assertEquals(BaselineWindowResolution(14, BaselineTransform.IDENTITY), spec.resolve(MetricId.respiratoryRate))
        assertEquals(BaselineWindowResolution(28, BaselineTransform.IDENTITY), spec.resolve("body.weight"))
    }

    // --- Pure goldens (identical to BaselineEngineTests.swift) ---

    @Test fun goldenIdentityWithOutlierRejected() {
        val values = listOf(50.0, 52.0, 48.0, 51.0, 49.0, 50.0, 53.0, 47.0, 50.0, 51.0, 49.0, 52.0, 48.0, 999.0)
        val c = BaselineEngine.computeBaseline(values, spec.resolve(MetricId.restingHeartRate), spec)!!
        assertEquals(50.0, c.center, 1e-9)
        assertEquals(1.0, c.spread, 1e-9)
        assertEquals(48.5174, c.bandLow, 1e-9)
        assertEquals(51.4826, c.bandHigh, 1e-9)
        assertEquals(13, c.nPoints)
        assertEquals(BaselineTier.ESTABLISHING, c.tier)
    }

    @Test fun goldenLogDomainBandIsAsymmetric() {
        val values = listOf(45.0, 50.0, 55.0, 48.0, 52.0, 60.0, 42.0, 47.0, 53.0, 58.0, 44.0, 300.0)
        val c = BaselineEngine.computeBaseline(values, spec.resolve(MetricId.hrv), spec)!!
        assertEquals(50.0, c.center, 1e-9)
        assertEquals(5.1186443699, c.spread, 1e-9)
        assertEquals(43.4111418516, c.bandLow, 1e-9)
        assertEquals(57.5889021428, c.bandHigh, 1e-9)
        assertEquals(11, c.nPoints)
        assertEquals(BaselineTier.PROVISIONAL, c.tier)
        assertTrue(
            "log-domain band must be asymmetric — the upper edge is farther",
            (c.bandHigh - c.center) > (c.center - c.bandLow),
        )
    }

    @Test fun goldenFlatWindowSkipsOutlierRejection() {
        val values = List(14) { 50.0 }
        val c = BaselineEngine.computeBaseline(values, spec.resolve(MetricId.restingHeartRate), spec)!!
        assertEquals(50.0, c.center, 1e-9)
        assertEquals(0.0, c.spread, 1e-9)
        assertEquals(50.0, c.bandLow, 1e-9)
        assertEquals(50.0, c.bandHigh, 1e-9)
        assertEquals(14, c.nPoints)
        assertEquals(BaselineTier.ESTABLISHED, c.tier)
    }

    @Test fun goldenLogSmallSample() {
        val c = BaselineEngine.computeBaseline(
            listOf(40.0, 50.0, 60.0), BaselineWindowResolution(3, BaselineTransform.LOG), spec,
        )!!
        assertEquals(50.0, c.center, 1e-9)
        assertEquals(10.4671025285, c.spread, 1e-9)
        assertEquals(38.1571464540, c.bandLow, 1e-9)
        assertEquals(65.5185262088, c.bandHigh, 1e-9)
        assertEquals(3, c.nPoints)
    }

    @Test fun logTransformDropsNonPositiveValuesRatherThanClamping() {
        val c = BaselineEngine.computeBaseline(
            listOf(0.0, 50.0, 50.0, 50.0), BaselineWindowResolution(14, BaselineTransform.LOG), spec,
        )!!
        assertEquals(50.0, c.center, 1e-9)
        assertEquals(3, c.nPoints)
    }

    // --- Tier classification ---

    @Test fun tierGatesOnPointsAndHalfWindow() {
        assertEquals(BaselineTier.PROVISIONAL, BaselineEngine.classifyTier(6, 14, spec))
        assertEquals(BaselineTier.ESTABLISHING, BaselineEngine.classifyTier(7, 14, spec))
        assertEquals(BaselineTier.ESTABLISHED, BaselineEngine.classifyTier(14, 14, spec))
        assertEquals(BaselineTier.PROVISIONAL, BaselineEngine.classifyTier(7, 60, spec))
        assertEquals(BaselineTier.PROVISIONAL, BaselineEngine.classifyTier(29, 60, spec))
        assertEquals(BaselineTier.ESTABLISHING, BaselineEngine.classifyTier(30, 60, spec))
        assertEquals(BaselineTier.ESTABLISHED, BaselineEngine.classifyTier(60, 60, spec))
    }

    // --- Retroactive labeling ---

    @Test fun isRetroactiveUsesGraceWindow() {
        val tz = "UTC"
        fun day(key: String): Long = DayAttribution.dateFromDayKey(key, tz)!!
        assertFalse(BaselineEngine.isRetroactive("2026-05-01", day("2026-05-01"), tz, spec))
        assertFalse(BaselineEngine.isRetroactive("2026-05-01", day("2026-05-03"), tz, spec))
        assertTrue(BaselineEngine.isRetroactive("2026-05-01", day("2026-05-04"), tz, spec))
        assertTrue(BaselineEngine.isRetroactive("2026-05-01", day("2026-07-20"), tz, spec))
    }

    // --- Calibration read model ---

    @Test fun calibrationReadModelFromBaseline() {
        val baseline = Baseline(
            id = "b1", metricId = MetricId.hrv, windowDays = 60, center = 50.0, spread = 5.0,
            bandLow = 45.0, bandHigh = 56.0, nPoints = 40, provisional = false,
            algorithmVersion = spec.algorithm.id, validFrom = 0L, computedAt = 0L, unit = "ms",
        )
        val cal = BaselineCalibration.from(baseline, spec)
        assertEquals(BaselineTier.ESTABLISHING, cal.tier)
        assertEquals(40, cal.nPoints)
        assertEquals(60, cal.windowDays)
        assertEquals(BaselineTransform.LOG, cal.transform)
        assertEquals(40.0 / 60.0, cal.maturity, 1e-9)
        assertFalse(cal.provisional)
    }

    @Test fun classpathContractLoads() {
        // Guards the resources mirror packaging: BaselineEngine's default spec depends on it.
        assertNotNull(AlgorithmRegistry.fromClasspath().definition("baseline.rolling_median_mad"))
    }
}
