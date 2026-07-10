import Foundation

/// Reference & identity: sources, devices, permission states, and the single user profile.
/// These describe *where data comes from* and back the Data Sources and Provenance screens.
final class CatalogRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Sources

    func upsertSource(_ s: Source) throws {
        try db.run("""
            INSERT OR REPLACE INTO sources
              (id, type, display_name, platform_bundle_id, status, connected_at, last_delivery_at,
               updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(s.id), .text(s.type.rawValue), .text(s.displayName), .string(s.platformBundleId),
             .text(s.status.rawValue), .date(s.connectedAt), .date(s.lastDeliveryAt),
             .date(s.updatedAt), .text(s.originDeviceId), .date(s.deletedAt)])
    }

    func sources(includeHidden: Bool = true) throws -> [Source] {
        var sql = "SELECT * FROM sources WHERE deleted_at IS NULL"
        if !includeHidden { sql += " AND status != 'hidden'" }
        sql += " ORDER BY display_name ASC;"
        return try db.query(sql).map(Self.readSource)
    }

    func source(id: String) throws -> Source? {
        try db.query("SELECT * FROM sources WHERE id = ?;", [.text(id)]).first.map(Self.readSource)
    }

    func setSourceStatus(id: String, status: SourceStatus, updatedAt: Date) throws {
        try db.run("UPDATE sources SET status = ?, updated_at = ? WHERE id = ?;",
                   [.text(status.rawValue), .date(updatedAt), .text(id)])
    }

    // MARK: - Devices

    func upsertDevice(_ d: Device) throws {
        try db.run("""
            INSERT OR REPLACE INTO source_devices
              (id, source_id, name, model, first_seen, last_seen, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(d.id), .text(d.sourceId), .text(d.name), .string(d.model), .date(d.firstSeen),
             .date(d.lastSeen), .date(d.updatedAt), .text(d.originDeviceId), .date(d.deletedAt)])
    }

    func devices(sourceId: String? = nil) throws -> [Device] {
        let sql = sourceId == nil
            ? "SELECT * FROM source_devices WHERE deleted_at IS NULL ORDER BY name;"
            : "SELECT * FROM source_devices WHERE source_id = ? AND deleted_at IS NULL ORDER BY name;"
        let params: [SQLValue] = sourceId.map { [.text($0)] } ?? []
        return try db.query(sql, params).map { r in
            Device(id: r.requireString("id"), sourceId: r.requireString("source_id"), name: r.requireString("name"),
                   model: r.string("model"), firstSeen: r.requireDate("first_seen"), lastSeen: r.requireDate("last_seen"),
                   updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
                   deletedAt: r.date("deleted_at"))
        }
    }

    // MARK: - Permission states

    func upsertPermission(_ p: PermissionState) throws {
        try db.run("""
            INSERT OR REPLACE INTO permission_states (store, platform_type, status, last_checked_at, last_read_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            [.text(p.store), .text(p.platformType), .text(p.status.rawValue), .date(p.lastCheckedAt), .date(p.lastReadAt)])
    }

    func permissions(store: String? = nil) throws -> [PermissionState] {
        let sql = store == nil
            ? "SELECT * FROM permission_states ORDER BY platform_type;"
            : "SELECT * FROM permission_states WHERE store = ? ORDER BY platform_type;"
        let params: [SQLValue] = store.map { [.text($0)] } ?? []
        return try db.query(sql, params).map { r in
            PermissionState(store: r.requireString("store"), platformType: r.requireString("platform_type"),
                            status: PermissionStatus(rawValue: r.requireString("status")) ?? .notRequested,
                            lastCheckedAt: r.requireDate("last_checked_at"), lastReadAt: r.date("last_read_at"))
        }
    }

    // MARK: - User profile

    func userProfile() throws -> UserProfile? {
        try db.query("SELECT * FROM user_profile LIMIT 1;").first.map { r in
            UserProfile(id: r.requireString("id"), displayName: r.string("display_name"),
                        heightMeters: r.double("height_m"), birthYear: r.intValue("birth_year"),
                        biologicalContextNote: r.string("bio_note"), createdAt: r.requireDate("created_at"),
                        updatedAt: r.requireDate("updated_at"))
        }
    }

    func saveUserProfile(_ p: UserProfile) throws {
        try db.run("""
            INSERT OR REPLACE INTO user_profile (id, display_name, height_m, birth_year, bio_note, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(p.id), .string(p.displayName), .double(p.heightMeters), .int(p.birthYear),
             .string(p.biologicalContextNote), .date(p.createdAt), .date(p.updatedAt)])
    }

    static func readSource(_ r: SQLiteRow) -> Source {
        Source(id: r.requireString("id"), type: SourceType(rawValue: r.requireString("type")) ?? .manual,
               displayName: r.requireString("display_name"), platformBundleId: r.string("platform_bundle_id"),
               status: SourceStatus(rawValue: r.requireString("status")) ?? .active,
               connectedAt: r.date("connected_at"), lastDeliveryAt: r.date("last_delivery_at"),
               updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
               deletedAt: r.date("deleted_at"))
    }
}
