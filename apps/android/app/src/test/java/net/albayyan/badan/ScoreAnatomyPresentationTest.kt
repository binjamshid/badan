package net.albayyan.badan

import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.derivation.EffortSpec
import net.albayyan.badan.domain.derivation.ReadinessSpec
import net.albayyan.badan.domain.derivation.SleepSpec
import net.albayyan.badan.features.metricdetail.AnatomyFormulas
import net.albayyan.badan.features.metricdetail.AnatomyScoreStrings
import net.albayyan.badan.features.metricdetail.confidenceWord
import net.albayyan.badan.features.metricdetail.contributionRows
import net.albayyan.badan.features.metricdetail.isReducedInputReadiness
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-25 — the anatomy sheet's pure contribution/confidence core. Contribution bars must sort by and
 * scale against the largest driver, the reduced-input variant must be detectable from the manifest
 * alone, and confidence must resolve to the honest word. The iOS side asserts the same anatomy core
 * in `ScoreSurfacesTests` (there is no standalone iOS `ScoreAnatomyPresentationTests` class).
 */
class ScoreAnatomyPresentationTest {

    private fun input(metricId: String, value: Double, weight: Double?) =
        InputManifest.Input(recordId = "r-$metricId", metricId = metricId, value = value, weight = weight)

    @Test
    fun contribution_rows_sort_largest_first_and_scale_against_the_leader() {
        val rows = contributionRows(
            listOf(
                input(MetricId.restingHeartRate, 55.0, 12.0),
                input(MetricId.hrv, 60.0, 40.0),
                input(MetricId.respiratoryRate, 14.0, 8.0),
            ),
        )
        assertEquals(listOf(MetricId.hrv, MetricId.restingHeartRate, MetricId.respiratoryRate), rows.map { it.metricId })
        assertEquals(1f, rows[0].fractionOfMax, 1e-6f)          // leader fills its row
        assertEquals(12f / 40f, rows[1].fractionOfMax, 1e-6f)
        assertEquals(8f / 40f, rows[2].fractionOfMax, 1e-6f)
        assertEquals(60.0, rows[0].measuredValue, 1e-9)          // raw reading preserved for lineage
    }

    @Test
    fun unweighted_manifests_produce_no_contribution_rows() {
        val rows = contributionRows(
            listOf(
                input(MetricId.sleepNeed, 27000.0, null),
                input(MetricId.timeAsleep, 25000.0, null),
            ),
        )
        assertTrue(rows.isEmpty())
    }

    @Test
    fun readiness_with_hrv_is_a_full_score() {
        val inputs = listOf(
            input(MetricId.hrv, 60.0, 40.0),
            input(MetricId.restingHeartRate, 55.0, 12.0),
        )
        assertFalse(isReducedInputReadiness(inputs))
    }

    @Test
    fun readiness_without_hrv_is_reduced_input() {
        val inputs = listOf(
            input(MetricId.restingHeartRate, 55.0, 20.0),
            input(MetricId.sleepPerformance, 90.0, 25.0),
        )
        assertTrue(isReducedInputReadiness(inputs))
    }

    @Test
    fun confidence_resolves_to_the_honest_word_at_its_thresholds() {
        assertEquals(AnatomyScoreStrings.confidenceEstablished, confidenceWord(0.9))
        assertEquals(AnatomyScoreStrings.confidenceEstablished, confidenceWord(0.75))
        assertEquals(AnatomyScoreStrings.confidenceFirming, confidenceWord(0.74))
        assertEquals(AnatomyScoreStrings.confidenceFirming, confidenceWord(0.4))
        assertEquals(AnatomyScoreStrings.confidenceEarly, confidenceWord(0.39))
        assertEquals(AnatomyScoreStrings.confidenceEarly, confidenceWord(0.0))
    }

    // MARK: - Published formulas (audit finding #3 — every surfaced score is inspectable in-app)

    /**
     * Completeness gate: EVERY derived score the app can surface reaches the anatomy sheet's formula
     * card via `AnatomyFormulas.lookup(methodString)`, so each must publish a formula or the card is
     * silently omitted (docs-yes / in-app-no). The ids are sourced from the engines' own published
     * identities, so a future engine output added without a formula fails HERE. Mirror of the iOS
     * `testEverySurfacedScoreHasAPublishedFormula`.
     */
    @Test
    fun every_surfaced_score_has_a_published_formula() {
        val sleep = SleepSpec.default()
        val effort = EffortSpec.default()
        val surfaced = buildSet {
            add(BaselineEngine.baselineAlgorithm.algorithmId)
            add(BaselineEngine.efficiencyAlgorithm.algorithmId)
            add(BaselineEngine.readinessAlgorithm.algorithmId)
            add(ReadinessSpec.default().algorithm.algorithmId)
            add(effort.dayAlgorithm.algorithmId)
            add(effort.workoutAlgorithm.algorithmId)
            for (output in listOf(sleep.need, sleep.performance, sleep.debt, sleep.consistency, sleep.disturbances)) {
                add(output.algorithm.algorithmId)
            }
        }
        for (id in surfaced) {
            assertNotNull("$id is a surfaced score but has no in-app published formula", AnatomyFormulas.lookup(id))
        }
    }

    @Test
    fun sleep_scores_publish_bilingual_formulas_with_distinct_alt_text() {
        // The three scores the audit flagged (debt/consistency/disturbances) plus the anchors.
        for (id in listOf("sleep.debt", "sleep.consistency", "sleep.disturbances", "sleep.need", "sleep.performance")) {
            val f = requireNotNull(AnatomyFormulas.byAlgorithmId[id]) { "$id should publish a formula" }
            assertTrue(f.formula.en.isNotEmpty() && f.formula.ar.isNotEmpty())
            assertTrue(f.altText.en.isNotEmpty() && f.altText.ar.isNotEmpty())
            assertTrue("alt-text is the plain-language reading, not the notation", f.formula.en != f.altText.en)
            assertTrue(f.formula.ar != f.altText.ar)
        }
    }

    @Test
    fun formula_lookup_tolerates_a_versioned_token() {
        assertNotNull(AnatomyFormulas.lookup("sleep.debt@0.1.0"))
        assertNotNull(AnatomyFormulas.lookup("sleep.debt"))
        assertNull(AnatomyFormulas.lookup("nonsense.algorithm"))
    }
}
