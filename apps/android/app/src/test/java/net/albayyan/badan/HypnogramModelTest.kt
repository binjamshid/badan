package net.albayyan.badan

import net.albayyan.badan.designsystem.components.HYPNOGRAM_LANES
import net.albayyan.badan.designsystem.components.buildHypnogram
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.SleepStage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EPIC-24 — the pure hypnogram model. The fractions and per-stage durations a set of stage rows
 * produces must not depend on the view (the designsystem `Hypnogram` composable), so they are pinned
 * here exactly as the engines' pure cores are. Mirror of the iOS `HypnogramModelTests`.
 */
class HypnogramModelTest {

    private val minute = 60_000L

    private fun stage(seq: Int, s: SleepStage, startMin: Long, endMin: Long) =
        SessionStage(sessionId = "sess", seq = seq, stage = s, startAt = startMin * minute, endAt = endMin * minute)

    @Test
    fun empty_input_is_an_empty_model() {
        val model = buildHypnogram(emptyList())
        assertTrue(model.segments.isEmpty())
        assertEquals(0.0, model.spanSeconds, 0.0)
        assertFalse(model.hasStagedSleep)
    }

    @Test
    fun single_stage_spans_the_whole_track() {
        val model = buildHypnogram(listOf(stage(0, SleepStage.DEEP, 0, 60)))
        assertEquals(1, model.segments.size)
        assertEquals(0f, model.segments[0].startFraction, 1e-6f)
        assertEquals(1f, model.segments[0].widthFraction, 1e-6f)
        assertEquals(3600.0, model.stageSeconds[SleepStage.DEEP]!!, 1e-6)
        assertTrue(model.hasStagedSleep)
    }

    @Test
    fun fractions_are_relative_to_the_whole_recorded_span() {
        // 0..30 light, 30..90 deep, 90..120 rem  → span 120 min.
        val model = buildHypnogram(
            listOf(
                stage(0, SleepStage.LIGHT, 0, 30),
                stage(1, SleepStage.DEEP, 30, 90),
                stage(2, SleepStage.REM, 90, 120),
            ),
        )
        assertEquals(3, model.segments.size)
        assertEquals(0f, model.segments[0].startFraction, 1e-6f)
        assertEquals(0.25f, model.segments[0].widthFraction, 1e-6f)   // 30/120
        assertEquals(0.25f, model.segments[1].startFraction, 1e-6f)   // 30/120
        assertEquals(0.5f, model.segments[1].widthFraction, 1e-6f)    // 60/120
        assertEquals(0.75f, model.segments[2].startFraction, 1e-6f)   // 90/120
        assertEquals(0.25f, model.segments[2].widthFraction, 1e-6f)   // 30/120
        assertEquals(7200.0, model.spanSeconds, 1e-6)
    }

    @Test
    fun stages_are_ordered_chronologically_even_when_input_is_shuffled() {
        val model = buildHypnogram(
            listOf(
                stage(2, SleepStage.REM, 90, 120),
                stage(0, SleepStage.LIGHT, 0, 30),
                stage(1, SleepStage.DEEP, 30, 90),
            ),
        )
        assertEquals(listOf(SleepStage.LIGHT, SleepStage.DEEP, SleepStage.REM), model.segments.map { it.stage })
    }

    @Test
    fun durations_accumulate_across_repeated_stages() {
        val model = buildHypnogram(
            listOf(
                stage(0, SleepStage.LIGHT, 0, 30),
                stage(1, SleepStage.DEEP, 30, 60),
                stage(2, SleepStage.LIGHT, 60, 90),
            ),
        )
        assertEquals(3600.0, model.stageSeconds[SleepStage.LIGHT]!!, 1e-6)  // 30 + 30 min
        assertEquals(1800.0, model.stageSeconds[SleepStage.DEEP]!!, 1e-6)
    }

    @Test
    fun zero_or_negative_length_rows_are_dropped() {
        val model = buildHypnogram(
            listOf(
                stage(0, SleepStage.DEEP, 30, 30),   // zero length
                stage(1, SleepStage.LIGHT, 0, 60),
            ),
        )
        assertEquals(1, model.segments.size)
        assertEquals(SleepStage.LIGHT, model.segments[0].stage)
    }

    @Test
    fun an_unstaged_night_has_no_drawable_lanes() {
        // A source that reported sleep but not its structure — only inBed / asleepUnspecified.
        val model = buildHypnogram(
            listOf(
                stage(0, SleepStage.IN_BED, 0, 60),
                stage(1, SleepStage.ASLEEP_UNSPECIFIED, 0, 55),
            ),
        )
        assertFalse("unstaged night must not claim drawable stage structure", model.hasStagedSleep)
    }

    @Test
    fun lane_order_is_awake_rem_light_deep() {
        assertEquals(
            listOf(SleepStage.AWAKE, SleepStage.REM, SleepStage.LIGHT, SleepStage.DEEP),
            HYPNOGRAM_LANES,
        )
    }
}
