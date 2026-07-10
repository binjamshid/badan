package net.albayyan.badan.domain.ingestion

import net.albayyan.badan.domain.Session
import java.util.Locale

/**
 * Dedup-lite: the one reconciliation rule BADAN ships at MVP — sleep session overlap. It
 * resolves the everyday case of a phone and a watch both reporting the same night: the
 * higher-priority source wins and the heavily-overlapping same-kind duplicates are
 * suppressed (never deleted, INVARIANT I3). Kept deliberately small and pure so it is
 * trivially testable and the journal can reverse any decision.
 */
object DedupLite {
    /** Stable id for the rule, journaled on every decision so power mode can name it. */
    const val ruleId = "sleep.session_overlap.v1"

    /** A loser must overlap the winner by at least this fraction to be suppressed. */
    const val overlapThreshold = 0.70

    /**
     * Overlap ratio in 0..1: intersection duration divided by the *shorter* of the two
     * durations (so a short session fully inside a long one scores ~1.0). Non-overlapping
     * or zero-length inputs score 0. Times are epoch millis (start, end); the ratio is
     * unit-independent so millis give the same value as iOS's seconds.
     */
    fun overlap(a: Pair<Long, Long>, b: Pair<Long, Long>): Double {
        val interStart = maxOf(a.first, b.first)
        val interEnd = minOf(a.second, b.second)
        val intersection = interEnd - interStart
        if (intersection <= 0L) return 0.0
        val minDuration = minOf(a.second - a.first, b.second - b.first)
        if (minDuration <= 0L) return 0.0
        return minOf(1.0, intersection.toDouble() / minDuration.toDouble())
    }

    /**
     * One suppression: which record lost, which won, the overlap score, and the human-
     * readable detail journaled alongside the decision.
     */
    data class DedupOutcome(
        val winnerId: String?,
        val suppressed: List<Suppression>,
    ) {
        data class Suppression(
            val loserId: String,
            val winnerId: String,
            val score: Double,
            val detail: Map<String, String>,
        )
    }

    /**
     * Reconcile a night's sleep sessions. The winner is the highest-priority sleep session
     * (ties broken by longer duration, then id, for determinism). Every *same-kind* session
     * that overlaps the winner by >= [overlapThreshold] is reported as suppressed.
     */
    fun reconcile(sessions: List<Session>, priorityForSource: (String) -> Int): DedupOutcome {
        val sleep = sessions.filter { it.kind.isSleep }
        val winner = sleep.maxWithOrNull(
            compareBy<Session> { priorityForSource(it.provenance.sourceId) }
                .thenBy { it.durationSeconds }
                .thenBy { it.id },
        ) ?: return DedupOutcome(winnerId = null, suppressed = emptyList())

        val winnerPriority = priorityForSource(winner.provenance.sourceId)
        val suppressed = mutableListOf<DedupOutcome.Suppression>()
        for (loser in sleep) {
            if (loser.id == winner.id || loser.kind != winner.kind) continue
            val score = overlap(winner.startAt to winner.endAt, loser.startAt to loser.endAt)
            if (score < overlapThreshold) continue
            val detail = mapOf(
                "rule" to ruleId,
                "overlap_pct" to format(score * 100, 1),
                "threshold" to format(overlapThreshold, 2),
                "winner_source" to winner.provenance.sourceId,
                "loser_source" to loser.provenance.sourceId,
                "winner_priority" to winnerPriority.toString(),
                "loser_priority" to priorityForSource(loser.provenance.sourceId).toString(),
            )
            suppressed.add(
                DedupOutcome.Suppression(
                    loserId = loser.id, winnerId = winner.id, score = score, detail = detail,
                ),
            )
        }
        return DedupOutcome(winnerId = winner.id, suppressed = suppressed)
    }

    /** Locale-independent fixed-point formatting, matching iOS `String(format:)` (period decimal). */
    private fun format(value: Double, decimals: Int): String =
        String.format(Locale.US, "%.${decimals}f", value)
}
