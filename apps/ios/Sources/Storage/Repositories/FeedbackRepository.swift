import Foundation

/// User feedback on derived values, and the personal calibrations learned from it (D-36).
///
/// Both tables live in the MAIN database, alongside `derived_values` itself. A direction ("this
/// number read high") carries no health value and names no condition, so it does not meet the
/// sensitive-plus bar the way a journal entry or a symptom does.
///
/// Feedback is keyed uniquely per (metric, period, algorithm) so a user can change their mind about
/// a day without stacking three contradictory opinions of it; calibrations are append-only and
/// latest-wins, exactly like `derived_values` (I2).
final class FeedbackRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Feedback

    /// Record (or replace) the user's reaction to one derived value.
    ///
    /// `ON CONFLICT … DO UPDATE` on the `(metric_id, period_key, algorithm_id)` index: tapping
    /// "doesn't match" and then changing to "matches" must leave ONE opinion of that day, not two
    /// that cancel. Replacing rather than appending is right here precisely because this is a
    /// preference about a day, not an observation of it — I2 governs derived values, not opinions.
    func record(_ feedback: DerivedFeedback) throws {
        try db.run("""
            INSERT INTO derived_feedback
              (id, metric_id, period_key, derived_value_id, algorithm_id, algorithm_version,
               direction, created_at, updated_at, origin_device_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(metric_id, period_key, algorithm_id) WHERE deleted_at IS NULL DO UPDATE SET
              direction = excluded.direction,
              derived_value_id = excluded.derived_value_id,
              algorithm_version = excluded.algorithm_version,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at;
            """, [.text(feedback.id), .text(feedback.metricId), .text(feedback.periodKey),
                  .text(feedback.derivedValueId), .text(feedback.algorithmId),
                  .text(feedback.algorithmVersion), .text(feedback.direction.rawValue),
                  .date(feedback.createdAt), .date(feedback.createdAt), .text("local")])
    }

    /// Every live opinion for one (metric, method) pair, newest first.
    ///
    /// Scoped by `algorithmId` because that scoping is the point: feedback about the sleep-led
    /// method must never calibrate the autonomic one. A method the user has not given feedback on
    /// returns nothing and is therefore uncalibrated, which the surface says out loud.
    func feedback(metricId: String, algorithmId: String) throws -> [DerivedFeedback] {
        try db.query("""
            SELECT * FROM derived_feedback
            WHERE metric_id = ? AND algorithm_id = ? AND deleted_at IS NULL
            ORDER BY created_at DESC;
            """, [.text(metricId), .text(algorithmId)]).compactMap(Self.readFeedback)
    }

    func feedbackForPeriod(metricId: String, periodKey: String,
                           algorithmId: String) throws -> DerivedFeedback? {
        try db.query("""
            SELECT * FROM derived_feedback
            WHERE metric_id = ? AND period_key = ? AND algorithm_id = ? AND deleted_at IS NULL
            LIMIT 1;
            """, [.text(metricId), .text(periodKey), .text(algorithmId)])
            .compactMap(Self.readFeedback).first
    }

    // MARK: - Calibrations

    func appendCalibration(_ calibration: MetricCalibration) throws {
        try db.run("""
            INSERT INTO metric_calibrations
              (id, metric_id, algorithm_id, algorithm_version, offset, sample_count, computed_at,
               updated_at, origin_device_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(calibration.id), .text(calibration.metricId), .text(calibration.algorithmId),
                  .text(calibration.algorithmVersion), .real(calibration.offset),
                  .int(calibration.sampleCount), .date(calibration.computedAt),
                  .date(calibration.computedAt), .text("local")])
    }

    /// The calibration in force for a (metric, method) pair: latest by `computed_at`.
    ///
    /// Latest-wins rather than "the only one", because older rows are kept — they are what explain
    /// a value computed while they were in force. Switching method does not delete the calibration
    /// for the method left behind, so switching back restores it.
    func latestCalibration(metricId: String, algorithmId: String) throws -> MetricCalibration? {
        try db.query("""
            SELECT * FROM metric_calibrations
            WHERE metric_id = ? AND algorithm_id = ? AND deleted_at IS NULL
            ORDER BY computed_at DESC LIMIT 1;
            """, [.text(metricId), .text(algorithmId)]).compactMap(Self.readCalibration).first
    }

    func calibration(id: String) throws -> MetricCalibration? {
        try db.query("SELECT * FROM metric_calibrations WHERE id = ?;", [.text(id)])
            .compactMap(Self.readCalibration).first
    }

    /// "Delete my feedback and calibrations." Removes both tables' contents outright.
    ///
    /// A hard delete, not a tombstone: this is the user asking for their opinions to be gone, and a
    /// soft-deleted opinion is still a stored opinion. Derived rows already computed are NOT
    /// rewritten — they keep their `calibration:` manifest input and therefore still disclose that
    /// they were adjusted, which is the honest outcome and what the surface says will happen.
    func deleteAllFeedbackAndCalibrations() throws {
        try db.run("DELETE FROM derived_feedback;")
        try db.run("DELETE FROM metric_calibrations;")
    }

    // MARK: - Mapping

    private static func readFeedback(_ r: SQLiteRow) -> DerivedFeedback? {
        guard let direction = FeedbackDirection(rawValue: r.requireString("direction")) else { return nil }
        return DerivedFeedback(
            id: r.requireString("id"), metricId: r.requireString("metric_id"),
            periodKey: r.requireString("period_key"),
            derivedValueId: r.requireString("derived_value_id"),
            algorithmId: r.requireString("algorithm_id"),
            algorithmVersion: r.requireString("algorithm_version"),
            direction: direction, createdAt: r.requireDate("created_at"))
    }

    private static func readCalibration(_ r: SQLiteRow) -> MetricCalibration? {
        MetricCalibration(
            id: r.requireString("id"), metricId: r.requireString("metric_id"),
            algorithmId: r.requireString("algorithm_id"),
            algorithmVersion: r.requireString("algorithm_version"),
            offset: r.requireDouble("offset"), sampleCount: Int(r.int("sample_count") ?? 0),
            computedAt: r.requireDate("computed_at"))
    }
}
