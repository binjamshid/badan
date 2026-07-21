package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.InsightTemplate
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.derivation.CorrelationFinding
import net.albayyan.badan.domain.derivation.CorrelationOutcome
import net.albayyan.badan.domain.derivation.CorrelationRenderer
import net.albayyan.badan.domain.derivation.CorrelationSpec
import net.albayyan.badan.domain.derivation.CorrelationSuppression
import net.albayyan.badan.domain.derivation.CorrelationSuppressionReason
import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.features.insights.CorrelationsPresentation
import net.albayyan.badan.features.insights.CorrelationsReadModel
import net.albayyan.badan.features.insights.CorrelationsStrings
import net.albayyan.badan.features.insights.correlationSpec
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.BehaviorDefinition
import net.albayyan.badan.ontology.BehaviorDictionary
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.ontology.MetricRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * EPIC-29 — the correlations surface's PURE presentation logic, and the Android mirror of the iOS
 * `CorrelationSurfacesTests` scope.
 *
 * `CorrelationEngineGoldenTest` already pins the statistics and the rendered copy. What is pinned
 * HERE is the layer that could quietly undo them without touching a number: the ordering (a list
 * sorted by effect size reads as a feed of hits), the confidence word (the casual altitude's whole
 * quantitative vocabulary), the spoken forms, and the fact that a suppressed pair has no numbers to
 * show at ANY altitude.
 */
class CorrelationPresentationTest {

    private val spec: CorrelationSpec = CorrelationSpec.load(AlgorithmRegistry.fromClasspath())
    private val params get() = spec.params

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val templatesFile = File("../../../packages/contracts/insights/templates.json")
    private val lenient = Json { ignoreUnknownKeys = true }

    private val templates: InsightTemplateStore by lazy {
        assertTrue("templates.json must be readable at ${templatesFile.absolutePath}", templatesFile.exists())
        val root = Json.parseToJsonElement(templatesFile.readText()).jsonObject
        InsightTemplateStore(
            root["templates"]!!.jsonArray.map { lenient.decodeFromJsonElement(InsightTemplate.serializer(), it) },
        )
    }

    /** A tiny dictionary whose English names deliberately sort against the insertion order. */
    private val behaviors = BehaviorDictionary(
        listOf(
            behavior("nap", "Nap", "قيلولة"),
            behavior("alcohol", "Alcohol", "الكحول"),
            behavior("caffeine", "Caffeine", "الكافيين"),
            behavior("screen_in_bed", "Screen in bed", "شاشة في السرير"),
        ),
    )
    private val registry = MetricRegistry(emptyList())

    private fun behavior(id: String, en: String, ar: String) = BehaviorDefinition(
        id = id, nameEn = en, nameAr = ar, valueKind = BehaviorValueKind.BOOLEAN,
        category = "stimulants", sensitiveClass = SensitiveClass.SENSITIVE_PLUS,
    )

    private val arabicLetters = Regex("[\\u0600-\\u06FF]")

    private fun assertRealArabic(label: String, s: LocalizedString) {
        assertTrue("$label must have English copy", s.en.isNotBlank())
        assertTrue("$label must have Arabic copy", s.ar.isNotBlank())
        assertTrue("$label Arabic must be Arabic script", arabicLetters.containsMatchIn(s.ar))
        assertNotEquals("$label must be translated, not duplicated", s.en, s.ar)
    }

    // --- Fixtures ---

    private fun finding(
        behaviorId: String,
        delta: Double,
        ciLow: Double,
        ciHigh: Double,
        confidence: Double,
        nObserved: Int = 24,
        contextDays: Int = 0,
        scoreId: String = MetricId.readinessScore,
    ): CorrelationOutcome = CorrelationOutcome.Finding(
        CorrelationFinding(
            behaviorId = behaviorId, scoreId = scoreId,
            nObserved = nObserved, nWith = nObserved / 2, nWithout = nObserved - nObserved / 2,
            delta = delta, ciLow = ciLow, ciHigh = ciHigh,
            medianWith = 60.0, medianWithout = 62.0, contextDays = contextDays,
            confidence = confidence, provisional = true,
            firstDayKey = "2026-06-01", lastDayKey = "2026-06-24",
        ),
    )

    private fun suppressed(
        behaviorId: String,
        reason: CorrelationSuppressionReason,
        scoreId: String = MetricId.readinessScore,
    ): CorrelationOutcome = CorrelationOutcome.Suppressed(
        CorrelationSuppression(
            behaviorId = behaviorId, scoreId = scoreId,
            nObserved = 6, nWith = 2, nWithout = 4, reason = reason,
        ),
    )

    private fun build(vararg outcomes: CorrelationOutcome): CorrelationsReadModel =
        CorrelationsReadModel.build(outcomes.toList(), behaviors, registry, templates, params)

    // --- The surface reads the published contract, not a copy of it ---

    @Test fun theSurfaceResolvesTheSameSpecTheEngineDoes() {
        assertTrue("the correlations surface must resolve the published contract", correlationSpec.isLoaded)
        assertEquals(spec.params.minObservedDays, correlationSpec.params.minObservedDays)
        assertEquals(spec.params.minDaysPerArm, correlationSpec.params.minDaysPerArm)
    }

    /** The gates travel with the read model so the screen can state them as numbers. */
    @Test fun theReadModelCarriesThePublishedGates() {
        val model = build(finding("caffeine", 0.4, 0.1, 0.7, 0.5))
        assertEquals(params.minObservedDays, model.minObservedDays)
        assertEquals(params.minDaysPerArm, model.minDaysPerArm)
        assertTrue(CorrelationsStrings.gateNote.en.contains("{n}"))
        assertTrue(CorrelationsStrings.gateNote.ar.contains("{arm}"))
        assertRealArabic("gateNote", CorrelationsStrings.gateNote)
    }

    // --- Ordering ---

    @Test fun findingsAndNotYetRowsAreSeparateSections() {
        val model = build(
            suppressed("nap", CorrelationSuppressionReason.TooFewObservedDays(8)),
            finding("caffeine", 0.4, 0.1, 0.7, 0.5),
        )
        assertEquals(listOf("caffeine"), model.findings.map { it.behaviorId })
        assertEquals(listOf("nap"), model.notYet.map { it.behaviorId })
        assertFalse(model.isEmpty)
    }

    /**
     * The anti-slot-machine property. Ordering is alphabetical by behaviour name — never by effect
     * size — so the strongest-looking association does not get to lead, and a card does not move
     * under the reader's thumb between opens.
     */
    @Test fun findingsAreOrderedAlphabeticallyNotByEffectSize() {
        val model = build(
            finding("nap", delta = 0.90, ciLow = 0.70, ciHigh = 0.99, confidence = 0.90),
            finding("alcohol", delta = 0.05, ciLow = -0.30, ciHigh = 0.40, confidence = 0.10),
            finding("caffeine", delta = -0.60, ciLow = -0.85, ciHigh = -0.20, confidence = 0.50),
        )
        assertEquals(listOf("alcohol", "caffeine", "nap"), model.findings.map { it.behaviorId })
    }

    /**
     * A "no clear association" result sits among the findings, ranked by name like any other — it is
     * not demoted below the directional ones, because a list that only ever contains hits is a slot
     * machine.
     */
    @Test fun aNullResultIsRankedLikeAnyOtherFinding() {
        val model = build(
            finding("alcohol", delta = 0.70, ciLow = 0.40, ciHigh = 0.95, confidence = 0.80),
            finding("caffeine", delta = 0.02, ciLow = -0.30, ciHigh = 0.34, confidence = 0.62),
            finding("nap", delta = -0.55, ciLow = -0.80, ciHigh = -0.10, confidence = 0.55),
        )
        assertEquals(listOf("alcohol", "caffeine", "nap"), model.findings.map { it.behaviorId })
        val nullRow = model.findings.first { it.behaviorId == "caffeine" }
        assertFalse("a null result is a finding, not a suppression", nullRow.isSuppressed)
        assertTrue(nullRow.card.casualText.en.contains("No clear association"))
    }

    @Test fun theSameBehaviourAcrossScoresOrdersByScoreId() {
        val model = build(
            finding("caffeine", 0.4, 0.1, 0.7, 0.5, scoreId = MetricId.sleepPerformance),
            finding("caffeine", 0.4, 0.1, 0.7, 0.5, scoreId = MetricId.effortDay),
        )
        assertEquals(listOf(MetricId.effortDay, MetricId.sleepPerformance), model.findings.map { it.scoreId })
    }

    // --- Confidence word ---

    /**
     * The casual altitude's confidence word is a reading of the SAME number power mode prints, so the
     * two can never disagree. It is not a p-value and must never be worded as one.
     */
    @Test fun confidenceWordBandsTheSameValuePowerModePrints() {
        assertEquals(CorrelationsPresentation.ConfidenceWord.EARLY, CorrelationsPresentation.confidenceWord(0.0))
        assertEquals(CorrelationsPresentation.ConfidenceWord.EARLY, CorrelationsPresentation.confidenceWord(0.33))
        assertEquals(CorrelationsPresentation.ConfidenceWord.MODERATE, CorrelationsPresentation.confidenceWord(1.0 / 3.0))
        assertEquals(CorrelationsPresentation.ConfidenceWord.MODERATE, CorrelationsPresentation.confidenceWord(0.66))
        assertEquals(CorrelationsPresentation.ConfidenceWord.ESTABLISHED, CorrelationsPresentation.confidenceWord(2.0 / 3.0))
        assertEquals(CorrelationsPresentation.ConfidenceWord.ESTABLISHED, CorrelationsPresentation.confidenceWord(1.0))
        CorrelationsPresentation.ConfidenceWord.entries.forEach {
            assertRealArabic("confidence word ${it.name}", it.label)
        }
    }

    // --- What a below-gate row may show ---

    /**
     * Small-n suppression is a hard invariant, and this is its presentation half: there is no
     * altitude at which a below-gate pair grows numbers, because the card it was rendered into has
     * none. The casual sentence names the shortfall instead.
     */
    @Test fun suppressedCardsHaveNoNumbersAtAnyAltitude() {
        listOf(
            CorrelationSuppressionReason.TooFewObservedDays(8),
            CorrelationSuppressionReason.TooFewDaysWithBehavior(3),
            CorrelationSuppressionReason.TooFewDaysWithoutBehavior(4),
        ).forEach { reason ->
            val row = build(suppressed("caffeine", reason)).notYet.single()
            assertTrue(row.isSuppressed)
            assertNull("power mode must have nothing to show for a suppressed pair", row.card.powerText)
            assertNull("there is no confidence in a comparison that was never made", row.finding)
            assertNull(row.card.contextNote)
            assertTrue(row.card.casualText.en.isNotBlank())
            assertTrue(row.card.casualText.ar.isNotBlank())

            // ...and the spoken form cannot leak them either, at either depth.
            val spokenPower = CorrelationsPresentation.spokenCard(row, DepthPolicy.POWER, AppLanguage.EN)
            assertFalse("no effect size may be spoken for a suppressed pair", spokenPower.contains("Effect size"))
            assertTrue(spokenPower.contains("not a cause"))
        }
    }

    /**
     * The locked line is on EVERY card — the positive, the negative, the null and the suppressed
     * alike, in both languages — and it is inside the spoken label so it cannot be swiped past.
     */
    @Test fun everyRowCarriesTheAssociationNotCauseLine() {
        val model = build(
            finding("caffeine", 0.5, 0.2, 0.8, 0.5),
            finding("alcohol", -0.5, -0.8, -0.2, 0.5),
            finding("screen_in_bed", 0.05, -0.3, 0.4, 0.5),
            suppressed("nap", CorrelationSuppressionReason.TooFewObservedDays(8)),
        )
        for (row in model.findings + model.notYet) {
            assertRealArabic("${row.metricId} association-not-cause", row.card.associationNotCause)
            assertTrue(row.card.lines.contains(row.card.associationNotCause))
            for (language in AppLanguage.entries) {
                val spoken = CorrelationsPresentation.spokenCard(row, DepthPolicy.CASUAL, language)
                assertTrue(
                    "${row.metricId} must speak the locked line in ${language.code}",
                    spoken.contains(row.card.associationNotCause.resolved(language)),
                )
            }
        }
    }

    /** A finding's power line and casual sentence come from ONE card — never two renderings (D-5). */
    @Test fun bothAltitudesReadTheSameCard() {
        val row = build(finding("caffeine", 0.42, 0.11, 0.73, 0.58, nObserved = 24)).findings.single()
        val casual = row.card.casualText.resolved(AppLanguage.EN)
        val power = row.card.powerText!!.resolved(AppLanguage.EN)
        assertTrue(casual.contains("24"))
        assertTrue(power.contains("n = 24"))
        assertTrue(power.contains(CorrelationRenderer.twoDecimals(0.42)))
    }

    /** Depth changes what is SPOKEN, from the same row — casual omits the numbers, power adds them. */
    @Test fun spokenCardAddsTheNumbersOnlyAtPowerDepth() {
        val row = build(finding("caffeine", 0.42, 0.11, 0.73, 0.58)).findings.single()
        val casual = CorrelationsPresentation.spokenCard(row, DepthPolicy.CASUAL, AppLanguage.EN)
        val power = CorrelationsPresentation.spokenCard(row, DepthPolicy.POWER, AppLanguage.EN)
        assertFalse(casual.contains("Effect size"))
        assertTrue(power.contains("Effect size"))
        assertTrue("the confidence word is the casual altitude's number", casual.contains("Moderate confidence"))
    }

    /**
     * The spoken numbers use a real minus sign: a screen reader reads an ASCII hyphen as a dash or
     * skips it entirely, on the one number that carries the direction of a finding.
     */
    @Test fun spokenNumbersUseARealMinusSign() {
        assertEquals("−0.42", CorrelationsPresentation.signedNumber(-0.42))
        assertEquals("0.42", CorrelationsPresentation.signedNumber(0.42))
        val row = build(finding("alcohol", -0.42, -0.71, -0.10, 0.5)).findings.single()
        val spoken = CorrelationsPresentation.spokenPowerDetail(row.finding!!, AppLanguage.EN)
        assertTrue(spoken.contains("−0.42"))
        assertFalse(spoken.contains("-0.42"))
        assertTrue("the scale has to be named or the number means nothing", spoken.contains("minus 1 to plus 1"))
    }

    /** Declared-context days are disclosed on the card, never dropped from the comparison. */
    @Test fun contextDaysAreDisclosedOnTheCard() {
        val row = build(finding("caffeine", 0.4, 0.1, 0.7, 0.5, contextDays = 3)).findings.single()
        val note = row.card.contextNote
        assertTrue("a window overlapping a declared period must say so", note != null)
        assertTrue(note!!.resolved(AppLanguage.EN).contains("3"))
        assertTrue(
            CorrelationsPresentation.spokenCard(row, DepthPolicy.CASUAL, AppLanguage.EN)
                .contains(note.resolved(AppLanguage.EN)),
        )
    }

    // --- Copy ---

    @Test fun correlationCopyIsBilingualThroughout() {
        listOf(
            "title" to CorrelationsStrings.title,
            "subtitle" to CorrelationsStrings.subtitle,
            "findingsHeader" to CorrelationsStrings.findingsHeader,
            "notYetHeader" to CorrelationsStrings.notYetHeader,
            "emptyTitle" to CorrelationsStrings.emptyTitle,
            "emptyMessage" to CorrelationsStrings.emptyMessage,
            "openJournal" to CorrelationsStrings.openJournal,
            "methodNote" to CorrelationsStrings.methodNote,
            "sensitiveOffMessage" to CorrelationsStrings.sensitiveOffMessage,
            "openSubtitle" to CorrelationsStrings.openSubtitle,
            "unavailable" to CorrelationsStrings.unavailable,
            "loadFailed" to CorrelationsStrings.loadFailed,
        ).forEach { (label, s) -> assertRealArabic(label, s) }
    }

    /** The method note names a rank-based method and never claims a significance test. */
    @Test fun theMethodNoteDoesNotClaimATestItNeverRan() {
        val en = CorrelationsStrings.methodNote.en
        assertTrue(en.contains("rank-based"))
        assertFalse(en.contains("significan"))
        assertFalse(en.contains("p-value"))
    }
}
