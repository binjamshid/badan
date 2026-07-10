package net.albayyan.badan.storage.repositories

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.Insight
import net.albayyan.badan.domain.ReconciliationDecision
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection
import net.albayyan.badan.storage.sqlite.Sql

/**
 * Persisted insights (template-rendered, en+ar) and the dedup decision journal. Both power
 * the "why is it saying that?" and provenance-lineage surfaces.
 */
class InsightRepository(private val db: SqliteConnection) {

    fun insert(i: Insight) {
        db.run(
            """
            INSERT OR REPLACE INTO insights
              (id, insight_type, template_id, template_version, metric_ids, period_key, depth_variant,
               rendered_en, rendered_ar, evidence_refs, generated_at, algorithm_version, feedback)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                i.id, i.insightType, i.templateId, i.templateVersion,
                JsonCoding.encode(i.metricIds), i.periodKey, i.depthVariant.code,
                i.renderedText.en, i.renderedText.ar, JsonCoding.encode(i.evidenceRefs),
                i.generatedAt, i.algorithmVersion, i.feedback?.toLong(),
            ),
        )
    }

    fun recent(limit: Int = 20): List<Insight> =
        db.query("SELECT * FROM insights ORDER BY generated_at DESC LIMIT ?;", listOf(limit.toLong())).map { read(it) }

    fun forPeriod(periodKey: String): List<Insight> =
        db.query("SELECT * FROM insights WHERE period_key = ? ORDER BY generated_at DESC;", listOf(periodKey)).map { read(it) }

    fun setFeedback(id: String, feedback: Int) {
        db.run("UPDATE insights SET feedback = ? WHERE id = ?;", listOf(feedback.toLong(), id))
    }

    fun deleteForPeriod(periodKey: String) {
        db.run("DELETE FROM insights WHERE period_key = ?;", listOf(periodKey))
    }

    companion object {
        fun read(r: Row): Insight =
            Insight(
                id = r.requireString("id"), insightType = r.requireString("insight_type"),
                templateId = r.requireString("template_id"), templateVersion = r.requireString("template_version"),
                metricIds = JsonCoding.decodeOrNull<List<String>>(r.getString("metric_ids")) ?: emptyList(),
                periodKey = r.requireString("period_key"),
                depthVariant = DepthPolicy.fromCode(r.requireString("depth_variant")),
                renderedText = LocalizedString(en = r.requireString("rendered_en"), ar = r.requireString("rendered_ar")),
                evidenceRefs = JsonCoding.decodeOrNull<List<String>>(r.getString("evidence_refs")) ?: emptyList(),
                generatedAt = r.requireDate("generated_at"), algorithmVersion = r.getString("algorithm_version"),
                feedback = r.getInt("feedback"),
            )
    }
}

/** The dedup journal: which record won, which was suppressed, by what rule — reversible. */
class ReconciliationRepository(private val db: SqliteConnection) {

    fun insert(d: ReconciliationDecision) {
        db.run(
            """
            INSERT OR REPLACE INTO dedup_decisions
              (id, batch_id, rule, rule_version, kept_record_id, suppressed_record_id, score, reversible,
               reversed_at, decided_at, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                d.id, d.batchId, d.rule, d.ruleVersion, d.keptRecordId,
                d.suppressedRecordId, d.score, Sql.bool(d.reversible), d.reversedAt,
                d.decidedAt, JsonCoding.encode(d.detail),
            ),
        )
    }

    fun forSuppressed(recordId: String): ReconciliationDecision? =
        db.query(
            "SELECT * FROM dedup_decisions WHERE suppressed_record_id = ? AND reversed_at IS NULL ORDER BY decided_at DESC LIMIT 1;",
            listOf(recordId),
        ).firstOrNull()?.let { read(it) }

    fun recent(limit: Int = 50): List<ReconciliationDecision> =
        db.query("SELECT * FROM dedup_decisions ORDER BY decided_at DESC LIMIT ?;", listOf(limit.toLong())).map { read(it) }

    fun markReversed(id: String, at: Long) {
        db.run("UPDATE dedup_decisions SET reversed_at = ? WHERE id = ?;", listOf(at, id))
    }

    companion object {
        fun read(r: Row): ReconciliationDecision =
            ReconciliationDecision(
                id = r.requireString("id"), batchId = r.getString("batch_id"),
                rule = r.requireString("rule"), ruleVersion = r.requireString("rule_version"),
                keptRecordId = r.requireString("kept_record_id"),
                suppressedRecordId = r.requireString("suppressed_record_id"), score = r.getDouble("score"),
                reversible = r.getBool("reversible"), reversedAt = r.getDate("reversed_at"),
                decidedAt = r.requireDate("decided_at"),
                detail = JsonCoding.decodeOrNull<Map<String, String>>(r.getString("detail")) ?: emptyMap(),
            )
    }
}
