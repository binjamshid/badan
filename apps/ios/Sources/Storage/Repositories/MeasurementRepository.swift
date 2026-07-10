import Foundation

/// Reads/writes the measurement chain: raw samples, interval records, sessions and stages.
/// Writes are idempotent by provenance identity `(metric_id, external_id, source_id)` so a
/// re-ingest of the same upstream record is a no-op (sync-readiness / dedup discipline).
final class MeasurementRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - RawSample

    /// Insert-or-update by identity. Returns true if a new row was created.
    @discardableResult
    func upsertRawSample(_ s: RawSample) throws -> Bool {
        if let externalId = s.provenance.externalId,
           let existing = try firstId(from: "raw_samples", metricId: s.metricId,
                                      externalId: externalId, sourceId: s.provenance.sourceId) {
            try updateRawSample(s, existingId: existing)
            return false
        }
        try db.run("""
            INSERT INTO raw_samples
              (id, metric_id, value, unit, original_value, original_unit, start_at, end_at, tz_id,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(s.id), .text(s.metricId), .real(s.value), .text(s.unit),
             .real(s.originalValue), .text(s.originalUnit), .date(s.startAt), .date(s.endAt), .text(s.tzId)]
            + Rows.provParams(s.provenance)
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
        return true
    }

    private func updateRawSample(_ s: RawSample, existingId: String) throws {
        try db.run("""
            UPDATE raw_samples SET value=?, unit=?, original_value=?, original_unit=?, start_at=?, end_at=?,
              tz_id=?, ingested_at=?, quality_flags=?, updated_at=? WHERE id=?;
            """,
            [.real(s.value), .text(s.unit), .real(s.originalValue), .text(s.originalUnit),
             .date(s.startAt), .date(s.endAt), .text(s.tzId), .date(s.provenance.ingestedAt),
             .string(s.provenance.qualityFlags.isEmpty ? nil : s.provenance.qualityFlags.map(\.rawValue).joined(separator: ";")),
             .date(s.updatedAt), .text(existingId)])
    }

    func rawSamples(metricId: String, from: Date? = nil, to: Date? = nil, includeSuppressed: Bool = false) throws -> [RawSample] {
        var sql = "SELECT * FROM raw_samples WHERE metric_id = ? AND deleted_at IS NULL"
        var params: [SQLValue] = [.text(metricId)]
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        if let from { sql += " AND measured_at >= ?"; params.append(.date(from)) }
        if let to { sql += " AND measured_at <= ?"; params.append(.date(to)) }
        sql += " ORDER BY measured_at ASC;"
        return try db.query(sql, params).map(Self.readRawSample)
    }

    // MARK: - IntervalRecord

    @discardableResult
    func upsertIntervalRecord(_ r: IntervalRecord) throws -> Bool {
        if let externalId = r.provenance.externalId,
           let existing = try firstId(from: "interval_records", metricId: r.metricId,
                                      externalId: externalId, sourceId: r.provenance.sourceId) {
            try db.run("UPDATE interval_records SET value=?, unit=?, coverage=?, ingested_at=?, updated_at=? WHERE id=?;",
                       [.real(r.value), .text(r.unit), .real(r.coverage), .date(r.provenance.ingestedAt),
                        .date(r.updatedAt), .text(existing)])
            return false
        }
        try db.run("""
            INSERT INTO interval_records
              (id, metric_id, value, unit, start_at, end_at, tz_id, aggregation, coverage,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
            """,
            [.text(r.id), .text(r.metricId), .real(r.value), .text(r.unit), .date(r.startAt),
             .date(r.endAt), .text(r.tzId), .text(r.aggregation.rawValue), .real(r.coverage)]
            + Rows.provParams(r.provenance)
            + Rows.convParams(updatedAt: r.updatedAt, originDeviceId: r.originDeviceId, deletedAt: r.deletedAt))
        return true
    }

    func intervalRecords(metricId: String, from: Date? = nil, to: Date? = nil, includeSuppressed: Bool = false) throws -> [IntervalRecord] {
        var sql = "SELECT * FROM interval_records WHERE metric_id = ? AND deleted_at IS NULL"
        var params: [SQLValue] = [.text(metricId)]
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        if let from { sql += " AND start_at >= ?"; params.append(.date(from)) }
        if let to { sql += " AND start_at <= ?"; params.append(.date(to)) }
        sql += " ORDER BY start_at ASC;"
        return try db.query(sql, params).map(Self.readIntervalRecord)
    }

    func latestInterval(metricId: String) throws -> IntervalRecord? {
        try db.query("SELECT * FROM interval_records WHERE metric_id = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at DESC LIMIT 1;",
                     [.text(metricId)]).first.map(Self.readIntervalRecord)
    }

    // MARK: - Session

    @discardableResult
    func upsertSession(_ s: Session, stages: [SessionStage] = []) throws -> Bool {
        let isNew: Bool
        if let externalId = s.provenance.externalId,
           let existing = try firstSessionId(kind: s.kind, externalId: externalId, sourceId: s.provenance.sourceId) {
            try db.run("UPDATE sessions SET start_at=?, end_at=?, local_night=?, detail=?, ingested_at=?, updated_at=? WHERE id=?;",
                       [.date(s.startAt), .date(s.endAt), .string(s.localNight), .text(JSONCoding.encode(s.detail)),
                        .date(s.provenance.ingestedAt), .date(s.updatedAt), .text(existing)])
            isNew = false
        } else {
            try db.run("""
                INSERT INTO sessions
                  (id, kind, subtype, start_at, end_at, tz_id, local_night, detail,
                   \(Rows.provColumns), \(Rows.convColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
                """,
                [.text(s.id), .text(s.kind.rawValue), .string(s.subtype), .date(s.startAt), .date(s.endAt),
                 .text(s.tzId), .string(s.localNight), .text(JSONCoding.encode(s.detail))]
                + Rows.provParams(s.provenance)
                + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
            for stage in stages {
                try db.run("INSERT OR REPLACE INTO session_stages (session_id, seq, stage, start_at, end_at) VALUES (?, ?, ?, ?, ?);",
                           [.text(stage.sessionId), .int(stage.seq), .text(stage.stage.rawValue), .date(stage.startAt), .date(stage.endAt)])
            }
            isNew = true
        }
        return isNew
    }

    func sessions(kind: SessionKind? = nil, from: Date? = nil, to: Date? = nil, includeSuppressed: Bool = false) throws -> [Session] {
        var sql = "SELECT * FROM sessions WHERE deleted_at IS NULL"
        var params: [SQLValue] = []
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        if let kind { sql += " AND kind = ?"; params.append(.text(kind.rawValue)) }
        if let from { sql += " AND start_at >= ?"; params.append(.date(from)) }
        if let to { sql += " AND start_at <= ?"; params.append(.date(to)) }
        sql += " ORDER BY start_at DESC;"
        return try db.query(sql, params).map(Self.readSession)
    }

    /// The "last night" query: the primary sleep session for a local night.
    func primarySleep(localNight: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE kind = 'sleepPrimary' AND local_night = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at DESC LIMIT 1;",
                     [.text(localNight)]).first.map(Self.readSession)
    }

    func allSleepSessions(localNight: String, includeSuppressed: Bool) throws -> [Session] {
        var sql = "SELECT * FROM sessions WHERE kind LIKE 'sleep%' AND local_night = ? AND deleted_at IS NULL"
        if !includeSuppressed { sql += " AND suppressed_by IS NULL" }
        sql += " ORDER BY start_at ASC;"
        return try db.query(sql, [.text(localNight)]).map(Self.readSession)
    }

    func stages(sessionId: String) throws -> [SessionStage] {
        try db.query("SELECT * FROM session_stages WHERE session_id = ? ORDER BY seq ASC;", [.text(sessionId)])
            .map { row in
                SessionStage(sessionId: row.requireString("session_id"), seq: row.intValue("seq") ?? 0,
                             stage: SleepStage(rawValue: row.requireString("stage")) ?? .asleepUnspecified,
                             startAt: row.requireDate("start_at"), endAt: row.requireDate("end_at"))
            }
    }

    // MARK: - Suppression (dedup)

    func setSuppressed(table: String, recordId: String, by winnerId: String?, updatedAt: Date) throws {
        try db.run("UPDATE \(table) SET suppressed_by = ?, updated_at = ? WHERE id = ?;",
                   [.string(winnerId), .date(updatedAt), .text(recordId)])
    }

    func session(id: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE id = ?;", [.text(id)]).first.map(Self.readSession)
    }

    // MARK: - Identity lookups

    private func firstId(from table: String, metricId: String, externalId: String, sourceId: String) throws -> String? {
        try db.query("SELECT id FROM \(table) WHERE metric_id = ? AND external_id = ? AND source_id = ? LIMIT 1;",
                     [.text(metricId), .text(externalId), .text(sourceId)]).first?.string("id")
    }
    private func firstSessionId(kind: SessionKind, externalId: String, sourceId: String) throws -> String? {
        try db.query("SELECT id FROM sessions WHERE kind = ? AND external_id = ? AND source_id = ? LIMIT 1;",
                     [.text(kind.rawValue), .text(externalId), .text(sourceId)]).first?.string("id")
    }

    // MARK: - Row readers

    static func readRawSample(_ r: SQLiteRow) -> RawSample {
        RawSample(id: r.requireString("id"), metricId: r.requireString("metric_id"),
                  value: r.requireDouble("value"), unit: r.requireString("unit"),
                  originalValue: r.requireDouble("original_value"), originalUnit: r.requireString("original_unit"),
                  startAt: r.requireDate("start_at"), endAt: r.date("end_at"), tzId: r.requireString("tz_id"),
                  provenance: Rows.readProvenance(r), updatedAt: r.requireDate("updated_at"),
                  originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readIntervalRecord(_ r: SQLiteRow) -> IntervalRecord {
        IntervalRecord(id: r.requireString("id"), metricId: r.requireString("metric_id"),
                       value: r.requireDouble("value"), unit: r.requireString("unit"),
                       startAt: r.requireDate("start_at"), endAt: r.requireDate("end_at"), tzId: r.requireString("tz_id"),
                       aggregation: Aggregation(rawValue: r.requireString("aggregation")) ?? .latest,
                       coverage: r.requireDouble("coverage"), provenance: Rows.readProvenance(r),
                       updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
                       deletedAt: r.date("deleted_at"))
    }

    static func readSession(_ r: SQLiteRow) -> Session {
        Session(id: r.requireString("id"), kind: SessionKind(rawValue: r.requireString("kind")) ?? .sleepPrimary,
                subtype: r.string("subtype"), startAt: r.requireDate("start_at"), endAt: r.requireDate("end_at"),
                tzId: r.requireString("tz_id"), localNight: r.string("local_night"),
                detail: JSONCoding.decode(SessionDetail.self, from: r.string("detail")) ?? SessionDetail(),
                provenance: Rows.readProvenance(r), updatedAt: r.requireDate("updated_at"),
                originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }
}
