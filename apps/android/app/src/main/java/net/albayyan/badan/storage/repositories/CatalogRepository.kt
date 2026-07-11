package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceStatus
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.domain.UserProfile
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Reference & identity: sources, devices, permission states, and the single user profile.
 * These describe *where data comes from* and back the Data Sources and Provenance screens.
 */
class CatalogRepository(private val db: SqliteConnection) {

    // MARK: - Sources

    fun upsertSource(s: Source) {
        db.run(
            """
            INSERT OR REPLACE INTO sources
              (id, type, display_name, platform_bundle_id, status, connected_at, last_delivery_at,
               updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                s.id, s.type.code, s.displayName, s.platformBundleId,
                s.status.code, s.connectedAt, s.lastDeliveryAt,
                s.updatedAt, s.originDeviceId, s.deletedAt,
            ),
        )
    }

    // Intentionally unbounded: a user's connected-source count is small by construction (one row
    // per health app/platform integration, not per data point), so no LIMIT is needed at any
    // realistic scale.
    fun sources(includeHidden: Boolean = true): List<Source> {
        var sql = "SELECT * FROM sources WHERE deleted_at IS NULL"
        if (!includeHidden) sql += " AND status != 'hidden'"
        sql += " ORDER BY display_name ASC;"
        return db.query(sql).map { readSource(it) }
    }

    fun source(id: String): Source? =
        db.query("SELECT * FROM sources WHERE id = ?;", listOf(id)).firstOrNull()?.let { readSource(it) }

    fun setSourceStatus(id: String, status: SourceStatus, updatedAt: Long) {
        db.run(
            "UPDATE sources SET status = ?, updated_at = ? WHERE id = ?;",
            listOf(status.code, updatedAt, id),
        )
    }

    // MARK: - Devices

    fun upsertDevice(d: Device) {
        db.run(
            """
            INSERT OR REPLACE INTO source_devices
              (id, source_id, name, model, first_seen, last_seen, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                d.id, d.sourceId, d.name, d.model, d.firstSeen,
                d.lastSeen, d.updatedAt, d.originDeviceId, d.deletedAt,
            ),
        )
    }

    fun devices(sourceId: String? = null): List<Device> {
        val sql = if (sourceId == null) {
            "SELECT * FROM source_devices WHERE deleted_at IS NULL ORDER BY name;"
        } else {
            "SELECT * FROM source_devices WHERE source_id = ? AND deleted_at IS NULL ORDER BY name;"
        }
        val params: List<Any?> = if (sourceId != null) listOf(sourceId) else emptyList()
        return db.query(sql, params).map { r ->
            Device(
                id = r.requireString("id"), sourceId = r.requireString("source_id"), name = r.requireString("name"),
                model = r.getString("model"), firstSeen = r.requireDate("first_seen"), lastSeen = r.requireDate("last_seen"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )
        }
    }

    // MARK: - Permission states

    fun upsertPermission(p: PermissionState) {
        db.run(
            """
            INSERT OR REPLACE INTO permission_states (store, platform_type, status, last_checked_at, last_read_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            listOf(p.store, p.platformType, p.status.code, p.lastCheckedAt, p.lastReadAt),
        )
    }

    // Intentionally unbounded: one row per (store, platform_type) pair, a small fixed set.
    fun permissions(store: String? = null): List<PermissionState> {
        val sql = if (store == null) {
            "SELECT * FROM permission_states ORDER BY platform_type;"
        } else {
            "SELECT * FROM permission_states WHERE store = ? ORDER BY platform_type;"
        }
        val params: List<Any?> = if (store != null) listOf(store) else emptyList()
        return db.query(sql, params).map { r ->
            PermissionState(
                store = r.requireString("store"), platformType = r.requireString("platform_type"),
                status = PermissionStatus.fromCode(r.requireString("status")),
                lastCheckedAt = r.requireDate("last_checked_at"), lastReadAt = r.getDate("last_read_at"),
            )
        }
    }

    // MARK: - User profile

    fun userProfile(): UserProfile? =
        db.query("SELECT * FROM user_profile LIMIT 1;").firstOrNull()?.let { r ->
            UserProfile(
                id = r.requireString("id"), displayName = r.getString("display_name"),
                heightMeters = r.getDouble("height_m"), birthYear = r.getInt("birth_year"),
                biologicalContextNote = r.getString("bio_note"), createdAt = r.requireDate("created_at"),
                updatedAt = r.requireDate("updated_at"),
            )
        }

    fun saveUserProfile(p: UserProfile) {
        db.run(
            """
            INSERT OR REPLACE INTO user_profile (id, display_name, height_m, birth_year, bio_note, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                p.id, p.displayName, p.heightMeters, p.birthYear?.toLong(),
                p.biologicalContextNote, p.createdAt, p.updatedAt,
            ),
        )
    }

    companion object {
        fun readSource(r: Row): Source =
            Source(
                id = r.requireString("id"), type = SourceType.fromCode(r.requireString("type")),
                displayName = r.requireString("display_name"), platformBundleId = r.getString("platform_bundle_id"),
                status = SourceStatus.fromCode(r.requireString("status")),
                connectedAt = r.getDate("connected_at"), lastDeliveryAt = r.getDate("last_delivery_at"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )
    }
}
