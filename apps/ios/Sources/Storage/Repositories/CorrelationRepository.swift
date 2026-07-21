import Foundation

/// Storage for the journal correlation engine's findings (EPIC-29), over the `derived_values` and
/// `input_manifests` tables created by **sensitive** migration v4.
///
/// **This repository holds the sensitive connection and nothing else** — the same structural I7
/// enforcement `JournalRepository` uses, for the same reason and one step further along the chain.
/// A journal row says "the user logged alcohol on the 12th". A correlation finding says the same
/// thing in its *identifier*: `journal.correlation.alcohol.readiness.score` discloses the habit
/// before any value is read, in a column, in plain text. If that row lived in `badan.db` it would
/// survive `Database.purgeSensitiveNamespace()` — a literal file deletion — and keep disclosing it
/// after the user had turned sensitive records off. There is no `main` connection in scope in this
/// file, so no statement here can address `badan.db` even by accident.
///
/// This is deliberately NOT how `stress.day_trend` works, and the difference is principled rather
/// than inconsistent: that metric is sensitive-plus too, but its ID names no behaviour, so only its
/// VALUE is revealing and the registry's `sensitiveClass` gate on the export path is enough. Here
/// the identifier itself is the disclosure, so placement has to carry the guarantee.
///
/// The purge needs no extension: it deletes and recreates `badan_sensitive.db` wholesale, so every
/// table in `Schema.sensitiveMigrations` — including v4's pair — is covered by construction.
///
/// Append-only (I2), identical in shape to `DerivationRepository`'s derived-value half: a recompute
/// INSERTs a fresh row with a new `computed_at`, and the latest one wins on read. Nothing here
/// updates or deletes a finding, so "what BADAN believed about this behaviour last month" stays
/// answerable — which for a statistical claim is the whole point of keeping the history.
final class CorrelationRepository {
    private let sensitive: SQLiteConnection

    init(sensitive: SQLiteConnection) {
        self.sensitive = sensitive
    }

    /// Batch a finding's manifest + row into one transaction instead of two implicit commits.
    /// Named without a suffix because this repository has only one connection to begin with.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T { try sensitive.transaction(body) }

    // MARK: - Input manifests

    func insertManifest(_ m: InputManifest) throws {
        try sensitive.run("INSERT OR REPLACE INTO input_manifests (id, inputs) VALUES (?, ?);",
                          [.text(m.id), .text(JSONCoding.encode(m.inputs))])
    }

    func manifest(id: String) throws -> InputManifest? {
        guard let row = try sensitive.query("SELECT * FROM input_manifests WHERE id = ?;", [.text(id)]).first,
              let inputs = JSONCoding.decode([InputManifest.Input].self, from: row.string("inputs")) else { return nil }
        return InputManifest(id: id, inputs: inputs)
    }

    // MARK: - Findings (append-only)

    func appendDerived(_ v: DerivedValue) throws {
        try sensitive.run("""
            INSERT INTO derived_values
              (id, metric_id, value, unit, period_key, confidence, provisional, algorithm_id,
               algorithm_version, input_manifest_id, computed_at, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(v.id), .text(v.metricId), .real(v.value), .text(v.unit), .text(v.periodKey),
             .double(v.confidence), .bool(v.provisional), .text(v.algorithmId), .text(v.algorithmVersion),
             .string(v.inputManifestId), .date(v.computedAt), .date(v.updatedAt),
             .text(v.originDeviceId), .date(v.deletedAt)])
    }

    /// Latest row for a metric + window (latest-read over the append-only log).
    func latestDerived(metricId: String, periodKey: String) throws -> DerivedValue? {
        try sensitive.query("""
            SELECT * FROM derived_values WHERE metric_id = ? AND period_key = ? AND deleted_at IS NULL
            ORDER BY computed_at DESC LIMIT 1;
            """, [.text(metricId), .text(periodKey)]).first.map(DerivationRepository.readDerived)
    }

    /// The current finding per metric id — one row per behaviour x score pair, newest belief each.
    ///
    /// The read a stored-findings surface would make. The correlations screen does **not** make it:
    /// it renders the outcomes `CorrelationEngine.recompute` has just returned, because a suppressed
    /// pair is never persisted and the "not yet, about N more days" rows can only come from a live
    /// evaluation — so the findings and the shortfalls arrive together, from one pass. The callers
    /// today are the suites, which use this to assert that findings land in the sensitive database
    /// only and that `purgeSensitiveNamespace()` takes them (I7).
    ///
    /// Grouped on `metric_id` alone rather than on (metric_id, period_key): a finding's window
    /// slides forward every day, so grouping by both would return the whole history of windows
    /// instead of the current view.
    func latestFindings() throws -> [DerivedValue] {
        try sensitive.query("""
            SELECT d.* FROM derived_values d
            JOIN (SELECT metric_id, MAX(computed_at) AS mc FROM derived_values
                  WHERE deleted_at IS NULL GROUP BY metric_id) latest
            ON d.metric_id = latest.metric_id AND d.computed_at = latest.mc
            WHERE d.deleted_at IS NULL
            ORDER BY d.metric_id ASC;
            """).map(DerivationRepository.readDerived)
    }

    /// Every appended row for one pair, oldest first — the audit trail I2 exists to preserve.
    func allDerived(metricId: String) throws -> [DerivedValue] {
        try sensitive.query("SELECT * FROM derived_values WHERE metric_id = ? ORDER BY computed_at ASC;",
                            [.text(metricId)]).map(DerivationRepository.readDerived)
    }
}
