import Foundation

/// Dedup-lite: BADAN's reconciliation rules. Two ship today — sleep session overlap
/// (`sleep.session_overlap.v1`) and workout-versus-manual overlap
/// (`workout.session_overlap.v1`, see the extension at the bottom of this file).
///
/// Sleep overlap resolves the everyday case of a phone and a watch both reporting the same
/// night: the higher-priority source wins and the heavily-overlapping same-kind duplicates are
/// suppressed (never deleted, INVARIANT I3). Kept deliberately small and pure so it is trivially
/// testable and the journal can reverse any decision.
struct DedupLite {
    /// Stable id for the rule, journaled on every decision so power mode can name it.
    static let ruleId = "sleep.session_overlap.v1"
    /// A loser must overlap the winner by at least this fraction to be suppressed.
    static let overlapThreshold = 0.70

    /// Overlap ratio in 0...1: intersection duration divided by the *shorter* of the two
    /// durations (so a short session fully inside a long one scores ~1.0). Non-overlapping
    /// or zero-length inputs score 0.
    static func overlap(_ a: (start: Date, end: Date), _ b: (start: Date, end: Date)) -> Double {
        let interStart = max(a.start, b.start)
        let interEnd = min(a.end, b.end)
        let intersection = interEnd.timeIntervalSince(interStart)
        guard intersection > 0 else { return 0 }
        let minDuration = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        guard minDuration > 0 else { return 0 }
        return min(1.0, intersection / minDuration)
    }

    /// One suppression: which record lost, which won, the overlap score, and the human-
    /// readable detail journaled alongside the decision.
    struct DedupOutcome {
        let winnerId: String?
        let suppressed: [(loserId: String, winnerId: String, score: Double, detail: [String: String])]
    }

    /// Reconcile a night's sleep sessions. The winner is the highest-priority sleep session
    /// (ties broken by longer duration, then id, for determinism). Every *same-kind* session
    /// that overlaps the winner by >= `overlapThreshold` is reported as suppressed.
    static func reconcile(sessions: [Session], priorityForSource: (String) -> Int) -> DedupOutcome {
        let sleep = sessions.filter { $0.kind.isSleep }
        guard let winner = sleep.max(by: { a, b in
            let pa = priorityForSource(a.provenance.sourceId)
            let pb = priorityForSource(b.provenance.sourceId)
            if pa != pb { return pa < pb }
            if a.durationSeconds != b.durationSeconds { return a.durationSeconds < b.durationSeconds }
            return a.id < b.id
        }) else {
            return DedupOutcome(winnerId: nil, suppressed: [])
        }

        let winnerPriority = priorityForSource(winner.provenance.sourceId)
        var suppressed: [(loserId: String, winnerId: String, score: Double, detail: [String: String])] = []
        for loser in sleep where loser.id != winner.id && loser.kind == winner.kind {
            let score = overlap((winner.startAt, winner.endAt), (loser.startAt, loser.endAt))
            guard score >= overlapThreshold else { continue }
            let detail: [String: String] = [
                "rule": ruleId,
                "overlap_pct": String(format: "%.1f", score * 100),
                "threshold": String(format: "%.2f", overlapThreshold),
                "winner_source": winner.provenance.sourceId,
                "loser_source": loser.provenance.sourceId,
                "winner_priority": String(winnerPriority),
                "loser_priority": String(priorityForSource(loser.provenance.sourceId)),
            ]
            suppressed.append((loserId: loser.id, winnerId: winner.id, score: score, detail: detail))
        }
        return DedupOutcome(winnerId: winner.id, suppressed: suppressed)
    }
}

// MARK: - workout.session_overlap.v1 (EPIC-03)

extension DedupLite {
    /// Stable id for the workout rule, journaled on every decision so power mode can name it.
    static let workoutRuleId = "workout.session_overlap.v1"
    static let workoutRuleVersion = "v1"

    /// A manual entry must overlap the ingested workout by at least this fraction to be
    /// suppressed. Same 0.70 as sleep, and for the same reason: the ratio is measured against
    /// the SHORTER of the two spans (see `overlap`), so a hand-typed "18:00–19:00" fully
    /// containing a watch's real 18:07–18:49 run scores 1.0, while a genuinely different session
    /// that merely brushes the same hour scores far below the bar and survives untouched.
    static let workoutOverlapThreshold = 0.70

    /// One manual entry suppressed by an ingested workout, ready to be journaled.
    ///
    /// Note the asymmetry with the sleep rule: this returns suppressions of rows in a DIFFERENT
    /// table (`workout_entries`), which has no `suppressed_by` column. Suppression for manual
    /// workouts therefore lives entirely in the `dedup_decisions` journal, and read models ask
    /// `ReconciliationRepository.forSuppressed(entryId)` (whose backing index
    /// `idx_dedup_suppressed` exists for exactly this direction) rather than reading a
    /// denormalized flag. That is fully I3-compliant — the row is untouched, the decision is
    /// journaled, and reversal is `markReversed`, after which the entry reappears with no data
    /// to restore because none was ever removed.
    struct ManualWorkoutSuppression {
        let manualEntryId: String
        let ingestedSessionId: String
        let score: Double
        let detail: [String: String]
    }

    /// Suppress manually-logged workouts that an ingested twin already covers.
    ///
    /// **The ingested row always wins, and that is not a contradiction of I4.** I4 scopes
    /// "manual wins" to weight, blood pressure and lab values — numbers a person reads off a
    /// display and types once, where a hand entry is a correction. A workout is the opposite
    /// case: the watch recorded duration, energy, average and max heart rate and possibly a
    /// route second by second, while the manual entry is a person remembering "about 45 minutes,
    /// maybe 400 calories" hours later. Suppressing the richer record in favour of the
    /// recollection would discard real measurements. Plan §9.1 states this rule in the same
    /// direction.
    ///
    /// Only `.manual` entries are eligible. An entry already marked `.platformStore` came from
    /// an ingestion path itself and is reconciled by identity upstream, not by overlap here.
    ///
    /// Activity type is deliberately NOT required to match. Manual entries carry free-text
    /// activity labels from the quick-add UI while ingested ones carry `HKTypeMap` slugs, so a
    /// type comparison would be a string-shape lottery that fails exactly when it matters ("Run"
    /// vs `running`). Two heavily-overlapping workout records are the same workout regardless of
    /// what each one calls it — and both labels are journaled in `detail` below, so a wrong call
    /// is visible and reversible rather than silent.
    ///
    /// Pure and static, like `reconcile` above, so the rule is unit-testable without a database.
    static func reconcileWorkouts(ingested: [Session], manual: [WorkoutEntry]) -> [ManualWorkoutSuppression] {
        let candidates = ingested.filter { $0.kind == .workout && $0.deletedAt == nil }
        guard !candidates.isEmpty else { return [] }

        var out: [ManualWorkoutSuppression] = []
        for entry in manual where entry.ingestionPath == .manual && entry.deletedAt == nil {
            // Best-overlapping ingested workout wins the pairing; ties broken by id so a manual
            // entry sitting between two back-to-back ingested workouts always attaches to the
            // same one across re-ingests instead of oscillating (which would re-journal a
            // decision on every sync).
            let best = candidates
                .map { (session: $0, score: overlap(($0.startAt, $0.endAt), (entry.startAt, entry.endAt))) }
                .filter { $0.score >= workoutOverlapThreshold }
                .max { a, b in
                    if a.score != b.score { return a.score < b.score }
                    return a.session.id > b.session.id
                }
            guard let best else { continue }

            let detail: [String: String] = [
                "rule": workoutRuleId,
                "overlap_pct": String(format: "%.1f", best.score * 100),
                "threshold": String(format: "%.2f", workoutOverlapThreshold),
                "kept_kind": "ingested_workout_session",
                "suppressed_kind": "manual_workout_entry",
                "kept_source": best.session.provenance.sourceId,
                "kept_activity": best.session.detail.workout?.activityType ?? "unknown",
                "suppressed_activity": entry.activityType,
            ]
            out.append(ManualWorkoutSuppression(manualEntryId: entry.id, ingestedSessionId: best.session.id,
                                                score: best.score, detail: detail))
        }
        // Deterministic order so a batch's journaled decisions read the same on every run.
        return out.sorted { $0.manualEntryId < $1.manualEntryId }
    }
}
