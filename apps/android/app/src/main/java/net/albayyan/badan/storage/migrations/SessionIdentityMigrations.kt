package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * **Owned by task B2-3.** Two allocated main-DB versions, and they are not the same kind of thing:
 * one fills a reserved hole that mirrors iOS, the other is the port's single Android-only number.
 *
 * Both stubs are empty. An empty provider records nothing and applies nothing, so a dev device
 * running a half-built tree is safe (see [MigrationProvider]).
 */

/**
 * main v3 — hole-fill. Mirrors iOS `Schema.mainMigrations` version 3 (BUG-11c): dedup
 * `session_stages` then `sessions` by `(external_id, source_id)`, `DROP INDEX IF EXISTS
 * idx_session_identity`, then recreate it as `CREATE UNIQUE INDEX idx_session_identity ON
 * sessions(external_id, source_id) WHERE external_id IS NOT NULL;`.
 *
 * This number is BELOW `Schema.kt`'s current head (8). That is deliberate, not a mistake to
 * "correct" by appending at 13 — see [MigrationAllocation] and ADR-0012. It only applies at all
 * because of [MigrationRunner]'s `NOT IN` predicate.
 *
 * The two DELETEs are not optional and must run before the `CREATE UNIQUE INDEX`: the index fails
 * outright against data that already violates it, and a failed migration means `Database`'s init
 * throws for exactly the users the fix exists for. Whoever fills this must also update
 * `MeasurementRepository`'s `ON CONFLICT` target to match the new index exactly, partial predicate
 * included.
 */
object SessionIdentityRepairMigration : MigrationProvider {
    override val taskId: String = "B2-3"
    override val main: List<Migration> = emptyList()
}

/**
 * main v12 — Android-only catch-up, no iOS counterpart. The five indexes iOS shipped in its own
 * main v2 that Android's v2 omitted: `idx_insight_period`, `idx_insight_generated`,
 * `idx_raw_metric_measured_live`, `idx_interval_metric_span_live`, `idx_session_kind_start_live`.
 *
 * Every statement must be written `CREATE INDEX IF NOT EXISTS`. Android's v2 is already written and
 * may already have been applied on a dev device, so the indexes cannot be retrofitted into it; and
 * the two `_live` names also appear in the sensitive namespace's v9 mirror, so `IF NOT EXISTS`
 * keeps the statement strings reusable rather than forked. This is the same discipline `Schema.kt`'s
 * v6 comment already documents for `idx_baseline_lookup`.
 */
object MainIndexCatchUpMigration : MigrationProvider {
    override val taskId: String = "B2-3"
    override val main: List<Migration> = emptyList()
}
