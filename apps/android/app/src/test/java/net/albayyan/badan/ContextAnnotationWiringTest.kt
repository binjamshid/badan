package net.albayyan.badan

import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.derivation.ReadinessComputation
import net.albayyan.badan.domain.derivation.ReadinessResult
import net.albayyan.badan.domain.derivation.ReadinessVariant
import net.albayyan.badan.domain.derivation.StressDensity
import net.albayyan.badan.domain.derivation.StressDensityState
import net.albayyan.badan.domain.derivation.StressSurface
import net.albayyan.badan.domain.derivation.StressTrend
import net.albayyan.badan.domain.derivation.StressTrendBand
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.domain.journal.ContextAnnotation
import net.albayyan.badan.domain.journal.ContextAnnotationResolver
import net.albayyan.badan.domain.journal.ContextAnnotator
import net.albayyan.badan.domain.journal.ContextCaveats
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.ContextStatusKind
import net.albayyan.badan.domain.journal.NO_CONTEXT_ANNOTATIONS
import net.albayyan.badan.features.healthmonitor.StressPresentation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-29 — the Android half of "a `ContextStatus` annotates confidence and copy, never the stored
 * value" (plan §18), and the parity anchor for the iOS `ContextAnnotationWiringTests`.
 *
 * Scope, stated honestly (the rule `JournalTest` and `StressEngineGoldenTest` already follow): this
 * module has no `androidTest` source set and no Robolectric, so nothing here opens a real SQLite
 * database. The DB-backed halves — a readiness row actually landing with a capped confidence, a
 * re-annotated day APPENDING under I2, `stress.day_trend` rows written by `DerivationCoordinator`,
 * and a hidden day writing nothing — run on iOS against a real connection.
 *
 * What IS verifiable on the JVM is pinned here, and it is the part that must be byte-identical
 * across platforms: the ceiling arithmetic every engine funnels its confidence through, the fact
 * that the value travels beside it untouched, the day-window resolution the caveat read model uses,
 * and the caveat reaching the surface copy.
 */
class ContextAnnotationWiringTest {
    private val tz = "UTC"
    private val format = ValueFormatter(CustomizationProfile(), MetricRegistry(emptyList()))

    /** A resolver that declares [kind] over the whole of time — the composition root's shape, faked. */
    private fun alwaysDeclared(kind: ContextStatusKind): ContextAnnotationResolver = { from, to ->
        ContextAnnotator.annotation(from, to, listOf(status(kind, startAt = 0L)))
    }

    private fun status(kind: ContextStatusKind, startAt: Long, endAt: Long? = null) = ContextStatus(
        id = "C-${kind.code}",
        statusId = kind.code,
        startAt = startAt,
        endAt = endAt,
        tzId = tz,
        provenance = Provenance(
            sourceId = "device", ingestionPath = IngestionPath.MANUAL, measuredAt = startAt,
            measuredTimezone = tz, recordedAt = startAt, ingestedAt = startAt,
        ),
        updatedAt = startAt,
        originDeviceId = "device",
    )

    private fun computation(score: Double, confidence: Double) = ReadinessComputation(
        score = score, confidence = confidence, provisional = true,
        variant = ReadinessVariant.Full, contributions = emptyList(),
    )

    // MARK: - The ceiling, and the value beside it

    /**
     * The acceptance property, stated on the type the engine persists from: a declared period lowers
     * the confidence that goes on the row and leaves the score exactly where it was.
     */
    @Test
    fun `a declared period lowers the published confidence and never the score`() {
        val plain = ReadinessResult("2026-07-21", computation(64.0, 1.0))
        val annotated = ReadinessResult(
            "2026-07-21", computation(64.0, 1.0),
            ContextAnnotator.annotation(0L, 1L, listOf(status(ContextStatusKind.TRAVEL, 0L))),
        )

        assertEquals(64.0, plain.computation.score, 1e-9)
        assertEquals(64.0, annotated.computation.score, 1e-9)
        assertEquals(
            "the score is the invariant — a declared context may never move it",
            plain.computation.score, annotated.computation.score, 0.0,
        )
        assertEquals(1.0, plain.publishedConfidence, 1e-9)
        assertEquals(
            ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, annotated.publishedConfidence, 1e-9,
        )
        assertTrue(annotated.publishedConfidence < plain.publishedConfidence)
    }

    /**
     * `applyingTo` is a CEILING, not a replacement: a score already less confident than the ceiling
     * keeps its own lower number rather than being lifted to 0.7 by a context being active.
     */
    @Test
    fun `a context never raises an already lower confidence`() {
        val annotation = ContextAnnotator.annotation(0L, 1L, listOf(status(ContextStatusKind.ILLNESS, 0L)))
        val result = ReadinessResult("2026-07-21", computation(58.0, 0.5), annotation)
        assertEquals(0.5, result.publishedConfidence, 1e-9)
        assertEquals(0.5, annotation.applyingTo(0.5)!!, 1e-9)
        assertEquals(0.7, annotation.applyingTo(0.9)!!, 1e-9)
    }

    /** Two declared periods over one day cap once, not twice — uncertainty does not compound. */
    @Test
    fun `overlapping periods do not compound the ceiling`() {
        val both = ContextAnnotator.annotation(
            0L, 1L,
            listOf(status(ContextStatusKind.TRAVEL, 0L), status(ContextStatusKind.ILLNESS, 0L)),
        )
        assertEquals(ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, both.confidenceCeiling, 1e-9)
        assertEquals(2, both.caveats.size)
    }

    /** No declared period means no annotation at all — the ordinary day, and the default wiring. */
    @Test
    fun `an engine with no resolver wired annotates nothing`() {
        val none = NO_CONTEXT_ANNOTATIONS(0L, 1L)
        assertTrue(none.isEmpty)
        assertEquals(1.0, none.confidenceCeiling, 1e-9)
        assertEquals(0.42, none.applyingTo(0.42)!!, 1e-9)
        assertEquals(1.0, ReadinessResult("2026-07-21", computation(64.0, 1.0)).publishedConfidence, 1e-9)
    }

    // MARK: - The caveat read model

    /**
     * The display half asks over the LOCAL DAY the value is attributed to — the same day-attribution
     * rule the engines score by — and returns the very sentence the context manager previews on the
     * card before the tap, in both languages.
     */
    @Test
    fun `the surface caveat is the same sentence the manager previews`() {
        val day = DayAttribution.dateFromDayKey("2026-07-21", tz)!!
        val caveats = ContextCaveats.forDay(day, tz, alwaysDeclared(ContextStatusKind.TRAVEL))
        assertEquals(1, caveats.size)
        assertEquals(ContextStatusKind.TRAVEL.caveat.en, caveats[0].en)
        assertEquals(ContextStatusKind.TRAVEL.caveat.ar, caveats[0].ar)
        assertTrue("real Arabic, not a placeholder", caveats[0].ar.contains("سفرك"))
        assertFalse(caveats[0].en == caveats[0].ar)
    }

    /** The window handed to the resolver is exactly `[dayStart, nextDayStart)`, half-open. */
    @Test
    fun `the caveat window is the local day the value belongs to`() {
        val day = DayAttribution.dateFromDayKey("2026-07-21", tz)!!
        var asked: Pair<Long, Long>? = null
        val probe: ContextAnnotationResolver = { from, to ->
            asked = from to to
            ContextAnnotation.NONE
        }
        ContextCaveats.forDay(day, tz, probe)
        assertEquals(DayAttribution.startOfDay(day, tz), asked!!.first)
        assertEquals(DayAttribution.addingDays(1, DayAttribution.startOfDay(day, tz), tz), asked!!.second)
    }

    /** A period key that is not a local day resolves to no caveats rather than to a guessed day. */
    @Test
    fun `a non-day period key resolves to no caveats`() {
        val resolver = alwaysDeclared(ContextStatusKind.TRAVEL)
        assertTrue(ContextCaveats.forPeriodKey("session:01ABC", tz, resolver).isEmpty())
        assertTrue(ContextCaveats.forPeriodKey("2026-07-21", tz, resolver).isEmpty())
        assertFalse(ContextCaveats.forPeriodKey("day:2026-07-21", tz, resolver).isEmpty())
    }

    /** An ordinary day renders nothing — silent, not an empty placeholder. */
    @Test
    fun `an ordinary day carries no caveat`() {
        val day = DayAttribution.dateFromDayKey("2026-07-21", tz)!!
        assertTrue(ContextCaveats.forDay(day, tz, NO_CONTEXT_ANNOTATIONS).isEmpty())
    }

    // MARK: - The caveat on a score surface

    /**
     * The stress card reads the caveat out LAST, as the frame the reading should be taken in. This is
     * what makes "adds a note beside them" true on a surface the user actually meets.
     */
    @Test
    fun `the stress card speaks the caveat after the reading`() {
        val trend = StressTrend(
            dayKey = "2026-07-21", value = 62.0, band = StressTrendBand.HIGHER_THAN_USUAL,
            confidence = 0.4, provisional = true, densityState = StressDensityState.MODERATE,
            density = StressDensity(0.62, 44, 71.0, 6, 7),
            daysPresent = 5, windowDays = 7, contributions = emptyList(),
        )
        val caveat = ContextStatusKind.TRAVEL.caveat
        for (language in listOf(AppLanguage.EN, AppLanguage.AR)) {
            val spoken = StressPresentation.spokenLabel(
                StressSurface.Moderate(trend), DepthPolicy.CASUAL, language, format, tz, listOf(caveat),
            )
            assertTrue(spoken.endsWith(caveat.resolved(language)))
        }
        // Without a declared period the card says nothing extra at all.
        val plain = StressPresentation.spokenLabel(
            StressSurface.Moderate(trend), DepthPolicy.CASUAL, AppLanguage.EN, format, tz,
        )
        assertFalse(plain.contains(caveat.en))
    }

    /** The stored-history line names how many days were actually KEPT, gaps and all. */
    @Test
    fun `the stress history note discloses the days actually saved`() {
        val en = StressPresentation.historyNote(9, AppLanguage.EN, format)
        assertTrue(en.contains("9 days"))
        assertTrue("gaps are disclosed, never filled", en.contains("left out"))
        val ar = StressPresentation.historyNote(9, AppLanguage.AR, format)
        assertTrue(ar.contains("9 أيام"))
        assertFalse(ar == en)
    }
}
