import Foundation

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
