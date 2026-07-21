package net.albayyan.badan.domain.derivation

import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.TimeZone

/**
 * EPIC-23/24/25/26 — the ONE place the score engines run in their cross-metric order. Faithful port
 * of the iOS `DerivationCoordinator`; the ordering rationale lives there in full and is summarized
 * here.
 *
 * It owns no scoring logic — only *what runs, in what order, over what window*. Every engine it calls
 * is append-only and skip-if-identical (I2), so a repeat run over unchanged data writes nothing and
 * the read model (latest row per period) is unchanged.
 *
 * **Produce order (baselines → effort → sleep → readiness).** The plan's guidance chain reads
 * "sleep → readiness → effort guidance" (§18), but that is the *display* order, not the *produce*
 * order. The stored-value graph has one edge the display chain hides: the EPIC-24 sleep-need model
 * consumes the **prior day's `effort.day`** as a published soft input. So `effort.day` (which reads
 * only HR + profile — no other score) must be produced BEFORE sleep, or a single recompute would
 * compute sleep without the effort term and only pick it up on the next run — a convergence lag that
 * breaks single-pass idempotency. Readiness then reads the fresh `sleep.performance`; the
 * readiness-linked effort **guidance** is a read model the UI calls on demand, so producing the
 * effort score before readiness never stales the guidance that depends on it. No stored value reads
 * readiness, so there is no cycle.
 *
 * `DeviationEngine` (EPIC-27) is NOT run here: it writes nothing (a pure read model over the
 * `Baseline` rows this pipeline refreshes, built on demand by the Health Monitor surface), so it is
 * constructed in the composition root and read by the UI, never "recomputed".
 *
 * Threading/transactions: synchronous, no dispatching, no transaction of its own — every caller
 * already runs it off the main thread and owns its batching transaction exactly as the bare
 * `BaselineEngine.recomputeAll` it replaces did (`AppEnvironment.syncHealthConnect` wraps it;
 * `SeedController` runs it on the IO-dispatched seed path).
 */
class DerivationCoordinator(
    private val baselines: BaselineEngine,
    private val sleep: SleepIntelligenceEngine,
    private val readiness: ReadinessEngine,
    private val effort: EffortEngine,
    private val config: Config = Config(),
) {
    /**
     * Orchestration windows — NOT algorithm constants (those live in `algorithms.json` per engine).
     * [recentScoreDays] is how many recent local days (including `asOf`) a routine [recompute]
     * re-scores for effort and readiness, so a just-completed day and any late overnight data are
     * picked up without re-walking history each ingest. Deep (re)scoring is [backfill].
     */
    data class Config(val recentScoreDays: Int = 2)

    /** Routine post-ingest / nightly recompute in the produce order above. Idempotent at the read
     *  model: a repeat run over unchanged data appends nothing. */
    fun recompute(asOf: Long, tz: String = TimeZone.getDefault().id) {
        // 1. Baselines first — the interim `readiness.score` composite is suppressed because the real
        //    ReadinessEngine (step 4) owns that id now; leaving both on would ping-pong a row per run
        //    (see the flag doc on `recomputeAll`). `sleep.efficiency` is still emitted.
        baselines.recomputeAll(asOf, tz = tz, includeInterimReadinessComposite = false)

        val days = recentDayStarts(asOf, tz)

        // 2. Effort BEFORE sleep — sleep-need consumes the prior day's `effort.day`, which reads only
        //    HR + profile, so nothing it needs is missing here.
        for (day in days) effort.computeDay(day, tz)
        days.firstOrNull()?.let { earliest -> effort.computeWorkouts(earliest, asOf, tz) }

        // 3. Sleep — reads the prior-day `effort.day` from step 2, emits `sleep.performance`.
        sleep.recompute(asOf, tz)

        // 4. Readiness — reads today's `sleep.performance` (step 3) + vitals baselines (step 1).
        for (day in days) readiness.compute(day, tz)
    }

    /**
     * Historical backfill over `[from, to]` (EPIC-23 first-connect/import score backfill, EPIC-26
     * HR-max/zone edit). Same produce order as [recompute] over the whole window; effort's own
     * oldest→newest loop covers every day so sleep sees the backfilled `effort.day`. Append-only, so
     * this is a plain re-run, not a mutating path (I2). Returns a touched-day/session count.
     */
    fun backfill(from: Long, to: Long, tz: String = TimeZone.getDefault().id): Int {
        baselines.recomputeAll(to, tz = tz, includeInterimReadinessComposite = false)

        var touched = 0
        touched += effort.recompute(from, to, tz)

        sleep.recompute(to, tz)

        var day = DayAttribution.startOfDay(from, tz)
        val lastDayStart = DayAttribution.startOfDay(to, tz)
        while (day <= lastDayStart) {
            if (readiness.compute(day, tz) != null) touched += 1
            day = DayAttribution.addingDays(1, day, tz)
        }
        return touched
    }

    /** The last [Config.recentScoreDays] local-day starts up to and including `asOf`'s day, oldest
     *  first. DST-safe day stepping via `DayAttribution`. */
    private fun recentDayStarts(asOf: Long, tz: String): List<Long> {
        val count = maxOf(1, config.recentScoreDays)
        val today = DayAttribution.startOfDay(asOf, tz)
        return (count - 1 downTo 0).map { DayAttribution.addingDays(-it, today, tz) }
    }
}
