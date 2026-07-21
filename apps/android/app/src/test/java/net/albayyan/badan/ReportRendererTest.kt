package net.albayyan.badan

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Numerals
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportModel
import net.albayyan.badan.domain.reports.ReportPeriod
import net.albayyan.badan.domain.reports.ReportPresentation
import net.albayyan.badan.export.ReportRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-31 — the report renderer. Model snapshots are covered in [ReportBuilderTest]; here the concern
 * is the shareable artifact: the Arabic document must be RTL, both languages must carry the evidence
 * refs, and an empty week must render an honest message rather than a fabricated or crashing one.
 * Mirror of iOS `ReportRendererTests`.
 *
 * Scope, stated honestly: this module has no Robolectric and no `androidTest` source set, so
 * [ReportRenderer.renderPdf] — which needs `android.graphics` — cannot rasterize a page here, and
 * nothing below claims it does. What IS asserted is the pure stage the PDF stage draws from: the
 * document's direction flag, its ordered content, and the evidence ids it carries. Direction is the
 * only input `renderPdf` uses to decide RTL (it feeds `TextDirectionHeuristics.RTL` into every
 * `StaticLayout`), so pinning it here pins what the PDF will do; glyph order itself is Android's text
 * stack and is verified on device, not on the JVM. The iOS suite renders real PDF bytes for both
 * languages.
 */
class ReportRendererTest {

    private val tz = "UTC"
    private val now = 1_784_000_000_000L // 2026-07-14 03:33 UTC, ISO 2026-W29

    private fun model(empty: Boolean = false): ReportModel {
        val period = ReportPeriod.week(now, tz)
        val prior = ReportPeriod.prior(period, tz)
        if (empty) {
            return ReportBuilder.build(
                ReportBuilder.Inputs(
                    period = period, prior = prior, currentByMetric = emptyMap(),
                    priorByMetric = emptyMap(), adherence = emptyList(), generatedAt = now,
                ),
            )
        }
        fun dv(day: String, v: Double, id: String) = DerivedValue(
            id = id, metricId = MetricId.sleepPerformance, value = v, unit = "score_0_100",
            periodKey = "day:$day", algorithmId = "t", algorithmVersion = "1", computedAt = now,
            updatedAt = now, originDeviceId = "d",
        )
        val sleep = listOf(
            dv(period.dayKeys[0], 70.0, "ev-alpha"),
            dv(period.dayKeys[1], 80.0, "ev-beta"),
            dv(period.dayKeys[2], 90.0, "ev-gamma"),
        )
        return ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(MetricId.sleepPerformance to sleep),
                priorByMetric = emptyMap(), adherence = null, generatedAt = now,
            ),
        )
    }

    @Test fun arabicDocumentIsRtl() {
        val doc = ReportRenderer.document(model(), AppLanguage.AR, arabicDigits = true)
        assertTrue("the Arabic document must be right-to-left", doc.isRtl)
        assertEquals(AppLanguage.AR, doc.language)
    }

    @Test fun englishDocumentIsLtr() {
        val doc = ReportRenderer.document(model(), AppLanguage.EN, arabicDigits = false)
        assertTrue("the English document must not be right-to-left", !doc.isRtl)
    }

    @Test fun arabicHtmlIsRtl() {
        val html = ReportRenderer.renderHtml(model(), AppLanguage.AR, arabicDigits = true)
        assertTrue("Arabic report must be dir=rtl", html.contains("dir=\"rtl\""))
        assertTrue(html.contains("lang=\"ar\""))
        assertTrue(html.contains("direction: rtl"))
        assertTrue("Arabic section title must appear", html.contains("النوم"))
    }

    @Test fun englishHtmlIsLtr() {
        val html = ReportRenderer.renderHtml(model(), AppLanguage.EN, arabicDigits = false)
        assertTrue(html.contains("dir=\"ltr\""))
        assertTrue(html.contains("lang=\"en\""))
        assertTrue(html.contains("Sleep"))
    }

    @Test fun htmlCarriesEvidenceRefs() {
        val html = ReportRenderer.renderHtml(model(), AppLanguage.EN, arabicDigits = false)
        for (id in listOf("ev-alpha", "ev-beta", "ev-gamma")) {
            assertTrue("evidence ref $id must be present in the artifact", html.contains(id))
        }
        assertTrue(html.contains("data-evidence"))
    }

    /** Every claim in the rendered document names the rows it rests on — in both languages. */
    @Test fun everyClaimCarriesItsEvidenceInBothLanguages() {
        for (language in listOf(AppLanguage.EN, AppLanguage.AR)) {
            val doc = ReportRenderer.document(model(), language, arabicDigits = language == AppLanguage.AR)
            val narratives = doc.blocks.count { it is ReportRenderer.Block.Narrative }
            val evidence = doc.blocks.filterIsInstance<ReportRenderer.Block.Evidence>()
            assertTrue("$language: expected at least one claim", narratives > 0)
            assertEquals("$language: every claim needs an evidence line", narratives, evidence.size)
            assertEquals(
                "$language: evidence must name the real rows",
                listOf("ev-alpha", "ev-beta", "ev-gamma"),
                evidence.flatMap { it.ids },
            )
        }
    }

    @Test fun documentIsSelfContainedAndOffline() {
        val html = ReportRenderer.renderHtml(model(), AppLanguage.EN, arabicDigits = false)
        for (token in listOf("<img", "<script", "<link", "http://", "https://")) {
            assertTrue("a report artifact must reference nothing external, found $token", !html.contains(token))
        }
    }

    @Test fun emptyWeekShowsHonestMessage() {
        val en = ReportRenderer.renderHtml(model(empty = true), AppLanguage.EN, arabicDigits = false)
        assertTrue(en.contains("Not enough logged this week"))
        val ar = ReportRenderer.renderHtml(model(empty = true), AppLanguage.AR, arabicDigits = true)
        assertTrue(ar.contains("dir=\"rtl\""))
        assertTrue(ar.contains("لا توجد بيانات كافية"))
    }

    /** An empty week still renders a complete, titled, disclaimed document — never a blank page. */
    @Test fun emptyWeekDocumentIsStillWellFormed() {
        val doc = ReportRenderer.document(model(empty = true), AppLanguage.AR, arabicDigits = true)
        assertTrue(doc.blocks.any { it is ReportRenderer.Block.Title })
        assertTrue(doc.blocks.any { it is ReportRenderer.Block.Empty })
        assertTrue(doc.blocks.last() is ReportRenderer.Block.Disclaimer)
        assertTrue(
            "an empty week must carry no claims",
            doc.blocks.none { it is ReportRenderer.Block.Narrative },
        )
    }

    /** The disclaimer is not optional: every report, every language, says what it is and is not. */
    @Test fun everyDocumentEndsWithTheDisclaimer() {
        for (language in listOf(AppLanguage.EN, AppLanguage.AR)) {
            for (empty in listOf(false, true)) {
                val doc = ReportRenderer.document(model(empty), language, arabicDigits = false)
                val last = doc.blocks.last()
                assertTrue("$language/$empty must end with the disclaimer", last is ReportRenderer.Block.Disclaimer)
            }
        }
    }

    // MARK: - Counted nouns

    /**
     * A report counts days, records and doses, and a week's counts sit in the 3–10 band where Arabic
     * takes the plural — so the noun has to agree with the number rather than be fixed. English needs
     * the singular at 1. Mirror of iOS `testArabicCountedNounsAgreeWithTheNumber`.
     */
    @Test fun arabicCountedNounsAgreeWithTheNumber() {
        fun days(n: Int) = ReportPresentation.dayCount(n, AppLanguage.AR, arabicDigits = false)
        assertEquals("يوم واحد", days(1))
        assertEquals("يومين", days(2)) // the dual needs no numeral
        assertEquals("7 أيام", days(7)) // a full week — the common case
        assertEquals("11 يوماً", days(11))

        assertEquals("5 سجلات", ReportPresentation.recordCount(5, AppLanguage.AR, arabicDigits = false))
        assertEquals("30 سجلاً", ReportPresentation.recordCount(30, AppLanguage.AR, arabicDigits = false))
        assertEquals("4 جرعات", ReportPresentation.doseCount(4, AppLanguage.AR, arabicDigits = false))
        assertEquals("3 أقسام", ReportPresentation.sectionCount(3, AppLanguage.AR, arabicDigits = false))
    }

    @Test fun englishCountedNounsAreSingularAtOne() {
        assertEquals("1 day", ReportPresentation.dayCount(1, AppLanguage.EN, arabicDigits = false))
        assertEquals("7 days", ReportPresentation.dayCount(7, AppLanguage.EN, arabicDigits = false))
        assertEquals("1 record", ReportPresentation.recordCount(1, AppLanguage.EN, arabicDigits = false))
        assertEquals("1 dose", ReportPresentation.doseCount(1, AppLanguage.EN, arabicDigits = false))
    }

    /**
     * The counted-noun path formats its number through `Numerals`, so the profile's digit preference
     * reaches a report's copy instead of being bypassed by a raw interpolation. (Which glyphs
     * `Numerals` chooses is its own contract, and differs by platform locale data — this asserts the
     * wiring, not the digit shapes.)
     */
    @Test fun countedNounFormatsItsNumberThroughNumerals() {
        val expected = Numerals.format(3.0, AppLanguage.AR, arabicDigits = true)
        assertEquals(
            "استناداً إلى $expected سجلات",
            ReportPresentation.evidenceCountPhrase(3, AppLanguage.AR, arabicDigits = true),
        )
    }
}
