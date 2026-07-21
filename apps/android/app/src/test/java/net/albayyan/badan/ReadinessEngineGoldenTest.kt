package net.albayyan.badan

import net.albayyan.badan.domain.derivation.ReadinessComputation
import net.albayyan.badan.domain.derivation.ReadinessEngine
import net.albayyan.badan.domain.derivation.ReadinessInput
import net.albayyan.badan.domain.derivation.ReadinessInputSample
import net.albayyan.badan.domain.derivation.ReadinessParams
import net.albayyan.badan.domain.derivation.ReadinessSpec
import net.albayyan.badan.domain.derivation.ReadinessVariant
import net.albayyan.badan.ontology.AlgorithmRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-25 — the pure-JVM half of the Readiness engine, and the parity anchor for the iOS
 * `ReadinessEngineTests` composite goldens. Android has no DB-backed test harness, so the DB
 * orchestration (two-source-HRV conflict, append-only writes, v1→v2 migration) is exercised on iOS;
 * what runs here is the pure composite + confidence + variant + contract resolution, asserted against
 * the SAME published weights (loaded from the classpath contract exactly as the app loads them) and
 * the SAME expected numbers as iOS. A drift in either the weights or the math on one platform breaks
 * one of the two suites.
 */
class ReadinessEngineGoldenTest {

    /** The real published contract, via the same classpath route ReadinessEngine's default uses. */
    private val spec: ReadinessSpec = ReadinessSpec.load(AlgorithmRegistry.fromClasspath())

    // --- Contract wiring ---

    @Test fun specLoadsPublishedWeightsAndGates() {
        assertTrue("composite.readiness_score must load from the classpath contract", spec.isLoaded)
        assertEquals("composite.readiness_score@2.0.0", spec.algorithm.id)
        assertEquals(0.5, spec.params.weight(ReadinessInput.HRV), 1e-9)
        assertEquals(0.2, spec.params.weight(ReadinessInput.RHR), 1e-9)
        assertEquals(0.1, spec.params.weight(ReadinessInput.RESPIRATORY_RATE), 1e-9)
        assertEquals(0.2, spec.params.weight(ReadinessInput.SLEEP_PERFORMANCE), 1e-9)
        assertEquals(1.0, spec.params.totalWeight, 1e-9)
        assertEquals(2.5, spec.params.zClampSigmas, 1e-9)
        assertEquals(3, spec.params.minInputsForFullScore)
        assertEquals(2, spec.params.minInputsToScoreAtAll)
        assertTrue(spec.params.algorithmProvisional)
    }

    // --- Pure composite goldens (identical to ReadinessEngineTests.swift) ---

    @Test fun goldenFullComposite() {
        // HRV +1σ (70), RHR +1σ (30), RR at baseline (50), sleep 90%. = 35 + 6 + 5 + 18 = 64.
        val present = listOf(vital(ReadinessInput.HRV, 1.0), vital(ReadinessInput.RHR, 1.0),
                             vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(90.0))
        val c = ReadinessEngine.composite(present, spec.params)!!
        assertEquals(64.0, c.score, 1e-9)
        assertEquals(1.0, c.confidence, 1e-9)
        assertEquals(ReadinessVariant.Full, c.variant)
        assertTrue(c.provisional)
        assertEquals(35.0, contribution(c, ReadinessInput.HRV), 1e-9)
        assertEquals(6.0, contribution(c, ReadinessInput.RHR), 1e-9)
        assertEquals(5.0, contribution(c, ReadinessInput.RESPIRATORY_RATE), 1e-9)
        assertEquals(18.0, contribution(c, ReadinessInput.SLEEP_PERFORMANCE), 1e-9)
        assertEquals(c.score, c.contributions.sumOf { it.contribution }, 1e-9)
    }

    @Test fun goldenMissingHrvReducedAndCapped() {
        val present = listOf(vital(ReadinessInput.RHR, 1.0), vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(90.0))
        val c = ReadinessEngine.composite(present, spec.params)!!
        assertEquals(58.0, c.score, 1e-9)
        assertEquals(0.5, c.confidence, 1e-9)
        val variant = c.variant as ReadinessVariant.ReducedInput
        assertEquals(setOf(ReadinessInput.HRV), variant.missing.toSet())
    }

    @Test fun goldenTwoInputMinimumIsReduced() {
        val present = listOf(vital(ReadinessInput.HRV, 1.0), sleep(70.0))
        val c = ReadinessEngine.composite(present, spec.params)!!
        assertEquals(70.0, c.score, 1e-9)
        assertEquals(0.7, c.confidence, 1e-9)
        val variant = c.variant as ReadinessVariant.ReducedInput
        assertEquals(setOf(ReadinessInput.RHR, ReadinessInput.RESPIRATORY_RATE), variant.missing.toSet())
    }

    @Test fun goldenClampBoundsTheComposite() {
        val maxed = listOf(vital(ReadinessInput.HRV, 3.0), vital(ReadinessInput.RHR, -3.0),
                           vital(ReadinessInput.RESPIRATORY_RATE, -3.0), sleep(130.0))
        assertEquals(100.0, ReadinessEngine.composite(maxed, spec.params)!!.score, 1e-9)
        val floored = listOf(vital(ReadinessInput.HRV, -3.0), vital(ReadinessInput.RHR, 3.0),
                             vital(ReadinessInput.RESPIRATORY_RATE, 3.0), sleep(0.0))
        assertEquals(0.0, ReadinessEngine.composite(floored, spec.params)!!.score, 1e-9)
    }

    @Test fun belowMinimumInputsScoresNothing() {
        assertNull(ReadinessEngine.composite(listOf(sleep(80.0)), spec.params))
        assertNull(ReadinessEngine.composite(listOf(vital(ReadinessInput.HRV, 1.0)), spec.params))
    }

    // --- Missing-input matrix (docs/algorithms/readiness.md table, in code) ---

    @Test fun missingInputMatrix() {
        assertScore(listOf(vital(ReadinessInput.HRV, 0.0), vital(ReadinessInput.RHR, 0.0),
                           vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0)), full = true, confidence = 1.0)
        assertScore(listOf(vital(ReadinessInput.HRV, 0.0), vital(ReadinessInput.RHR, 0.0), sleep(50.0)),
                    full = true, confidence = 0.9)   // RR missing
        assertScore(listOf(vital(ReadinessInput.HRV, 0.0), vital(ReadinessInput.RHR, 0.0),
                           vital(ReadinessInput.RESPIRATORY_RATE, 0.0)), full = true, confidence = 0.8)   // sleep missing
        assertScore(listOf(vital(ReadinessInput.HRV, 0.0), sleep(50.0)), full = false, confidence = 0.7)
        assertScore(listOf(vital(ReadinessInput.RHR, 0.0), vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0)),
                    full = false, confidence = 0.5)   // no HRV
        assertScore(listOf(vital(ReadinessInput.RHR, 0.0), sleep(50.0)), full = false, confidence = 0.4)
        assertScore(listOf(vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0)), full = false, confidence = 0.3)
        assertNull(ReadinessEngine.composite(listOf(vital(ReadinessInput.RHR, 0.0)), spec.params))
    }

    @Test fun confidenceTracksBaselineMaturity() {
        val present = listOf(vital(ReadinessInput.HRV, 0.0, maturity = 0.4), vital(ReadinessInput.RHR, 0.0),
                             vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0))
        assertEquals(0.4, ReadinessEngine.composite(present, spec.params)!!.confidence, 1e-9)
    }

    @Test fun provisionalIsIndependentOfCompleteness() {
        val stable = ReadinessParams(
            weights = spec.params.weights, zClampSigmas = spec.params.zClampSigmas,
            minInputsForFullScore = spec.params.minInputsForFullScore,
            minInputsToScoreAtAll = spec.params.minInputsToScoreAtAll, algorithmProvisional = false)
        val established = listOf(vital(ReadinessInput.HRV, 0.0), vital(ReadinessInput.RHR, 0.0),
                                vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0))
        assertFalse(ReadinessEngine.composite(established, stable)!!.provisional)
        val coldHrv = listOf(vital(ReadinessInput.HRV, 0.0, provisional = true), vital(ReadinessInput.RHR, 0.0),
                             vital(ReadinessInput.RESPIRATORY_RATE, 0.0), sleep(50.0))
        assertTrue(ReadinessEngine.composite(coldHrv, stable)!!.provisional)
    }

    @Test fun classpathContractLoads() {
        assertTrue(AlgorithmRegistry.fromClasspath().definition("composite.readiness_score") != null)
    }

    // --- Fixtures ---

    private fun vital(input: ReadinessInput, z: Double, maturity: Double = 1.0, provisional: Boolean = false) =
        ReadinessInputSample(input, measuredValue = 0.0, z = z, maturity = maturity,
            provisional = provisional, recordId = "rec-$input", sourceId = "src")

    private fun sleep(performance: Double, maturity: Double = 1.0, provisional: Boolean = false) =
        ReadinessInputSample(ReadinessInput.SLEEP_PERFORMANCE, measuredValue = performance, z = null,
            maturity = maturity, provisional = provisional, recordId = "rec-sleep", sourceId = null)

    private fun contribution(c: ReadinessComputation, input: ReadinessInput): Double =
        c.contributions.first { it.input == input }.contribution

    private fun assertScore(present: List<ReadinessInputSample>, full: Boolean, confidence: Double) {
        val c = ReadinessEngine.composite(present, spec.params)!!
        assertEquals(full, c.variant is ReadinessVariant.Full)
        assertEquals(confidence, c.confidence, 1e-9)
    }
}
