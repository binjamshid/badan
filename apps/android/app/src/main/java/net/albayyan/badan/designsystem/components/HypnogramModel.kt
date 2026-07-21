package net.albayyan.badan.designsystem.components

import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.SleepStage

/**
 * The pure hypnogram model (mirror of the iOS `HypnogramModel`). Compose-free on purpose: the numbers
 * a set of stages produces must not depend on the view, so they are asserted by `HypnogramModelTest`
 * exactly as the engines' pure cores are — and a JVM unit test can load this file without pulling in
 * the Compose runtime the `Hypnogram` composable needs.
 */

/**
 * One stage occupying a slice of the night, expressed as fractions of the whole recorded span so the
 * renderer never touches epoch millis. [startFraction] and [widthFraction] are both in `0..1`; a gap
 * between two segments is a real gap in the record, not a zero — the surface leaves it blank rather
 * than inventing a stage there (plan §18).
 */
data class HypnogramSegment(
    val stage: SleepStage,
    val startFraction: Float,
    val widthFraction: Float,
)

/**
 * The whole hypnogram reduced to what a lane renderer needs: the ordered segments, the per-stage total
 * seconds (the lane labels double as the legend), and the recorded span in seconds.
 *
 * [hasStagedSleep] is the honest gate: a night whose only rows are `inBed`/`asleepUnspecified` (an
 * unstaged source) carries no lane-drawable detail, and the surface must say so rather than draw an
 * empty chart that reads as "no sleep".
 */
data class HypnogramModel(
    val segments: List<HypnogramSegment>,
    val stageSeconds: Map<SleepStage, Double>,
    val spanSeconds: Double,
) {
    /** True when at least one segment sits in a drawable lane (awake/rem/light/deep). */
    val hasStagedSleep: Boolean get() = segments.any { it.stage in HYPNOGRAM_LANES }
}

/**
 * The lanes a hypnogram draws, top-to-bottom: the classic awake → REM → light → deep depth ordering.
 * `inBed` (the envelope, not a sleep depth) and `asleepUnspecified` (a source that reported sleep but
 * not its structure) are deliberately NOT lanes — an unstaged night has no depth structure to plot,
 * and forcing one would fabricate detail the source never provided (I1).
 */
val HYPNOGRAM_LANES: List<SleepStage> = listOf(
    SleepStage.AWAKE, SleepStage.REM, SleepStage.LIGHT, SleepStage.DEEP,
)

/**
 * Build the hypnogram model from a session's stage rows. Pure: no Compose, no clock, no I/O, so both
 * platforms produce the same fractions from the same rows.
 *
 * The span is the recorded envelope `[min startAt, max endAt]` across ALL stage rows (including
 * `inBed`/`awake`), so a segment's position is honest relative to the whole night, not just to the
 * asleep portion. Zero- or negative-length rows are dropped rather than drawn as slivers. An empty or
 * degenerate input yields an empty model, never a divide-by-zero.
 */
fun buildHypnogram(stages: List<SessionStage>): HypnogramModel {
    val usable = stages.filter { it.endAt > it.startAt }
    if (usable.isEmpty()) return HypnogramModel(emptyList(), emptyMap(), 0.0)

    val minStart = usable.minOf { it.startAt }
    val maxEnd = usable.maxOf { it.endAt }
    val spanMillis = (maxEnd - minStart).toDouble()
    if (spanMillis <= 0.0) return HypnogramModel(emptyList(), emptyMap(), 0.0)

    val ordered = usable.sortedBy { it.startAt }
    val segments = ordered.map { s ->
        HypnogramSegment(
            stage = s.stage,
            startFraction = ((s.startAt - minStart).toDouble() / spanMillis).toFloat(),
            widthFraction = ((s.endAt - s.startAt).toDouble() / spanMillis).toFloat(),
        )
    }

    val stageSeconds = HashMap<SleepStage, Double>()
    for (s in ordered) {
        stageSeconds[s.stage] = (stageSeconds[s.stage] ?: 0.0) + s.durationSeconds
    }

    return HypnogramModel(segments = segments, stageSeconds = stageSeconds, spanSeconds = spanMillis / 1000.0)
}
