import Foundation

/// Dedup-lite: the one reconciliation rule BADAN ships at MVP — sleep session overlap. It
/// resolves the everyday case of a phone and a watch both reporting the same night: the
/// higher-priority source wins and the heavily-overlapping same-kind duplicates are
/// suppressed (never deleted, INVARIANT I3). Kept deliberately small and pure so it is
/// trivially testable and the journal can reverse any decision.
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
