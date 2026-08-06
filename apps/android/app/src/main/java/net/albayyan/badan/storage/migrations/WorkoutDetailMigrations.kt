package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * **Owned by task B2-4.** main v9 — mirrors iOS `Schema.mainMigrations` version 9.
 *
 * Four tables and three indexes, in iOS's order: `workout_checkpoints`, `strength_sets` +
 * `idx_strength_sets_session`, `workout_intervals` + `idx_workout_intervals_session`,
 * `workout_quality` + `idx_workout_quality_session`.
 *
 * Column names, column ORDER and index names must match iOS byte for byte — cross-platform export
 * fixtures diff the two schemas, so a "harmless" reordering here is a test failure there. Note that
 * `workout_checkpoints` carries only `origin_device_id`, not the full convention-column set, and
 * that iOS deliberately puts no `CHECK` constraint on the state/kind columns (the enums are the
 * domain layer's to evolve); mirror both choices rather than improving on them.
 */
object WorkoutDetailMigration : MigrationProvider {
    override val taskId: String = "B2-4"
    override val main: List<Migration> = emptyList()
}
