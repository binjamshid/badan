import Foundation

/// Reads/writes workout GPS traces: `workout_routes` (the consent-bearing parent) and
/// `route_points` (the bulk trace), both introduced in migration v4 (plan §9.2).
///
/// Two things make this repository shaped differently from `MeasurementRepository`:
///
/// 1. **A route is replaced wholesale, never merged.** There is no meaningful "update one GPS
///    fix" operation — half a re-ingested route interleaved with half an old one is a state no
///    reader can interpret. `upsert` therefore deletes the route's existing points and re-inserts
///    the current trace, which is also exactly what migration v4's `route_points` comment says
///    the table is designed for (no per-point `deleted_at`, precisely so that half-states cannot
///    exist).
/// 2. **Points are written in bounded batches** (§13.2 line: "route points batched (500/insert)").
///    A 30-minute run is ~1,800 fixes and a long ride can pass 10,000; one INSERT with 10,000
///    value tuples is 60,000 bound parameters, well past SQLite's default
///    `SQLITE_MAX_VARIABLE_NUMBER` — it would not be slow, it would fail outright. See
///    `pointInsertBatchSize`.
///
/// Consent is NOT enforced here. It is enforced upstream, at read time, in `HealthKitAdapter`:
/// without consent no route is ever read, so no `RouteDTO` exists to reach this repository. This
/// layer's job is to record faithfully — including the `consentSnapshot` under which the rows
/// were captured — not to re-adjudicate a decision it has no user context for.
final class RouteRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// Points per INSERT statement (§13.2).
    ///
    /// 500 points × 7 columns = 3,500 bound parameters, comfortably inside SQLite's default
    /// 32,766-variable ceiling with room for the limit to be lower on some builds. Raising this
    /// buys very little (the cost is dominated by the write itself, not the statement count) and
    /// risks `SQLITE_TOOBIG` on a platform with a tighter limit, so treat it as a ceiling to stay
    /// under rather than a knob to tune upward.
    static let pointInsertBatchSize = 500

    /// Insert or replace one route and its complete point list, inside the caller's transaction.
    ///
    /// Identity is `(session_id, external_id)` rather than the primary key: `workout_routes` has
    /// no unique index on provenance columns (v4 gave it only `idx_workout_routes_session`), so
    /// `ON CONFLICT` has no target to match and a SELECT-then-insert/update is the correct shape
    /// here — unlike the measurement tables, where a real partial unique index exists. Routes are
    /// a handful of rows per user per day, so the extra round trip is not worth a migration.
    ///
    /// Returns the route id that actually won (the existing row's id on an update), which is what
    /// `WorkoutDetail.routeRef` must point at — using the freshly-generated id after an update
    /// would leave the session referencing a route row that does not exist.
    @discardableResult
    func upsert(_ route: WorkoutRoute, points: [RoutePoint]) throws -> String {
        let existingId = try db.query("""
            SELECT id FROM workout_routes WHERE session_id = ? AND external_id IS ? LIMIT 1;
            """,
            [.text(route.sessionId), .string(route.provenance.externalId)]).first?.string("id")

        let routeId = existingId ?? route.id
        let consent = try JSONCoding.encodeOrThrow(route.consentSnapshot)

        if existingId != nil {
            try db.run("""
                UPDATE workout_routes SET
                  point_count = ?, start_at = ?, end_at = ?, consent_snapshot = ?,
                  measured_at = ?, measured_tz = ?, recorded_at = ?, ingested_at = ?,
                  quality_flags = ?, updated_at = ?, deleted_at = ?
                WHERE id = ?;
                """,
                [.int(route.pointCount), .date(route.startAt), .date(route.endAt), .text(consent),
                 .date(route.provenance.measuredAt), .text(route.provenance.measuredTimezone),
                 .date(route.provenance.recordedAt), .date(route.provenance.ingestedAt),
                 .string(Self.encodeFlags(route.provenance.qualityFlags)),
                 .date(route.updatedAt), .date(route.deletedAt), .text(routeId)])
        } else {
            try db.run("""
                INSERT INTO workout_routes
                  (id, session_id, point_count, start_at, end_at, consent_snapshot,
                   \(Rows.provColumns), \(Rows.convColumns))
                VALUES (?, ?, ?, ?, ?, ?, \(Rows.provPlaceholders), \(Rows.convPlaceholders));
                """,
                [.text(routeId), .text(route.sessionId), .int(route.pointCount),
                 .date(route.startAt), .date(route.endAt), .text(consent)]
                + Rows.provParams(route.provenance)
                + Rows.convParams(updatedAt: route.updatedAt, originDeviceId: route.originDeviceId,
                                  deletedAt: route.deletedAt))
        }

        try replacePoints(routeId: routeId, points: points)
        return routeId
    }

    /// Delete-then-bulk-insert this route's points. See the type doc for why replacement is
    /// wholesale; see `pointInsertBatchSize` for why the insert is chunked.
    ///
    /// `seq` is re-derived from the supplied order rather than trusted from the incoming
    /// `RoutePoint.seq` values, so a caller that assembled a trace across several delivery
    /// batches (`HealthKitAdapter.RouteAccumulator`) cannot leave a gap or a duplicate in the
    /// primary key.
    private func replacePoints(routeId: String, points: [RoutePoint]) throws {
        try db.run("DELETE FROM route_points WHERE route_id = ?;", [.text(routeId)])
        guard !points.isEmpty else { return }

        var seq = 0
        for batch in points.badanChunked(Self.pointInsertBatchSize) {
            let placeholders = batch.map { _ in "(?, ?, ?, ?, ?, ?, ?)" }.joined(separator: ", ")
            var params: [SQLValue] = []
            params.reserveCapacity(batch.count * 7)
            for point in batch {
                params.append(contentsOf: [
                    .text(routeId), .int(seq), .real(point.latitude), .real(point.longitude),
                    .double(point.altitudeMeters), .double(point.horizontalAccuracyMeters),
                    .date(point.timestamp),
                ])
                seq += 1
            }
            try db.run("""
                INSERT INTO route_points (route_id, seq, lat, lon, altitude_m, hacc_m, timestamp)
                VALUES \(placeholders);
                """, params)
        }
    }

    /// Routes belonging to one workout session (normally exactly one; the schema permits more
    /// because a multi-segment workout can carry several traces).
    func routes(sessionId: String) throws -> [WorkoutRoute] {
        try db.query("SELECT * FROM workout_routes WHERE session_id = ? AND deleted_at IS NULL ORDER BY start_at ASC;",
                     [.text(sessionId)]).map(Self.readRoute)
    }

    func route(id: String) throws -> WorkoutRoute? {
        try db.query("SELECT * FROM workout_routes WHERE id = ?;", [.text(id)]).first.map(Self.readRoute)
    }

    /// One route's points in trace order.
    ///
    /// Unpaged on purpose: the caller is a map preview or a GPX writer, both of which need the
    /// whole trace, and 10,000 points is ~500 KB of value types — cheaper than the alternative of
    /// a paging protocol every caller has to get right. If a route large enough to matter ever
    /// appears, page here rather than at the call sites.
    func points(routeId: String) throws -> [RoutePoint] {
        try db.query("SELECT * FROM route_points WHERE route_id = ? ORDER BY seq ASC;",
                     [.text(routeId)]).map(Self.readPoint)
    }

    func pointCount(routeId: String) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS c FROM route_points WHERE route_id = ?;",
                         [.text(routeId)]).first?.int("c") ?? 0)
    }

    /// Soft-delete a route (I3: suppress/soft-delete, never hard-delete raw data).
    ///
    /// Its points deliberately stay: they have no independent lifecycle and are only ever reached
    /// through the route, so hiding the parent hides the trace. A hard purge of location data —
    /// which is a different, stronger promise than deletion of a workout — belongs with the
    /// route-consent toggle's own "delete my routes" action, not here.
    @discardableResult
    func softDelete(routeId: String, updatedAt: Date) throws -> Bool {
        try db.run("UPDATE workout_routes SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                   [.date(updatedAt), .date(updatedAt), .text(routeId)]) > 0
    }

    // MARK: - Row readers

    private static func encodeFlags(_ flags: [QualityFlag]) -> String? {
        flags.isEmpty ? nil : flags.map(\.rawValue).joined(separator: ";")
    }

    static func readRoute(_ r: SQLiteRow) -> WorkoutRoute {
        WorkoutRoute(
            id: r.requireString("id"), sessionId: r.requireString("session_id"),
            pointCount: r.intValue("point_count") ?? 0,
            startAt: r.requireDate("start_at"), endAt: r.requireDate("end_at"),
            // A row whose consent snapshot fails to decode is reported as NOT granted rather
            // than defaulting to granted: an unreadable consent record is exactly the case where
            // claiming permission would be least defensible.
            consentSnapshot: JSONCoding.decode(RouteConsent.self, from: r.string("consent_snapshot")) ?? .denied,
            provenance: Rows.readProvenance(r), updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"), deletedAt: r.date("deleted_at"))
    }

    static func readPoint(_ r: SQLiteRow) -> RoutePoint {
        RoutePoint(routeId: r.requireString("route_id"), seq: r.intValue("seq") ?? 0,
                   latitude: r.requireDouble("lat"), longitude: r.requireDouble("lon"),
                   altitudeMeters: r.double("altitude_m"),
                   horizontalAccuracyMeters: r.double("hacc_m"),
                   timestamp: r.requireDate("timestamp"))
    }
}
