import Foundation

/// Reads/writes the measurement chain: raw samples, interval records, sessions and stages.
/// Writes are idempotent by provenance identity `(metric_id, external_id, source_id)` so a
/// re-ingest of the same upstream record is a no-op (sync-readiness / dedup discipline).
final class MeasurementRepository {
    private let db: SQLiteConnection
    /// The sensitive connection, when this repository is routing (A21/D-26). `nil` means
    /// single-connection mode: every row goes to `db`, exactly as before routing existed. Tests
    /// that construct `MeasurementRepository(conn)` with one connection keep that behavior, and so
    /// does `Database.inMemoryFallback()`'s degraded path.
    private let sensitiveDb: SQLiteConnection?
    private let registry: MetricRegistry

    /// - Parameter sensitive: the `badan_sensitive.db` connection. Supply it and rows for
    ///   sensitive-plus metrics (`MeasurementRouting`) are read and written there instead of `db`;
    ///   omit it and this type behaves exactly as it did before D-26's routing seam existed.
    init(_ db: SQLiteConnection, sensitive: SQLiteConnection? = nil, registry: MetricRegistry = .shared) {
        self.db = db
        self.sensitiveDb = sensitive
        self.registry = registry
    }

    /// The connection owning `metricId`'s measurement rows. Every metric-scoped statement below
    /// goes through this — there is no direct `db` use left on a path that takes a metric id.
    private func connection(for metricId: String) -> SQLiteConnection {
        guard let sensitiveDb, MeasurementRouting.isSensitive(metricId: metricId, registry: registry) else { return db }
        return sensitiveDb
    }

    /// The tables sensitive migration 9 actually mirrors. `sessions`/`session_stages` are NOT among
    /// them — a session is never a sensitive-plus metric (`SessionKind` covers sleep and workouts,
    /// all `sensitiveClass: normal`), so those tables exist only in `badan.db`. This set is what
    /// stops a table-name-driven statement from being aimed at a file where the table does not
    /// exist, which would throw "no such table" rather than harmlessly matching zero rows.
    private static let sensitiveMirroredTables: Set<String> = ["raw_samples", "interval_records"]

    /// The connections a statement naming `table` may run against, main first. Used by the few
    /// statements that address a row by primary key or upstream identity WITHOUT a metric id to
    /// route on: running them against both files is correct rather than merely convenient, because
    /// row ids are unique across the pair and the statement matches nothing on whichever file does
    /// not hold the row.
    private func connections(forTable table: String) -> [SQLiteConnection] {
        guard let sensitiveDb, Self.sensitiveMirroredTables.contains(table) else { return [db] }
        return [db, sensitiveDb]
    }

    /// Run a batch of writes as a single transaction instead of one implicit commit+fsync per
    /// row. Any other main-DB repo called from inside `body` shares this same connection (and
    /// its recursive-lock/nesting), so its writes join the same transaction (PERF-02 (audit
    /// 2026-07-12)).
    ///
    /// When routing is on, `body` is bracketed by a transaction on BOTH files (nesting-aware on
    /// each, so an inner repo's own `transaction` still joins rather than re-begins). A throw from
    /// `body` therefore rolls back both. What this deliberately does NOT claim is cross-file
    /// atomicity: two separate SQLite files cannot two-phase-commit, so a process kill in the
    /// instant between the sensitive COMMIT and the main COMMIT can leave the sensitive rows
    /// durable and the main rows rolled back. That window is survivable rather than ignored —
    /// every write in this repository is an idempotent upsert keyed by provenance identity, so the
    /// next ingest of the same upstream records restores agreement. Stating the limit is the point;
    /// a comment claiming atomicity here would be false.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard let sensitiveDb else { return try db.transaction(body) }
        return try db.transaction { try sensitiveDb.transaction(body) }
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
    ///
    /// It also carries `deleted_at` across, which is what makes a tombstone REVIVABLE. Two callers
    /// depend on that and neither worked without it. `IngestionPipeline.applyIngestBatched` applies
    /// upstream deletions before the batch's writes precisely so a row both deleted and re-delivered
    /// in one sync "ends up live rather than stuck soft-deleted" (BUG-10a) — true only if the write
    /// clears the flag the delete just set. And `ImportBatchRepository.undo` now tombstones an
    /// import's rows instead of hard-deleting them (so the delta carries the removal), which would
    /// make a re-import of the same archive permanently invisible if the upsert could not un-delete.
    /// The value is `excluded.deleted_at`, not a hardcoded NULL: a caller writing an already-deleted
    /// row (re-persisting a struct read back from storage) keeps it deleted rather than silently
    /// resurrecting it.
    @discardableResult
    func upsertRawSample(_ s: RawSample) throws -> Bool {
        let wonId = try connection(for: s.metricId).query("""
            INSERT INTO raw_samples
              (id, metric_id, value, unit, original_value, original_unit, start_at, end_at, tz_id,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders))
            ON CONFLICT(metric_id, external_id, source_id) WHERE external_id IS NOT NULL DO UPDATE SET
              value=excluded.value, unit=excluded.unit, original_value=excluded.original_value,
              original_unit=excluded.original_unit, start_at=excluded.start_at, end_at=excluded.end_at,
              tz_id=excluded.tz_id, measured_at=excluded.measured_at, recorded_at=excluded.recorded_at,
              ingested_at=excluded.ingested_at, quality_flags=excluded.quality_flags,
              updated_at=excluded.updated_at, deleted_at=excluded.deleted_at
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
        return try connection(for: metricId).query(sql, params).map(Self.readRawSample)
    }

    // MARK: - IntervalRecord

    /// Insert-or-update by identity in a single statement (PERF-126). The `DO UPDATE SET` clause
    /// also refreshes `start_at`/`end_at`/`tz_id`/`measured_at`/`recorded_at` — the previous
    /// UPDATE path only touched `value`/`unit`/`coverage`, silently dropping a corrected time
    /// span or provenance timestamp on re-ingest (OPT-170). See `upsertRawSample` for how the
    /// `RETURNING id` comparison determines insert vs. update, and for why `deleted_at` is carried
    /// across (a tombstoned row must be revivable by a re-ingest or a re-import).
    @discardableResult
    func upsertIntervalRecord(_ r: IntervalRecord) throws -> Bool {
        let wonId = try connection(for: r.metricId).query("""
            INSERT INTO interval_records
              (id, metric_id, value, unit, start_at, end_at, tz_id, aggregation, coverage,
               \(Rows.provColumns), \(Rows.convColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders))
            ON CONFLICT(metric_id, external_id, source_id) WHERE external_id IS NOT NULL DO UPDATE SET
              value=excluded.value, unit=excluded.unit, start_at=excluded.start_at, end_at=excluded.end_at,
              tz_id=excluded.tz_id, coverage=excluded.coverage, measured_at=excluded.measured_at,
              recorded_at=excluded.recorded_at, ingested_at=excluded.ingested_at, updated_at=excluded.updated_at,
              deleted_at=excluded.deleted_at
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
        return try connection(for: metricId).query(sql, params).map(Self.readIntervalRecord)
    }

    /// The earliest and latest `measured_at` across every live measurement in the NON-sensitive
    /// store — the span a whole-store re-derivation covers.
    ///
    /// Deliberately does not consult the sensitive connection. Scores are derived from the metrics
    /// in the main store, and reaching into `badan_sensitive.db` to compute a window would widen
    /// this repository's routing surface for no gain (I7). `nil` when there is nothing stored yet,
    /// which is a real state on a fresh install and the caller must handle rather than substituting
    /// an arbitrary window.
    ///
    /// Shaped after `ImportBatchRepository.measuredRange`, minus the batch predicate.
    func storedMeasurementSpan() throws -> (from: Date, to: Date)? {
        var earliest: Date?
        var latest: Date?
        for table in ["raw_samples", "interval_records", "sessions"] {
            let row = try db.query("""
                SELECT MIN(measured_at) AS lo, MAX(measured_at) AS hi FROM \(table)
                WHERE deleted_at IS NULL;
                """).first
            if let lo = row?.date("lo") { earliest = earliest.map { min($0, lo) } ?? lo }
            if let hi = row?.date("hi") { latest = latest.map { max($0, hi) } ?? hi }
        }
        guard let from = earliest, let to = latest else { return nil }
        return (from, to)
    }

    func latestInterval(metricId: String) throws -> IntervalRecord? {
        try connection(for: metricId)
            .query("SELECT * FROM interval_records WHERE metric_id = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at DESC LIMIT 1;",
                   [.text(metricId)]).first.map(Self.readIntervalRecord)
    }

    /// Whether ANY row (including soft-deleted/suppressed) exists at this identity — used to
    /// distinguish a genuine correction from backfill noise (BUG-10b: a freshly-computed
    /// zero-valued steps day is only worth writing if a row already exists to correct).
    func intervalRecordExists(metricId: String, externalId: String) throws -> Bool {
        try connection(for: metricId)
            .query("SELECT 1 FROM interval_records WHERE metric_id = ? AND external_id = ? LIMIT 1;",
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
    ///
    /// `deleted_at` is carried across for the reason `upsertRawSample` documents: a tombstoned row
    /// must be revivable by a re-ingest or a re-import, or the tombstone becomes permanent.
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
              updated_at=excluded.updated_at, deleted_at=excluded.deleted_at
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

    /// The "last night" query: the primary sleep session a local night STARTED with.
    ///
    /// (AUDIT 2026-08-06, SLEEP-H1) `ORDER BY start_at ASC` — this used to be `DESC`, which was
    /// wrong the moment a night held more than one unsuppressed `sleepPrimary` row, and it
    /// legitimately can: `HealthKitAdapter` classifies any cluster with 3h+ of asleep time as
    /// primary and files it under the night it ENDS in, while `DedupLite` only suppresses losers
    /// that overlap a winner, so a 13:00–16:30 afternoon sleep survives alongside the night that
    /// ended at 07:00 that morning. `DESC` then made "last night" mean the afternoon episode on
    /// every surface that reads this — the Home sleep card, the Insights sleep row and the
    /// ambient/watch snapshot. `ASC` names the night's first cluster instead, agreeing with
    /// `SleepNight.primarySessionId` (`sessionIds.first`) in the derivation layer.
    ///
    /// This deliberately still returns ONE row, so it remains the wrong thing to compute a night's
    /// DURATION from — that is a sum over the night's whole primary set, which is what
    /// `IngestionPipeline.dedup(night:)` writes into the `sleep.time_asleep` rollup and what
    /// `SleepIntelligenceEngine` derives. Use this for the night's identity and bedtime, not its
    /// totals.
    ///
    /// The `suppressed_by IS NULL` predicate stays: a session that lost a dedup is not the night.
    func primarySleep(localNight: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE kind = 'sleepPrimary' AND local_night = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at ASC LIMIT 1;",
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

    /// Addressed by primary key with no metric id to route on, so it runs against every file that
    /// has this table (see `connections(forTable:)`). Row ids are UUIDs, unique across the pair, so
    /// the statement updates the one row that exists and matches nothing on the other file.
    func setSuppressed(table: String, recordId: String, by winnerId: String?, updatedAt: Date) throws {
        for connection in connections(forTable: table) {
            try connection.run("UPDATE \(table) SET suppressed_by = ?, updated_at = ? WHERE id = ?;",
                               [.string(winnerId), .date(updatedAt), .text(recordId)])
        }
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
        // With a `metricId` this could route to one file, but it deliberately does not: a deletion
        // signal that DOES carry a metric id is not more trustworthy about placement than the row
        // itself, and running both is already the correct behavior for the `metricId == nil` case
        // (`HKDeletedObject` exposes only a UUID). One code path for both shapes beats two.
        var deleted = false
        for connection in connections(forTable: table) {
            if try connection.run(sql, params) > 0 { deleted = true }
        }
        return deleted
    }

    /// The measurement-chain rows tombstoned since `watermark` — for a delta export's `deletions[]`
    /// (§22.6 / EPIC-17). A delta gathers only LIVE rows (every read above filters `deleted_at IS
    /// NULL`), so a row soft-deleted after the last run would otherwise be invisible to a downstream
    /// store that only ever receives additions. This is the one read that deliberately looks PAST
    /// that filter, at `deleted_at` alone.
    ///
    /// The axis is `deleted_at`, not the ingested watermark: a tombstone's job is to report WHEN a
    /// row went away, which the ingested axis says nothing about. `> watermark` (strictly) matches
    /// the cursor's forward-only window; re-reporting a tombstone on a later run until the cursor
    /// advances past it is idempotent for a downstream store (deleting an already-deleted record is
    /// a no-op). Ordered by `record_id` for a deterministic, cross-platform-stable array.
    ///
    /// Spans both files when routing is on. A tombstone for a relocated sensitive-plus row lives in
    /// `badan_sensitive.db`, and omitting it would make a delta export silently under-report
    /// deletions for exactly those metrics — the downstream store would keep serving a reading the
    /// user deleted. The sensitive half queries only the two mirrored tables (migration 9); the
    /// `sessions` arm is main-only, matching where that table exists. Sorting happens once over the
    /// merged rows rather than per file, preserving the deterministic `record_id` order the export
    /// contract depends on.
    func tombstones(since watermark: Date) throws -> [ExportTombstone] {
        func read(_ connection: SQLiteConnection, includeSessions: Bool) throws -> [ExportTombstone] {
            var sql = """
                SELECT id, 'raw_sample' AS entity, deleted_at, tz_id FROM raw_samples WHERE deleted_at > ?
                UNION ALL
                SELECT id, 'interval_record' AS entity, deleted_at, tz_id FROM interval_records WHERE deleted_at > ?
                """
            var params: [SQLValue] = [.date(watermark), .date(watermark)]
            if includeSessions {
                sql += """
                    \nUNION ALL
                    SELECT id, 'session' AS entity, deleted_at, tz_id FROM sessions WHERE deleted_at > ?
                    """
                params.append(.date(watermark))
            }
            return try connection.query(sql + ";", params).map { row in
                ExportTombstone(recordId: row.requireString("id"), entity: row.requireString("entity"),
                                deletedAt: row.requireDate("deleted_at"), tzId: row.requireString("tz_id"))
            }
        }
        var all = try read(db, includeSessions: true)
        if let sensitiveDb { all += try read(sensitiveDb, includeSessions: false) }
        return all.sorted { $0.recordId < $1.recordId }
    }

    func session(id: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE id = ?;", [.text(id)]).first.map(Self.readSession)
    }

    /// One raw sample by primary key, including suppressed rows — a conflict's candidate list names
    /// record ids and nothing else, so resolving it means reading each candidate back. Suppressed
    /// rows are included deliberately: the losing side of an already-applied decision still has to
    /// render when the user reopens "why am I seeing this value?".
    ///
    /// Searches both files for the reason `connections(forTable:)` documents — the id arrives with
    /// no metric attached, and a sensitive-plus candidate lives in the other file.
    func rawSample(id: String) throws -> RawSample? {
        for connection in connections(forTable: "raw_samples") {
            if let row = try connection.query("SELECT * FROM raw_samples WHERE id = ?;", [.text(id)]).first {
                return Self.readRawSample(row)
            }
        }
        return nil
    }

    /// The interval-record counterpart of `rawSample(id:)`, same reasoning throughout.
    func intervalRecord(id: String) throws -> IntervalRecord? {
        for connection in connections(forTable: "interval_records") {
            if let row = try connection.query("SELECT * FROM interval_records WHERE id = ?;", [.text(id)]).first {
                return Self.readIntervalRecord(row)
            }
        }
        return nil
    }

    /// The session stored at an upstream identity, including suppressed and soft-deleted rows.
    ///
    /// (EPIC-03) `upsertSession` returns only whether the row was new, not which id won — on an
    /// update the existing row keeps its id and the caller's freshly-generated one is discarded.
    /// A workout route has to attach to the id that actually won (`workout_routes.session_id`),
    /// so re-reading by identity is the only way to learn it. Covered by `idx_session_identity`
    /// (`(external_id, source_id)`, migration v3), so this is an index seek rather than the scan
    /// a `sessions(kind:...)`-then-filter would have been.
    ///
    /// Suppressed and deleted rows are included deliberately: a route must still resolve to its
    /// session when that session lost a dedup or was removed upstream, otherwise re-ingesting a
    /// restored workout would orphan the trace instead of re-attaching it.
    func session(externalId: String, sourceId: String) throws -> Session? {
        try db.query("SELECT * FROM sessions WHERE external_id = ? AND source_id = ? LIMIT 1;",
                     [.text(externalId), .text(sourceId)]).first.map(Self.readSession)
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
