package net.albayyan.badan.storage.repositories

import net.albayyan.badan.core.MILLIS_PER_DAY
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionDetail
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.SleepStage
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Reads/writes the measurement chain: raw samples, interval records, sessions and stages.
 * Writes are idempotent by provenance identity `(metric_id, external_id, source_id)` so a
 * re-ingest of the same upstream record is a no-op (sync-readiness / dedup discipline).
 */
class MeasurementRepository(private val db: SqliteConnection) {

    // MARK: - RawSample

    /** Insert-or-update by identity. Returns true if a new row was created. */
    fun upsertRawSample(s: RawSample): Boolean {
        val externalId = s.provenance.externalId
        if (externalId != null) {
            val existing = firstId("raw_samples", s.metricId, externalId, s.provenance.sourceId)
            if (existing != null) {
                updateRawSample(s, existing)
                return false
            }
        }
        db.run(
            """
            INSERT INTO raw_samples
              (id, metric_id, value, unit, original_value, original_unit, start_at, end_at, tz_id,
               ${Rows.provColumns}, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf<Any?>(
                s.id, s.metricId, s.value, s.unit,
                s.originalValue, s.originalUnit, s.startAt, s.endAt, s.tzId,
            )
                + Rows.provParams(s.provenance)
                + Rows.convParams(s.updatedAt, s.originDeviceId, s.deletedAt),
        )
        return true
    }

    private fun updateRawSample(s: RawSample, existingId: String) {
        db.run(
            """
            UPDATE raw_samples SET value=?, unit=?, original_value=?, original_unit=?, start_at=?, end_at=?,
              tz_id=?, ingested_at=?, quality_flags=?, updated_at=? WHERE id=?;
            """,
            listOf(
                s.value, s.unit, s.originalValue, s.originalUnit,
                s.startAt, s.endAt, s.tzId, s.provenance.ingestedAt,
                if (s.provenance.qualityFlags.isEmpty()) null else s.provenance.qualityFlags.joinToString(";") { it.code },
                s.updatedAt, existingId,
            ),
        )
    }

    fun rawSamples(metricId: String, from: Long? = null, to: Long? = null, includeSuppressed: Boolean = false): List<RawSample> {
        var sql = "SELECT * FROM raw_samples WHERE metric_id = ? AND deleted_at IS NULL"
        val params = mutableListOf<Any?>(metricId)
        if (!includeSuppressed) sql += " AND suppressed_by IS NULL"
        if (from != null) { sql += " AND measured_at >= ?"; params.add(from) }
        if (to != null) { sql += " AND measured_at <= ?"; params.add(to) }
        sql += " ORDER BY measured_at ASC;"
        return db.query(sql, params).map { readRawSample(it) }
    }

    // MARK: - IntervalRecord

    fun upsertIntervalRecord(r: IntervalRecord): Boolean {
        val externalId = r.provenance.externalId
        if (externalId != null) {
            val existing = firstId("interval_records", r.metricId, externalId, r.provenance.sourceId)
            if (existing != null) {
                db.run(
                    "UPDATE interval_records SET value=?, unit=?, coverage=?, ingested_at=?, updated_at=? WHERE id=?;",
                    listOf(r.value, r.unit, r.coverage, r.provenance.ingestedAt, r.updatedAt, existing),
                )
                return false
            }
        }
        db.run(
            """
            INSERT INTO interval_records
              (id, metric_id, value, unit, start_at, end_at, tz_id, aggregation, coverage,
               ${Rows.provColumns}, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf<Any?>(
                r.id, r.metricId, r.value, r.unit, r.startAt,
                r.endAt, r.tzId, r.aggregation.code, r.coverage,
            )
                + Rows.provParams(r.provenance)
                + Rows.convParams(r.updatedAt, r.originDeviceId, r.deletedAt),
        )
        return true
    }

    fun intervalRecords(metricId: String, from: Long? = null, to: Long? = null, includeSuppressed: Boolean = false): List<IntervalRecord> {
        var sql = "SELECT * FROM interval_records WHERE metric_id = ? AND deleted_at IS NULL"
        val params = mutableListOf<Any?>(metricId)
        if (!includeSuppressed) sql += " AND suppressed_by IS NULL"
        if (from != null) { sql += " AND start_at >= ?"; params.add(from) }
        if (to != null) { sql += " AND start_at <= ?"; params.add(to) }
        sql += " ORDER BY start_at ASC;"
        return db.query(sql, params).map { readIntervalRecord(it) }
    }

    fun latestInterval(metricId: String): IntervalRecord? =
        db.query(
            "SELECT * FROM interval_records WHERE metric_id = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at DESC LIMIT 1;",
            listOf(metricId),
        ).firstOrNull()?.let { readIntervalRecord(it) }

    // MARK: - Session

    fun upsertSession(s: Session, stages: List<SessionStage> = emptyList()): Boolean {
        val externalId = s.provenance.externalId
        if (externalId != null) {
            val existing = firstSessionId(s.kind, externalId, s.provenance.sourceId)
            if (existing != null) {
                // Mirrors updateRawSample's field coverage: refresh subtype/tz_id/quality_flags
                // too, so a corrected upstream session (e.g. Health Connect revising a sleep
                // classification) actually converges to the latest truth on re-ingest instead of
                // silently keeping stale values from the first write forever.
                db.run(
                    "UPDATE sessions SET subtype=?, start_at=?, end_at=?, tz_id=?, local_night=?, detail=?, ingested_at=?, quality_flags=?, updated_at=? WHERE id=?;",
                    listOf(
                        s.subtype, s.startAt, s.endAt, s.tzId, s.localNight, JsonCoding.encode(s.detail),
                        s.provenance.ingestedAt,
                        if (s.provenance.qualityFlags.isEmpty()) null else s.provenance.qualityFlags.joinToString(";") { it.code },
                        s.updatedAt, existing,
                    ),
                )
                return false
            }
        }
        db.run(
            """
            INSERT INTO sessions
              (id, kind, subtype, start_at, end_at, tz_id, local_night, detail,
               ${Rows.provColumns}, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf<Any?>(
                s.id, s.kind.code, s.subtype, s.startAt, s.endAt,
                s.tzId, s.localNight, JsonCoding.encode(s.detail),
            )
                + Rows.provParams(s.provenance)
                + Rows.convParams(s.updatedAt, s.originDeviceId, s.deletedAt),
        )
        for (stage in stages) {
            db.run(
                "INSERT OR REPLACE INTO session_stages (session_id, seq, stage, start_at, end_at) VALUES (?, ?, ?, ?, ?);",
                listOf(stage.sessionId, stage.seq.toLong(), stage.stage.code, stage.startAt, stage.endAt),
            )
        }
        return true
    }

    fun sessions(kind: SessionKind? = null, from: Long? = null, to: Long? = null, includeSuppressed: Boolean = false): List<Session> {
        var sql = "SELECT * FROM sessions WHERE deleted_at IS NULL"
        val params = mutableListOf<Any?>()
        if (!includeSuppressed) sql += " AND suppressed_by IS NULL"
        if (kind != null) { sql += " AND kind = ?"; params.add(kind.code) }
        if (from != null) { sql += " AND start_at >= ?"; params.add(from) }
        if (to != null) { sql += " AND start_at <= ?"; params.add(to) }
        sql += " ORDER BY start_at DESC;"
        return db.query(sql, params).map { readSession(it) }
    }

    /** The "last night" query: the primary sleep session for a local night. */
    fun primarySleep(localNight: String): Session? =
        db.query(
            "SELECT * FROM sessions WHERE kind = 'sleepPrimary' AND local_night = ? AND deleted_at IS NULL AND suppressed_by IS NULL ORDER BY start_at DESC LIMIT 1;",
            listOf(localNight),
        ).firstOrNull()?.let { readSession(it) }

    fun allSleepSessions(localNight: String, includeSuppressed: Boolean): List<Session> {
        var sql = "SELECT * FROM sessions WHERE kind LIKE 'sleep%' AND local_night = ? AND deleted_at IS NULL"
        if (!includeSuppressed) sql += " AND suppressed_by IS NULL"
        sql += " ORDER BY start_at ASC;"
        return db.query(sql, listOf(localNight)).map { readSession(it) }
    }

    /**
     * Every session of one kind attributed to one local day key.
     *
     * Reuses `local_night` for workouts, which is the sleep-attribution column by name only — the
     * pipeline stores each workout's *start* day there (see `IngestionPipeline.ingest`). The name
     * is now doing double duty and that is worth knowing before writing a query against it: it is
     * "the local day this session is filed under", and the rule for computing it differs by kind.
     * Renaming the column would be a migration for no behavioural gain, so the meaning is
     * documented here instead.
     */
    fun sessionsForDay(kind: SessionKind, dayKey: String, includeSuppressed: Boolean): List<Session> {
        // Bounded by start_at first so the query rides `idx_session_kind_start`, then filtered to
        // the exact day in Kotlin. The obvious query — `WHERE kind = ? AND local_night = ?` — is a
        // full scan for workouts: `idx_session_local_night` is a PARTIAL index with
        // `WHERE kind LIKE 'sleep%'`, so it covers sleep and deliberately does not cover this.
        //
        // The window is the day key parsed as UTC, padded a day either side. Padding rather than
        // parsing in the session's own zone because sessions from different sources can carry
        // different zones for the same day key, so there is no single correct zone to parse in;
        // ±1 day covers every real UTC offset (max ±14h) with room to spare, and the exact match
        // below is what actually decides membership.
        val dayStartUtc = dayKeyToUtcMillis(dayKey) ?: return emptyList()
        val from = dayStartUtc - MILLIS_PER_DAY
        val to = dayStartUtc + 2 * MILLIS_PER_DAY

        var sql = "SELECT * FROM sessions WHERE kind = ? AND start_at >= ? AND start_at <= ? AND deleted_at IS NULL"
        if (!includeSuppressed) sql += " AND suppressed_by IS NULL"
        sql += " ORDER BY start_at ASC;"
        return db.query(sql, listOf(kind.code, from, to))
            .map { readSession(it) }
            .filter { it.localNight == dayKey }
    }

    /** "YYYY-MM-DD" -> that day's start instant in UTC. Null for anything not in that shape. */
    private fun dayKeyToUtcMillis(dayKey: String): Long? {
        val parts = dayKey.split("-").mapNotNull { it.toIntOrNull() }
        if (parts.size != 3) return null
        return runCatching {
            java.time.LocalDate.of(parts[0], parts[1], parts[2])
                .atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()
        }.getOrNull()
    }

    /**
     * The stored session id for one upstream identity, or null if it was never written.
     *
     * Exists because `upsertSession` returns only whether a row was created, not which row it
     * touched — sufficient for counting, insufficient for anything that must then reference the
     * row (a route needs its workout's real id, which on an update is the pre-existing one, not
     * the caller's freshly-minted ULID).
     */
    fun sessionIdFor(kind: SessionKind, externalId: String, sourceId: String): String? =
        firstSessionId(kind, externalId, sourceId)

    fun stages(sessionId: String): List<SessionStage> =
        db.query("SELECT * FROM session_stages WHERE session_id = ? ORDER BY seq ASC;", listOf(sessionId))
            .map { row ->
                SessionStage(
                    sessionId = row.requireString("session_id"), seq = row.getInt("seq") ?: 0,
                    stage = SleepStage.fromCode(row.requireString("stage")),
                    startAt = row.requireDate("start_at"), endAt = row.requireDate("end_at"),
                )
            }

    // MARK: - Suppression (dedup)

    fun setSuppressed(table: String, recordId: String, by: String?, updatedAt: Long) {
        db.run(
            "UPDATE $table SET suppressed_by = ?, updated_at = ? WHERE id = ?;",
            listOf(by, updatedAt, recordId),
        )
    }

    fun session(id: String): Session? =
        db.query("SELECT * FROM sessions WHERE id = ?;", listOf(id)).firstOrNull()?.let { readSession(it) }

    // MARK: - Identity lookups

    private fun firstId(table: String, metricId: String, externalId: String, sourceId: String): String? =
        db.query(
            "SELECT id FROM $table WHERE metric_id = ? AND external_id = ? AND source_id = ? LIMIT 1;",
            listOf(metricId, externalId, sourceId),
        ).firstOrNull()?.getString("id")

    private fun firstSessionId(kind: SessionKind, externalId: String, sourceId: String): String? =
        db.query(
            "SELECT id FROM sessions WHERE kind = ? AND external_id = ? AND source_id = ? LIMIT 1;",
            listOf(kind.code, externalId, sourceId),
        ).firstOrNull()?.getString("id")

    // MARK: - Row readers

    companion object {
        fun readRawSample(r: Row): RawSample =
            RawSample(
                id = r.requireString("id"), metricId = r.requireString("metric_id"),
                value = r.requireDouble("value"), unit = r.requireString("unit"),
                originalValue = r.requireDouble("original_value"), originalUnit = r.requireString("original_unit"),
                startAt = r.requireDate("start_at"), endAt = r.getDate("end_at"), tzId = r.requireString("tz_id"),
                provenance = Rows.readProvenance(r), updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )

        fun readIntervalRecord(r: Row): IntervalRecord =
            IntervalRecord(
                id = r.requireString("id"), metricId = r.requireString("metric_id"),
                value = r.requireDouble("value"), unit = r.requireString("unit"),
                startAt = r.requireDate("start_at"), endAt = r.requireDate("end_at"), tzId = r.requireString("tz_id"),
                aggregation = Aggregation.fromCode(r.requireString("aggregation")),
                coverage = r.requireDouble("coverage"), provenance = Rows.readProvenance(r),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )

        fun readSession(r: Row): Session =
            Session(
                id = r.requireString("id"), kind = SessionKind.fromCode(r.requireString("kind")),
                subtype = r.getString("subtype"), startAt = r.requireDate("start_at"), endAt = r.requireDate("end_at"),
                tzId = r.requireString("tz_id"), localNight = r.getString("local_night"),
                detail = JsonCoding.decodeOrNull<SessionDetail>(r.getString("detail")) ?: SessionDetail(),
                provenance = Rows.readProvenance(r), updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )
    }
}
