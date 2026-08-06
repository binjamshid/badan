package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * **Owned by task B2-5.** main v10 — mirrors iOS `Schema.mainMigrations` version 10.
 *
 * Two new tables plus three indexes — `data_conflicts` (+ `idx_data_conflicts_status`,
 * `idx_data_conflicts_scope`) and `source_priority_rules` (+ `idx_source_priority_rules_metric`) —
 * **and four additive column adds**, which are easy to miss because they are the tail of the
 * statement list rather than the head:
 *
 * ```
 * ALTER TABLE sources        ADD COLUMN connection_type TEXT;
 * ALTER TABLE sources        ADD COLUMN capabilities    TEXT;
 * ALTER TABLE source_devices ADD COLUMN connection_type TEXT;
 * ALTER TABLE source_devices ADD COLUMN capabilities    TEXT;
 * ```
 *
 * Both columns are nullable on purpose: an existing HealthConnect source predates them and has
 * never been asked what connection type it has, which is a different fact from "connects by an
 * unknown method." Neither new table is a second decisions ledger — `dedup_decisions` stays the
 * one and only `ReconciliationDecision` journal — and `source_priority_rules` deliberately carries
 * no unique constraint on `metric_id`.
 *
 * These `ALTER TABLE`s are the concrete reason application order must be sorted by version rather
 * than by provider registration: they fail outright if v1's `sources`/`source_devices` have not
 * been created yet.
 */
object DeviceEcosystemMigration : MigrationProvider {
    override val taskId: String = "B2-5"
    override val main: List<Migration> = emptyList()
}
