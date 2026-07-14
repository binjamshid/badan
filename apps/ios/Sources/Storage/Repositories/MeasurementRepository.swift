import Foundation

/// Reads/writes the measurement chain: raw samples, interval records, sessions and stages.
/// Writes are idempotent by provenance identity `(metric_id, external_id, source_id)` so a
/// re-ingest of the same upstream record is a no-op (sync-readiness / dedup discipline).
final class MeasurementRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// Run a batch of writes as a single transaction instead of one implicit commit+fsync per
    /// row. Any other main-DB repo called from inside `body` shares this same connection (and
    /// its recursive-lock/nesting), so its writes join the same transaction (PERF-02 (audit
    /// 2026-07-12)).
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    // MARK: - RawSample

    /// Insert-or-update by identity `(metric_id, external_id, source_id)` in a single statement
    /// (PERF-125), replacing the previous SELECT-then-INSERT/UPDATE round trip. `RETURNING id`
    /// tells us which row won: on conflict the existing row's `id` is left untouched by the
    /// `DO UPDATE SET` clause, so it differs from the fresh `s.id` we attempted to insert.
    /// Returns true if a new row was created.
    ///
    /// The `DO UPDATE SET` clause also refreshes `measured_at`/`recorded_at` (DATA-12) —
    /// mirroring `upsertIntervalRecord`'s OPT-170 fix — so a re-ingest with a corrected
    /// measured/recorded timestamp isn't silently dropped.
    @discardableResult
    func upsertRawSample(_ s: RawSample) throws -> Bool {
        let wonId = try db.query("""
            INSERT INTO raw_samples
              (id, metric_id, value, unit, original_value, original_unit, start_at, end_at, tz_id,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders))
            ON CONFLICT(metric_id, external_id, source_id) WHERE external_id IS NOT NULL DO UPDATE SET
              value=excluded.value, unit=excluded.unit, original_value=excluded.original_value,
              original_unit=excluded.original_unit, start_at=excluded.start_at, end_at=excluded.end_at,
              tz_id=excluded.tz_id, measured_at=excluded.measured_at, recorded_at=excluded.recorded_at,
              ingested_at=excluded.ingested_at, quality_flags=excluded.quality_flags,
              updated_at=excluded.updated_at
            RETURNING id;
            """,
            [.text(s.id), .text(s.metricId), .real(s.value), .text(s.unit),
             .real(s.originalValue), .text(s.originalUnit), .date(s.startAt), .date(s.endAt), .text(s.tzId)]
            + Rows.provParams(s.provenance)
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
            .first?.string("id")
        return wonId == s.id
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

    /// Insert-or-update by identity in a single statement (PERF-126). The `DO UPDATE SET` clause
    /// also refreshes `start_at`/`end_at`/`tz_id`/`measured_at`/`recorded_at` — the previous
    /// UPDATE path only touched `value`/`unit`/`coverage`, silently dropping a corrected time
    /// span or provenance timestamp on re-ingest (OPT-170). See `upsertRawSample` for how the
    /// `RETURNING id` comparison determines insert vs. update.
    @discardableResult
    func upsertIntervalRecord(_ r: IntervalRecord) throws -> Bool {
        let wonId = try db.query("""
            INSERT INTO interval_records
              (id, metric_id, value, unit, start_at, end_at, tz_id, aggregation, coverage,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders))
            ON CONFLICT(metric_id, external_id, source_id) WHERE external_id IS NOT NULL DO UPDATE SET
              value=excluded.value, unit=excluded.unit, start_at=excluded.start_at, end_at=excluded.end_at,
              tz_id=excluded.tz_id, coverage=excluded.coverage, measured_at=excluded.measured_at,
              recorded_at=excluded.recorded_at, ingested_at=excluded.ingested_at, updated_at=excluded.updated_at
            RETURNING id;
            """,
            [.text(r.id), .text(r.metricId), .real(r.value), .text(r.unit), .date(r.startAt),
             .date(r.endAt), .text(r.tzId), .text(r.aggregation.rawValue), .real(r.coverage)]
            + Rows.provParams(r.provenance)
            + Rows.convParams(updatedAt: r.updatedAt, originDeviceId: r.originDeviceId, deletedAt: r.deletedAt))
            .first?.string("id")
        return wonId == r.id
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

    /// Whether ANY row (including soft-deleted/suppressed) exists at this identity — used to
    /// distinguish a genuine correction from backfill noise (BUG-10b: a freshly-computed
    /// zero-valued steps day is only worth writing if a row already exists to correct).
    func intervalRecordExists(metricId: String, externalId: String) throws -> Bool {
        try db.query("SELECT 1 FROM interval_records WHERE metric_id = ? AND external_id = ? LIMIT 1;",
                     [.text(metricId), .text(externalId)]).first != nil
    }

    // MARK: - Session

    /// Insert-or-update by identity in a single statement (PERF-127). Stage rows are keyed off
    /// the *winning* session id (the existing row's id on an update, since `DO UPDATE SET` never
    /// touches `id` — not `stage.sessionId`, which callers set from the freshly-generated `s.id`
    /// that may differ from an existing matched row). When `stages` is supplied, any previously
    /// stored stages for that session are replaced so corrected/late-arriving stage data from a
    /// re-delivered session isn't silently dropped (OPT-169); omitting `stages:` (e.g. the dedup
    /// path) leaves existing stages untouched.
    ///
    /// The `DO UPDATE SET` clause also refreshes `tz_id`/`measured_at`/`measured_tz`/
    /// `recorded_at` (DATA-12) — mirroring `upsertIntervalRecord`'s OPT-170 fix — so a
    /// re-ingest after e.g. a corrected per-sample timezone (DATA-07) isn't silently dropped.
    ///
    /// (BUG-11c) The conflict target is `(external_id, source_id)` — deliberately NOT
    /// `(kind, external_id, source_id)` the way it used to be. `kind` (primary vs. nap, a
    /// 3-hour asleep-time threshold — see `HealthKitAdapter.sleepPrimaryMinSeconds`) can
    /// legitimately flip between two re-ingests of the SAME night once more of it has synced
    /// (`HealthKitAdapter`'s night-rebuild seam recomputes `kind` from the full current sample
    /// set every time). With `kind` inside the identity, that flip's INSERT couldn't match the
    /// existing row (its stored `kind` differs from the fresh one) and landed as a brand-new
    /// duplicate row instead of updating in place — this is the fix. `kind` and `subtype` are
    /// now in the `DO UPDATE SET` list so a flip actually overwrites the stored value. This
    /// target MUST match `Migrations.swift`'s `idx_session_identity` (v3) column-for-column,
    /// including the partial-index predicate — SQLite requires an exact match between an
    /// `ON CONFLICT` target and a real unique index/constraint, mirroring the exact-match
    /// requirement already noted on this table's other partial indexes.
    @discardableResult
    func upsertSession(_ s: Session, stages: [SessionStage] = []) throws -> Bool {
        let wonId = try db.query("""
            INSERT INTO sessions
              (id, kind, subtype, start_at, end_at, tz_id, local_night, detail,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders))
            ON CONFLICT(external_id, source_id) WHERE external_id IS NOT NULL DO UPDATE SET
              kind=excluded.kind, subtype=excluded.subtype,
              start_at=excluded.start_at, end_at=excluded.end_at, tz_id=excluded.tz_id,
              local_night=excluded.local_night, detail=excluded.detail,
              measured_at=excluded.measured_at, measured_tz=excluded.measured_tz,
              recorded_at=excluded.recorded_at, ingested_at=excluded.ingested_at,
              updated_at=excluded.updated_at
            RETURNING id;
            """,
            [.text(s.id), .text(s.kind.rawValue), .string(s.subtype), .date(s.startAt), .date(s.endAt),
             .text(s.tzId), .string(s.localNight), .text(try JSONCoding.encodeOrThrow(s.detail))]
            + Rows.provParams(s.provenance)
            + Rows.convParams(updatedAt: s.updatedAt, originDeviceId: s.originDeviceId, deletedAt: s.deletedAt))
            .first?.string("id")
        let sessionId = wonId ?? s.id
        let isNew = sessionId == s.id

        if !stages.isEmpty {
            try db.run("DELETE FROM session_stages WHERE session_id = ?;", [.text(sessionId)])
            let placeholders = stages.map { _ in "(?, ?, ?, ?, ?)" }.joined(separator: ", ")
            var params: [SQLValue] = []
            params.reserveCapacity(stages.count * 5)
            for stage in stages {
                params.append(contentsOf: [.text(sessionId), .int(stage.seq), .text(stage.stage.rawValue),
                                            .date(stage.startAt), .date(stage.endAt)])
            }
            try db.run("INSERT OR REPLACE INTO session_stages (session_id, seq, stage, start_at, end_at) VALUES \(placeholders);", params)
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
            .map(Self.readSessionStage)
    }

    /// Batched form of `stages(sessionId:)` for callers rendering stage detail across several
    /// sessions at once (e.g. a week-of-sleep-stages view), avoiding a structural N+1 (PERF-142).
    func stages(sessionIds: [String]) throws -> [String: [SessionStage]] {
        guard !sessionIds.isEmpty else { return [:] }
        let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try db.query("SELECT * FROM session_stages WHERE session_id IN (\(placeholders)) ORDER BY session_id, seq ASC;",
                                 sessionIds.map { .text($0) })
        var byId: [String: [SessionStage]] = [:]
        for row in rows {
            let stage = Self.readSessionStage(row)
            byId[stage.sessionId, default: []].append(stage)
        }
        return byId
    }

    private static func readSessionStage(_ row: SQLiteRow) -> SessionStage {
        SessionStage(sessionId: row.requireString("session_id"), seq: row.intValue("seq") ?? 0,
                     stage: SleepStage(rawValue: row.requireString("stage")) ?? .asleepUnspecified,
                     startAt: row.requireDate("start_at"), endAt: row.requireDate("end_at"))
    }

    // MARK: - Suppression (dedup)

    func setSuppressed(table: String, recordId: String, by winnerId: String?, updatedAt: Date) throws {
        try db.run("UPDATE \(table) SET suppressed_by = ?, updated_at = ? WHERE id = ?;",
                   [.string(winnerId), .date(updatedAt), .text(recordId)])
    }

    /// Soft-delete (INVARIANT I3: never hard-delete, mirrors `setSuppressed` above) the row
    /// matching this upstream identity (BUG-10). `metricId`/`sourceId` are both optional because
    /// a deletion signal doesn't always carry them — `HKDeletedObject` exposes only the deleted
    /// sample's own UUID, no metric or source info — but `externalId` alone (a HealthKit-
    /// generated UUID, globally unique regardless of source) is enough to disambiguate the row
    /// without them. Idempotent: re-applying the same deletion twice is a no-op (`deleted_at IS
    /// NULL` in the WHERE clause), matching every other write in this repository.
    @discardableResult
    func softDelete(table: String, metricId: String?, externalId: String, sourceId: String?, updatedAt: Date) throws -> Bool {
        var sql = "UPDATE \(table) SET deleted_at = ?, updated_at = ? WHERE external_id = ? AND deleted_at IS NULL"
        var params: [SQLValue] = [.date(updatedAt), .date(updatedAt), .text(externalId)]
        if let metricId {
            sql += " AND metric_id = ?"
            params.append(.text(metricId))
        }
        if let sourceId {
            sql += " AND source_id = ?"
            params.append(.text(sourceId))
        }
        sql += ";"
        return try db.run(sql, params) > 0
    }

    func session(id: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE id = ?;", [.text(id)]).first.map(Self.readSession)
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
