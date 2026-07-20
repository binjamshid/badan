import Foundation

/// `export_cursors` (migration v4, plan §9.6) — the incremental-export checkpoint per
/// (template, destination).
///
/// The watermark is a max **`ingested_at`**, never a max `measured_at`. `ExportCursor`'s doc
/// carries the full reasoning; the short version is that a watch syncing Saturday's workout on
/// Monday produces a row whose `measured_at` is behind an existing Sunday watermark, so a
/// `measured_at` cursor drops every late-arriving and backfilled row without any file looking
/// wrong. Anyone tempted to "fix" the column to `measured_at` should read that comment first.
final class ExportCursorRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Reads

    func cursor(templateId: String, destinationId: String) throws -> ExportCursor? {
        try db.query("""
            SELECT * FROM export_cursors WHERE template_id = ? AND destination_id = ?;
            """, [.text(templateId), .text(destinationId)]).first.map(Self.read)
    }

    func all() throws -> [ExportCursor] {
        try db.query("SELECT * FROM export_cursors ORDER BY updated_at DESC;").map(Self.read)
    }

    // MARK: - Writes

    /// Move a cursor forward after a successful delta run. Returns false — and writes nothing —
    /// if `watermark` is not ahead of the stored one.
    ///
    /// Forward-only on purpose. A cursor that can move backwards silently re-exports a window the
    /// user already has, which is merely wasteful; but the same unguarded write is how a cursor
    /// moves *forward past* data during an out-of-order retry, and that loses rows permanently.
    /// So the only unconditional writes here are the two explicit ones below, both named for what
    /// they do. Callers wanting to re-export deliberately call `rewind` or `reset`.
    @discardableResult
    func advance(templateId: String, destinationId: String, to watermark: Date,
                 lastRunId: String?, manifestSha: ManifestDigest?, now: Date) throws -> Bool {
        try db.transaction {
            if let existing = try cursor(templateId: templateId, destinationId: destinationId),
               existing.highWatermark >= watermark {
                return false
            }
            try write(ExportCursor(templateId: templateId, destinationId: destinationId,
                                   highWatermark: watermark, lastManifestSha: manifestSha,
                                   lastRunId: lastRunId, updatedAt: now))
            return true
        }
    }

    /// Deliberately move a cursor backwards, so the next run re-exports from `watermark`.
    ///
    /// Separate from `advance` rather than a flag on it: re-exporting is a legitimate user action
    /// ("send last month again"), but it is never something a run should be able to do as a side
    /// effect of a retry. Splitting them means a rewind is always an explicit call someone wrote.
    func rewind(templateId: String, destinationId: String, to watermark: Date, now: Date) throws {
        try write(ExportCursor(templateId: templateId, destinationId: destinationId,
                               highWatermark: watermark, lastManifestSha: nil,
                               lastRunId: nil, updatedAt: now))
    }

    /// Drop the checkpoint entirely; the next `sinceLastRun` run has no cursor.
    ///
    /// Note what that means downstream (§12 EPIC-09's input rule): a `sinceLastRun` template with
    /// no cursor falls back to `lastNDays` **with a notice**, rather than silently exporting all
    /// of history. Hard delete, not a tombstone — a soft-deleted watermark that could be
    /// resurrected would resume from a stale position (the v4 comment's reasoning for this table
    /// having no convention columns).
    func reset(templateId: String, destinationId: String) throws {
        try db.run("DELETE FROM export_cursors WHERE template_id = ? AND destination_id = ?;",
                   [.text(templateId), .text(destinationId)])
    }

    /// Drop every checkpoint for a template — used when a template's scope changes materially,
    /// where resuming from the old watermark would mean the newly-added metrics are never
    /// backfilled into an export at all.
    func resetAll(templateId: String) throws {
        try db.run("DELETE FROM export_cursors WHERE template_id = ?;", [.text(templateId)])
    }

    private func write(_ c: ExportCursor) throws {
        try db.run("""
            INSERT OR REPLACE INTO export_cursors
              (template_id, destination_id, high_watermark, last_manifest_sha, last_run_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            [.text(c.templateId), .text(c.destinationId), .date(c.highWatermark),
             .string(c.lastManifestSha?.hex), .string(c.lastRunId), .date(c.updatedAt)])
    }

    static func read(_ r: SQLiteRow) -> ExportCursor {
        ExportCursor(
            templateId: r.requireString("template_id"),
            destinationId: r.requireString("destination_id"),
            highWatermark: r.requireDate("high_watermark"),
            lastManifestSha: r.string("last_manifest_sha").flatMap { ManifestDigest(hex: $0) },
            lastRunId: r.string("last_run_id"),
            updatedAt: r.requireDate("updated_at"))
    }
}
