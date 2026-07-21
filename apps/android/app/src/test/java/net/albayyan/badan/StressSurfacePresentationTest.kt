package net.albayyan.badan

import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.derivation.StressAbsenceReason
import net.albayyan.badan.domain.derivation.StressDensity
import net.albayyan.badan.domain.derivation.StressDensityState
import net.albayyan.badan.domain.derivation.StressEngine
import net.albayyan.badan.domain.derivation.StressSurface
import net.albayyan.badan.domain.derivation.StressTrend
import net.albayyan.badan.domain.derivation.StressTrendBand
import net.albayyan.badan.features.healthmonitor.StressPresentation
import net.albayyan.badan.features.healthmonitor.StressStrings
import net.albayyan.badan.ontology.MetricRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-34 — the stress surface's PURE presentation mapping, and the Android mirror of the iOS
 * `StressSurfacesTests` scope. `StressEngineGoldenTest` pins the gate and the trend method; this
 * pins what a VIEW is allowed to do with the three surfaces it gets.
 *
 * The property under test throughout is that nothing here can manufacture a live reading or an
 * unexplained blank: a hidden surface carries no value to draw and no density to quote, every state
 * that carries a value also carries its window, and the absence copy is a checkable statement about
 * the device.
 */
class StressSurfacePresentationTest {

    private val format = ValueFormatter(CustomizationProfile(), MetricRegistry(emptyList()))
    private val tz = "UTC"

    private val arabicLetters = Regex("[\\u0600-\\u06FF]")

    private fun assertRealArabic(label: String, s: LocalizedString) {
        assertTrue("$label must have English copy", s.en.isNotBlank())
        assertTrue("$label must have Arabic copy", s.ar.isNotBlank())
        assertTrue("$label Arabic must be Arabic script", arabicLetters.containsMatchIn(s.ar))
        assertNotEquals("$label must be translated, not duplicated", s.en, s.ar)
    }

    private fun density(samples: Int = 42, hours: Double = 112.4, days: Int = 6) = StressDensity(
        samplesPerHour = if (hours > 0) samples / hours else 0.0,
        daytimeSamples = samples, daytimeHours = hours, daysWithSamples = days, windowDays = 7,
    )

    private fun trend(
        band: StressTrendBand,
        state: StressDensityState = StressDensityState.MODERATE,
        value: Double = 55.4,
        confidence: Double = 0.42,
    ) = StressTrend(
        dayKey = "2026-07-21", value = value, band = band, confidence = confidence, provisional = true,
        densityState = state, density = density(), daysPresent = 5, windowDays = 7,
        contributions = emptyList(),
    )

    // --- Chips ---

    @Test fun bandChipsShareOneAmberAndDisambiguateByArrow() {
        assertEquals(
            ChipStatus.Above to StressStrings.bandHigher,
            StressPresentation.chipSpec(StressTrendBand.HIGHER_THAN_USUAL),
        )
        assertEquals(
            ChipStatus.Below to StressStrings.bandLower,
            StressPresentation.chipSpec(StressTrendBand.LOWER_THAN_USUAL),
        )
        assertEquals(
            ChipStatus.InBand to StressStrings.bandAbout,
            StressPresentation.chipSpec(StressTrendBand.ABOUT_USUAL),
        )
        StressTrendBand.entries.forEach { assertRealArabic("band ${it.code}", StressPresentation.chipSpec(it).second) }
    }

    /**
     * A hidden surface has nothing to draw and — by construction, not by choice — no density to
     * quote: `StressSurface.Hidden` carries only the reason, so nothing downstream can rebuild a
     * reading out of a surface that was refused.
     */
    @Test fun hiddenCarriesNothingNumericAtAll() {
        val hidden = StressSurface.Hidden(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE)
        assertNull(hidden.trend)
        assertEquals(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE, hidden.absenceReason)
    }

    @Test fun bandSentencesAreDirectionsAgainstYourOwnUsual() {
        assertEquals(
            "Your daytime load has been reading higher than your own usual.",
            StressPresentation.sentence(StressTrendBand.HIGHER_THAN_USUAL).resolved(AppLanguage.EN),
        )
        StressTrendBand.entries.forEach {
            assertRealArabic("sentence ${it.code}", StressPresentation.sentence(it))
        }
    }

    // --- The dense state still renders the daily trend ---

    /**
     * Dense density means the DATA would support an hour-by-hour view, not that BADAN computes one.
     * The note is asserted against the engine's own constant so the claim and the capability change
     * together when Phase 4 lands.
     */
    @Test fun denseSaysTheIntradayViewIsNotBuiltYet() {
        assertFalse(
            "this build computes no intraday index — if that changes, this test and the note change together",
            StressEngine.INTRADAY_INDEX_IMPLEMENTED,
        )
        assertRealArabic("intradayNote", StressStrings.intradayNote)
        val dense = StressSurface.Dense(trend(StressTrendBand.HIGHER_THAN_USUAL, StressDensityState.DENSE))
        assertEquals(StressDensityState.DENSE, dense.trend!!.densityState)
        assertEquals(7, dense.trend!!.windowDays)
    }

    // --- The window travels with the value ---

    /** The line that stops a daily trend from being read as a live number. Not power-gated. */
    @Test fun theWindowNoteSaysItIsNotRightNow() {
        val note = StressPresentation.windowNote(trend(StressTrendBand.ABOUT_USUAL), AppLanguage.EN, format, tz)
        assertTrue(note.contains("7 days"))
        assertTrue(note.contains("not a reading for right now"))
        assertRealArabic("windowNote", StressStrings.windowNote)
    }

    /**
     * Arabic counted nouns: 1 singular, 2 dual, 3–10 plural, 11+ indeclinable. The window length is
     * contract data, so the copy cannot hardcode "week" and cannot hardcode one plural form either.
     */
    @Test fun arabicDayCountsAgreeWithTheNumber() {
        assertEquals("يوم واحد", StressPresentation.dayCount(1, AppLanguage.AR, format))
        assertEquals("يومان", StressPresentation.dayCount(2, AppLanguage.AR, format))
        assertEquals("7 أيام", StressPresentation.dayCount(7, AppLanguage.AR, format))
        assertEquals("14 يوماً", StressPresentation.dayCount(14, AppLanguage.AR, format))
        assertEquals("7 days", StressPresentation.dayCount(7, AppLanguage.EN, format))
    }

    /** An unparseable day key degrades to the key itself rather than to an invented date. */
    @Test fun anUnparseableDayKeyIsNotInvented() {
        val broken = trend(StressTrendBand.ABOUT_USUAL).copy(dayKey = "not-a-day")
        assertTrue(StressPresentation.windowNote(broken, AppLanguage.EN, format, tz).contains("not-a-day"))
    }

    // --- Power lines ---

    @Test fun thePowerLineNamesTheScaleAndTheNeutralPoint() {
        val line = StressPresentation.powerLine(trend(StressTrendBand.HIGHER_THAN_USUAL), AppLanguage.EN, format)
        assertTrue("the value is rounded, never printed to decimals", line.contains("55 of 100"))
        assertTrue("50 must be named as the person's own usual", line.contains("50 is your own usual"))
        assertTrue(line.contains("0.42"))
        assertTrue(line.contains("5 of 7"))
        assertRealArabic("powerLine", StressStrings.powerLine)
    }

    @Test fun theDensityLineIsWholeHoursNotFalsePrecision() {
        val line = StressPresentation.densityLine(density(samples = 42, hours = 112.4, days = 6), AppLanguage.EN, format)
        assertTrue(line.contains("42"))
        assertTrue("waking hours are whole hours", line.contains("112"))
        assertFalse(line.contains("112.4"))
        assertTrue(line.contains(StressPresentation.twoDecimals(42 / 112.4)))
        assertRealArabic("densityLine", StressStrings.densityLine)
    }

    // --- Spoken label ---

    /** A hidden card speaks its explanation and nothing else — there is no number to read out. */
    @Test fun aHiddenCardSpeaksOnlyItsExplanation() {
        val spoken = StressPresentation.spokenLabel(
            StressSurface.Hidden(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE),
            DepthPolicy.POWER, AppLanguage.EN, format, tz,
        )
        assertTrue(spoken.contains(StressStrings.title.en))
        assertTrue(spoken.contains(StressAbsenceReason.DAYTIME_HRV_TOO_SPARSE.explanation.en))
        assertFalse("nothing numeric may be spoken for a refused surface", spoken.contains("of 100"))
    }

    /** A rendered trend always speaks its window; the numbers are added only at power depth. */
    @Test fun aTrendCardAlwaysSpeaksItsWindow() {
        val surface = StressSurface.Moderate(trend(StressTrendBand.HIGHER_THAN_USUAL))
        val casual = StressPresentation.spokenLabel(surface, DepthPolicy.CASUAL, AppLanguage.EN, format, tz)
        val power = StressPresentation.spokenLabel(surface, DepthPolicy.POWER, AppLanguage.EN, format, tz)
        assertTrue(casual.contains("not a reading for right now"))
        assertFalse(casual.contains("of 100"))
        assertTrue(power.contains("of 100"))
    }

    // --- Absence copy ---

    /**
     * Every absence is explained, in both languages, by copy owned by the engine — so there is no
     * code path that produces a hidden surface without a rendered sentence, and this file cannot
     * soften one.
     */
    @Test fun everyAbsenceReasonHasRealBilingualCopy() {
        StressAbsenceReason.entries.forEach { reason ->
            assertRealArabic("absence ${reason.code}", reason.explanation)
        }
    }

    @Test fun stressCopyIsBilingualThroughout() {
        listOf(
            "title" to StressStrings.title,
            "bandHigher" to StressStrings.bandHigher,
            "bandAbout" to StressStrings.bandAbout,
            "bandLower" to StressStrings.bandLower,
        ).forEach { (label, s) -> assertRealArabic(label, s) }
    }
}
