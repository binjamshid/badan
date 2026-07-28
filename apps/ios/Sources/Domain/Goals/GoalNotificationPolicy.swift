import Foundation

/// The most recent canonical reading for a metric, whichever shape it is stored in.
///
/// Lifted out of `GoalsViewModel`, where it was a `private static` on a `@MainActor @Observable`
/// view model. The goal-reached producer needs exactly the same lookup, and two implementations of
/// "what is this metric's current value?" would drift — one of them silently, since the failure mode
/// is a goal that reads as reached on one surface and not on the other.
///
/// Goals can target any metric in the ontology, and the ontology stores values three ways: interval
/// aggregates (steps, energy), instant samples (weight, heart rate) and engine-derived values
/// (readiness, sleep performance). Checking all three — rather than assuming one — is what lets a
/// goal be set on any metric instead of an arbitrary subset.
enum GoalMetricValue {
    static func current(for metricId: String,
                        measurements: MeasurementRepository,
                        derivation: DerivationRepository) -> Double? {
        if let interval = try? measurements.latestInterval(metricId: metricId) { return interval.value }
        if let sample = try? measurements.rawSamples(metricId: metricId).last { return sample.value }
        if let derived = try? derivation.latestDerivedSeries(metricId: metricId).last { return derived.value }
        return nil
    }
}

/// Decides whether a `goalReached` notification should be raised, over the existing pure
/// `GoalEvaluation.evaluate`.
///
/// ## What this deliberately does not do
///
/// There is no `goalAtRisk` counterpart, and there will not be one by accident. `GoalEvaluation`'s
/// own doc states the rule: "There is no scoring, no streak and no judgement here by design: BADAN
/// describes, it doesn't grade." Reaching a goal is a fact that occurred and can be stated flatly. A
/// notification saying you are behind with hours left is a verdict on your day and a prompt to fix
/// it — the shape of thing this app's guardrails exist to keep out, however gently it is worded.
///
/// ## Once a day, without new storage
///
/// A user with six goals could reach four of them in an afternoon. Rather than track per-goal
/// announcements — which would need a column the `notification_deliveries` ledger does not have —
/// this announces at most one goal per day and lets the ledger's existing class+day idempotency
/// enforce the "once" for free. The copy is correspondingly general ("a goal you set"), so it stays
/// true whichever goal triggered it and no reading is named unless the user opted into values.
enum GoalNotificationPolicy {

    /// One goal's standing, as the producer reads it.
    struct Candidate: Equatable {
        let goalId: String
        let active: Bool
        let evaluation: GoalEvaluation

        init(goalId: String, active: Bool, evaluation: GoalEvaluation) {
            self.goalId = goalId
            self.active = active
            self.evaluation = evaluation
        }
    }

    /// The goal to announce, or `nil` if none qualifies.
    ///
    /// Sorted by id rather than taken in storage order so the choice is deterministic: the same day
    /// with the same data must pick the same goal every time it is evaluated, or a foreground
    /// evaluation and a background one could disagree about which goal was announced.
    ///
    /// A paused goal is skipped even when its metric is past target — the user switched it off, and
    /// a notification about a goal they are not currently keeping is noise about a decision they
    /// already made.
    static func goalToAnnounce(_ candidates: [Candidate]) -> Candidate? {
        candidates
            .filter { $0.active && $0.evaluation == .onTrack }
            .sorted { $0.goalId < $1.goalId }
            .first
    }
}
