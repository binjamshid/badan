package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * **Owned by task B2-7.** All six allocated sensitive-namespace versions live in this one file
 * because they share one owner — no other task edits it, so there is no collision surface here
 * regardless of how the objects are split. They are separate objects rather than one provider
 * returning six migrations so that `MigrationAllocationTest` can attribute a stray version to a
 * specific slot rather than to "the sensitive provider."
 *
 * Everything below goes in `badan_sensitive.db`, and the placement IS the guarantee: I7/D-9 make
 * "turn this off" a literal file deletion (`Database.purgeSensitiveNamespace`), so a table that
 * belongs here and lands in `badan.db` silently downgrades that promise to best-effort. That is not
 * hypothetical — it is exactly the bug [SensitiveMeasurementChainMigration] (v9) exists to close.
 */

/**
 * sensitive v2 — hole-fill. Mirrors iOS `Schema.sensitiveMigrations` version 2 (PERF-117).
 * Exactly one statement:
 *
 * ```
 * CREATE INDEX idx_regimen_ended ON medication_regimens(ended_at);
 * ```
 *
 * The number is below `Schema.kt`'s current sensitive head (4) on purpose — it fills the reserved
 * hole rather than appending at 10. See [MigrationAllocation].
 */
object RegimenEndedIndexMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}

/**
 * sensitive v5 — mirrors iOS `Schema.sensitiveMigrations` version 5. The lab-notebook set: eight
 * tables — `lab_reports`, `lab_panels`, `lab_results`, `reference_ranges`, `user_corrections`,
 * `lab_annotations`, `derived_trends`, `source_documents` — plus thirteen indexes, 21 statements
 * in total on iOS. `idx_source_documents_sha256` is UNIQUE and partial (`WHERE deleted_at IS NULL`).
 */
object LabNotebookMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}

/**
 * sensitive v6 — mirrors iOS `Schema.sensitiveMigrations` version 6. Six cycle tables —
 * `cycle_records`, `flow_logs`, `contraceptive_context_logs`, `cycle_predictions`,
 * `cycle_phase_estimates`, `cycle_anomaly_events` — **plus a sensitive-namespace `baselines`
 * table**, seven tables and nine indexes, 16 statements in total on iOS.
 *
 * The sensitive `baselines` is a deliberate duplicate of the main-DB table (CYCLE-06): one shared
 * reader over two structurally identical tables in two physically separate files, rather than one
 * table whose rows carry a sensitivity flag some future query forgets to filter on. Its index is
 * `idx_baseline_lookup`, the same NAME as the main DB's — which is fine, index names are scoped per
 * database file, and copying the statement verbatim is the point.
 */
object CycleMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}

/**
 * sensitive v7 — mirrors iOS `Schema.sensitiveMigrations` version 7. `cycle_fertile_window_estimates`
 * plus `idx_cycle_fertile_window_estimates_generated` (two statements).
 */
object FertileWindowMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}

/**
 * sensitive v8 — mirrors iOS `Schema.sensitiveMigrations` version 8. Four pregnancy tables —
 * `pregnancy_records`, `due_date_source_entries`, `due_date_estimates`,
 * `loss_declaration_records` — plus five indexes, nine statements in total.
 */
object PregnancyMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}

/**
 * sensitive v9 — mirrors iOS `Schema.sensitiveMigrations` version 9 (A21 / D-26 scope-gap closure).
 * `raw_samples` and `interval_records` mirrored into the sensitive namespace, plus **seven**
 * indexes: the five from main v1 (`idx_raw_metric_measured`, `idx_raw_identity`, `idx_raw_batch`,
 * `idx_interval_metric_span`, `idx_interval_identity`) and the two `_live` partial indexes from
 * main v2 (`idx_raw_metric_measured_live`, `idx_interval_metric_span_live`) — nine statements.
 *
 * Every statement is byte-identical to its main-DB original. That duplication is the decision, not
 * an oversight: it is what makes `sensitiveClass = sensitivePlus` metrics (today exactly
 * `body.glucose`) land in the file `purgeSensitiveNamespace()` deletes wholesale. Before this,
 * glucose sat in `badan.db` — unencrypted relative to the rest of the sensitive set, and silently
 * surviving a user turning "Sensitive records" off.
 *
 * On Android, note that main v2 shipped only three of iOS's six indexes, so the two `_live`
 * statements copied here are the same strings [MainIndexCatchUpMigration] (main v12) adds to the
 * main DB. Keep them `IF NOT EXISTS`-consistent with whatever that migration writes.
 */
object SensitiveMeasurementChainMigration : MigrationProvider {
    override val taskId: String = "B2-7"
    override val sensitive: List<Migration> = emptyList()
}
