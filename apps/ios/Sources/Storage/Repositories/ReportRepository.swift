import Foundation

/// One generated periodic report's METADATA (migration v8, plan §9.12). The rendered artifact (a
/// PDF) lives as a file and is regenerable, so this row is DERIVED and never a source of truth:
/// `ReportBuilder` is deterministic, so re-running it reproduces the same model and the same
/// `sha256`. The row exists so the Reports surface can list and open reports without re-deriving,
/// and so a rendered file can be checked against what the store would regenerate.
public struct ReportRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var periodKey: String
    public var generatedAt: Date
    public var algorithmVersionId: String
    /// The section ids present (`ReportModel.sectionsIncluded`), stored whole so the section set can
    /// evolve without a migration. An empty period legitimately has fewer (or zero) sections.
    public var sectionsIncluded: [String]
    /// The rendered PDF's path, or nil — the file may not have been rendered yet, or may have been
    /// pruned. A report row is valid without a file: the file is regenerable from the model.
    public var artifactPath: String?
    /// Content hash of the deterministic model (`ReportBuilder.contentHash`). The integrity anchor:
    /// a rendered artifact is trustworthy iff re-deriving the model reproduces this hash. Always
    /// present even when `artifactPath` is nil.
    public var sha256: String
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, periodKey: String, generatedAt: Date, algorithmVersionId: String,
                sectionsIncluded: [String], artifactPath: String?, sha256: String, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.periodKey = periodKey; self.generatedAt = generatedAt
        self.algorithmVersionId = algorithmVersionId; self.sectionsIncluded = sectionsIncluded
        self.artifactPath = artifactPath; self.sha256 = sha256; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// Whether the report's on-disk artifact is stale relative to a freshly-derived model: the
    /// content hash the store would regenerate now differs from what this row was rendered against.
    /// A stale report must be obviously regenerable — never silently shown as current.
    public func isStale(against freshHash: String) -> Bool { sha256 != freshHash }
}

/// `reports` (migration v8, plan §9.12) — periodic-report metadata.
///
/// Soft-delete only (`deleted_at`), like every other convention-column table, and — deliberately
/// unlike `derived_values`/`baselines` — NOT append-only: a report is a disposable, regenerable
/// rollup, so regenerating for the same (period, algorithm version) REPLACES the row in place
/// rather than appending (I2 governs BADAN's beliefs over time, not a rendered artifact). The
/// (period_key, algorithm_version_id) identity is enforced by the partial unique index
/// `idx_reports_period_algorithm` (WHERE deleted_at IS NULL).
final class ReportRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // MARK: - Writes

    /// Persist a report's metadata, replacing any existing (non-deleted) row for the same
    /// (period, algorithm version) in place so the row's id is stable across regenerations. Returns
    /// the persisted record (its id is the existing row's id on a replace, a fresh ULID otherwise).
    @discardableResult
    func save(periodKey: String, algorithmVersionId: String, generatedAt: Date,
              sectionsIncluded: [String], artifactPath: String?, sha256: String,
              now: Date, originDeviceId: String) throws -> ReportRecord {
        try db.transaction {
            let sectionsJSON = try JSONCoding.encodeOrThrow(sectionsIncluded)
            if let existing = try current(periodKey: periodKey, algorithmVersionId: algorithmVersionId) {
                try db.run("""
                    UPDATE reports SET generated_at = ?, sections_included = ?, artifact_path = ?,
                      sha256 = ?, updated_at = ? WHERE id = ?;
                    """,
                    [.date(generatedAt), .text(sectionsJSON), .string(artifactPath),
                     .text(sha256), .date(now), .text(existing.id)])
                return ReportRecord(id: existing.id, periodKey: periodKey, generatedAt: generatedAt,
                                    algorithmVersionId: algorithmVersionId, sectionsIncluded: sectionsIncluded,
                                    artifactPath: artifactPath, sha256: sha256, updatedAt: now,
                                    originDeviceId: existing.originDeviceId, deletedAt: nil)
            }
            let id = ULID.newID()
            try db.run("""
                INSERT INTO reports
                  (id, period_key, generated_at, algorithm_version_id, sections_included, artifact_path,
                   sha256, \(Rows.convColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, \(Rows.convPlaceholders));
                """,
                [.text(id), .text(periodKey), .date(generatedAt), .text(algorithmVersionId),
                 .text(sectionsJSON), .string(artifactPath), .text(sha256)]
                + Rows.convParams(updatedAt: now, originDeviceId: originDeviceId, deletedAt: nil))
            return ReportRecord(id: id, periodKey: periodKey, generatedAt: generatedAt,
                                algorithmVersionId: algorithmVersionId, sectionsIncluded: sectionsIncluded,
                                artifactPath: artifactPath, sha256: sha256, updatedAt: now,
                                originDeviceId: originDeviceId, deletedAt: nil)
        }
    }

    /// Record (or clear) the rendered artifact's path for an existing report row. Kept separate
    /// from `save` because the artifact is rendered after the metadata is written and may be pruned
    /// later — the row outlives its file.
    func setArtifactPath(id: String, path: String?, at date: Date) throws {
        try db.run("UPDATE reports SET artifact_path = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                   [.string(path), .date(date), .text(id)])
    }

    /// Tombstone a report. The file, if any, is the caller's to remove; a soft-deleted row frees
    /// its (period, version) identity so the user can regenerate a report they just deleted.
    func softDelete(id: String, at date: Date) throws {
        try db.run("UPDATE reports SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                   [.date(date), .date(date), .text(id)])
    }

    // MARK: - Reads

    /// The current report for a (period, algorithm version), or nil. Matches the partial unique
    /// index's predicate exactly (WHERE deleted_at IS NULL).
    func current(periodKey: String, algorithmVersionId: String) throws -> ReportRecord? {
        try db.query("SELECT * FROM reports WHERE period_key = ? AND algorithm_version_id = ? AND deleted_at IS NULL;",
                     [.text(periodKey), .text(algorithmVersionId)]).first.map(Self.read)
    }

    func report(id: String) throws -> ReportRecord? {
        try db.query("SELECT * FROM reports WHERE id = ? AND deleted_at IS NULL;", [.text(id)]).first.map(Self.read)
    }

    /// Live reports, most recent period first (period keys are lexicographically sortable).
    func all() throws -> [ReportRecord] {
        try db.query("SELECT * FROM reports WHERE deleted_at IS NULL ORDER BY period_key DESC, generated_at DESC;")
            .map(Self.read)
    }

    /// The set of period keys that currently have a (non-deleted) report for `algorithmVersionId`
    /// — what `ReportTrigger.dueWeeklyPeriodKey` needs to avoid regenerating an existing week.
    func periodKeys(algorithmVersionId: String) throws -> Set<String> {
        let rows = try db.query("SELECT period_key FROM reports WHERE algorithm_version_id = ? AND deleted_at IS NULL;",
                                [.text(algorithmVersionId)])
        return Set(rows.compactMap { $0.string("period_key") })
    }

    static func read(_ r: SQLiteRow) -> ReportRecord {
        ReportRecord(
            id: r.requireString("id"),
            periodKey: r.requireString("period_key"),
            generatedAt: r.requireDate("generated_at"),
            algorithmVersionId: r.requireString("algorithm_version_id"),
            sectionsIncluded: JSONCoding.decode([String].self, from: r.string("sections_included")) ?? [],
            artifactPath: r.string("artifact_path"),
            sha256: r.requireString("sha256"),
            updatedAt: r.requireDate("updated_at"),
            originDeviceId: r.requireString("origin_device_id"),
            deletedAt: r.date("deleted_at"))
    }
}
