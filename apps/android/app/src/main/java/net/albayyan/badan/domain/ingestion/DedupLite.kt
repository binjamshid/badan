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

    /**
     * The workout counterpart (plan §9.1/§20 EPIC-03). A separate rule id rather than a shared
     * one because the journal is user-facing: "sleep overlap" and "workout overlap" resolve
     * different everyday situations (a phone and a watch recording one night, versus a watch
     * recording a run the user had already typed in), and a single id would make the provenance
     * sheet unable to say which happened.
     */
    const val workoutRuleId = "workout.session_overlap.v1"

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

    // MARK: - workout.session_overlap.v1

    /**
     * A workout considered for reconciliation, from either side of the unified read model: an
     * ingested `sessions` row (kind=workout) or a manually-typed `workout_entries` row.
     *
     * A flat struct rather than the two real entity types on purpose — the rule must be able to
     * compare a `Session` against a `WorkoutEntry`, which share no supertype and never should.
     * Reducing both to (id, source, window, manual?) is also what keeps the rule pure and
     * fixture-testable against iOS's identical inputs.
     */
    data class WorkoutCandidate(
        val id: String,
        val sourceId: String,
        val startAt: Long,
        val endAt: Long,
        /** True for `workout_entries` rows (the quick-add path), false for ingested sessions. */
        val isManual: Boolean,
    )

    /**
     * Reconcile overlapping workouts.
     *
     * Unlike sleep — where a local night has one winner by definition — a day holds many
     * unrelated workouts, so this returns one outcome *per overlap cluster* rather than a single
     * global winner. Collapsing them to one winner would suppress a morning run because an
     * evening lift outranked it.
     *
     * Clustering is greedy from the strongest candidate outward, repeated until every candidate is
     * assigned: take the best unassigned workout as a winner, absorb everything still unassigned
     * that overlaps it past [overlapThreshold], emit, repeat. Greedy rather than transitive
     * (union-find over pairwise overlaps) because transitivity is wrong here — three workouts each
     * overlapping the next by 70% can span twice the duration of the first, and chaining them into
     * one cluster would suppress a genuinely separate session that merely touched its neighbour.
     *
     * Ingested beats manual on a tie. That is not a contradiction of I4 ("manual wins for
     * weight/BP/labs"): I4's list is deliberately the metrics people *correct* by hand, where a
     * typed number is a considered override of a device. A workout is the opposite case — the
     * quick-add entry is a rough estimate the user typed before their watch synced, and the
     * device's version has the real start, end and heart rate. Suppressing the estimate is what
     * the user means by having both.
     */
    fun reconcileWorkouts(
        candidates: List<WorkoutCandidate>,
        priorityForSource: (String) -> Int,
    ): List<DedupOutcome> {
        // Total, deterministic ordering. `best` picks the maximum, so the ordering runs weakest to
        // strongest: lower priority first, manual before ingested, shorter before longer, id last
        // as the final tiebreak so two identical windows always resolve the same way across runs
        // and across platforms (the parity fixtures depend on this).
        val strength = compareBy<WorkoutCandidate> { priorityForSource(it.sourceId) }
            .thenBy { if (it.isManual) 0 else 1 }
            .thenBy { it.endAt - it.startAt }
            .thenBy { it.id }

        val remaining = candidates.sortedWith(strength).toMutableList()
        val outcomes = mutableListOf<DedupOutcome>()

        while (remaining.isNotEmpty()) {
            val winner = remaining.maxWith(strength)
            remaining.remove(winner)
            val winnerPriority = priorityForSource(winner.sourceId)

            val suppressed = mutableListOf<DedupOutcome.Suppression>()
            val absorbed = mutableListOf<WorkoutCandidate>()
            for (loser in remaining) {
                val score = overlap(winner.startAt to winner.endAt, loser.startAt to loser.endAt)
                if (score < overlapThreshold) continue
                absorbed.add(loser)
                suppressed.add(
                    DedupOutcome.Suppression(
                        loserId = loser.id, winnerId = winner.id, score = score,
                        detail = mapOf(
                            "rule" to workoutRuleId,
                            "overlap_pct" to format(score * 100, 1),
                            "threshold" to format(overlapThreshold, 2),
                            "winner_source" to winner.sourceId,
                            "loser_source" to loser.sourceId,
                            "winner_priority" to winnerPriority.toString(),
                            "loser_priority" to priorityForSource(loser.sourceId).toString(),
                            // The one detail the sleep rule has no equivalent of, and the one a
                            // user is most likely to ask about: "why did my typed-in run vanish?"
                            "loser_manual" to loser.isManual.toString(),
                        ),
                    ),
                )
            }
            remaining.removeAll(absorbed)

            // A cluster of one is still reported, with an empty suppression list: callers use the
            // winner id to know which workout survived, and dropping singletons would make a
            // day with no duplicates indistinguishable from a day with no workouts.
            outcomes.add(DedupOutcome(winnerId = winner.id, suppressed = suppressed))
        }
        return outcomes
    }

    /** Locale-independent fixed-point formatting, matching iOS `String(format:)` (period decimal). */
    private fun format(value: Double, decimals: Int): String =
        String.format(Locale.US, "%.${decimals}f", value)
}
