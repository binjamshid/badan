import Foundation

/// Storage for `source_priority_rules` (migration 10, main db). Deliberately history-preserving
/// rather than update-in-place: `insert` only ever appends a row (no `metric_id` uniqueness
/// constraint at the DB level, and no `ON CONFLICT` target), and `rule(forMetric:)` reads back the
/// most-recently-updated LIVE row for that metric. This sidesteps the exact `INSERT OR REPLACE` +
/// partial-unique-index interaction this schema's own migration comments warn about elsewhere
/// (`idx_export_templates_name`'s doc) — there is no unique index here for a write to silently
/// collide with — while still giving "one active rule per metric" behavior at read time.
final class SourcePriorityRuleRepository {
    private let main: SQLiteConnection

    init(main: SQLiteConnection) {
        self.main = main
    }

    private static let columns = "id, metric_id, priority_order, is_user_override, created_at"
    private static let placeholders = "?, ?, ?, ?, ?"

    /// Appends one row. Re-saving a rule for a metric that already has one does not overwrite the
    /// prior row — see the type's own header doc for why — so a metric's rule HISTORY survives,
    /// even though only the freshest live row is what `rule(forMetric:)` surfaces.
    func insert(_ rule: SourcePriorityRule) throws {
        try main.run("""
            INSERT OR REPLACE INTO source_priority_rules
              (\(Self.columns), \(Rows.convColumns))
            VALUES (\(Self.placeholders), \(Rows.convPlaceholders));
            """,
            [.text(rule.id), .text(rule.metricId), .text(JSONCoding.encode(rule.priorityOrder)),
             .bool(rule.isUserOverride), .date(rule.createdAt)]
            + Rows.convParams(updatedAt: rule.updatedAt, originDeviceId: rule.originDeviceId, deletedAt: rule.deletedAt))
    }

    /// The currently-live rule for a metric — the one `ConflictDecisionEngine.decide` should
    /// consult — or `nil` if none has ever been saved (or all have been tombstoned).
    func rule(forMetric metricId: String) throws -> SourcePriorityRule? {
        try main.query("""
            SELECT * FROM source_priority_rules WHERE metric_id = ? AND deleted_at IS NULL
            ORDER BY updated_at DESC LIMIT 1;
            """, [.text(metricId)]).first.map(Self.read)
    }

    /// Every metric with a live rule today, one row per metric (the freshest), for a Source
    /// Priority Editor listing.
    func all() throws -> [SourcePriorityRule] {
        try main.query("""
            SELECT t.* FROM source_priority_rules t
            INNER JOIN (
              SELECT metric_id, MAX(updated_at) AS max_updated
              FROM source_priority_rules WHERE deleted_at IS NULL GROUP BY metric_id
            ) latest ON latest.metric_id = t.metric_id AND latest.max_updated = t.updated_at
            WHERE t.deleted_at IS NULL
            ORDER BY t.metric_id ASC;
            """).map(Self.read)
    }

    /// Tombstones one specific rule row (I3-flavored — the row stays for history; a re-saved rule
    /// for the same metric becomes the new live head automatically since it never overwrote this
    /// one in the first place).
    func delete(id: String, at date: Date) throws {
        try main.run("UPDATE source_priority_rules SET deleted_at = ?, updated_at = ? WHERE id = ?;",
                     [.date(date), .date(date), .text(id)])
    }

    static func read(_ r: SQLiteRow) -> SourcePriorityRule {
        SourcePriorityRule(id: r.requireString("id"), metricId: r.requireString("metric_id"),
                           priorityOrder: JSONCoding.decode([String].self, from: r.string("priority_order")) ?? [],
                           isUserOverride: r.bool("is_user_override"), createdAt: r.requireDate("created_at"),
                           updatedAt: r.requireDate("updated_at"), originDeviceId: r.requireString("origin_device_id"),
                           deletedAt: r.date("deleted_at"))
    }
}
