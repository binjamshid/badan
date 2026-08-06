import Foundation

/// The metrics whose derivation actually READS a stored calibration (D-36).
///
/// Today that is `readiness.score` and nothing else. `ReadinessEngine.activeCalibration()` is the
/// only call to `FeedbackRepository.latestCalibration` anywhere in `Sources/` that reaches a
/// computed value; `SleepIntelligenceEngine`, `EffortEngine`, `StressEngine` and the mood estimate
/// hold no `FeedbackRepository` at all, so a calibration row written for one of their metrics sits
/// in `metric_calibrations` and moves nothing.
///
/// Collecting feedback for every derived metric is deliberate and stays — it is the evidence
/// priority 3 ("earn the derived numbers") is waiting on, and an offer is what produces it. What
/// must not happen is the app describing *collection* as *adjustment*. Two surfaces therefore read
/// this list instead of inferring the answer from "a row exists", which is the thing that was
/// wrong:
///
/// - `DerivedFeedbackCard` promises adjustment, and counts down to it, only where an adjustment is
///   consumed. Everywhere else it says what is true.
/// - `FootprintCollector` derives `calibrationApplied` from this. Under ADR-0011 a footprint is a
///   statement about METHODOLOGY, and "a calibration was in force" is simply false for a metric no
///   engine calibrates. A closed schema does not help if a field inside it is untrue.
///
/// Adding an engine here is not a copy change. Wire it to read `latestCalibration` at derivation
/// time FIRST, then add its metric id — in that order, or the promise runs ahead of the code again.
enum CalibrationConsumers {
    static let metricIds: Set<String> = [MetricID.readinessScore]

    /// Whether a calibration learned for `metricId` is actually applied to values computed after it.
    static func adjustsFutureValues(of metricId: String) -> Bool { metricIds.contains(metricId) }
}

/// Records feedback and keeps each (metric, method) pair's calibration up to date (D-36).
///
/// Deliberately thin: `FeedbackCalibrator.offset` holds every rule and is pure, this holds only the
/// I/O around it. The split is what makes "no adjustment below the event floor" and "the offset is
/// clamped" testable without a database.
struct CalibrationCoordinator {
    let feedback: FeedbackRepository
    let clock: Clock
    let spec: CalibrationSpec

    /// Record the user's reaction to a derived value and recompute that pair's calibration.
    ///
    /// Recomputing immediately, rather than on the next derivation, is what makes the tenth tap
    /// visibly do something. Existing rows are untouched — the new calibration applies to values
    /// computed after it (I2), which is what the surface says.
    ///
    /// This records for ANY derived metric, on purpose: the feedback is worth keeping even where no
    /// engine reads it yet. Whether the row it appends will ever move a number is
    /// `CalibrationConsumers`' answer, not this type's — and the surfaces that make a claim about
    /// that must ask there rather than take the existence of the row as the claim.
    @discardableResult
    func recordFeedback(metricId: String, periodKey: String, derivedValueId: String,
                        algorithmId: String, algorithmVersion: String,
                        direction: FeedbackDirection) throws -> MetricCalibration? {
        try feedback.record(DerivedFeedback(
            id: ULID.newID(), metricId: metricId, periodKey: periodKey,
            derivedValueId: derivedValueId, algorithmId: algorithmId,
            algorithmVersion: algorithmVersion, direction: direction, createdAt: clock.now()))
        return try recomputeCalibration(metricId: metricId, algorithmId: algorithmId,
                                        algorithmVersion: algorithmVersion)
    }

    /// Recompute and append the calibration for one pair, or append nothing when no adjustment
    /// applies.
    ///
    /// Appends only when the offset actually MOVED. Without that check every tap would append a row
    /// that says the same thing as the one before it, and `metric_calibrations` would grow without
    /// any of those rows explaining a different value.
    @discardableResult
    func recomputeCalibration(metricId: String, algorithmId: String,
                              algorithmVersion: String) throws -> MetricCalibration? {
        let events = try feedback.feedback(metricId: metricId, algorithmId: algorithmId)
        guard let offset = FeedbackCalibrator.offset(from: events, asOf: clock.now(), spec: spec)
        else { return nil }

        let existing = try feedback.latestCalibration(metricId: metricId, algorithmId: algorithmId)
        if let existing, abs(existing.offset - offset) < 0.005, existing.sampleCount == events.count {
            return existing
        }
        let calibration = MetricCalibration(
            id: ULID.newID(), metricId: metricId, algorithmId: algorithmId,
            algorithmVersion: algorithmVersion, offset: offset, sampleCount: events.count,
            computedAt: clock.now())
        try feedback.appendCalibration(calibration)
        return calibration
    }
}
