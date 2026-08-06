package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * **Owned by task B2-6.** main v11 — mirrors iOS `Schema.mainMigrations` version 11 (D-35/D-36).
 *
 * Six statements, in iOS's order:
 *  1. `DROP TABLE IF EXISTS metric_pins;` — dropped, not migrated. It shipped in v1 and never
 *     acquired a caller on either platform; D-35's pins live on `customization_profile`, which
 *     `purgeIngestedData` already preserves. Android's `Schema.kt` v1 creates `metric_pins`, so
 *     this DROP is a real drop here, not a no-op.
 *  2. `derived_feedback` + `idx_derived_feedback_metric` + `idx_derived_feedback_period` (unique).
 *  3. `metric_calibrations` + `idx_metric_calibrations_latest`.
 *
 * `algorithm_id`/`algorithm_version` on both tables are load-bearing, not bookkeeping: feedback
 * about the sleep-led readiness method must never calibrate the autonomic one, and a version bump
 * means the number the user judged is not the number the code now produces. `metric_calibrations`
 * is append-only and latest-wins exactly like `derived_values` (I2) — an older calibration row is
 * what explains a value computed while it was in force, so it is never rewritten.
 *
 * Whoever fills this: if anything on Android still reads `metric_pins`, that read has to move to
 * `CustomizationProfile` in the same change — the table stops existing at v11.
 */
object FeedbackCalibrationMigration : MigrationProvider {
    override val taskId: String = "B2-6"
    override val main: List<Migration> = emptyList()
}
