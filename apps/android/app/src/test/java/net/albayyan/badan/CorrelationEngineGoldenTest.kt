package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.InsightTemplate
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.derivation.CorrelationDay
import net.albayyan.badan.domain.derivation.CorrelationDirection
import net.albayyan.badan.domain.derivation.CorrelationEngine
import net.albayyan.badan.domain.derivation.CorrelationFinding
import net.albayyan.badan.domain.derivation.CorrelationMagnitude
import net.albayyan.badan.domain.derivation.CorrelationMath
import net.albayyan.badan.domain.derivation.CorrelationMetricId
import net.albayyan.badan.domain.derivation.CorrelationOutcome
import net.albayyan.badan.domain.derivation.CorrelationRenderer
import net.albayyan.badan.domain.derivation.CorrelationSpec
import net.albayyan.badan.domain.derivation.CorrelationSuppression
import net.albayyan.badan.domain.derivation.CorrelationSuppressionReason
import net.albayyan.badan.domain.journal.ContextAnnotator
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.InsightTemplateStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * EPIC-29 — the pure-JVM half of the correlation engine, and the parity anchor for the iOS
 * `CorrelationEngineTests`.
 *
 * Android has no DB-backed test harness (see `BaselineEngineGoldenTest`'s note), so the persistence
 * path — sensitive-DB placement, append-only recompute, the manifest round trip — is exercised on
 * iOS. What runs here is the part that must be byte-identical, because a gate that differs by
 * platform is not a gate and an interval that differs by platform is not an interval: the minimum-n
 * decision, Cliff's delta, the seeded bootstrap, and the rendered copy.
 *
 * The expected numbers come from `packages/fixtures/correlation/`, the same file the iOS suite
 * reads. Neither suite can see the other; both see that file.
 */
class CorrelationEngineGoldenTest {

    private val spec: CorrelationSpec = CorrelationSpec.load(AlgorithmRegistry.fromClasspath())
    private val params get() = spec.params

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val fixtureDir = File("../../../packages/fixtures/correlation")
    private val templatesFile = File("../../../packages/contracts/insights/templates.json")
    private val behaviorsFile = File("../../../packages/contracts/dictionaries/behaviors.json")
    private val lenient = Json { ignoreUnknownKeys = true }

    private val templates: InsightTemplateStore by lazy {
        assertTrue("templates.json must be readable at ${templatesFile.absolutePath}", templatesFile.exists())
        val root = Json.parseToJsonElement(templatesFile.readText()).jsonObject
        val parsed = root["templates"]!!.jsonArray.map { lenient.decodeFromJsonElement(InsightTemplate.serializer(), it) }
        InsightTemplateStore(parsed)
    }

    // --- Contract wiring ---

    @Test fun specLoadsPublishedConstants() {
        assertTrue("journal.correlation missing from the classpath algorithms.json", spec.isLoaded)
        assertEquals("journal.correlation@0.1.0", spec.algorithm.id)
        assertEquals(14, params.minObservedDays)
        assertEquals(5, params.minDaysPerArm)
        assertEquals(2000, params.bootstrapIterations)
        assertEquals(29L, params.bootstrapSeed)
        assertEquals(0.025, params.ciLowerPercentile, 1e-12)
        assertEquals(0.975, params.ciUpperPercentile, 1e-12)
        assertEquals(30.0, params.confidenceFullNDays, 1e-12)
        assertTrue(
            "the constants are unvalidated, so every row must carry provisional = true",
            params.algorithmProvisional,
        )
    }

    /**
     * The context ceiling is read from ContextAnnotator, never re-declared in the correlation params
     * block — the same rule stress.day_trend follows for madToSigma.
     */
    @Test fun contextCeilingIsNotDuplicatedIntoTheCorrelationParams() {
        val registry = AlgorithmRegistry.fromClasspath()
        assertNull(registry.param("journal.correlation", "contextConfidenceCeiling"))
        assertNull(registry.param("journal.correlation", "activeContextConfidenceCeiling"))
        assertEquals(0.7, ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, 1e-12)
    }

    /** A spec that failed to load must compute nothing rather than fall back to invented gates. */
    @Test fun unloadedSpecSuppressesEverything() {
        val empty = CorrelationSpec.load(AlgorithmRegistry(null))
        assertFalse(empty.isLoaded)
        val days = (0 until 40).map { CorrelationDay(dayKey(it), it % 2 == 0, (50 + it).toDouble()) }
        val outcome = CorrelationEngine.evaluate("caffeine", MetricId.readinessScore, days, empty)
        assertNotNull("an unloaded contract must suppress, never guess", outcome.suppressionOrNull)
    }

    // --- Metric id pattern ---

    @Test fun metricIdComposesAndParsesBackToThePair() {
        val id = CorrelationMetricId.metricId("caffeine", MetricId.readinessScore)
        assertEquals("journal.correlation.caffeine.readiness.score", id)
        val parsed = CorrelationMetricId.parse(id)!!
        assertEquals("caffeine", parsed.first)
        assertEquals("the score id keeps its own dot", "readiness.score", parsed.second)
        assertTrue(CorrelationMetricId.isCorrelationMetricId(id))
    }

    @Test fun unrelatedMetricIdsAreNotClaimedByTheFamily() {
        for (id in listOf(MetricId.readinessScore, MetricId.stressDayTrend,
                          "journal.correlation", "journal.correlation.")) {
            assertNull("$id is not a correlation finding id", CorrelationMetricId.parse(id))
            assertFalse(CorrelationMetricId.isCorrelationMetricId(id))
        }
    }

    /**
     * The parse rule splits at the first dot after the namespace, so a behaviour key containing a
     * dot would produce an id that parses back to the wrong pair. Asserted against the shipped
     * dictionary so adding such a key fails here rather than corrupting stored findings.
     */
    @Test fun everyBehaviorIdRoundTripsThroughTheIdPattern() {
        assertTrue("behaviors.json must be readable", behaviorsFile.exists())
        val behaviors = Json.parseToJsonElement(behaviorsFile.readText()).jsonObject["behaviors"]!!.jsonArray
        assertTrue(behaviors.isNotEmpty())
        for (behavior in behaviors) {
            val behaviorId = behavior.jsonObject["id"]!!.jsonPrimitive.content
            assertFalse(
                "behaviour id '$behaviorId' contains a dot — the finding id pattern splits on the " +
                    "first one, so this would parse back to the wrong pair",
                behaviorId.contains("."),
            )
            for (scoreId in MetricId.correlatedScores) {
                val parsed = CorrelationMetricId.parse(CorrelationMetricId.metricId(behaviorId, scoreId))
                assertEquals(behaviorId, parsed?.first)
                assertEquals(scoreId, parsed?.second)
            }
        }
    }

    // --- Cliff's delta and the median, hand-checkable ---

    @Test fun cliffsDeltaGoldens() {
        assertEquals(1.0, CorrelationMath.cliffsDelta(listOf(10.0, 11.0, 12.0), listOf(1.0, 2.0, 3.0)), 1e-12)
        assertEquals(-1.0, CorrelationMath.cliffsDelta(listOf(1.0, 2.0, 3.0), listOf(10.0, 11.0, 12.0)), 1e-12)
        assertEquals(
            "identical arms are exactly zero — ties count for neither side",
            0.0, CorrelationMath.cliffsDelta(listOf(1.0, 2.0, 3.0), listOf(1.0, 2.0, 3.0)), 1e-12,
        )
        assertEquals(0.0, CorrelationMath.cliffsDelta(listOf(5.0, 5.0), listOf(5.0, 5.0)), 1e-12)
        assertEquals(1.0, CorrelationMath.cliffsDelta(listOf(3.0, 4.0), listOf(1.0, 2.0)), 1e-12)
        assertEquals(0.0, CorrelationMath.cliffsDelta(listOf(3.0, 2.0), listOf(1.0, 4.0)), 1e-12)
        assertEquals(-2.0 / 6.0, CorrelationMath.cliffsDelta(listOf(1.0, 2.0, 3.0), listOf(2.0, 3.0)), 1e-12)
        assertEquals(
            "an empty arm has no comparison to make",
            0.0, CorrelationMath.cliffsDelta(emptyList(), listOf(1.0, 2.0)), 1e-12,
        )
    }

    @Test fun medianGoldens() {
        assertEquals(2.0, CorrelationMath.median(listOf(3.0, 1.0, 2.0)), 1e-12)
        assertEquals(2.5, CorrelationMath.median(listOf(4.0, 1.0, 3.0, 2.0)), 1e-12)
        assertEquals(0.0, CorrelationMath.median(emptyList()), 1e-12)
    }

    // --- Determinism ---

    /**
     * The exact words splitmix64 produces from the contract's seed, and the exact draw indices they
     * shift down to. Identical to the iOS assertion: this is where a Kotlin `shr`-instead-of-`ushr`
     * mistake would show up, and it would otherwise surface only as two platforms quietly reporting
     * different confidence intervals for the same days.
     */
    @Test fun seededGeneratorIsPinnedAndPlatformNeutral() {
        val rng = CorrelationMath.SplitMix64(29L)
        val words = (0 until 4).map { rng.next() }
        assertEquals(
            listOf(
                java.lang.Long.parseUnsignedLong("13509472508297990000"),
                java.lang.Long.parseUnsignedLong("13427402966873120026"),
                java.lang.Long.parseUnsignedLong("16265223287273912455"),
                5994361799526217112L,
            ),
            words,
        )
        val indexRng = CorrelationMath.SplitMix64(29L)
        assertEquals(
            listOf(1572709589 % 7, 1563155437 % 7, 1893521203 % 7, 697835558 % 7),
            (0 until 4).map { indexRng.index(7) },
        )
    }

    /** A correlation that changes when you reopen the app is not a finding. */
    @Test fun bootstrapIsDeterministicAcrossRepeatedRuns() {
        val with = listOf(74.0, 78.0, 71.0, 80.0, 76.0, 69.0, 77.0)
        val without = listOf(61.0, 58.0, 66.0, 55.0, 63.0, 59.0, 72.0, 57.0)
        val a = CorrelationMath.bootstrapInterval(with, without, params)
        val b = CorrelationMath.bootstrapInterval(with, without, params)
        assertEquals("identical, not merely close", a.first, b.first, 0.0)
        assertEquals(a.second, b.second, 0.0)
    }

    // --- Gates ---

    @Test fun exactlyAtTheGateProducesAFinding() {
        val outcome = CorrelationEngine.evaluate(
            "nap", MetricId.effortDay,
            days(listOf(58.0, 61.0, 55.0, 63.0, 59.0), listOf(44.0, 47.0, 41.0, 60.0, 45.0, 43.0, 48.0, 46.0, 42.0)),
            spec,
        )
        val finding = outcome.findingOrNull
        assertNotNull("n = 14 / 5 / 9 is exactly the published minimum", finding)
        assertEquals(14, finding!!.nObserved)
        assertEquals(5, finding.nWith)
        assertEquals(9, finding.nWithout)
    }

    @Test fun oneBelowTheTotalGateIsSuppressed() {
        val outcome = CorrelationEngine.evaluate(
            "nap", MetricId.effortDay,
            days(listOf(58.0, 61.0, 55.0, 63.0, 59.0), listOf(44.0, 47.0, 41.0, 49.0, 45.0, 43.0, 48.0, 46.0)),
            spec,
        )
        val suppression = outcome.suppressionOrNull
        assertNotNull("n = 13 must be suppressed, not hedged", suppression)
        assertEquals(13, suppression!!.nObserved)
        assertTrue(suppression.reason is CorrelationSuppressionReason.TooFewObservedDays)
        assertEquals("the user is told exactly how far off they are", 1, suppression.reason.moreDaysNeeded)
    }

    @Test fun oneBelowTheWithArmGateIsSuppressed() {
        val outcome = CorrelationEngine.evaluate(
            "sauna_hot_bath", MetricId.readinessScore,
            days(listOf(72.0, 70.0, 75.0, 68.0),
                 listOf(61.0, 63.0, 59.0, 65.0, 58.0, 62.0, 60.0, 64.0, 57.0, 66.0)),
            spec,
        )
        val suppression = outcome.suppressionOrNull!!
        assertEquals("enough days overall — the ARM is what fails", 14, suppression.nObserved)
        assertTrue(suppression.reason is CorrelationSuppressionReason.TooFewDaysWithBehavior)
        assertEquals(1, suppression.reason.moreDaysNeeded)
    }

    /** The near-daily-habit case: plenty of days, almost none without the behaviour. */
    @Test fun oneBelowTheWithoutArmGateIsSuppressed() {
        val outcome = CorrelationEngine.evaluate(
            "caffeine", MetricId.readinessScore,
            days(listOf(72.0, 70.0, 75.0, 68.0, 73.0, 69.0, 74.0, 71.0, 67.0, 76.0),
                 listOf(61.0, 63.0, 59.0, 65.0)),
            spec,
        )
        val suppression = outcome.suppressionOrNull!!
        assertTrue(suppression.reason is CorrelationSuppressionReason.TooFewDaysWithoutBehavior)
        assertEquals(1, suppression.reason.moreDaysNeeded)
    }

    // --- The null result ---

    /**
     * Both gates cleared, the interval straddles zero, and the honest answer is reported as a
     * finding with authored copy — not withheld, not softened into a hit.
     */
    @Test fun nullCaseIsReportedAsAFindingThatSaysNoClearAssociation() {
        val outcome = CorrelationEngine.evaluate(
            "electrolytes", MetricId.readinessScore,
            days(listOf(70.0, 64.0, 75.0, 61.0, 68.0, 73.0, 66.0),
                 listOf(72.0, 63.0, 69.0, 74.0, 65.0, 71.0, 67.0, 62.0)),
            spec,
        )
        val finding = outcome.findingOrNull
        assertNotNull("a null result is a RESULT — it must not suppress", finding)
        assertEquals(CorrelationDirection.NO_CLEAR_ASSOCIATION, finding!!.direction)
        assertTrue(finding.ciLow <= 0.0 && finding.ciHigh >= 0.0)

        val card = CorrelationRenderer.render(
            outcome, LocalizedString("Electrolytes", "أملاح معدنية"),
            LocalizedString("Readiness", "الجاهزية"), templates, params,
        )
        assertEquals("journal_correlation_none", card.templateId)
        assertTrue(card.casualText.en, card.casualText.en.lowercase().contains("no clear association"))
        assertTrue(card.casualText.ar, card.casualText.ar.contains("لا يوجد ارتباط واضح"))
        assertFalse(card.isSuppressed)
        assertNotNull("a null finding still shows its numbers", card.powerText)
    }

    /** The interval decides the direction, not the point estimate. */
    @Test fun directionFollowsTheIntervalNotThePointEstimate() {
        val finding = finding(delta = -0.4, ciLow = -0.8, ciHigh = 0.1)
        assertEquals(
            "a centre of −0.4 with an interval crossing zero is not a direction",
            CorrelationDirection.NO_CLEAR_ASSOCIATION, finding.direction,
        )
    }

    // --- Context annotation ---

    @Test fun contextDaysReduceConfidenceAndAreNeverDropped() {
        val withScores = listOf(62.0, 58.0, 66.0, 55.0, 61.0, 60.0, 57.0, 64.0, 59.0, 63.0, 56.0, 65.0, 54.0, 81.0, 53.0)
        val withoutScores = listOf(84.0, 88.0, 79.0, 91.0, 82.0, 86.0, 60.5, 90.0, 83.0, 87.0, 80.0, 89.0, 78.0, 85.0, 92.0)
        val plain = days(withScores, withoutScores)
        val annotated = plain.mapIndexed { index, day ->
            if (index < 6) day.copy(inDeclaredContext = true) else day
        }

        val clean = CorrelationEngine.evaluate("screen_in_bed", MetricId.sleepPerformance, plain, spec).findingOrNull!!
        val withContext = CorrelationEngine.evaluate("screen_in_bed", MetricId.sleepPerformance, annotated, spec)
            .findingOrNull!!

        assertEquals(6, withContext.contextDays)
        assertEquals("no day was removed", clean.nObserved, withContext.nObserved)
        assertEquals(clean.nWith, withContext.nWith)
        assertEquals(clean.nWithout, withContext.nWithout)
        assertEquals("the VALUE is untouched by context", clean.delta, withContext.delta, 0.0)
        assertEquals(clean.ciLow, withContext.ciLow, 0.0)
        assertEquals(clean.ciHigh, withContext.ciHigh, 0.0)
        assertTrue(
            "fixture must be strong enough that the cap is observable",
            clean.confidence > ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING,
        )
        assertEquals(ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING, withContext.confidence, 1e-12)

        val card = CorrelationRenderer.render(
            CorrelationOutcome.Finding(withContext), LocalizedString("Screen in bed", "شاشة في السرير"),
            LocalizedString("Sleep performance", "أداء النوم"), templates, params,
        )
        val note = card.contextNote
        assertNotNull("context must be disclosed, not silently applied", note)
        assertTrue(note!!.en, note.en.contains("6"))
        assertTrue(note.en, note.en.lowercase().contains("still counted"))
        assertTrue(note.ar, note.ar.contains("محسوبة"))
    }

    // --- Shared fixture ---

    /**
     * The same input file the iOS suite reads, and the same expected doubles, asserted to 1e-12.
     * There is nothing stochastic left to tolerate: the bootstrap is seeded from the contract, so a
     * mismatch here means a real divergence in the method, not noise.
     */
    @Test fun sharedFixtureMatchesOnThisPlatform() {
        val input = File(fixtureDir, "correlation-input-v1.json")
        val expectedFile = File(fixtureDir, "correlation-expected-v1.json")
        assertTrue("fixture must be readable at ${input.absolutePath}", input.exists())

        val cases = Json.parseToJsonElement(input.readText()).jsonObject["cases"]!!.jsonArray
        val expected = Json.parseToJsonElement(expectedFile.readText()).jsonObject["cases"]!!.jsonArray
            .associateBy { it.jsonObject["id"]!!.jsonPrimitive.content }
        assertEquals(cases.size, expected.size)
        assertTrue("the fixture set lost cases", cases.size >= 9)

        for (element in cases) {
            val case = element.jsonObject
            val id = case["id"]!!.jsonPrimitive.content
            val expect = expected[id]!!.jsonObject
            val days = case["days"]!!.jsonArray.map {
                val day = it.jsonObject
                CorrelationDay(
                    dayKey = day["dayKey"]!!.jsonPrimitive.content,
                    present = day["present"]!!.jsonPrimitive.content.toBoolean(),
                    nextDayScore = day["nextDayScore"].takeIf { v -> v != null && v != JsonNull }
                        ?.jsonPrimitive?.content?.toDouble(),
                    inDeclaredContext = day["inDeclaredContext"]?.jsonPrimitive?.content?.toBoolean() ?: false,
                )
            }
            val outcome = CorrelationEngine.evaluate(
                case["behaviorId"]!!.jsonPrimitive.content,
                case["scoreId"]!!.jsonPrimitive.content,
                days, spec,
            )
            when (expect["kind"]!!.jsonPrimitive.content) {
                "suppressed" -> {
                    val s = outcome.suppressionOrNull
                    assertNotNull("$id should be suppressed", s)
                    assertEquals("$id n", expect.int("nObserved"), s!!.nObserved)
                    assertEquals("$id nWith", expect.int("nWith"), s.nWith)
                    assertEquals("$id nWithout", expect.int("nWithout"), s.nWithout)
                    assertEquals("$id shortfall", expect.int("moreDaysNeeded"), s.reason.moreDaysNeeded)
                    assertEquals("$id reason", expect.str("reason"), reasonName(s.reason))
                }
                "finding" -> {
                    val f = outcome.findingOrNull
                    assertNotNull("$id should produce a finding", f)
                    assertEquals("$id n", expect.int("nObserved"), f!!.nObserved)
                    assertEquals("$id nWith", expect.int("nWith"), f.nWith)
                    assertEquals("$id nWithout", expect.int("nWithout"), f.nWithout)
                    assertEquals("$id delta", expect.dbl("delta"), f.delta, 1e-12)
                    assertEquals("$id ciLow", expect.dbl("ciLow"), f.ciLow, 1e-12)
                    assertEquals("$id ciHigh", expect.dbl("ciHigh"), f.ciHigh, 1e-12)
                    assertEquals("$id medianWith", expect.dbl("medianWith"), f.medianWith, 1e-12)
                    assertEquals("$id medianWithout", expect.dbl("medianWithout"), f.medianWithout, 1e-12)
                    assertEquals("$id contextDays", expect.int("contextDays"), f.contextDays)
                    assertEquals("$id confidence", expect.dbl("confidence"), f.confidence, 1e-12)
                    assertEquals("$id direction", expect.str("direction"), directionName(f.direction))
                    assertEquals("$id periodKey", expect.str("periodKey"), f.periodKey)
                }
                else -> throw AssertionError("unknown expectation kind for $id")
            }
        }
    }

    // --- The manifest round trip ---

    /**
     * The `stat:` convention round-trips: everything power mode shows is read back from what was
     * written, so the two halves cannot drift into showing an interval nobody computed. iOS asserts
     * this through the real database; here it is asserted over the pure encode/decode pair, which is
     * the part that has to agree across platforms.
     */
    @Test fun findingRoundTripsThroughTheManifestInputs() {
        val original = finding(delta = 0.62, ciLow = 0.21, ciHigh = 0.88, contextDays = 2)
        val days = days(listOf(70.0, 72.0, 68.0, 74.0, 71.0), listOf(60.0, 62.0, 58.0, 64.0, 61.0))
        val inputs = CorrelationEngine.manifestInputs(original, days)

        val restored = CorrelationFinding.from(
            metricId = original.metricId, value = original.delta, periodKey = original.periodKey,
            confidence = original.confidence, provisional = original.provisional, manifestInputs = inputs,
        )!!
        assertEquals(original.behaviorId, restored.behaviorId)
        assertEquals(original.scoreId, restored.scoreId)
        assertEquals(original.nObserved, restored.nObserved)
        assertEquals(original.nWith, restored.nWith)
        assertEquals(original.nWithout, restored.nWithout)
        assertEquals(original.ciLow, restored.ciLow, 0.0)
        assertEquals(original.ciHigh, restored.ciHigh, 0.0)
        assertEquals(original.contextDays, restored.contextDays)
        assertEquals(original.firstDayKey, restored.firstDayKey)
        assertEquals(original.lastDayKey, restored.lastDayKey)

        // `weight` carries the arm for the per-day inputs.
        val dayInputs = inputs.filterNot { it.recordId.startsWith("stat:") }
        assertEquals(days.size, dayInputs.size)
        assertEquals(5, dayInputs.count { it.weight == 1.0 })
        assertEquals(5, dayInputs.count { it.weight == 0.0 })
    }

    /**
     * The reader FAILS CLOSED: a stored row whose manifest lost its interval rebuilds to nothing,
     * never to a finding carrying a direction.
     *
     * [CorrelationFinding.direction] is decided by the interval alone, so a reader that defaulted a
     * missing bound to the point estimate would hand back `ciLow == ciHigh == delta` — asserted
     * below to read as a CONFIDENT `HIGHER` over `nObserved == 0`, indistinguishable on screen from
     * one the bootstrap actually earned. A statistical claim assembled out of missing data is the
     * worst outcome this feature has available to it, so every degraded manifest here must produce
     * null. Mirror of iOS
     * `testAFindingRebuiltWithoutItsIntervalIsRefusedRatherThanGivenADirection`.
     */
    @Test fun aFindingRebuiltWithoutItsIntervalIsRefused() {
        val original = finding(delta = 0.62, ciLow = 0.21, ciHigh = 0.88)
        val complete = CorrelationEngine.manifestInputs(original, emptyList())

        fun rebuild(inputs: List<InputManifest.Input>) =
            CorrelationFinding.from(
                metricId = original.metricId, value = original.delta, periodKey = original.periodKey,
                confidence = original.confidence, provisional = original.provisional,
                manifestInputs = inputs,
            )

        // The hazard, stated as an assertion rather than as a comment: an interval collapsed onto
        // the point estimate IS a confident direction.
        assertEquals(
            "this is the fabricated result the reader must never produce",
            CorrelationDirection.HIGHER,
            finding(delta = 0.62, ciLow = 0.62, ciHigh = 0.62).direction,
        )

        // Intact, it rebuilds and keeps the direction the bootstrap earned.
        val intact = rebuild(complete)!!
        assertEquals(CorrelationDirection.HIGHER, intact.direction)
        assertEquals(0.21, intact.ciLow, 0.0)
        assertEquals(0.88, intact.ciHigh, 0.0)

        fun without(vararg recordIds: String) = complete.filterNot { it.recordId in recordIds }
        fun replacing(recordId: String, value: Double) =
            complete.map { if (it.recordId == recordId) it.copy(value = value) else it }

        val refused: List<Pair<String, List<InputManifest.Input>>> = listOf(
            "no statistics at all" to emptyList(),
            "lower bound missing" to without("stat:ci_low"),
            "upper bound missing" to without("stat:ci_high"),
            "both bounds missing" to without("stat:ci_low", "stat:ci_high"),
            "undecodable lower bound" to replacing("stat:ci_low", Double.NaN),
            "infinite upper bound" to replacing("stat:ci_high", Double.POSITIVE_INFINITY),
            "bounds the wrong way round" to replacing("stat:ci_low", 0.95),
            "sample size missing" to without("stat:n"),
            "undecodable sample size" to replacing("stat:n", Double.NaN),
        )
        for ((label, inputs) in refused) {
            assertNull("$label: must rebuild nothing rather than a finding with a direction", rebuild(inputs))
        }
    }

    // --- Copy ---

    /** The one rule with no exceptions, over every outcome the engine can produce. */
    @Test fun everyRenderedCardCarriesTheAssociationNotCauseLine() {
        val locked = templates.template(CorrelationRenderer.LOCKED_TEMPLATE_ID)!!
        assertEquals(
            "the fallback must stay verbatim-equal to the contract copy",
            CorrelationRenderer.ASSOCIATION_NOT_CAUSE_FALLBACK.en, locked.textEn,
        )
        assertEquals(CorrelationRenderer.ASSOCIATION_NOT_CAUSE_FALLBACK.ar, locked.textAr)

        for (outcome in everyOutcomeShape()) {
            val card = CorrelationRenderer.render(
                outcome, LocalizedString("Caffeine", "الكافيين"),
                LocalizedString("Readiness", "الجاهزية"), templates, params,
            )
            assertEquals(locked.textEn, card.associationNotCause.en)
            assertEquals(locked.textAr, card.associationNotCause.ar)
            assertTrue(
                "the locked line must be one of the rendered lines for ${card.templateId}",
                card.lines.contains(card.associationNotCause),
            )
            assertTrue(card.associationNotCause.en.lowercase().contains("not a cause"))
            assertTrue(card.associationNotCause.ar.contains("وليس سببًا"))
        }
    }

    @Test fun suppressionCopyNamesTheShortfallAndShowsNoNumbers() {
        val cases = listOf(
            CorrelationSuppressionReason.TooFewObservedDays(3) to "journal_correlation_needs_days",
            CorrelationSuppressionReason.TooFewDaysWithBehavior(2) to "journal_correlation_needs_with_days",
            CorrelationSuppressionReason.TooFewDaysWithoutBehavior(4) to "journal_correlation_needs_without_days",
        )
        for ((reason, templateId) in cases) {
            val outcome = CorrelationOutcome.Suppressed(
                CorrelationSuppression("caffeine", MetricId.readinessScore, 12, 3, 9, reason),
            )
            val card = CorrelationRenderer.render(
                outcome, LocalizedString("Caffeine", "الكافيين"),
                LocalizedString("Readiness", "الجاهزية"), templates, params,
            )
            assertEquals(templateId, card.templateId)
            assertTrue(card.isSuppressed)
            assertNull("a suppressed pair has no statistics — showing any would be the leak", card.powerText)
            assertTrue(card.casualText.en, card.casualText.en.contains(reason.moreDaysNeeded.toString()))
            assertTrue(card.casualText.ar, card.casualText.ar.contains(reason.moreDaysNeeded.toString()))
            assertFalse("unfilled placeholder in $templateId", card.casualText.en.contains("{"))
            assertFalse("unfilled placeholder in $templateId (ar)", card.casualText.ar.contains("{"))
        }
    }

    /** Power mode shows the numbers from the SAME finding the casual sentence is built from (D-5). */
    @Test fun powerModeShowsTheNumbersFromTheSameComputation() {
        val outcome = CorrelationEngine.evaluate(
            "wind_down", MetricId.readinessScore,
            days(listOf(74.0, 78.0, 71.0, 80.0, 76.0, 69.0, 77.0),
                 listOf(61.0, 58.0, 66.0, 55.0, 63.0, 59.0, 72.0, 57.0)),
            spec,
        )
        val f = outcome.findingOrNull!!
        val card = CorrelationRenderer.render(
            outcome, LocalizedString("Wind-down", "روتين تهدئة"),
            LocalizedString("Readiness", "الجاهزية"), templates, params,
        )
        val power = card.powerText!!
        for (expected in listOf(
            f.nObserved.toString(), f.nWith.toString(), f.nWithout.toString(),
            CorrelationRenderer.twoDecimals(f.delta), CorrelationRenderer.twoDecimals(f.ciLow),
            CorrelationRenderer.twoDecimals(f.ciHigh), params.bootstrapIterations.toString(),
        )) {
            assertTrue("power line is missing $expected: ${power.en}", power.en.contains(expected))
            assertTrue("Arabic power line is missing $expected: ${power.ar}", power.ar.contains(expected))
        }
        assertTrue(card.casualText.en.contains(f.nObserved.toString()))
    }

    @Test fun correlationTemplatesAreBilingualAndComplete() {
        val correlationTemplates = templates.templates.filter { it.templateId.startsWith("journal_correlation_") }
        assertEquals("the nine EPIC-29 templates", 9, correlationTemplates.size)
        val known = setOf("behavior", "score", "n", "nWith", "nWithout", "days",
                          "delta", "ciLow", "ciHigh", "confidence", "iterations")
        for (template in correlationTemplates) {
            assertEquals("journal", template.metricFamily)
            assertTrue("${template.templateId} has no English", template.textEn.isNotBlank())
            assertTrue("${template.templateId} has no Arabic", template.textAr.isNotBlank())
            assertNotEquals("${template.templateId} is untranslated", template.textEn, template.textAr)
            assertTrue(
                "${template.templateId}'s Arabic is not in Arabic script",
                template.textAr.any { it.code in 0x0600..0x06FF },
            )
            assertTrue("${template.templateId} documents no condition", template.conditionEn.isNotBlank())
            for (text in listOf(template.textEn, template.textAr)) {
                for (token in placeholders(text)) {
                    assertTrue(
                        "${template.templateId} uses {$token}, which the renderer never fills",
                        known.contains(token),
                    )
                }
            }
        }
    }

    /**
     * The wellness lint, over every string this feature can put on screen. Causal verbs are the
     * specific hazard: a correlation surface is where "caused" gets written by accident.
     */
    @Test fun correlationCopyIsWellnessSafe() {
        val bannedEn = listOf("causes", "caused by", "because of", "proves", "leads to", "you should",
                              "you must", "stop ", "avoid ", "risk", "danger", "abnormal", "diagnos",
                              "disease", "unhealthy", "bad for you", "harmful", "significant")
        val bannedAr = listOf("يسبب", "بسبب", "يثبت", "يؤدي إلى", "خطر", "مرض", "تشخيص", "توقف عن", "تجنب")
        val strings = mutableListOf<Pair<String, LocalizedString>>()
        templates.templates.filter { it.templateId.startsWith("journal_correlation_") }
            .forEach { strings.add(it.templateId to it.text) }
        strings.add("associationNotCauseFallback" to CorrelationRenderer.ASSOCIATION_NOT_CAUSE_FALLBACK)
        CorrelationMagnitude.entries.forEach { strings.add("magnitude.${it.name}" to it.displayLabel) }

        for ((name, text) in strings) {
            val en = text.en.lowercase()
            for (phrase in bannedEn) {
                // "not a cause" is the LOCKED disclaimer; a lint that fired on the word would push
                // authors to delete the disclaimer rather than the causal claim.
                if (phrase == "causes" && en.contains("not a cause")) continue
                assertFalse("$name contains the banned frame \"$phrase\": ${text.en}", en.contains(phrase))
            }
            for (phrase in bannedAr) {
                assertFalse("$name Arabic contains the banned frame \"$phrase\"", text.ar.contains(phrase))
            }
        }
    }

    // --- Helpers ---

    private fun dayKey(offset: Int): String =
        java.time.LocalDate.parse("2026-03-01").plusDays(offset.toLong()).toString()

    /** Interleave the two arms day by day, exactly as the shared fixture does. */
    private fun days(withScores: List<Double>, withoutScores: List<Double>): List<CorrelationDay> {
        val out = mutableListOf<CorrelationDay>()
        var wi = 0
        var woi = 0
        var i = 0
        while (wi < withScores.size || woi < withoutScores.size) {
            val takeWith = (i % 2 == 0 && wi < withScores.size) || woi >= withoutScores.size
            if (takeWith) {
                out.add(CorrelationDay(dayKey(i), true, withScores[wi])); wi++
            } else {
                out.add(CorrelationDay(dayKey(i), false, withoutScores[woi])); woi++
            }
            i++
        }
        return out
    }

    private fun finding(
        delta: Double,
        ciLow: Double,
        ciHigh: Double,
        contextDays: Int = 0,
    ) = CorrelationFinding(
        behaviorId = "caffeine", scoreId = MetricId.readinessScore, nObserved = 10, nWith = 5,
        nWithout = 5, delta = delta, ciLow = ciLow, ciHigh = ciHigh, medianWith = 70.0,
        medianWithout = 61.0, contextDays = contextDays, confidence = 0.5, provisional = true,
        firstDayKey = "2026-03-01", lastDayKey = "2026-03-10",
    )

    private fun everyOutcomeShape(): List<CorrelationOutcome> = listOf(
        CorrelationOutcome.Finding(finding(0.5, 0.2, 0.8)),
        CorrelationOutcome.Finding(finding(-0.5, -0.8, -0.2, contextDays = 3)),
        CorrelationOutcome.Finding(finding(0.02, -0.4, 0.45)),
        CorrelationOutcome.Suppressed(
            CorrelationSuppression("caffeine", MetricId.readinessScore, 9, 4, 5,
                CorrelationSuppressionReason.TooFewObservedDays(5)),
        ),
        CorrelationOutcome.Suppressed(
            CorrelationSuppression("caffeine", MetricId.readinessScore, 16, 3, 13,
                CorrelationSuppressionReason.TooFewDaysWithBehavior(2)),
        ),
        CorrelationOutcome.Suppressed(
            CorrelationSuppression("caffeine", MetricId.readinessScore, 16, 14, 2,
                CorrelationSuppressionReason.TooFewDaysWithoutBehavior(3)),
        ),
    )

    private fun reasonName(reason: CorrelationSuppressionReason): String = when (reason) {
        is CorrelationSuppressionReason.TooFewObservedDays -> "tooFewObservedDays"
        is CorrelationSuppressionReason.TooFewDaysWithBehavior -> "tooFewDaysWithBehavior"
        is CorrelationSuppressionReason.TooFewDaysWithoutBehavior -> "tooFewDaysWithoutBehavior"
    }

    private fun directionName(direction: CorrelationDirection): String = when (direction) {
        CorrelationDirection.HIGHER -> "higher"
        CorrelationDirection.LOWER -> "lower"
        CorrelationDirection.NO_CLEAR_ASSOCIATION -> "noClearAssociation"
    }

    private fun placeholders(text: String): List<String> {
        val out = mutableListOf<String>()
        var current: StringBuilder? = null
        for (character in text) {
            when {
                character == '{' -> current = StringBuilder()
                character == '}' -> { current?.let { out.add(it.toString()) }; current = null }
                else -> current?.append(character)
            }
        }
        return out
    }

    private fun kotlinx.serialization.json.JsonObject.int(key: String): Int =
        this[key]!!.jsonPrimitive.content.toInt()

    private fun kotlinx.serialization.json.JsonObject.dbl(key: String): Double =
        this[key]!!.jsonPrimitive.content.toDouble()

    private fun kotlinx.serialization.json.JsonObject.str(key: String): String =
        this[key]!!.jsonPrimitive.content
}
