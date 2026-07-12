import Foundation

/// Persisted insights (template-rendered, en+ar) and the dedup decision journal. Both power
/// the "why is it saying that?" and provenance-lineage surfaces.
final class InsightRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    /// Run a batch of writes as a single transaction instead of one implicit commit+fsync per
    /// row (PERF-02 (audit 2026-07-12)).
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    func insert(_ i: Insight) throws {
        try db.run("""
            INSERT OR REPLACE INTO insights
              (id, insight_type, template_id, template_version, metric_ids, period_key, depth_variant,
               rendered_en, rendered_ar, evidence_refs, generated_at, algorithm_version, feedback)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(i.id), .text(i.insightType), .text(i.templateId), .text(i.templateVersion),
             .text(JSONCoding.encode(i.metricIds)), .text(i.periodKey), .text(i.depthVariant.rawValue),
             .text(i.renderedText.en), .text(i.renderedText.ar), .text(JSONCoding.encode(i.evidenceRefs)),
             .date(i.generatedAt), .string(i.algorithmVersion), .int(i.feedback)])
    }

    func recent(limit: Int = 20) throws -> [Insight] {
        try db.query("SELECT * FROM insights ORDER BY generated_at DESC LIMIT ?;", [.int(limit)]).map(Self.read)
    }

    func forPeriod(_ periodKey: String) throws -> [Insight] {
        try db.query("SELECT * FROM insights WHERE period_key = ? ORDER BY generated_at DESC;", [.text(periodKey)]).map(Self.read)
    }

    func setFeedback(id: String, feedback: Int) throws {
        try db.run("UPDATE insights SET feedback = ? WHERE id = ?;", [.int(feedback), .text(id)])
    }

    func deleteForPeriod(_ periodKey: String) throws {
        try db.run("DELETE FROM insights WHERE period_key = ?;", [.text(periodKey)])
    }

    static func read(_ r: SQLiteRow) -> Insight {
        Insight(id: r.requireString("id"), insightType: r.requireString("insight_type"),
                templateId: r.requireString("template_id"), templateVersion: r.requireString("template_version"),
                metricIds: JSONCoding.decode([String].self, from: r.string("metric_ids")) ?? [],
                periodKey: r.requireString("period_key"),
                // Decoding tolerance (UX-03): rows persisted while "balanced" existed, or any
                // other unrecognized value, fall back to .casual rather than throwing.
                depthVariant: DepthPolicy(rawValue: r.requireString("depth_variant")) ?? .casual,
                renderedText: LocalizedString(en: r.requireString("rendered_en"), ar: r.requireString("rendered_ar")),
                evidenceRefs: JSONCoding.decode([String].self, from: r.string("evidence_refs")) ?? [],
                generatedAt: r.requireDate("generated_at"), algorithmVersion: r.string("algorithm_version"),
                feedback: r.intValue("feedback"))
    }
}

/// The dedup journal: which record won, which was suppressed, by what rule — reversible.
final class ReconciliationRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    func insert(_ d: ReconciliationDecision) throws {
        try db.run("""
            INSERT OR REPLACE INTO dedup_decisions
              (id, batch_id, rule, rule_version, kept_record_id, suppressed_record_id, score, reversible,
               reversed_at, decided_at, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [.text(d.id), .string(d.batchId), .text(d.rule), .text(d.ruleVersion), .text(d.keptRecordId),
             .text(d.suppressedRecordId), .double(d.score), .bool(d.reversible), .date(d.reversedAt),
             .date(d.decidedAt), .text(JSONCoding.encode(d.detail))])
    }

    func forSuppressed(_ recordId: String) throws -> ReconciliationDecision? {
        try db.query("SELECT * FROM dedup_decisions WHERE suppressed_record_id = ? AND reversed_at IS NULL ORDER BY decided_at DESC LIMIT 1;",
                     [.text(recordId)]).first.map(Self.read)
    }

    func recent(limit: Int = 50) throws -> [ReconciliationDecision] {
        try db.query("SELECT * FROM dedup_decisions ORDER BY decided_at DESC LIMIT ?;", [.int(limit)]).map(Self.read)
    }

    func markReversed(id: String, at date: Date) throws {
        try db.run("UPDATE dedup_decisions SET reversed_at = ? WHERE id = ?;", [.date(date), .text(id)])
    }

    static func read(_ r: SQLiteRow) -> ReconciliationDecision {
        ReconciliationDecision(id: r.requireString("id"), batchId: r.string("batch_id"),
                               rule: r.requireString("rule"), ruleVersion: r.requireString("rule_version"),
                               keptRecordId: r.requireString("kept_record_id"),
                               suppressedRecordId: r.requireString("suppressed_record_id"), score: r.double("score"),
                               reversible: r.bool("reversible"), reversedAt: r.date("reversed_at"),
                               decidedAt: r.requireDate("decided_at"),
                               detail: JSONCoding.decode([String: String].self, from: r.string("detail")) ?? [:])
    }
}
