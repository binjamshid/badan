import Foundation

/// Shared column lists and (de)serialization for the embedded provenance + convention
/// columns that recur across measurement tables. Keeping these in one place is what stops
/// the 12 provenance columns from drifting between INSERTs.
enum Rows {
    static let provColumns =
        "source_id, device_id, ingestion_path, external_id, batch_id, measured_at, measured_tz, recorded_at, ingested_at, algorithm_version_id, quality_flags, suppressed_by"
    static let provPlaceholders = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"
    static let convColumns = "updated_at, origin_device_id, deleted_at"
    static let convPlaceholders = "?, ?, ?"

    static func provParams(_ p: Provenance) -> [SQLValue] {
        let flags = p.qualityFlags.isEmpty ? nil : p.qualityFlags.map(\.rawValue).joined(separator: ";")
        return [
            .text(p.sourceId),
            .string(p.deviceId),
            .text(p.ingestionPath.rawValue),
            .string(p.externalId),
            .string(p.importBatchId),
            .date(p.measuredAt),
            .text(p.measuredTimezone),
            .date(p.recordedAt),
            .date(p.ingestedAt),
            .string(p.algorithmVersionId),
            .string(flags),
            .string(p.suppressedBy),
        ]
    }

    static func readProvenance(_ row: SQLiteRow) -> Provenance {
        let flags = (row.string("quality_flags") ?? "")
            .split(separator: ";").compactMap { QualityFlag(rawValue: String($0)) }
        return Provenance(
            sourceId: row.requireString("source_id"),
            deviceId: row.string("device_id"),
            ingestionPath: IngestionPath(rawValue: row.requireString("ingestion_path")) ?? .manual,
            externalId: row.string("external_id"),
            importBatchId: row.string("batch_id"),
            measuredAt: row.requireDate("measured_at"),
            measuredTimezone: row.requireString("measured_tz"),
            recordedAt: row.requireDate("recorded_at"),
            ingestedAt: row.requireDate("ingested_at"),
            algorithmVersionId: row.string("algorithm_version_id"),
            qualityFlags: flags,
            suppressedBy: row.string("suppressed_by")
        )
    }

    static func convParams(updatedAt: Date, originDeviceId: String, deletedAt: Date?) -> [SQLValue] {
        [.date(updatedAt), .text(originDeviceId), .date(deletedAt)]
    }
}
