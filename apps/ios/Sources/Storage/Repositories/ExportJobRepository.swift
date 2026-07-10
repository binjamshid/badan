import Foundation

/// Export job history with manifests. Kept in the main DB; the export code path itself has
/// no networking or entitlement imports (D-8).
final class ExportJobRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    func insert(_ job: ExportJob) throws {
        try db.run("""
            INSERT OR REPLACE INTO export_jobs
              (id, scope, format, status, manifest, output_path, row_count, started_at, finished_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(job.id), .text(JSONCoding.encode(job.scope)), .text(job.format.rawValue), .text(job.status.rawValue),
             .string(job.manifest.map { JSONCoding.encode($0) }), .string(job.outputPath), .int(job.rowCount),
             .date(job.startedAt), .date(job.finishedAt), .date(job.createdAt)])
    }

    func recent(limit: Int = 30) throws -> [ExportJob] {
        try db.query("SELECT * FROM export_jobs ORDER BY created_at DESC LIMIT ?;", [.int(limit)]).map(Self.read)
    }

    static func read(_ r: SQLiteRow) -> ExportJob {
        ExportJob(id: r.requireString("id"),
                  scope: JSONCoding.decode(ExportScope.self, from: r.string("scope")) ?? .everything,
                  format: ExportFormat(rawValue: r.requireString("format")) ?? .csv,
                  status: ExportJobStatus(rawValue: r.requireString("status")) ?? .pending,
                  manifest: JSONCoding.decode(ExportManifest.self, from: r.string("manifest")),
                  outputPath: r.string("output_path"), rowCount: r.intValue("row_count"),
                  startedAt: r.date("started_at"), finishedAt: r.date("finished_at"),
                  createdAt: r.requireDate("created_at"))
    }
}
