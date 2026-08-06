package net.albayyan.badan.storage.migrations

/**
 * **Frozen table. One owner per version. Never invent a number here; never renumber one.**
 *
 * Android's migration versions are deliberately EQUAL to iOS's version numbers for the same
 * logical change — `Schema.kt`'s own comments say so at every migration ("Byte-equivalent mirror
 * of iOS `Schema.mainMigrations` version N"), and ADR-0012 makes that posture binding for the
 * parity port. Two consequences a reader must not "fix":
 *
 *  * **main 3 and sensitive 2 are holes, not skips.** They are reserved for iOS's main v3 and
 *    sensitive v2 content, which was never ported before the 2026-07-22 pause. That content lands
 *    AT 3 and AT 2 — not appended past the current head — or the numbering forks permanently
 *    between platforms and needs a hand-maintained mapping comment to recover what equal integers
 *    already give for free (ADR-0012, "Migration numbering stays aligned with iOS").
 *  * **main 12 is the one Android-only number**, and it has no iOS counterpart by construction:
 *    it carries the five indexes iOS shipped inside its own v2 that Android's v2 omitted. They
 *    cannot be retrofitted into Android's already-written v2 without changing a migration some
 *    device may have applied, so they get their own number and every statement is
 *    `IF NOT EXISTS` — see [MAIN_INDEX_CATCH_UP].
 *
 * Filling a hole is only safe because `Database.migrate` selects pending work with
 * `version NOT IN (SELECT version FROM schema_migrations)` rather than `version > MAX(version)`,
 * and because both this file's consumer ([Migrations]) and `Database.migrate` sort by version
 * before applying. See [MigrationRunner].
 */
object MigrationAllocation {

    // ---------------------------------------------------------------------------------------
    // Owners
    // ---------------------------------------------------------------------------------------

    /** Everything already in `storage/Schema.kt` before the parity port resumed. */
    const val OWNER_PRE_PORT = "pre-port"

    // ---------------------------------------------------------------------------------------
    // Main DB (badan.db) — Schema.kt already holds 1, 2, 4, 5, 6, 7, 8.
    // ---------------------------------------------------------------------------------------

    /**
     * B2-3 — mirrors iOS `Schema.mainMigrations` version 3 (BUG-11c). Session-identity repair:
     * dedup `session_stages` then `sessions` by `(external_id, source_id)`, drop
     * `idx_session_identity`, recreate it keyed by `(external_id, source_id)` alone so a sleep
     * session whose `kind` flips between re-ingests updates in place instead of duplicating.
     * Four statements on iOS; the two DELETEs run first and are not optional.
     */
    const val MAIN_SESSION_IDENTITY_REPAIR = 3

    /**
     * B2-4 — mirrors iOS `Schema.mainMigrations` version 9. `workout_checkpoints`,
     * `strength_sets`, `workout_intervals`, `workout_quality` plus their three session indexes
     * (seven statements on iOS).
     */
    const val MAIN_WORKOUT_DETAIL = 9

    /**
     * B2-5 — mirrors iOS `Schema.mainMigrations` version 10. `data_conflicts` and
     * `source_priority_rules` plus three indexes, AND four additive `ALTER TABLE … ADD COLUMN`
     * statements: `connection_type` and `capabilities` on **both** `sources` and `source_devices`
     * (nine statements on iOS).
     */
    const val MAIN_DEVICE_ECOSYSTEM = 10

    /**
     * B2-6 — mirrors iOS `Schema.mainMigrations` version 11 (D-35/D-36). `DROP TABLE IF EXISTS
     * metric_pins`, then `derived_feedback` + two indexes and `metric_calibrations` + one index
     * (six statements on iOS).
     */
    const val MAIN_FEEDBACK_CALIBRATION = 11

    /**
     * B2-3 — **Android-only catch-up; no iOS migration mirrors this number.** iOS's main v2 shipped
     * six indexes; Android's v2 shipped three, sharing only `idx_export_jobs_created`. The five
     * Android is missing are `idx_insight_period`, `idx_insight_generated`,
     * `idx_raw_metric_measured_live`, `idx_interval_metric_span_live` and
     * `idx_session_kind_start_live`. Every statement must be written `IF NOT EXISTS` — this
     * migration exists precisely because the already-written v2 cannot be edited, and the same
     * `IF NOT EXISTS` discipline `Schema.kt`'s v6 comment already documents for `idx_baseline_lookup`
     * applies here for the same reason.
     */
    const val MAIN_INDEX_CATCH_UP = 12

    // ---------------------------------------------------------------------------------------
    // Sensitive DB (badan_sensitive.db) — Schema.kt already holds 1, 3, 4.
    // ---------------------------------------------------------------------------------------

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 2 (PERF-117). Exactly one statement:
     * `CREATE INDEX idx_regimen_ended ON medication_regimens(ended_at);`
     */
    const val SENSITIVE_REGIMEN_ENDED_INDEX = 2

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 5. The lab-notebook set: eight tables
     * — `lab_reports`, `lab_panels`, `lab_results`, `reference_ranges`, `user_corrections`,
     * `lab_annotations`, `derived_trends`, `source_documents` — plus thirteen indexes
     * (21 statements on iOS).
     */
    const val SENSITIVE_LAB_NOTEBOOK = 5

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 6. Six cycle tables — `cycle_records`,
     * `flow_logs`, `contraceptive_context_logs`, `cycle_predictions`, `cycle_phase_estimates`,
     * `cycle_anomaly_events` — plus a sensitive-namespace `baselines` table (seven tables) and nine
     * indexes: **16 statements on iOS, not 7.** The sensitive `baselines` is a deliberate duplicate
     * of the main-DB table (CYCLE-06 precedent), not a mistake to consolidate.
     */
    const val SENSITIVE_CYCLE = 6

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 7. `cycle_fertile_window_estimates`
     * plus `idx_cycle_fertile_window_estimates_generated` (two statements on iOS).
     */
    const val SENSITIVE_FERTILE_WINDOW = 7

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 8. Four pregnancy tables —
     * `pregnancy_records`, `due_date_source_entries`, `due_date_estimates`,
     * `loss_declaration_records` — plus five indexes (nine statements on iOS).
     */
    const val SENSITIVE_PREGNANCY = 8

    /**
     * B2-7 — mirrors iOS `Schema.sensitiveMigrations` version 9 (A21/D-26 scope-gap closure).
     * `raw_samples` and `interval_records` mirrored into the sensitive namespace so
     * `sensitiveClass = sensitivePlus` metrics (today: `body.glucose`) land there instead of
     * `badan.db`. **Seven indexes, not five**: the five from main v1
     * (`idx_raw_metric_measured`, `idx_raw_identity`, `idx_raw_batch`, `idx_interval_metric_span`,
     * `idx_interval_identity`) *and* the two `_live` partial indexes from main v2
     * (`idx_raw_metric_measured_live`, `idx_interval_metric_span_live`) — nine statements on iOS.
     * All DDL is byte-identical to the main-DB originals; that duplication is the decision, per
     * iOS's own migration comment.
     */
    const val SENSITIVE_MEASUREMENT_CHAIN = 9

    // ---------------------------------------------------------------------------------------
    // The table itself: version -> owning task id.
    // ---------------------------------------------------------------------------------------

    /** Every main-DB version that may legally exist, and who owns it. */
    val main: Map<Int, String> = mapOf(
        1 to OWNER_PRE_PORT,
        2 to OWNER_PRE_PORT,
        MAIN_SESSION_IDENTITY_REPAIR to "B2-3",
        4 to OWNER_PRE_PORT,
        5 to OWNER_PRE_PORT,
        6 to OWNER_PRE_PORT,
        7 to OWNER_PRE_PORT,
        8 to OWNER_PRE_PORT,
        MAIN_WORKOUT_DETAIL to "B2-4",
        MAIN_DEVICE_ECOSYSTEM to "B2-5",
        MAIN_FEEDBACK_CALIBRATION to "B2-6",
        MAIN_INDEX_CATCH_UP to "B2-3",
    )

    /** Every sensitive-DB version that may legally exist, and who owns it. */
    val sensitive: Map<Int, String> = mapOf(
        1 to OWNER_PRE_PORT,
        SENSITIVE_REGIMEN_ENDED_INDEX to "B2-7",
        3 to OWNER_PRE_PORT,
        4 to OWNER_PRE_PORT,
        SENSITIVE_LAB_NOTEBOOK to "B2-7",
        SENSITIVE_CYCLE to "B2-7",
        SENSITIVE_FERTILE_WINDOW to "B2-7",
        SENSITIVE_PREGNANCY to "B2-7",
        SENSITIVE_MEASUREMENT_CHAIN to "B2-7",
    )
}
