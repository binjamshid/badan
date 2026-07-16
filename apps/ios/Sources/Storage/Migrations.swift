import Foundation

/// Forward-only, numbered migrations (D-policy: no down-migrations, ever). Migration 001 is
/// the §4 schema adapted to MVP scope. Every row table carries the sync-ready convention
/// columns (`updated_at`, `origin_device_id`, `deleted_at`) from day one (D-7), and every
/// health datum carries embedded provenance columns (D-3, I1).
struct Migration {
    let version: Int
    let statements: [String]
}

enum Schema {
    // Provenance columns shared by measurement tables (embedded, never a join).
    private static let provenanceCols = """
        source_id TEXT NOT NULL,
        device_id TEXT,
        ingestion_path TEXT NOT NULL,
        external_id TEXT,
        batch_id TEXT,
        measured_at INTEGER NOT NULL,
        measured_tz TEXT NOT NULL,
        recorded_at INTEGER NOT NULL,
        ingested_at INTEGER NOT NULL,
        algorithm_version_id TEXT,
        quality_flags TEXT,
        suppressed_by TEXT
    """

    private static let conventionCols = """
        updated_at INTEGER NOT NULL,
        origin_device_id TEXT NOT NULL,
        deleted_at INTEGER
    """

    // MARK: - Main DB (badan.db)

    static var mainMigrations: [Migration] {
        [Migration(version: 1, statements: [
            """
            CREATE TABLE sources (
              id TEXT PRIMARY KEY, type TEXT NOT NULL, display_name TEXT NOT NULL,
              platform_bundle_id TEXT, status TEXT NOT NULL, connected_at INTEGER,
              last_delivery_at INTEGER, \(conventionCols)
            );
            """,
            """
            CREATE TABLE source_devices (
              id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL, model TEXT,
              first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, \(conventionCols)
            );
            """,
            """
            CREATE TABLE permission_states (
              store TEXT NOT NULL, platform_type TEXT NOT NULL, status TEXT NOT NULL,
              last_checked_at INTEGER NOT NULL, last_read_at INTEGER,
              PRIMARY KEY (store, platform_type)
            );
            """,
            """
            CREATE TABLE user_profile (
              id TEXT PRIMARY KEY, display_name TEXT, height_m REAL, birth_year INTEGER,
              bio_note TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE raw_samples (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL,
              original_value REAL NOT NULL, original_unit TEXT NOT NULL,
              start_at INTEGER NOT NULL, end_at INTEGER, tz_id TEXT NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_raw_metric_measured ON raw_samples(metric_id, measured_at);",
            "CREATE UNIQUE INDEX idx_raw_identity ON raw_samples(metric_id, external_id, source_id) WHERE external_id IS NOT NULL;",
            "CREATE INDEX idx_raw_batch ON raw_samples(batch_id);",
            """
            CREATE TABLE interval_records (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL,
              start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, tz_id TEXT NOT NULL,
              aggregation TEXT NOT NULL, coverage REAL NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_interval_metric_span ON interval_records(metric_id, start_at, end_at);",
            "CREATE UNIQUE INDEX idx_interval_identity ON interval_records(metric_id, external_id, source_id) WHERE external_id IS NOT NULL;",
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, subtype TEXT,
              start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, tz_id TEXT NOT NULL,
              local_night TEXT, detail TEXT NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_session_kind_start ON sessions(kind, start_at);",
            "CREATE INDEX idx_session_local_night ON sessions(local_night) WHERE kind LIKE 'sleep%';",
            "CREATE UNIQUE INDEX idx_session_identity ON sessions(kind, external_id, source_id) WHERE external_id IS NOT NULL;",
            """
            CREATE TABLE session_stages (
              session_id TEXT NOT NULL, seq INTEGER NOT NULL, stage TEXT NOT NULL,
              start_at INTEGER NOT NULL, end_at INTEGER NOT NULL,
              PRIMARY KEY (session_id, seq)
            );
            """,
            """
            CREATE TABLE derived_values (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL,
              period_key TEXT NOT NULL, confidence REAL, provisional INTEGER NOT NULL,
              algorithm_id TEXT NOT NULL, algorithm_version TEXT NOT NULL, input_manifest_id TEXT,
              computed_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_derived_latest ON derived_values(metric_id, period_key, computed_at DESC);",
            "CREATE TABLE input_manifests (id TEXT PRIMARY KEY, inputs TEXT NOT NULL);",
            """
            CREATE TABLE baselines (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, covariate_context TEXT NOT NULL,
              window_days INTEGER NOT NULL, method TEXT NOT NULL, center REAL NOT NULL,
              spread REAL NOT NULL, band_low REAL NOT NULL, band_high REAL NOT NULL,
              n_points INTEGER NOT NULL, provisional INTEGER NOT NULL, algorithm_version TEXT NOT NULL,
              valid_from INTEGER NOT NULL, computed_at INTEGER NOT NULL, unit TEXT NOT NULL
            );
            """,
            "CREATE UNIQUE INDEX idx_baseline_identity ON baselines(metric_id, covariate_context, window_days, valid_from);",
            """
            CREATE TABLE insights (
              id TEXT PRIMARY KEY, insight_type TEXT NOT NULL, template_id TEXT NOT NULL,
              template_version TEXT NOT NULL, metric_ids TEXT NOT NULL, period_key TEXT NOT NULL,
              depth_variant TEXT NOT NULL, rendered_en TEXT NOT NULL, rendered_ar TEXT NOT NULL,
              evidence_refs TEXT NOT NULL, generated_at INTEGER NOT NULL, algorithm_version TEXT, feedback INTEGER
            );
            """,
            "CREATE INDEX idx_insight_type_gen ON insights(insight_type, generated_at);",
            """
            CREATE TABLE dedup_decisions (
              id TEXT PRIMARY KEY, batch_id TEXT, rule TEXT NOT NULL, rule_version TEXT NOT NULL,
              kept_record_id TEXT NOT NULL, suppressed_record_id TEXT NOT NULL, score REAL,
              reversible INTEGER NOT NULL, reversed_at INTEGER, decided_at INTEGER NOT NULL, detail TEXT NOT NULL
            );
            """,
            "CREATE INDEX idx_dedup_suppressed ON dedup_decisions(suppressed_record_id);",
            """
            CREATE TABLE workout_entries (
              id TEXT PRIMARY KEY, activity_type TEXT NOT NULL, start_at INTEGER NOT NULL,
              end_at INTEGER NOT NULL, tz_id TEXT NOT NULL, energy_kcal REAL, distance_m REAL,
              avg_hr REAL, max_hr REAL, perceived_effort INTEGER, note TEXT, ingestion_path TEXT NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_workout_start ON workout_entries(start_at);",
            """
            CREATE TABLE nutrition_entries (
              id TEXT PRIMARY KEY, description TEXT NOT NULL, meal_type TEXT NOT NULL,
              energy_kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
              water_ml REAL, caffeine_mg REAL, low_detail INTEGER NOT NULL,
              occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, note TEXT, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_nutrition_occurred ON nutrition_entries(occurred_at);",
            """
            CREATE TABLE note_entries (
              id TEXT PRIMARY KEY, text TEXT NOT NULL, occurred_at INTEGER NOT NULL,
              tz_id TEXT NOT NULL, tags TEXT NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_note_occurred ON note_entries(occurred_at);",
            """
            CREATE TABLE goals (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, target REAL NOT NULL, unit TEXT NOT NULL,
              direction TEXT NOT NULL, active INTEGER NOT NULL, created_at INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE export_jobs (
              id TEXT PRIMARY KEY, scope TEXT NOT NULL, format TEXT NOT NULL, status TEXT NOT NULL,
              manifest TEXT, output_path TEXT, row_count INTEGER, started_at INTEGER,
              finished_at INTEGER, created_at INTEGER NOT NULL
            );
            """,
            "CREATE TABLE customization_profile (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL);",
            "CREATE TABLE metric_pins (metric_id TEXT PRIMARY KEY, pinned_at INTEGER NOT NULL);",
            // FEAT-01: backs `ReadAnchorRepository` — `HealthKitAdapter` persists one
            // NSKeyedArchiver-encoded `HKQueryAnchor` per HealthKit type here so a real backfill
            // resumes incrementally instead of re-scanning full history. `resetAll()` drops this
            // table like every other main-DB table, which is exactly what a real backfill
            // restart needs.
            "CREATE TABLE read_anchors (store TEXT NOT NULL, platform_type TEXT NOT NULL, anchor BLOB, updated_at INTEGER NOT NULL, PRIMARY KEY (store, platform_type));",
            "CREATE TABLE import_batches (id TEXT PRIMARY KEY, source_kind TEXT NOT NULL, file_name TEXT, state TEXT NOT NULL, chunk_cursor TEXT, counts TEXT, created_at INTEGER NOT NULL);",
            "CREATE TABLE sync_cursors (scope_key TEXT NOT NULL, device_id TEXT NOT NULL, lamport INTEGER NOT NULL, last_synced_at INTEGER, PRIMARY KEY (scope_key, device_id));",
        ]),
        // Version 2: index-completeness fixes surfaced by the storage audit (forward-only —
        // no down-migrations, ever). export_jobs/insights had no index covering the sort
        // column their only queries actually use (OPT-183, OPT-184, PERF-115, PERF-134); the
        // three heaviest-read tables had no index matching their real WHERE clause once the
        // soft-delete/suppression predicate is included (PERF-116).
        Migration(version: 2, statements: [
            "CREATE INDEX idx_export_jobs_created ON export_jobs(created_at DESC);",
            "CREATE INDEX idx_insight_period ON insights(period_key);",
            "CREATE INDEX idx_insight_generated ON insights(generated_at DESC);",
            "CREATE INDEX idx_raw_metric_measured_live ON raw_samples(metric_id, measured_at) WHERE deleted_at IS NULL AND suppressed_by IS NULL;",
            "CREATE INDEX idx_interval_metric_span_live ON interval_records(metric_id, start_at, end_at) WHERE deleted_at IS NULL AND suppressed_by IS NULL;",
            "CREATE INDEX idx_session_kind_start_live ON sessions(kind, start_at) WHERE deleted_at IS NULL AND suppressed_by IS NULL;",
        ]),
        // Version 3 (BUG-11c): a sleep session's `kind` (primary vs. nap, a 3-hour asleep-time
        // threshold) can legitimately flip between two re-ingests of the SAME night once more
        // of it has synced from HealthKit — see `HealthKitAdapter`'s night-rebuild seam, which
        // recomputes `kind` from the full current sample set every time a night is touched.
        // With `kind` inside the sessions identity index, that reclassification's INSERT can't
        // match the existing row (its stored `kind` differs) and lands as a brand-new duplicate
        // row instead of updating in place. Forward-only (D-policy: no down-migrations): SQLite
        // has no `ALTER INDEX`, so this drops the old (kind, external_id, source_id) unique
        // index and replaces it with one keyed by (external_id, source_id) alone. Every session
        // still carries `kind` as an ordinary column — only the conflict IDENTITY changes.
        // `MeasurementRepository.upsertSession`'s `ON CONFLICT` target is updated to match this
        // exactly (SQLite requires an ON CONFLICT target to exactly match a real unique index,
        // including its partial predicate).
        //
        // (F3) The two DELETEs run BEFORE the index and are not optional. `CREATE UNIQUE INDEX`
        // fails outright if the data already violates it, and the rows it would reject are
        // exactly the ones this migration exists to stop producing: a v2 install that
        // reclassified a night (nap <-> primary) holds two sessions sharing
        // `(external_id, source_id)` and differing only in `kind`. Without the dedup, migration
        // throws -> `Database.init` throws -> `AppEnvironment` falls back to an ephemeral scratch
        // DB (`AppEnvironment.makeDefault`), so the users MOST affected by the duplicate bug are
        // the ones whose real database silently stops being opened, with their data stranded on
        // disk behind a "temporary mode" banner. The upgrade has to repair the data it's
        // tightening the constraint on.
        //
        // The survivor is the freshest row by `updated_at` (rowid breaking ties, so the choice is
        // deterministic rather than dependent on scan order): every duplicate describes the SAME
        // night from the same source, so the newest write is the one carrying the latest
        // classification and stage set — and any next sync of that night rewrites it in place
        // anyway now that the identity is stable. Stages are deleted first and scoped by
        // `session_id`, since `session_stages` has no identity of its own to dedup by and would
        // otherwise be orphaned.
        Migration(version: 3, statements: [
            """
            DELETE FROM session_stages WHERE session_id IN (
              SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (
                  PARTITION BY external_id, source_id ORDER BY updated_at DESC, rowid DESC
                ) AS rn
                FROM sessions WHERE external_id IS NOT NULL
              ) WHERE rn > 1
            );
            """,
            """
            DELETE FROM sessions WHERE id IN (
              SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (
                  PARTITION BY external_id, source_id ORDER BY updated_at DESC, rowid DESC
                ) AS rn
                FROM sessions WHERE external_id IS NOT NULL
              ) WHERE rn > 1
            );
            """,
            "DROP INDEX IF EXISTS idx_session_identity;",
            "CREATE UNIQUE INDEX idx_session_identity ON sessions(external_id, source_id) WHERE external_id IS NOT NULL;",
        ])]
    }

    // MARK: - Sensitive DB (badan_sensitive.db)

    static var sensitiveMigrations: [Migration] {
        [Migration(version: 1, statements: [
            """
            CREATE TABLE medication_regimens (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, strength TEXT, form TEXT,
              schedule TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER, notes TEXT,
              \(conventionCols)
            );
            """,
            """
            CREATE TABLE adherence_events (
              id TEXT PRIMARY KEY, regimen_id TEXT NOT NULL, kind TEXT NOT NULL, scheduled_for INTEGER,
              occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, skip_reason TEXT, skip_note TEXT,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_adherence_regimen ON adherence_events(regimen_id, occurred_at);",
            "CREATE INDEX idx_adherence_occurred ON adherence_events(occurred_at);",
            """
            CREATE TABLE symptom_entries (
              id TEXT PRIMARY KEY, symptom_id TEXT, custom_label TEXT, severity INTEGER NOT NULL,
              occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, duration_s REAL, body_location TEXT,
              triggers TEXT NOT NULL, note TEXT, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_symptom_occurred ON symptom_entries(occurred_at);",
            """
            CREATE TABLE conditions (
              id TEXT PRIMARY KEY, label TEXT NOT NULL, status TEXT NOT NULL, onset_at INTEGER,
              linked_regimen_ids TEXT NOT NULL, linked_symptom_ids TEXT NOT NULL, notes TEXT,
              \(conventionCols)
            );
            """,
        ]),
        // Version 2: medication_regimens(ended_at) has no index for the activeOnly filter
        // LoggingRepository.regimens(activeOnly:) applies (PERF-117).
        Migration(version: 2, statements: [
            "CREATE INDEX idx_regimen_ended ON medication_regimens(ended_at);",
        ])]
    }
}
