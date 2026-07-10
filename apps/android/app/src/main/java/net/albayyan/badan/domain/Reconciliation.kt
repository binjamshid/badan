package net.albayyan.badan.domain

/**
 * The dedup journal. When two sources report the same episode, one wins and the other is
 * suppressed (never deleted, I3) — and the decision is recorded here so power mode can show it
 * and, crucially, reverse it. Reversal clears `suppressedBy` and journals a compensating row.
 */
data class ReconciliationDecision(
    val id: String,
    val batchId: String? = null,
    val rule: String,            // e.g. "sleep.session_overlap.v1"
    val ruleVersion: String,
    val keptRecordId: String,
    val suppressedRecordId: String,
    val score: Double? = null,
    val reversible: Boolean = true,
    val reversedAt: Long? = null,
    val decidedAt: Long,
    val detail: Map<String, String> = emptyMap(),  // thresholds, overlap %, source names
) {
    val isReversed: Boolean get() = reversedAt != null
}
