import Foundation

/// Storage for flagged pattern-deviation events (`CycleAnomalyEvent` — `cycle_anomaly_events`,
/// sensitive migration v6). Append-only AT CREATION (I2): a new detection always INSERTs a fresh
/// row, mirroring `CyclePredictionRepository.appendPrediction`/`DerivedTrendRepository.appendTrend`.
/// `updateState` is the one deliberate exception — a plain UPDATE of `state`/`updated_at` only,
/// because acknowledging or dismissing an anomaly is a UI lifecycle action on an existing detection
/// fact, not a re-derivation of it, mirroring `DataConflictRepository.markResolved`'s exact shape
/// ("detection facts stay frozen, only the lifecycle state transitions").
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `CycleRecordRepository` uses. `message_key` never carries rendered text (see
/// `CycleAnomalyEvent`'s own doc) — this repository has no method that could persist one.
final class CycleAnomalyEventRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    /// Plain INSERT (never `OR REPLACE`) — append-only at creation, mirrors
    /// `CyclePredictionRepository.appendPrediction`/`CyclePhaseEstimateRepository.appendEstimate`.
    func appendEvent(_ event: CycleAnomalyEvent) throws {
        try sensitive.run("""
            INSERT INTO cycle_anomaly_events
              (id, type, detected_at, basis_window_cycle_ids, severity, message_key, state,
               algorithm_version, confidence, \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
            """,
            [.text(event.id), .text(event.type.rawValue), .date(event.detectedAt),
             .text(JSONCoding.encode(event.basisWindowCycleIds)), .text(event.severity.rawValue),
             .text(event.messageKey), .text(event.state.rawValue), .text(event.algorithmVersion),
             .real(event.confidence)]
            + Rows.convParams(updatedAt: event.updatedAt, originDeviceId: event.originDeviceId,
                              deletedAt: event.deletedAt))
    }

    /// Every live anomaly, most recently detected first — the surfacing read a home/module summary
    /// screen would use.
    func liveEvents() throws -> [CycleAnomalyEvent] {
        try sensitive.query("""
            SELECT * FROM cycle_anomaly_events WHERE deleted_at IS NULL ORDER BY detected_at DESC;
            """).map(Self.readEvent)
    }

    /// Transitions `state` only (acknowledge/dismiss/suppress) — never touches `type`/
    /// `detected_at`/`basis_window_cycle_ids`/`message_key`/`severity`/`confidence`, so the
    /// detection's own facts stay frozen exactly as computed, mirroring
    /// `DataConflictRepository.markResolved`'s one-column-transition shape.
    func updateState(id: String, state: CycleAnomalyState, at date: Date) throws {
        try sensitive.run("UPDATE cycle_anomaly_events SET state = ?, updated_at = ? WHERE id = ?;",
                          [.text(state.rawValue), .date(date), .text(id)])
    }

    static func readEvent(_ r: SQLiteRow) -> CycleAnomalyEvent {
        CycleAnomalyEvent(
            id: r.requireString("id"),
            type: CycleAnomalyType(rawValue: r.requireString("type")) ?? .repeatedIrregularity,
            detectedAt: r.requireDate("detected_at"),
            basisWindowCycleIds: JSONCoding.decode([String].self, from: r.string("basis_window_cycle_ids")) ?? [],
            severity: CycleAnomalySeverity(rawValue: r.requireString("severity")) ?? .low,
            messageKey: r.requireString("message_key"),
            state: CycleAnomalyState(rawValue: r.requireString("state")) ?? .active,
            algorithmVersion: r.requireString("algorithm_version"),
            confidence: r.requireDouble("confidence"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
