package net.albayyan.badan

import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.domain.ingestion.DedupLite
import net.albayyan.badan.domain.ingestion.SleepStageRollup
import net.albayyan.badan.domain.ingestion.WorkoutLinkage
import net.albayyan.badan.platform.health.IntervalDto
import net.albayyan.badan.platform.health.SampleDto
import net.albayyan.badan.platform.health.SessionDto
import net.albayyan.badan.platform.health.WorkoutTotalsDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixtures for the two pure rules EPIC-03 adds on the Android side: `workout.session_overlap.v1`
 * and the workout-to-metric linkage that produces `SessionDetail.workout.totals`.
 *
 * Both are deliberately platform-neutral (they operate on DTOs and plain windows, never on
 * Health Connect or HealthKit types) so the same inputs can be fed to the iOS implementations and
 * the canonical outputs compared — the Phase-0 exit criterion. Every timestamp here is a round
 * epoch-millis number for exactly that reason: a fixture that is awkward to transcribe is a
 * fixture that will not be transcribed.
 */
class WorkoutIngestionTest {

    private val t0 = 1_700_000_000_000L   // fixed epoch millis; no wall-clock dependence
    private fun min(n: Long) = n * 60_000L

    private fun candidate(id: String, source: String, startMin: Long, durationMin: Long, manual: Boolean = false) =
        DedupLite.WorkoutCandidate(
            id = id, sourceId = source, startAt = t0 + min(startMin),
            endAt = t0 + min(startMin + durationMin), isManual = manual,
        )

    private fun priority(source: String) = when (source) {
        "watch" -> 68
        "phone" -> 42
        "manual" -> 0
        else -> 30
    }

    // --- workout.session_overlap.v1 ---

    @Test fun twoAppsRecordingOneRunResolveToTheHigherPrioritySource() {
        val outcomes = DedupLite.reconcileWorkouts(
            listOf(
                candidate("phone-run", "phone", startMin = 0, durationMin = 45),
                candidate("watch-run", "watch", startMin = 1, durationMin = 44),
            ),
            ::priority,
        )
        assertEquals("one overlap cluster", 1, outcomes.size)
        assertEquals("watch-run", outcomes[0].winnerId)
        assertEquals(listOf("phone-run"), outcomes[0].suppressed.map { it.loserId })
        assertEquals(DedupLite.workoutRuleId, outcomes[0].suppressed[0].detail["rule"])
    }

    /**
     * The reason this rule returns a list where the sleep rule returns one outcome. A day holds
     * many unrelated workouts; a single global winner would suppress the morning run because the
     * evening lift outranked it.
     */
    @Test fun separateWorkoutsInOneDayAreSeparateClusters() {
        val outcomes = DedupLite.reconcileWorkouts(
            listOf(
                candidate("morning-run", "watch", startMin = 0, durationMin = 45),
                candidate("evening-lift", "watch", startMin = 600, durationMin = 60),
            ),
            ::priority,
        )
        assertEquals(2, outcomes.size)
        assertTrue("nothing overlaps, so nothing is suppressed", outcomes.all { it.suppressed.isEmpty() })
        assertEquals(setOf("morning-run", "evening-lift"), outcomes.mapNotNull { it.winnerId }.toSet())
    }

    /**
     * Greedy clustering, not transitive. A overlaps B and B overlaps C, but A and C barely touch —
     * chaining them would suppress a genuinely separate session because it happened to abut its
     * neighbour. The strongest candidate absorbs what actually overlaps *it*, then the rest are
     * reconsidered on their own.
     */
    @Test fun overlapIsNotTransitive() {
        val outcomes = DedupLite.reconcileWorkouts(
            listOf(
                candidate("a", "watch", startMin = 0, durationMin = 60),
                candidate("b", "phone", startMin = 50, durationMin = 60),
                candidate("c", "phone", startMin = 100, durationMin = 60),
            ),
            ::priority,
        )
        // "a" (highest priority) absorbs nothing: it overlaps "b" by only 10 of 60 minutes.
        val winners = outcomes.mapNotNull { it.winnerId }.toSet()
        assertEquals(setOf("a", "b", "c"), winners)
        assertTrue(outcomes.all { it.suppressed.isEmpty() })
    }

    @Test fun containedWorkoutIsSuppressedAndScoresOne() {
        val outcomes = DedupLite.reconcileWorkouts(
            listOf(
                candidate("long", "watch", startMin = 0, durationMin = 60),
                candidate("short", "phone", startMin = 10, durationMin = 20),
            ),
            ::priority,
        )
        assertEquals(1, outcomes.size)
        assertEquals("long", outcomes[0].winnerId)
        // Overlap is measured against the *shorter* duration, so full containment is 1.0.
        assertEquals(1.0, outcomes[0].suppressed.single().score, 0.0001)
    }

    /**
     * Ingested beats manual, and this is not a contradiction of I4. I4's "manual wins" list is
     * weight/BP/labs — the metrics people deliberately correct by hand. A quick-add workout is the
     * opposite: a rough estimate typed before the watch synced, where the device version has the
     * real start, end and heart rate.
     */
    @Test fun ingestedWorkoutSuppressesTheManualDuplicate() {
        val outcomes = DedupLite.reconcileWorkouts(
            listOf(
                candidate("typed-in", "manual", startMin = 0, durationMin = 45, manual = true),
                candidate("from-watch", "watch", startMin = 2, durationMin = 43),
            ),
            ::priority,
        )
        assertEquals("from-watch", outcomes[0].winnerId)
        val suppression = outcomes[0].suppressed.single()
        assertEquals("typed-in", suppression.loserId)
        assertEquals(
            "the journal must be able to answer 'why did my typed-in run vanish?'",
            "true", suppression.detail["loser_manual"],
        )
    }

    /** Two candidates that tie on everything but id must still resolve identically every run —
     *  the parity fixtures compare exact winner ids across platforms. */
    @Test fun tiesResolveDeterministically() {
        val a = candidate("aaa", "watch", startMin = 0, durationMin = 45)
        val b = candidate("bbb", "watch", startMin = 0, durationMin = 45)
        val first = DedupLite.reconcileWorkouts(listOf(a, b), ::priority)
        val second = DedupLite.reconcileWorkouts(listOf(b, a), ::priority)
        assertEquals(first[0].winnerId, second[0].winnerId)
        assertEquals("bbb", first[0].winnerId)   // higher id wins the final tiebreak
    }

    @Test fun emptyInputProducesNoOutcomes() {
        assertTrue(DedupLite.reconcileWorkouts(emptyList(), ::priority).isEmpty())
    }

    // --- WorkoutLinkage ---

    private fun workout(source: String = "watch", startMin: Long = 0, durationMin: Long = 60, totals: WorkoutTotalsDto? = null) =
        SessionDto(
            kind = SessionKind.WORKOUT, start = t0 + min(startMin), end = t0 + min(startMin + durationMin),
            tz = "UTC", sourceId = source, externalId = "w1", activityType = "running", totals = totals,
        )

    private fun interval(metricId: String, source: String, startMin: Long, endMin: Long, value: Double) =
        IntervalDto(
            metricId = metricId, value = value, unit = "kJ", start = t0 + min(startMin), end = t0 + min(endMin),
            tz = "UTC", aggregation = Aggregation.SUM, sourceId = source, externalId = "i-$startMin-$metricId",
        )

    private fun hr(source: String, atMin: Long, bpm: Double) =
        SampleDto(
            metricId = MetricId.heartRate, value = bpm, unit = "bpm", start = t0 + min(atMin),
            tz = "UTC", sourceId = source, externalId = "hr-$atMin",
        )

    @Test fun containedIntervalsAreSummedIntoTheWorkoutTotal() {
        val totals = WorkoutLinkage.totals(
            workout(),
            samples = emptyList(),
            intervals = listOf(
                interval(MetricId.activeEnergy, "watch", 5, 20, 300.0),
                interval(MetricId.activeEnergy, "watch", 20, 55, 500.0),
            ),
        )
        assertEquals(800.0, totals.energyKj!!, 0.0001)
    }

    /**
     * The decision this whole helper exists to get right. A writer that emits one energy record
     * per day contributes nothing to a 60-minute workout — under-counting, which surfaces as null
     * and renders as "—". Proportional attribution would instead invent a confident, plausible,
     * entirely fabricated number from a day-long bucket.
     */
    @Test fun aDayLongBucketContributesNothingRatherThanAFraction() {
        val totals = WorkoutLinkage.totals(
            workout(),
            samples = emptyList(),
            intervals = listOf(interval(MetricId.activeEnergy, "watch", -600, 840, 9000.0)),
        )
        assertNull("a day bucket must not be sliced into the workout", totals.energyKj)
    }

    /** Null, not 0.0 — "no contributing record" and "the source measured zero" are different
     *  claims, and only one of them is true. */
    @Test fun noContributingRecordsYieldsNullNotZero() {
        val totals = WorkoutLinkage.totals(workout(), emptyList(), emptyList())
        assertNull(totals.energyKj)
        assertNull(totals.distanceM)
        assertNull(totals.avgHrBpm)
        assertNull(totals.maxHrBpm)
        assertNull("no Health Connect source reports elevation gain", totals.elevationGainM)
    }

    /**
     * The multi-writer hazard reappearing at the totals layer, where no dedup rule is looking: two
     * apps both recording the run would otherwise sum to roughly twice the truth.
     */
    @Test fun anotherWritersRecordsAreNotFoldedIntoThisWorkoutsTotals() {
        val totals = WorkoutLinkage.totals(
            workout(source = "watch"),
            samples = listOf(hr("phone", 30, 190.0)),
            intervals = listOf(
                interval(MetricId.activeEnergy, "watch", 5, 55, 700.0),
                interval(MetricId.activeEnergy, "phone", 5, 55, 700.0),
            ),
        )
        assertEquals(700.0, totals.energyKj!!, 0.0001)
        assertNull("another device's max must not be reported as this one's", totals.maxHrBpm)
    }

    @Test fun heartRateIsAveragedAndMaxedOverTheWorkoutWindowOnly() {
        val totals = WorkoutLinkage.totals(
            workout(startMin = 0, durationMin = 60),
            samples = listOf(
                hr("watch", -10, 62.0),    // before the workout
                hr("watch", 10, 140.0),
                hr("watch", 30, 150.0),
                hr("watch", 50, 160.0),
                hr("watch", 90, 70.0),     // after the workout
            ),
            intervals = emptyList(),
        )
        assertEquals(150.0, totals.avgHrBpm!!, 0.0001)
        assertEquals(160.0, totals.maxHrBpm!!, 0.0001)
    }

    /**
     * A port that knows its own totals (HealthKit hands them over on `HKWorkout`; the sample store
     * carries them on the DTO) wins over anything derived here. Without this the two platforms
     * would report different numbers for the same workout — the thing the parity criterion exists
     * to prevent.
     */
    @Test fun portSuppliedTotalsWinOverDerivedOnes() {
        val totals = WorkoutLinkage.totals(
            workout(totals = WorkoutTotalsDto(energyKj = 1234.0, maxHrBpm = 171.0)),
            samples = listOf(hr("watch", 30, 150.0)),
            intervals = listOf(interval(MetricId.activeEnergy, "watch", 5, 55, 700.0)),
        )
        assertEquals(1234.0, totals.energyKj!!, 0.0001)
        assertEquals(171.0, totals.maxHrBpm!!, 0.0001)
        // Fields the port did not supply still fall through to the derived values.
        assertEquals(150.0, totals.avgHrBpm!!, 0.0001)
    }

    // MARK: - Sleep stage rollup

    /**
     * Stage data was already reaching `session_stages` and stopping there, while charts and
     * baselines read `interval_records` — so four registry metrics that exist and are
     * `baselineEligible` had nothing writing them, and deep/REM sleep were in the database but
     * absent from the product. These are the ids `IngestionPipeline.upsertStageIntervals` now
     * writes; a typo here is a metric `MetricRegistry` cannot resolve on read.
     */
    @Test fun everyRolledUpStageNamesItsRegistryMetric() {
        assertEquals(MetricId.sleepDeep, SleepStageRollup.metrics[SleepStage.DEEP])
        assertEquals(MetricId.sleepRem, SleepStageRollup.metrics[SleepStage.REM])
        assertEquals(MetricId.sleepLight, SleepStageRollup.metrics[SleepStage.LIGHT])
        assertEquals(MetricId.sleepAwake, SleepStageRollup.metrics[SleepStage.AWAKE])
    }

    /**
     * The two omissions are decisions, so they are asserted rather than left to be noticed.
     * In-bed time is already `sleep.time_in_bed`, and "asleep, stage unspecified" is the *absence*
     * of a stage breakdown — filing it under a stage would invent the detail the source just told
     * us it does not have.
     */
    @Test fun inBedAndUnspecifiedSleepAreDeliberatelyNotRolledUp() {
        assertNull(SleepStageRollup.metrics[SleepStage.IN_BED])
        assertNull(SleepStageRollup.metrics[SleepStage.ASLEEP_UNSPECIFIED])
    }
}
