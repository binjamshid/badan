package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.RoutePoint
import net.albayyan.badan.domain.WorkoutRoute
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Reads/writes `workout_routes` + `route_points` (migration v4, plan §9.2) — the GPS traces
 * attached to ingested workouts, and the only location-bearing data BADAN stores.
 *
 * Separate from `MeasurementRepository` for a reason that is not tidiness: routes are the one
 * entity behind an independent consent gate, and every caller of this class is therefore a caller
 * that must have checked that gate. Folding these methods into the repository every screen
 * already holds would make "who can reach location data" unanswerable by looking at imports, and
 * a route read would become one autocomplete away from any surface in the app.
 *
 * Replacement, not merge: a re-read of the same workout replaces its points wholesale
 * ([upsertRoute] deletes then bulk-inserts). See the `route_points` comment in Schema.kt — a
 * point has no independent lifecycle, so there is no correct way to partially update a trace and
 * no reader that would know how to interpret one.
 */
class RouteRepository(private val db: SqliteConnection) {

    /**
     * Insert or replace one route and all of its points. Returns true if the route row was newly
     * created (false when an existing route for the same upstream identity was refreshed), so
     * `IngestionPipeline` can report "new this run" the same way the measurement upserts do.
     *
     * Identity is `(external_id, source_id)`, matching how every other ingested entity is keyed:
     * `HcTypeMap.routeExternalId` derives it from the workout's platform record id, so re-reading
     * a workout on every sync updates one route instead of accumulating a fresh copy of the same
     * trace daily.
     *
     * Points are inserted inside a transaction (never per-point autocommit): a 10k-point route is
     * 10k statements, and the plan's <2s ingest budget for exactly that size is unreachable if
     * each one fsyncs. The delete-then-insert lives in the same transaction, so a failure
     * mid-write cannot leave a route row pointing at half a trace.
     */
    fun upsertRoute(route: WorkoutRoute, points: List<RoutePoint>): Boolean {
        val externalId = route.provenance.externalId
        val existingId = if (externalId != null) {
            db.query(
                "SELECT id FROM workout_routes WHERE external_id = ? AND source_id = ? LIMIT 1;",
                listOf(externalId, route.provenance.sourceId),
            ).firstOrNull()?.getString("id")
        } else {
            null
        }

        // Points are keyed by the route id, so when refreshing an existing route they must be
        // written under the id already on disk — not the freshly-minted ULID on `route`, which
        // would orphan the old points under the old id and leave `point_count` describing rows
        // nobody can reach.
        val routeId = existingId ?: route.id
        val isNew = existingId == null

        db.transaction {
            if (isNew) {
                db.run(
                    """
                    INSERT INTO workout_routes
                      (id, session_id, point_count, start_at, end_at, consent_snapshot,
                       ${Rows.provColumns}, ${Rows.convColumns})
                    VALUES (?, ?, ?, ?, ?, ?, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
                    """,
                    listOf<Any?>(
                        routeId, route.sessionId, points.size.toLong(), route.startAt, route.endAt,
                        route.consentSnapshot,
                    )
                        + Rows.provParams(route.provenance)
                        + Rows.convParams(route.updatedAt, route.originDeviceId, route.deletedAt),
                )
            } else {
                // `consent_snapshot` is deliberately NOT refreshed here. It records the consent
                // state at first ingest; re-reading the same trace later under a different consent
                // state does not rewrite the history of when it was captured (plan §9.2). The
                // session link is refreshed because a re-ingested workout legitimately gets a new
                // session row id.
                db.run(
                    """
                    UPDATE workout_routes SET session_id=?, point_count=?, start_at=?, end_at=?,
                      ingested_at=?, updated_at=? WHERE id=?;
                    """,
                    listOf(
                        route.sessionId, points.size.toLong(), route.startAt, route.endAt,
                        route.provenance.ingestedAt, route.updatedAt, routeId,
                    ),
                )
            }

            db.run("DELETE FROM route_points WHERE route_id = ?;", listOf(routeId))
            for (p in points) {
                db.run(
                    """
                    INSERT INTO route_points (route_id, seq, lat, lon, altitude_m, hacc_m, timestamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    listOf<Any?>(
                        routeId, p.seq.toLong(), p.lat, p.lon, p.altitudeM, p.horizontalAccuracyM,
                        p.timestamp,
                    ),
                )
            }
        }
        return isNew
    }

    /** The routes recorded for one workout session. Usually zero or one; a list because nothing
     *  in the schema forbids a source splitting a session's trace. */
    fun routes(sessionId: String): List<WorkoutRoute> =
        db.query(
            "SELECT * FROM workout_routes WHERE session_id = ? AND deleted_at IS NULL ORDER BY start_at ASC;",
            listOf(sessionId),
        ).map { readRoute(it) }

    fun route(id: String): WorkoutRoute? =
        db.query("SELECT * FROM workout_routes WHERE id = ?;", listOf(id)).firstOrNull()?.let { readRoute(it) }

    /**
     * A route's points in recorded order.
     *
     * No range/limit parameter: a route is bounded by the workout that produced it (thousands of
     * points, not millions), and the callers that exist — map preview, GPX export — both need the
     * whole trace. A partial trace is a wrong map, not a cheaper one.
     */
    fun points(routeId: String): List<RoutePoint> =
        db.query("SELECT * FROM route_points WHERE route_id = ? ORDER BY seq ASC;", listOf(routeId))
            .map { r ->
                RoutePoint(
                    routeId = r.requireString("route_id"), seq = r.getInt("seq") ?: 0,
                    lat = r.requireDouble("lat"), lon = r.requireDouble("lon"),
                    altitudeM = r.getDouble("altitude_m"), horizontalAccuracyM = r.getDouble("hacc_m"),
                    timestamp = r.requireDate("timestamp"),
                )
            }

    /**
     * Hard-delete every route and point.
     *
     * The one place in the measurement layer where a real DELETE is correct rather than a
     * suppression (contrast I3, which governs dedup). This backs "turn route capture off and
     * remove what was collected": a soft-deleted route still has the user's coordinates in the
     * file, so a soft delete would not be the thing the toggle appears to promise. The same
     * reasoning I7 applies to the sensitive namespace, at a smaller scale.
     */
    fun purgeAll() {
        db.transaction {
            db.run("DELETE FROM route_points;")
            db.run("DELETE FROM workout_routes;")
        }
    }

    /** Whether any route data exists at all — cheap enough to drive a settings-screen disclosure
     *  without loading coordinates into a surface that has no business holding them. */
    fun routeCount(): Int =
        db.query("SELECT COUNT(*) AS n FROM workout_routes WHERE deleted_at IS NULL;")
            .firstOrNull()?.getInt("n") ?: 0

    private fun readRoute(r: Row): WorkoutRoute =
        WorkoutRoute(
            id = r.requireString("id"), sessionId = r.requireString("session_id"),
            pointCount = r.getInt("point_count") ?: 0,
            startAt = r.requireDate("start_at"), endAt = r.requireDate("end_at"),
            consentSnapshot = r.requireString("consent_snapshot"),
            provenance = Rows.readProvenance(r), updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
        )
}
