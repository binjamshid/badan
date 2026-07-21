package net.albayyan.badan

import net.albayyan.badan.domain.derivation.StressAbsenceReason
import net.albayyan.badan.domain.derivation.StressDayBucket
import net.albayyan.badan.domain.derivation.StressDayContribution
import net.albayyan.badan.domain.derivation.StressDensityState
import net.albayyan.badan.domain.derivation.StressEngine
import net.albayyan.badan.domain.derivation.StressReference
import net.albayyan.badan.domain.derivation.StressSpec
import net.albayyan.badan.domain.derivation.StressSurface
import net.albayyan.badan.domain.derivation.StressTrendBand
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.ontology.AlgorithmRegistry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.exp
import kotlin.math.ln

/**
 * EPIC-34 — the pure-JVM half of the device-gated stress monitor, and the parity anchor for the iOS
 * `StressEngineTests`. Android has no DB-backed test harness (see `BaselineEngineGoldenTest`'s note),
 * so the DB orchestration (daytime bucketing, sleep-window exclusion, append-only persistence) is
 * exercised on iOS; what runs here is **the gate** — the part that must be byte-identical, because a
 * gate that differs by platform is not a gate — plus the trend math, the surface states, and the
 * bilingual absence copy.
 *
 * The expected numbers are the SAME ones the iOS suite asserts, against the SAME published constants
 * loaded from the classpath contract exactly as the app loads them.
 */
class StressEngineGoldenTest {

    private val spec: StressSpec = StressSpec.load(AlgorithmRegistry.fromClasspath())

    // --- Contract wiring ---

    @Test fun specLoadsPublishedConstants() {
        assertTrue(spec.isLoaded)
        assertEquals("stress.day_trend@0.2.0", spec.algorithm.id)
        val p = spec.params
        assertEquals(7, p.densityWindowDays)
        assertEquals(4.0, p.denseMinSamplesPerHour, 1e-9)
        assertEquals(0.5, p.moderateMinSamplesPerHour, 1e-9)
        assertEquals(5, p.minDaysWithDaytimeSamples)
        assertEquals(24.0, p.minDaytimeHoursInWindow, 1e-9)
        assertEquals(2, p.minDaytimeSamplesPerDay)
        assertEquals(28, p.referenceWindowDays)
        assertEquals(14, p.minReferenceDays)
        assertEquals(7, p.trendWindowDays)
        assertEquals(4, p.minTrendDays)
        assertEquals(2.0, p.trendHalfLifeDays, 1e-9)
        assertEquals(2.5, p.zClampSigmas, 1e-9)
        assertEquals(10.0, p.bandNeutralHalfWidth, 1e-9)
        assertEquals(0.5, p.moderateConfidenceCap, 1e-9)
        assertEquals(1.0, p.denseConfidenceCap, 1e-9)
        assertTrue("stress.day_trend is provisional until its constants are validated", p.algorithmProvisional)
        // Read from the BASELINE entry, never re-declared in the stress block.
        assertEquals(1.4826, p.madToSigma, 1e-9)
        assertNull(
            "madToSigma must not be duplicated into the stress params block",
            AlgorithmRegistry.fromClasspath().param("stress.day_trend", "madToSigma"),
        )
    }

    /**
     * The "contract did not load" spec produces NO trend from data that would otherwise be dense —
     * an engine with no thresholds must not guess where the thresholds are. (The engine's own entry
     * point short-circuits to CONTRACT_UNAVAILABLE before it ever gathers buckets; that path needs a
     * DB and is asserted on iOS. What is pinned here is that the pure core is safe on its own.)
     */
    @Test fun unavailableSpecRefusesToProduceATrend() {
        val surface = StressEngine.evaluate(buckets(7, samplesPerDay = 96, hoursPerDay = 16.0), StressSpec.unavailable.params)
        assertTrue(surface is StressSurface.Hidden)
        assertNull(surface.trend)
    }

    // --- The gate: density boundaries (identical to StressEngineTests.swift) ---

    @Test fun densityArithmetic() {
        val density = StressEngine.measureDensity(buckets(7, samplesPerDay = 8, hoursPerDay = 16.0), spec.params)
        assertEquals(56, density.daytimeSamples)
        assertEquals(112.0, density.daytimeHours, 1e-9)
        assertEquals(0.5, density.samplesPerHour, 1e-9)
        assertEquals(7, density.daysWithSamples)
        assertEquals(7, density.windowDays)
    }

    /**
     * Only the trailing `densityWindowDays` count. A dense month followed by a sparse week must read
     * as the sparse week — the gate describes what the device is doing NOW.
     */
    @Test fun densityMeasuresOnlyTheTrailingWindow() {
        val window = buckets(21, samplesPerDay = 96, hoursPerDay = 16.0) + buckets(7, samplesPerDay = 1, hoursPerDay = 16.0)
        val density = StressEngine.measureDensity(window, spec.params)
        assertEquals(7, density.daytimeSamples)
        assertEquals(StressDensityState.INSUFFICIENT, StressEngine.classify(density, spec.params))
    }

    @Test fun classifyAtEachThresholdBoundary() {
        // 7 days × 16 waking hours = 112 hours. The rate is samples ÷ 112.
        fun state(samplesPerWeek: Int): StressDensityState {
            val perDay = samplesPerWeek / 7
            val remainder = samplesPerWeek % 7
            val window = buckets(7, samplesPerDay = perDay, hoursPerDay = 16.0).toMutableList()
            if (remainder > 0) {
                val last = window.last()
                window[window.size - 1] = last.copy(daytimeHrv = List(perDay + remainder) { 50.0 })
            }
            return StressEngine.classify(StressEngine.measureDensity(window, spec.params), spec.params)
        }

        // Moderate floor: exactly 0.5/hr clears (56 ÷ 112); one sample fewer does not.
        assertEquals("a rate exactly ON the threshold clears it", StressDensityState.MODERATE, state(56))
        assertEquals(
            "just below the floor is hidden, not 'moderate with a caveat'",
            StressDensityState.INSUFFICIENT, state(55),
        )
        // Dense floor: exactly 4.0/hr clears (448 ÷ 112); one fewer stays moderate.
        assertEquals(StressDensityState.DENSE, state(448))
        assertEquals(StressDensityState.MODERATE, state(447))
    }

    /** A single dense day cannot unlock a surface the rest of the week cannot support. */
    @Test fun daysCoveredGateIsIndependentOfRate() {
        val window = (buckets(4, samplesPerDay = 200, hoursPerDay = 16.0) +
            buckets(3, samplesPerDay = 0, hoursPerDay = 16.0)).toMutableList()
        val density = StressEngine.measureDensity(window, spec.params)
        assertTrue(density.samplesPerHour > spec.params.denseMinSamplesPerHour)
        assertEquals(4, density.daysWithSamples)
        assertEquals(StressDensityState.INSUFFICIENT, StressEngine.classify(density, spec.params))
        assertEquals(StressAbsenceReason.TOO_FEW_DAYS_COVERED, StressEngine.absenceReason(density, spec.params))

        window[4] = window[4].copy(daytimeHrv = List(200) { 50.0 })
        val cleared = StressEngine.measureDensity(window, spec.params)
        assertEquals(5, cleared.daysWithSamples)
        assertEquals(StressDensityState.DENSE, StressEngine.classify(cleared, spec.params))
    }

    /** Three samples in one waking hour is 3.0/hr arithmetically and evidence of nothing. */
    @Test fun wakingCoverageGuardsTheDenominator() {
        val density = StressEngine.measureDensity(buckets(7, samplesPerDay = 3, hoursPerDay = 0.5), spec.params)
        assertEquals(6.0, density.samplesPerHour, 1e-9)
        assertEquals(StressDensityState.INSUFFICIENT, StressEngine.classify(density, spec.params))
        assertEquals(StressAbsenceReason.NOT_ENOUGH_WAKING_COVERAGE, StressEngine.absenceReason(density, spec.params))
    }

    @Test fun absenceReasonsAreSpecific() {
        val none = StressEngine.measureDensity(buckets(7, samplesPerDay = 0, hoursPerDay = 16.0), spec.params)
        assertEquals(StressAbsenceReason.NO_DAYTIME_HRV, StressEngine.absenceReason(none, spec.params))
        // The headline case: a watch-class wearable — a couple of daytime readings a day.
        val watch = StressEngine.measureDensity(buckets(7, samplesPerDay = 2, hoursPerDay = 16.0), spec.params)
        assertEquals(14.0 / 112.0, watch.samplesPerHour, 1e-9)
        assertEquals(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE, StressEngine.absenceReason(watch, spec.params))
    }

    /** The whole point, end to end: a watch-only week is HIDDEN, not softened into a number. */
    @Test fun watchOnlyWeekIsHidden() {
        val surface = StressEngine.evaluate(varyingBuckets(28, samplesPerDay = 2), spec.params)
        assertEquals(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE, surface.absenceReason)
        assertNull(surface.trend)
    }

    // --- Honest absence is a shipped state, with rendered copy ---

    @Test fun everyAbsenceReasonRendersBilingualCopy() {
        for (reason in StressAbsenceReason.entries) {
            assertFalse("$reason has no English explanation", reason.explanation.en.isEmpty())
            assertFalse("$reason has no Arabic explanation", reason.explanation.ar.isEmpty())
            assertNotEquals(reason.explanation.en, reason.explanation.ar)
            assertTrue(
                "$reason's Arabic copy is not in Arabic script",
                reason.explanation.ar.any { it.code in 0x0600..0x06FF },
            )
        }
    }

    /** The sparse-device explanation is a fact about the DEVICE, not a complaint about the user. */
    @Test fun sparseExplanationIsAboutTheDeviceNotTheUser() {
        val copy = StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE.explanation
        assertTrue(copy.en.lowercase().contains("your device"))
        assertTrue(copy.ar.contains("جهازك"))
        for (banned in listOf("you didn't", "you did not", "you failed", "you need to", "error", "unavailable", "sorry", "wear your")) {
            assertFalse("device copy blames the user or reads as an error: $banned", copy.en.lowercase().contains(banned))
        }
    }

    @Test fun absenceCopyIsWellnessSafe() {
        val bannedEn = listOf(
            "you may have", "signs of", "abnormal", "diagnos", "disease", "stressed out",
            "do not", "don't ", "stop ", "risk", "warning", "danger", "urgent", "anxiety", "burnout",
        )
        val bannedAr = listOf("تشخيص", "مرض", "خطر", "توقف", "تحذير", "عاجل", "قلق")
        for (reason in StressAbsenceReason.entries) {
            val en = reason.explanation.en.lowercase()
            for (phrase in bannedEn) {
                assertFalse("$reason: \"${reason.explanation.en}\" contains banned frame \"$phrase\"", en.contains(phrase))
            }
            for (phrase in bannedAr) {
                assertFalse("$reason Arabic contains banned frame \"$phrase\"", reason.explanation.ar.contains(phrase))
            }
        }
    }

    /** The copy is authored identically on both platforms — one wording, two mirrors. */
    @Test fun absenceCopyMatchesTheIosWording() {
        assertEquals(
            "Your device doesn't record daytime heart-rate variability often enough for this.",
            StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE.explanation.en,
        )
        assertEquals(
            "Still learning your usual daytime pattern — this needs a few more weeks of readings.",
            StressAbsenceReason.STILL_LEARNING_DAYTIME_PATTERN.explanation.en,
        )
    }

    // --- No state can emit a live index ---

    @Test fun denseStateStillYieldsADailyTrendAndNoLiveIndex() {
        assertFalse(
            "Phase 3 ships no intraday index; flipping this without building one would be a false claim",
            StressEngine.INTRADAY_INDEX_IMPLEMENTED,
        )
        val surface = StressEngine.evaluate(varyingBuckets(28, samplesPerDay = 96), spec.params)
        assertTrue("expected the dense state, got $surface", surface is StressSurface.Dense)
        val trend = surface.trend!!
        assertEquals(StressDensityState.DENSE, trend.densityState)
        assertEquals("a trend describes a window, never a moment", spec.params.trendWindowDays, trend.windowDays)
        assertEquals("2026-01-28", trend.dayKey)
        assertTrue(
            "the cap is state-dependent: dense data is not held to the moderate ceiling",
            trend.confidence > spec.params.moderateConfidenceCap,
        )
        assertTrue(trend.confidence <= spec.params.denseConfidenceCap)
    }

    // --- Trend math goldens (identical to StressEngineTests.swift) ---

    @Test fun dailyLoadGoldens() {
        val p = spec.params
        // A reference with logMad = 0.1 makes the z arithmetic exact: z = (ln v − ln 50) / (1.4826·0.1).
        val reference = StressReference(ln(50.0), 0.1, 28)
        assertEquals(50.0, StressEngine.dailyLoad(50.0, reference, p), 1e-9)
        assertEquals(70.0, StressEngine.dailyLoad(50 * exp(-0.14826), reference, p), 1e-9)
        assertEquals(30.0, StressEngine.dailyLoad(50 * exp(0.14826), reference, p), 1e-9)
        assertEquals(100.0, StressEngine.dailyLoad(50 * exp(-1.0), reference, p), 1e-9)
        assertEquals(0.0, StressEngine.dailyLoad(50 * exp(1.0), reference, p), 1e-9)
        // A perfectly flat reference cannot define a deviation — neutral, never an infinite z.
        assertEquals(50.0, StressEngine.dailyLoad(20.0, StressReference(ln(50.0), 0.0, 28), p), 1e-9)
    }

    @Test fun recencyWeightGoldens() {
        val p = spec.params // halfLife = 2 days
        assertEquals(1.0, StressEngine.recencyWeight(0.0, p), 1e-12)
        assertEquals(0.7071067811865476, StressEngine.recencyWeight(1.0, p), 1e-12)
        assertEquals(0.5, StressEngine.recencyWeight(2.0, p), 1e-12)
        assertEquals(0.25, StressEngine.recencyWeight(4.0, p), 1e-12)
        assertEquals(0.125, StressEngine.recencyWeight(6.0, p), 1e-12)
    }

    @Test fun trendValueIsARecencyWeightedMean() {
        val contributions = listOf(
            StressDayContribution("2026-01-01", 40.0, 0.0, 0.5),
            StressDayContribution("2026-01-02", 40.0, 100.0, 1.0),
        )
        assertEquals(66.66666666666667, StressEngine.trendValue(contributions), 1e-9)
        assertEquals(50.0, StressEngine.trendValue(emptyList()), 1e-9)
    }

    @Test fun bandBoundaries() {
        val p = spec.params // neutral half-width 10
        assertEquals(StressTrendBand.ABOUT_USUAL, StressEngine.band(50.0, p))
        assertEquals("exactly on the edge stays neutral", StressTrendBand.ABOUT_USUAL, StressEngine.band(60.0, p))
        assertEquals(StressTrendBand.HIGHER_THAN_USUAL, StressEngine.band(60.001, p))
        assertEquals(StressTrendBand.ABOUT_USUAL, StressEngine.band(40.0, p))
        assertEquals(StressTrendBand.LOWER_THAN_USUAL, StressEngine.band(39.999, p))
    }

    // --- Sleep-window arithmetic (the pure half of "daytime is the point") ---

    @Test fun overlappingSleepWindowsAreUnionedNotSummed() {
        val hour = 3_600_000L
        // Two devices recording the same night (both rows still live — dedup suppresses, never
        // deletes). Summed they would subtract 12 hours from the waking day; unioned they subtract 8.
        val windows = listOf(0L to 8 * hour, 1 * hour to 5 * hour)
        assertEquals(8.0 * hour, StressEngine.overlapMillis(windows, 0L, 24 * hour), 1e-9)
        // A window that runs past the day edge is clipped to the day.
        assertEquals(2.0 * hour, StressEngine.overlapMillis(listOf(22 * hour to 30 * hour), 0L, 24 * hour), 1e-9)
        assertEquals(0.0, StressEngine.overlapMillis(emptyList(), 0L, 24 * hour), 1e-9)
    }

    // --- Surface fixtures ---

    @Test fun denseButShortHistoryIsStillLearningNotADeviceComplaint() {
        val surface = StressEngine.evaluate(varyingBuckets(10, samplesPerDay = 96), spec.params)
        assertEquals(StressAbsenceReason.STILL_LEARNING_DAYTIME_PATTERN, surface.absenceReason)
        assertNull(surface.trend)
        assertFalse(StressAbsenceReason.STILL_LEARNING_DAYTIME_PATTERN.explanation.en.lowercase().contains("device"))
    }

    @Test fun moderateTrendCarriesACappedConfidence() {
        val surface = StressEngine.evaluate(varyingBuckets(28, samplesPerDay = 14), spec.params)
        assertTrue("expected the moderate state, got $surface", surface is StressSurface.Moderate)
        val trend = surface.trend!!
        assertEquals(
            "a full-coverage moderate window sits exactly at the cap, never above it",
            spec.params.moderateConfidenceCap, trend.confidence, 1e-9,
        )
        assertTrue(trend.provisional)
        assertEquals(7, trend.daysPresent)
        assertTrue(trend.value in 0.0..100.0)
        // The recent week's HRV sits below the personal reference → more load than usual.
        assertTrue(trend.value > 50.0)
        assertEquals(StressTrendBand.HIGHER_THAN_USUAL, trend.band)
    }

    @Test fun thinDaysAreGapsNotImputedValues() {
        val window = varyingBuckets(28, samplesPerDay = 96).toMutableList()
        for (i in window.size - 7 until window.size - 3) {
            window[i] = window[i].copy(daytimeHrv = listOf(50.0))
        }
        assertNotEquals(
            "the density gate still passes — this fixture isolates the per-day usability rule",
            StressDensityState.INSUFFICIENT,
            StressEngine.classify(StressEngine.measureDensity(window, spec.params), spec.params),
        )
        assertEquals(StressAbsenceReason.TOO_FEW_RECENT_DAYS, StressEngine.evaluate(window, spec.params).absenceReason)
    }

    // --- I7: the ontology classes this sensitive-plus ---

    /**
     * `stress.day_trend` is `sensitivePlus` in the metric ontology, which is what keeps it out of any
     * export that has not opted into sensitive data. Pinned so a future ontology edit cannot silently
     * downgrade an inference about someone's daily state.
     */
    @Test fun stressTrendIsSensitivePlusInTheOntology() {
        // Read the real bundled asset the same way `MetricFamilyParityTest` does — a JVM test has no
        // AssetManager, and a fixture would be one more thing that can drift from the registry it is
        // supposed to police. Unit tests run with `apps/android/app` as the working directory.
        val file = File("src/main/assets/registry.json")
        assertTrue("registry.json must be readable at ${file.absolutePath}", file.exists())
        val metric = Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
            .map { it.jsonObject }
            .first { it["metricId"]?.jsonPrimitive?.content == MetricId.stressDayTrend }
        assertEquals(
            SensitiveClass.SENSITIVE_PLUS.code,
            metric["sensitiveClass"]?.jsonPrimitive?.content,
        )
        assertEquals("score_0_100", metric["canonicalUnit"]?.jsonPrimitive?.content)
    }

    // --- Fixtures ---

    private fun buckets(days: Int, samplesPerDay: Int, hoursPerDay: Double): List<StressDayBucket> =
        (0 until days).map { d ->
            StressDayBucket("2026-01-%02d".format(d + 1), hoursPerDay, List(samplesPerDay) { 50.0 })
        }

    /**
     * A window whose older days vary around ~50 ms (so the reference has a real spread) and whose last
     * seven days sit lower (so the trend has a direction to report). Mirrors the iOS fixture exactly.
     */
    private fun varyingBuckets(days: Int, samplesPerDay: Int): List<StressDayBucket> =
        (0 until days).map { d ->
            val value = if (d >= days - 7) 38.0 else listOf(45.0, 50.0, 55.0)[d % 3]
            StressDayBucket("2026-01-%02d".format(d + 1), 16.0, List(samplesPerDay) { value })
        }
}
