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
        ]),
        // Version 4 (plan §9): the route + export/automation entity set. Purely additive — no
        // existing table, index or row is touched, so an upgrading v3 install reaches v4 by
        // running CREATEs only and cannot lose data the way v3's repair migration could have.
        //
        // Two conventions govern which columns each new table gets, and they are not
        // interchangeable:
        //   * `provenanceCols` (I1) goes on anything that asserts a fact about the user's body
        //     or their day. A route is a measurement — it came from a specific watch, by a
        //     specific ingestion path, at a specific time — so it carries the full struct.
        //     Operational rows (a run log, a cursor) assert nothing about the user and would be
        //     lying if they claimed a `measured_at`.
        //   * `conventionCols` (D-7) goes on anything a *second device* would need to reconcile.
        //     Where it is omitted below, the omission is deliberate and the reason is stated at
        //     the table; "it seemed like boilerplate" is never the reason.
        Migration(version: 4, statements: [
            // §9.2. `consent_snapshot` records the route-consent state as it stood at ingest,
            // not as it stands now: routes are location data under their own toggle (§4.11), and
            // a later toggle-off must not retroactively relabel rows that were captured while
            // consent was genuinely granted. Export gating reads the *current* toggle; this
            // column exists so "was this row allowed to exist when it was written" stays
            // answerable after the fact, which is the same question I1 answers for sources.
            """
            CREATE TABLE workout_routes (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, point_count INTEGER NOT NULL,
              start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, consent_snapshot TEXT NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            // §9.2. Deliberately NO per-point provenance and NO convention columns — this is the
            // same shape decision `session_stages` already makes, for the same reasons, and it is
            // load-bearing in both directions:
            //   * Provenance would be pure duplication. Every point in a route came from the one
            //     device, one ingestion path and one batch that produced its parent
            //     `workout_routes` row; stamping 12 provenance columns onto each of ~3,000 points
            //     in a single 30-minute run multiplies the table's size several-fold to store the
            //     same answer the parent already gives. I1 is satisfied by the route: "where did
            //     this point come from" resolves through `route_id` in one join, never through a
            //     separate audit trail that could drift.
            //   * Convention columns would be actively wrong. A point has no independent lifecycle
            //     — you do not soft-delete or sync one GPS fix out of a trace. Routes are replaced
            //     wholesale (delete by `route_id`, bulk re-insert), so a per-point `deleted_at`
            //     would create a state — half a route — that no reader knows how to interpret.
            // If someone later "normalizes" this by adding provenance here, the bulk-insert path
            // gets several times slower and the route stops being the unit of consent.
            """
            CREATE TABLE route_points (
              route_id TEXT NOT NULL, seq INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
              altitude_m REAL, hacc_m REAL, timestamp INTEGER NOT NULL,
              PRIMARY KEY (route_id, seq)
            );
            """,
            // The (route_id, seq) PK already covers ordered point reads; this covers the other
            // direction — finding a workout's routes from the session it belongs to.
            "CREATE INDEX idx_workout_routes_session ON workout_routes(session_id);",
            // §9.3. `scope` holds the existing `ExportScope` JSON verbatim rather than being
            // shredded into columns, so a template keeps working unchanged when `ExportScope`
            // gains a field — the same reason `sessions.detail` is JSON.
            // `aggregation_method` is nullable because it is only meaningful when `aggregation`
            // is not `raw`; a raw export has nothing to aggregate *by*.
            """
            CREATE TABLE export_templates (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL, range_rule TEXT NOT NULL,
              format TEXT NOT NULL, aggregation TEXT NOT NULL, aggregation_method TEXT,
              layout TEXT NOT NULL, include_schema_docs INTEGER NOT NULL, destination_id TEXT,
              created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            // §9.3 specifies unique(name); the partial predicate is the part that isn't obvious.
            // `export_templates` carries `deleted_at`, so a plain UNIQUE(name) would let a
            // soft-deleted template permanently squat on its own name — the user deletes
            // "Weekly to Dropbox", tries to recreate it, and gets a constraint failure over a row
            // they cannot see. Scoping uniqueness to live rows makes the index enforce what the
            // user actually experiences. Any `ON CONFLICT(name)` written against this table must
            // repeat the `WHERE deleted_at IS NULL` predicate verbatim — SQLite requires an
            // ON CONFLICT target to match a real unique index including its predicate (same
            // constraint migration 3 documents for `idx_session_identity`).
            "CREATE UNIQUE INDEX idx_export_templates_name ON export_templates(name) WHERE deleted_at IS NULL;",
            // §9.4. `credential_ref` is a Keychain/Keystore key — never a secret. The column is
            // named `_ref` rather than `token`/`secret` so that a future reviewer grepping this
            // schema for credential leakage gets an answer from the column name alone, and so
            // that anyone tempted to stash a bearer token here has to first rename the column.
            // `config` holds the non-secret half (folder bookmark ref, URL, header template ids).
            """
            CREATE TABLE export_destinations (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, display_name TEXT NOT NULL, config TEXT NOT NULL,
              credential_ref TEXT, tls_policy TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_verified_at INTEGER, status TEXT NOT NULL, \(conventionCols)
            );
            """,
            // §9.5, the trust ledger. NO convention columns, and that is the whole design:
            //   * `deleted_at` would defeat the table. A ledger whose rows can be soft-deleted
            //     cannot answer "did my Tuesday export actually run", which is the only question
            //     it exists to answer. Rows are append-only (I2's spirit) and leave only via the
            //     pruning job.
            //   * `updated_at`/`origin_device_id` describe cross-device reconciliation, which does
            //     not apply: a run is an event that happened on THIS device. Merging another
            //     device's run log into this one would produce a history the user never observed
            //     here. The rows ride along in a full backup as a record, not as sync state.
            // `error_detail` is sanitized, value-free text by contract — a failed export must
            // never smuggle a health value into a log line (mirrors the DiagnosticsTests rule).
            //
            // Column named `trigger_kind`, not §9.5's `trigger`: TRIGGER is a SQL reserved word.
            // SQLite happens to accept it bare as a column name, but it is a keyword every other
            // engine and most schema tooling will reject or demand quoting for, and a column that
            // only works because one parser is lenient is a trap for whoever ports this next. The
            // `_kind` suffix also matches how this schema already names discriminators
            // (`sessions.kind`, `export_destinations.kind`, `background_runs.kind`). The domain
            // field is still `trigger`; only the storage identifier differs.
            """
            CREATE TABLE export_runs (
              id TEXT PRIMARY KEY, template_id TEXT, job_id TEXT, trigger_kind TEXT NOT NULL,
              started_at INTEGER NOT NULL, finished_at INTEGER, outcome TEXT NOT NULL,
              error_code TEXT, error_detail TEXT, bytes_written INTEGER, row_counts TEXT,
              destination_id TEXT, delivered_at INTEGER, cursor_before INTEGER, cursor_after INTEGER,
              manifest_sha256 TEXT
            );
            """,
            "CREATE INDEX idx_export_runs_started ON export_runs(started_at DESC);",
            "CREATE INDEX idx_export_runs_template_started ON export_runs(template_id, started_at DESC);",
            // §9.6. `high_watermark` tracks max `ingested_at`, NOT `measured_at` — the plan is
            // explicit and the distinction is the difference between a correct delta export and a
            // silently lossy one. A watch that syncs Saturday's workout on Monday writes a row
            // whose `measured_at` is already behind a Sunday watermark; only `ingested_at`
            // (stamped when BADAN wrote the row) is monotonic with respect to what this device
            // has actually had available to export.
            //
            // `destination_id` is NOT NULL despite §9.3 making a *template's* destination
            // optional, because those are different things: a template need not pin a
            // destination, but a run always resolves to one — `shareSheet` is itself a
            // destination kind (§9.4), not the absence of a destination. It matters mechanically
            // too: SQLite permits NULL in a non-INTEGER PRIMARY KEY column and NULLs never
            // compare equal, so a nullable destination here would let one template accumulate
            // unlimited duplicate "no destination" cursor rows, each with its own watermark, and
            // `sinceLastRun` would start re-exporting or skipping ranges depending on which row
            // it happened to read.
            //
            // No convention columns: `updated_at` is declared explicitly per §9.6, while
            // `deleted_at` is meaningless (a checkpoint is deleted by deleting the row —
            // resurrecting a soft-deleted watermark would resume from a stale position) and
            // `origin_device_id` is redundant since a cursor describes only this device's export
            // progress.
            """
            CREATE TABLE export_cursors (
              template_id TEXT NOT NULL, destination_id TEXT NOT NULL, high_watermark INTEGER NOT NULL,
              last_manifest_sha TEXT, last_run_id TEXT, updated_at INTEGER NOT NULL,
              PRIMARY KEY (template_id, destination_id)
            );
            """,
            // §9.7. `tier` is stored, never inferred, because it is a *promise to the user* and
            // §4.10 requires that promise be labeled honestly at every surface: an
            // `opportunisticBackground` schedule says "best-effort", a `shortcutDriven` one says
            // "device must be unlocked". `next_expected_window` is a display-only estimate — it
            // is never read back as a due-time to fire on, or the honest tier label would be
            // quietly contradicted by a scheduler behaving as if it had a wall clock.
            """
            CREATE TABLE automation_schedules (
              id TEXT PRIMARY KEY, template_id TEXT NOT NULL, tier TEXT NOT NULL,
              desired_cadence TEXT NOT NULL, quiet_hours TEXT, enabled INTEGER NOT NULL,
              consecutive_failures INTEGER NOT NULL, last_success_at INTEGER,
              next_expected_window INTEGER, created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            // Matches the scheduler's only real query shape: "which enabled schedules of this
            // tier are due to be considered on this kind of wakeup".
            "CREATE INDEX idx_automation_enabled_tier ON automation_schedules(enabled, tier);",
            // §9.8. Substrate-level log, wider than `export_runs`: it also covers ingest wakeups,
            // so a user asking "why is my data stale" can be answered from wakeup history rather
            // than guesswork. Same no-convention-columns rationale as `export_runs` (append-only,
            // device-local, pruned at 90 days).
            // `work_done` holds COUNTS ONLY, never values — "42 samples" is diagnostics, "42 bpm"
            // is a health value in a log, which this codebase does not do anywhere.
            // `completion_handler_called_in_ms` is iOS-specific but present in both platforms'
            // schema so the two stay byte-identical and a cross-platform fixture can diff them;
            // Android simply writes NULL. It guards the BGTaskScheduler budget: iOS terminates an
            // app that misses its expiration handler three times, and that failure is otherwise
            // invisible until background refresh has already been revoked.
            """
            CREATE TABLE background_runs (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, started_at INTEGER NOT NULL, duration_ms INTEGER,
              outcome TEXT NOT NULL, work_done TEXT, completion_handler_called_in_ms INTEGER
            );
            """,
            "CREATE INDEX idx_background_runs_started ON background_runs(started_at DESC);",
        ]),
        // Version 5 (plan §11 EPIC-26): the two Effort-engine profile inputs — an HR-max override
        // and an editable five-zone override — added to `user_profile`. Additive and forward-only:
        // SQLite `ALTER TABLE ADD COLUMN` appends a nullable column without rewriting existing rows,
        // so a populated v4 install reaches v5 by running these two ALTERs and keeps every profile
        // row intact (asserted by `ProfileHRZonesFixTests`).
        //
        // Both columns are nullable BY DESIGN, and `NULL` is the meaningful default at each — not
        // "unset", but an instruction to derive:
        //   * `hr_max` NULL  → no override; EPIC-26 derives the max from age (`208 − 0.7·age` over
        //     `birth_year`). Stored as REAL because that formula is fractional and this schema must
        //     not pre-round a value whose precision the engine owns (NO FALSE PRECISION).
        //   * `hr_zones` NULL → no personal zone override; EPIC-26 derives the five zones from the
        //     HR max. Held as JSON TEXT (an `HRZones` blob) so the zone shape can evolve — a
        //     per-zone label, a %HRR anchor — without another migration, the same reason
        //     `sessions.detail` is JSON.
        // This migration only STORES the overrides; the default formula and the zone curve are the
        // engine's (EPIC-26 stage 2), never this schema's. Byte-equivalent mirror in Android
        // `Schema.mainMigrations` version 5 — the two statement strings are identical on both
        // platforms so a divergence is a reviewable diff, not a silent drift.
        Migration(version: 5, statements: [
            "ALTER TABLE user_profile ADD COLUMN hr_max REAL;",
            "ALTER TABLE user_profile ADD COLUMN hr_zones TEXT;",
        ]),
        // Version 6 (audit 2026-07-20, FINDING #1): make `baselines` genuinely append-only, so the
        // repository's "Nothing is overwritten" promise (I2) stops being a lie for the flagship
        // auditability differentiator. The bug was the shape of THIS index, not the writer alone.
        //
        // `idx_baseline_identity` was UNIQUE on the natural key (metric_id, covariate_context,
        // window_days, valid_from). `DerivationRepository.upsertBaseline` wrote with
        // `INSERT OR REPLACE`, which on a hit at that unique key does a DELETE-then-INSERT — an
        // in-place overwrite of prior history. The nightly recompute path never tripped it (it
        // stamps `valid_from = clock.now()`, so each write lands at a fresh key), but the
        // persisted score-backfill RETRY re-runs the coordinator with a FIXED `window.to`: an
        // interrupted-then-retried backfill after an interleaved ingest recomputes a DIFFERENT band
        // at the SAME `valid_from` and silently deleted the first row. `derived_values` has no such
        // unique index and is the target shape — it appends and lets the latest read win.
        //
        // Forward-only (D-policy: no down-migrations; SQLite has no ALTER INDEX): drop the unique
        // index and replace it with a NON-unique lookup index on the columns `latestBaseline`
        // actually filters and orders by (metric_id, covariate_context, valid_from DESC), so that
        // read stays a fast index scan while a plain `INSERT` can no longer conflict. The `id`
        // column is still a unique ULID PRIMARY KEY — row identity is unaffected; only the
        // natural-key UNIQUE constraint is removed, which is exactly what lets two rows share a
        // `valid_from` and BOTH survive (the retry case), with `computed_at` breaking the tie on read.
        //
        // No data repair needed: dropping an index and creating a non-unique one never fail on
        // existing rows (unlike migration 3's UNIQUE tightening). `IF NOT EXISTS` on the CREATE is
        // load-bearing for the Android mirror only: Android already shipped `idx_baseline_lookup`
        // in ITS version 2, so this statement is a no-op there and a create here — keeping the two
        // platforms' version-6 statement strings byte-identical (a divergence would be a reviewable
        // diff, not silent drift).
        Migration(version: 6, statements: [
            "DROP INDEX IF EXISTS idx_baseline_identity;",
            "CREATE INDEX IF NOT EXISTS idx_baseline_lookup ON baselines(metric_id, covariate_context, valid_from DESC);",
        ]),
        // Version 7 (plan §9.14 / EPIC-38): the hydration module's data substrate — an append-first
        // drink ledger plus its beverage/container catalogs, goals, and per-day summaries. Purely
        // additive (CREATEs only), so an upgrading v6 install reaches v7 without touching an
        // existing row. Byte-equivalent mirror in Android `Schema.mainMigrations` version 7 — the
        // statement strings are identical on both platforms so a divergence is a reviewable diff.
        //
        // SCOPE: this is the Phase-1 slice of EPIC-38 (ledger + quick-log + goals + export). It does
        // NOT create the module's later-phase tables (fasting profiles, reminder schedules,
        // contextual target rules); those arrive as their own forward migrations. `hydration_entries`
        // is normal-class and lives here in the main DB — a logged drink is not sensitive-plus. The
        // fasting/cycle/pregnancy CONTEXTS that §9.14 marks sensitive-plus are deliberately not
        // modelled yet, and the default export redacts them structurally (see `HydrationExport`).
        Migration(version: 7, statements: [
            // §9.14 `HydrationEntry`. The append-first ledger with an auditable revision chain, and
            // full embedded provenance (I1) because a manually-asserted drink is still a fact with
            // an origin (`ingestion_path=manual` distinguishes it from a future platform import).
            //
            // REVISION-CHAIN DESIGN (the heart of "evidence first, auditable second"). Editing a
            // logged drink never overwrites the row — it APPENDS a new row that supersedes the old,
            // so the full history of "what the user said, and how they later corrected it" survives
            // (I2-flavored). Three columns carry the chain:
            //   * `original_id` — the stable identity of a logical drink across all its revisions.
            //     For a first-time (un-revised) entry, `original_id == id`. Every revision copies the
            //     original's `original_id`, so one query on `original_id` returns the whole audit
            //     chain, tombstones included.
            //   * `supersedes` — the id of the immediately-prior row this revision replaces; NULL for
            //     an original. This is the backward link that lets the LIVE view be computed without
            //     ever mutating an old row: a row is live iff it is not tombstoned AND no *non-deleted*
            //     row supersedes it. That "non-deleted superseder" qualifier is load-bearing — it is
            //     what lets `undo` of a revision (tombstone just the revision) revert to the prior
            //     version, while `delete` (tombstone the WHOLE chain) removes the entry outright. The
            //     two operations differ only in how many rows they tombstone, never in a mutate.
            //   * `revision` — a 1-based counter (1 = original), for honest display ("edited") and
            //     stable chain ordering. Not required by the live query, but cheap and audit-useful.
            // `note` is nullable and is REDACTED from the default export (§7A.1) — the schema stores
            // it, the export writer withholds it unless explicitly opted in.
            """
            CREATE TABLE hydration_entries (
              id TEXT PRIMARY KEY, volume_ml REAL NOT NULL, fluid_type TEXT NOT NULL,
              beverage_id TEXT, container_id TEXT, occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL,
              note TEXT, original_id TEXT NOT NULL, supersedes TEXT, revision INTEGER NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            // Day/range reads scan by `occurred_at` (a day's summary, a week's history).
            "CREATE INDEX idx_hydration_occurred ON hydration_entries(occurred_at);",
            // The whole audit chain of one logical drink, by its stable identity.
            "CREATE INDEX idx_hydration_original ON hydration_entries(original_id);",
            // Backs the live-view subquery ("which rows are superseded by a non-deleted revision").
            // Partial, because only revisions carry a non-NULL `supersedes`.
            "CREATE INDEX idx_hydration_supersedes ON hydration_entries(supersedes) WHERE supersedes IS NOT NULL;",
            // §9.14 `BeverageDefinition`. USER-added beverages live here; the curated built-ins ship
            // as `packages/contracts/dictionaries/beverages.json` (same dictionary-vs-custom split as
            // `symptoms.json` / `symptom_entries`). `caffeine_mg_per_100ml`/`alcohol_pct`/
            // `electrolyte_note` are DISPLAY METADATA ONLY this phase — they are stored so a future
            // phase can surface them, but NOTHING reads them into a "net hydration" multiplier (a
            // §7A.1 Reject item). No provenance columns: a beverage definition is a catalog row, not a
            // measurement of the user's body.
            """
            CREATE TABLE beverage_definitions (
              id TEXT PRIMARY KEY, name_en TEXT NOT NULL, name_ar TEXT NOT NULL, fluid_type TEXT NOT NULL,
              default_volume_ml REAL, caffeine_mg_per_100ml REAL, alcohol_pct REAL, electrolyte_note TEXT,
              is_builtin INTEGER NOT NULL, \(conventionCols)
            );
            """,
            // §9.14 `ContainerPreset`. The "My Bottle" favorites that make a log ≤2 actions. Bilingual
            // name so a built-in preset renders in either locale (a user-named bottle sets both to
            // their own text). `beverage_id` is the preset's default drink; NULL means plain water.
            """
            CREATE TABLE container_presets (
              id TEXT PRIMARY KEY, name_en TEXT NOT NULL, name_ar TEXT NOT NULL, volume_ml REAL NOT NULL,
              beverage_id TEXT, sort_order INTEGER NOT NULL, \(conventionCols)
            );
            """,
            // §9.14 `HydrationGoal`. `kind` is the equal-status discriminator: `none` is a real,
            // first-class value ("I track without a goal"), never the absence of a row — the product
            // rule is that no-goal is never nagged and never treated as "unset" (§7A.1). `target_ml`
            // is NULL exactly when `kind = none`. `day_type` is a USER-AUTHORED label (rest/training/…)
            // for day-type goal schedules (§7A.1, Phase 2); NULL is the default goal that applies when
            // no day-type override matches. The engine never INFERS a day type — the caller supplies it.
            """
            CREATE TABLE hydration_goals (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, target_ml REAL, day_type TEXT, active INTEGER NOT NULL,
              created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_hydration_goals_active ON hydration_goals(active, day_type);",
            // §9.14 per-day goal snapshot. A rollup keyed by local calendar day, storing the day's
            // manual/imported/estimated totals SEPARATELY (I5 — only `manual_ml` is populated this
            // phase; the other two exist so an imported/estimated total is never silently blended into
            // the logged number). `goal_target_ml`/`goal_kind`/`goal_id` are the SNAPSHOT: the goal
            // that was in effect when this day was first summarized, frozen so history stays honest
            // after a later goal change (`GoalEngine.makeSummary` preserves an existing snapshot on
            // recompute). No provenance: a summary is a derived rollup, not a measurement.
            """
            CREATE TABLE hydration_daily_summaries (
              day_key TEXT PRIMARY KEY, tz_id TEXT NOT NULL, manual_ml REAL NOT NULL, imported_ml REAL NOT NULL,
              estimated_ml REAL NOT NULL, entry_count INTEGER NOT NULL, goal_kind TEXT NOT NULL,
              goal_target_ml REAL, goal_id TEXT, \(conventionCols)
            );
            """,
        ]),
        // Version 8 (plan §9.12 / EPIC-31 + EPIC-32): the two Phase-3A tables — periodic-report
        // metadata and the notification-delivery budget ledger. Purely additive (CREATEs only), so
        // an upgrading v7 install reaches v8 without touching an existing row. Byte-equivalent mirror
        // in Android `Schema.mainMigrations` version 8 — the statement strings are identical on both
        // platforms so a divergence is a reviewable diff, not silent drift.
        //
        // NEITHER table carries provenance columns (I1), for the same reason migration 4 omits them
        // from `export_runs`/`background_runs`: provenance asserts "a source measured this fact about
        // the user's body." A report is a rollup BADAN COMPUTED from rows that already carry their own
        // provenance (it is derived, not measured), and a notification-delivery row is operational
        // metadata about a scheduling decision — a `measured_at`/`source_id` on either would be a lie.
        // BOTH carry the convention columns (D-7), and here — unlike the v4 ledgers — that is correct:
        // a report is a user-visible row deleted from a list and reconcilable across devices, and a
        // queued delivery is a row that transitions state (scheduled → delivered/suppressed), so
        // `updated_at`/`origin_device_id`/`deleted_at` all carry meaning rather than being boilerplate.
        Migration(version: 8, statements: [
            // §9.12 `Report`. Generated weekly/monthly report METADATA. The rendered artifact (a PDF)
            // lives as a file and is regenerable, so this row is DERIVED and never a source of truth:
            // EPIC-31's `ReportBuilder` is a pure function over the derived store, so re-running it
            // reproduces the same typed model. The row exists so the in-app Reports surface can list
            // and open reports without re-deriving, and so a rendered file can be checked against what
            // the store would regenerate.
            //   * `period_key` — the report's period in the same textual, sortable, language-neutral
            //     form the rest of the schema uses for period keys (e.g. `week:2026-W29`,
            //     `month:2026-07`).
            //   * `algorithm_version_id` — the report-building algorithm version that produced this
            //     row. Part of the identity (below) because regenerating under a NEW version is a
            //     genuinely different report, not a replacement of the old one.
            //   * `sections_included` — JSON array of the section ids present (sleep/effort/readiness/
            //     adherence/changes), stored whole rather than shredded so the section set can evolve
            //     without a migration (same reason `sessions.detail` is JSON). An empty week
            //     legitimately includes fewer sections.
            //   * `artifact_path` — NULLABLE: the PDF may not have been rendered yet, or may have been
            //     pruned to reclaim space. A report row is valid without a file on disk — the file is
            //     regenerable from the model, never the other way round.
            //   * `sha256` — NOT NULL content hash of the deterministic report MODEL (not of any one
            //     rendered file). It is the row's integrity anchor: because the builder is
            //     deterministic, a rendered artifact can be trusted iff re-deriving the model
            //     reproduces this hash — which is exactly what lets the artifact be "never a source of
            //     truth" while staying verifiable, and it is always computable even when
            //     `artifact_path` is NULL.
            """
            CREATE TABLE reports (
              id TEXT PRIMARY KEY, period_key TEXT NOT NULL, generated_at INTEGER NOT NULL,
              algorithm_version_id TEXT NOT NULL, sections_included TEXT NOT NULL, artifact_path TEXT,
              sha256 TEXT NOT NULL, \(conventionCols)
            );
            """,
            // §9.12 unique(period_key, algorithm_version_id): one CURRENT report per period per
            // algorithm version. Regenerating for the same period+version REPLACES rather than
            // appends — a report is derived and regenerable, so this is deliberately NOT the
            // append-only shape `baselines`/`derived_values` hold (I2 governs BADAN's beliefs over
            // time, not a disposable rendered rollup). The predicate is `WHERE deleted_at IS NULL` for
            // the same reason `idx_export_templates_name` is partial: `reports` carries `deleted_at`,
            // and a plain UNIQUE would let a soft-deleted report squat on its (period, version)
            // identity so the user could not regenerate a report they had just deleted. Any
            // `ON CONFLICT(period_key, algorithm_version_id)` written against this table must repeat
            // this `WHERE deleted_at IS NULL` predicate verbatim — SQLite requires an ON CONFLICT
            // target to match a real unique index including its predicate (same constraint migrations
            // 3 and 4 document).
            "CREATE UNIQUE INDEX idx_reports_period_algorithm ON reports(period_key, algorithm_version_id) WHERE deleted_at IS NULL;",
            // EPIC-32 the notification budget ledger. VALUE-FREE by contract: a row records that a
            // notification of some CLASS was scheduled/delivered, never the health value that
            // notification was about — "readiness summary scheduled for 07:00" is metadata; the
            // readiness score is not stored here (same rule as `background_runs.work_done` holding
            // counts, never values). This table backs the daily non-med budget AND the 64-pending
            // cap interplay: EPIC-32 EXTENDS the existing `NotificationScheduler`, it does not replace
            // it, and the decision engine COUNTS rows here — by class and by day-window — to know what
            // it has already sent or queued before deciding whether the next notification fits.
            //   * `notification_class` — the discriminator (readiness|windDown|deviation|exportHealth|
            //     hydration|meds). Named `notification_class`, not the plan's bare `class`, because
            //     `class` is a reserved keyword in BOTH host languages (Swift and Kotlin); this
            //     follows the spirit of migration 4's `trigger`→`trigger_kind` rename — keep storage
            //     identifiers clear of keywords that trap the next porter or tool. The domain field is
            //     still "class".
            //   * `scheduled_for` — the instant the notification is scheduled to fire; the budget
            //     window is measured over this, not over `delivered_at`.
            //   * `delivered_at` — NULLABLE: NULL means scheduled/queued but not yet fired. A queued
            //     row still counts toward what the engine has committed for the day.
            //   * `outcome` — the delivery's current state (e.g. scheduled|delivered|suppressed|
            //     cancelled). NOT NULL because a row always HAS a state; the exact enum is EPIC-32's,
            //     not pinned by the schema.
            """
            CREATE TABLE notification_deliveries (
              id TEXT PRIMARY KEY, notification_class TEXT NOT NULL, scheduled_for INTEGER NOT NULL,
              delivered_at INTEGER, outcome TEXT NOT NULL, \(conventionCols)
            );
            """,
            // EPIC-32 Index (class, scheduled_for): the budget/cap query is "how many of this class
            // are scheduled/delivered in this window", a range scan on `scheduled_for` within a class,
            // so the class leads and `scheduled_for` follows.
            "CREATE INDEX idx_notification_deliveries_class_scheduled ON notification_deliveries(notification_class, scheduled_for);",
        ]),
        // Version 9 (plan §9.18 / EPIC-42): the workout OS's child-table set. `WorkoutSession`
        // itself STAYS `sessions(kind=workout)` — no new top-level session table — because the
        // richer, versioned detail payload plan §9.18 asks for (state history, quality summary,
        // refs to the tables below) is exactly the kind of "the shape may grow" data
        // `sessions.detail` already exists to hold as JSON, the same reason `WorkoutDetail` itself
        // lives there rather than as its own table (see that struct's doc in Measurements.swift).
        // Every table below is additive (CREATEs only), so an upgrading v8 install reaches v9
        // without touching an existing row. A byte-equivalent Android mirror is deferred rather
        // than written here: Android was paused mid-project (2026-07-22) and this migration is
        // picked up unmodified whenever it resumes — writing an untested, unmirrored Android
        // migration string now would be a claim of parity this slice cannot back up.
        //
        // FOUR TABLES, four different reasons to exist OUTSIDE `sessions.detail` rather than
        // inside it, and none of the four is interchangeable with another:
        //   * `workout_checkpoints` — hot, in-progress state for the ONE session currently being
        //     recorded. Everything else in this migration describes a workout that already
        //     happened; this describes one that might not survive to finish. It is the SOLE
        //     exception to append-only in this file (see below) — a live session's checkpoint is
        //     overwritten in place on every tick, and the row is deleted outright (not tombstoned)
        //     the moment the session finalizes into `sessions`, because at that point the
        //     finalized row IS the durable record and a lingering "still recording" draft would be
        //     actively misleading to a crash-recovery scan.
        //   * `strength_sets` — one row per logged set, keyed to a session by `session_id`,
        //     because a strength workout can log dozens of sets and shredding that many rows into
        //     one JSON blob column would make "how did my 3rd set of squats change over 6 weeks" an
        //     expensive full-table-scan-and-parse instead of an indexed range read.
        //   * `workout_intervals` — the same volume argument for structured work/rest/lap/segment
        //     data (plan §7A.5's interval/HIIT engine): a 20-lap interval session is 20 rows here,
        //     not 20 entries buried in a growing JSON array nobody can index.
        //   * `workout_quality` — completeness/continuity/accuracy PER METRIC FAMILY (HR, GPS,
        //     cadence, power…), because a single session can be simultaneously "GPS: good" and
        //     "HR: gap-filled the first two minutes" (plan §7A.5's honest per-family badges), and
        //     collapsing that into one number on the session row would erase exactly the
        //     distinction I5 exists to preserve — here, good-metric vs. bad-metric within the SAME
        //     session, not just raw vs. derived.
        //
        // PROVENANCE, deliberately omitted from all three non-checkpoint tables (not an oversight
        // — this follows the exact model migration 4's `route_points` comment sets out):
        //   * `strength_sets` / `workout_intervals` are children of a `sessions` row that ALREADY
        //     carries full embedded provenance (I1) — the same source, device, and ingestion path
        //     cover every set and every lap in that session. Stamping 12 provenance columns onto
        //     every set of a 5×5 workout would duplicate an answer the parent session already
        //     gives; "where did this set come from" resolves through `session_id` in one join,
        //     never through a second audit trail that could drift from the first.
        //   * `workout_quality` is a COMPUTED assessment, not a measurement — the same reason
        //     `derived_values`/`baselines` carry no `measured_at`/`source_id` of their own. It does
        //     carry `algorithm_version` and `computed_at`, the pair that actually identifies a
        //     computation, mirroring those two tables exactly.
        //
        // CONVENTION COLUMNS (D-7), and the one deliberate omission:
        //   * `strength_sets` carries the full set — AND the append-first revision chain
        //     (`original_id`/`supersedes`/`revision`) `hydration_entries` already established
        //     (migration 7): a corrected set (wrong weight logged) APPENDS a new revision, it never
        //     UPDATEs the row, so "what the user logged, and how they corrected it" stays auditable
        //     (I2-flavored) exactly like a hydration entry's history. `is_warm_up` is a plain flag,
        //     not folded into `set_kind`'s vocabulary, because plan §7A.5 is explicit that warm-ups
        //     are excluded from PR/volume logic BY DEFAULT — a query needs to filter them without
        //     parsing every semantic set-kind value to guess which ones count as warm-up.
        //   * `workout_intervals` carries the plain convention set — no revision chain, because a
        //     lap is a recorded/computed segment, not a hand-typed number someone mis-keys the way
        //     a set's weight can be — so a wrong segment is still correctable via the ordinary
        //     tombstone (`deleted_at`) rather than needing a chain.
        //   * `workout_quality` carries the plain convention set too, matching `derived_values`'
        //     own shape (which also carries `conventionCols` despite being append-only — I2 governs
        //     the VALUE history; the convention columns are the same cross-device sync bookkeeping
        //     every other row gets, which is not a contradiction of append-only).
        //   * `workout_checkpoints` carries NEITHER `provenanceCols` NOR `conventionCols` — it
        //     asserts nothing about the user's body (provenance would lie, the same reasoning
        //     migration 4 gives for `export_runs`/`background_runs`) and it is not a cross-device
        //     reconciliation target (`updated_at`/`origin_device_id`/`deleted_at` would lie too —
        //     only one device is ever recording one live session). `last_checkpoint_at` plays
        //     `updated_at`'s role under a name that says what it actually means, and there is no
        //     `deleted_at` because this table's one removal path is a real `DELETE`, not a
        //     tombstone — see `WorkoutCheckpointRepository.clear`.
        //
        // `state` (workout_checkpoints), `set_kind`/`superset_group` (strength_sets), and `kind`
        // (workout_intervals) are deliberately bare TEXT, not a CHECK-constrained enum: the
        // domain-side `WorkoutLifecycleState` / set-semantics / interval-kind enums are Swift's
        // (and, once Android resumes, Kotlin's) to own and evolve. A schema CHECK would need its
        // own forward-only migration every time either enum gained a case, which defeats the same
        // additive-without-a-migration reasoning this comment already applies to `sessions.detail`
        // — just applied to a column instead of a JSON blob.
        Migration(version: 9, statements: [
            """
            CREATE TABLE workout_checkpoints (
              session_id TEXT PRIMARY KEY,
              activity_type TEXT NOT NULL,
              state TEXT NOT NULL,
              started_at INTEGER NOT NULL,
              state_history TEXT NOT NULL,
              hot_state TEXT NOT NULL,
              last_checkpoint_at INTEGER NOT NULL,
              origin_device_id TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE strength_sets (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              original_id TEXT NOT NULL,
              supersedes TEXT,
              revision INTEGER NOT NULL,
              movement_id TEXT,
              custom_label TEXT,
              set_kind TEXT NOT NULL,
              superset_group TEXT,
              seq INTEGER NOT NULL,
              reps INTEGER,
              weight_value REAL,
              weight_unit TEXT,
              is_warm_up INTEGER NOT NULL,
              recorded_at INTEGER NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_strength_sets_session ON strength_sets(session_id, seq);",
            """
            CREATE TABLE workout_intervals (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              kind TEXT NOT NULL,
              start_at INTEGER NOT NULL,
              end_at INTEGER,
              target TEXT,
              result TEXT,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_workout_intervals_session ON workout_intervals(session_id, seq);",
            """
            CREATE TABLE workout_quality (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              metric_family TEXT NOT NULL,
              completeness REAL,
              continuity REAL,
              accuracy REAL,
              primary_source_id TEXT,
              algorithm_version TEXT NOT NULL,
              computed_at INTEGER NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_workout_quality_session ON workout_quality(session_id);",
        ]),
        // Version 10 (plan §7A.6 / §9.19, EPIC-43 ungated core): device-ecosystem reconciliation v2's
        // two new tables, plus additive connection/capability columns on the two existing device-
        // identity tables. Purely additive (CREATEs + ALTERs only), so an upgrading v9 install reaches
        // v10 without touching an existing row.
        //
        // `data_conflicts` and `source_priority_rules` are genuinely NEW concepts (a detected-but-
        // unresolved disagreement, and a per-metric default priority order) — the existing
        // `dedup_decisions` table remains the one and only `ReconciliationDecision` ledger per the
        // plan's own §9.19 text ("the existing dedup_decisions table serves as the immutable
        // ReconciliationDecision ledger, rule refs extended"); NEITHER new table is a parallel
        // decisions journal, and nothing here touches `dedup_decisions` itself.
        //
        // `data_conflicts` carries the full convention-column set (D-7: `updated_at`/
        // `origin_device_id`/`deleted_at`) because a conflict transitions state (unresolved ->
        // resolved) and is reconcilable across devices — closer in shape to `notification_deliveries`
        // (migration 8) than to the append-only, no-lifecycle ledgers migration 4 documents. It carries
        // NO provenance columns (I1): a conflict is a statement ABOUT two-or-more existing provenance-
        // carrying records, not a measurement of its own — the same reason `derived_values`/
        // `workout_quality` omit provenance, just applied to a detection row instead of a computation.
        // `candidate_record_ids` is a JSON array (not a join table) for the same reason
        // `sessions.detail` is JSON: the set of disagreeing records is fixed at detection time and
        // never independently queried by a third table, so a normalized child table would add a join
        // with no read this schema actually needs.
        //
        // `source_priority_rules` deliberately carries NO unique constraint on `metric_id` — see
        // `SourcePriorityRuleRepository`'s own header doc for why (it sidesteps the exact
        // `INSERT OR REPLACE` + partial-unique-index interaction migration 4's `idx_export_templates_name`
        // comment already warns about elsewhere); `idx_source_priority_rules_metric` is a plain lookup
        // index, not a uniqueness guarantee, and reads pick the freshest live row explicitly.
        //
        // `sources`/`source_devices` gain two nullable columns each — `connection_type` (the
        // `ConnectionType` enum's raw value) and `capabilities` (a JSON array of `DeviceCapability` raw
        // values) — additive exactly like migration 5's `hr_max`/`hr_zones` ALTERs. NULL is the correct
        // default for an upgraded row: an existing HealthKit/HealthConnect source predates this column
        // and has never been asked what connection type or capabilities it has, which is a different
        // fact from "connects by an empty/unknown method." NOTE (scope, stated plainly so a future
        // reader doesn't assume otherwise): `CatalogRepository` — the existing reader/writer of both
        // tables — is NOT updated in this migration's slice to populate or read these two columns; that
        // repository wiring, and any real writer that would set `connection_type = ble_direct` (which
        // needs the follow-up slice's real `CBCentralManager`-backed adapter to ever exist), are out of
        // scope here. The columns exist so the schema is ready; nothing in this slice claims they are
        // wired end to end yet.
        Migration(version: 10, statements: [
            """
            CREATE TABLE data_conflicts (
              id TEXT PRIMARY KEY, scope_key TEXT NOT NULL, window_start INTEGER NOT NULL,
              window_end INTEGER NOT NULL, candidate_record_ids TEXT NOT NULL, status TEXT NOT NULL,
              resolved_by_decision_id TEXT, detected_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_data_conflicts_status ON data_conflicts(status, detected_at DESC) WHERE deleted_at IS NULL;",
            "CREATE INDEX idx_data_conflicts_scope ON data_conflicts(scope_key, window_start);",
            """
            CREATE TABLE source_priority_rules (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, priority_order TEXT NOT NULL,
              is_user_override INTEGER NOT NULL, created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_source_priority_rules_metric ON source_priority_rules(metric_id, updated_at DESC);",
            "ALTER TABLE sources ADD COLUMN connection_type TEXT;",
            "ALTER TABLE sources ADD COLUMN capabilities TEXT;",
            "ALTER TABLE source_devices ADD COLUMN connection_type TEXT;",
            "ALTER TABLE source_devices ADD COLUMN capabilities TEXT;",
        ]),
        // Version 11 (D-35/D-36).
        //
        // `metric_pins` is dropped, not migrated. It shipped in version 1 and never acquired a
        // single caller — `ProfileRepository.pinnedMetrics()`/`setPinned()` were dead code in
        // Sources and Tests alike — so there is no user data in it to preserve on any install.
        // D-35's pins live on the customization profile instead, because this table could only
        // ever express `pinned_at` insertion order and the feature needs user-chosen order.
        Migration(version: 11, statements: [
            "DROP TABLE IF EXISTS metric_pins;",
            // D-36. Feedback is recorded against the exact (algorithm, version) that produced the
            // row the user reacted to. That is load-bearing, not bookkeeping: feedback about the
            // sleep-led readiness method must never calibrate the autonomic one, and a version bump
            // means the number the user judged is not the number the code now produces.
            """
            CREATE TABLE derived_feedback (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, period_key TEXT NOT NULL,
              derived_value_id TEXT NOT NULL, algorithm_id TEXT NOT NULL,
              algorithm_version TEXT NOT NULL, direction TEXT NOT NULL,
              created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_derived_feedback_metric ON derived_feedback(metric_id, algorithm_id, created_at DESC) WHERE deleted_at IS NULL;",
            "CREATE UNIQUE INDEX idx_derived_feedback_period ON derived_feedback(metric_id, period_key, algorithm_id) WHERE deleted_at IS NULL;",
            // Append-only and latest-wins, exactly like `derived_values` (I2). An older calibration
            // row is what explains a value computed while it was in force, so it is never rewritten.
            """
            CREATE TABLE metric_calibrations (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL,
              algorithm_id TEXT NOT NULL, algorithm_version TEXT NOT NULL,
              offset REAL NOT NULL, sample_count INTEGER NOT NULL,
              computed_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_metric_calibrations_latest ON metric_calibrations(metric_id, algorithm_id, computed_at DESC) WHERE deleted_at IS NULL;",
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
        ]),
        // Version 3 (plan §9.9–§9.11): journal / context / cycle. These live in the SENSITIVE
        // database rather than the main one, and the placement is the point — I7 makes
        // "turn this off" a literal file deletion (`Database.purgeSensitiveNamespace`) instead of
        // a row-by-row purge that has to be trusted. Putting any of these three in `badan.db`
        // would silently downgrade that guarantee to best-effort.
        //
        // Each is sensitive-plus for a distinct reason, and they gate INDEPENDENTLY (§4.11) —
        // there is no single "sensitive" switch that covers all three:
        //   * `journal_entries` — behavior tags (alcohol, late meal, supplements) are
        //     lifestyle-revealing in a way a step count is not.
        //   * `context_statuses` — travel/illness/injury intervals disclose circumstance.
        //   * `cycle_contexts` — double-gated: its own consent toggle AND the general sensitive
        //     toggle, with a cycle-specific export opt-in on top. It is never included by the
        //     general sensitive toggle alone.
        // Consent is enforced at the repository/export layer; the schema's job is to make the
        // separation structural. All three carry full embedded provenance (I1): a manually
        // asserted fact is still a fact with an origin, and `ingestion_path=manual` is what
        // distinguishes "the user told us" from "a device measured it" at read time.
        Migration(version: 3, statements: [
            // §9.9. `behavior_id` (dictionary key) and `custom_label` are both nullable because
            // exactly one is set per row: a curated bilingual dictionary entry, or the user's own
            // words. Storing the dictionary KEY rather than its rendered label is what keeps
            // Arabic/RTL a first-order concern — the row stays language-neutral and renders in
            // whichever locale reads it, so a journal written in Arabic exports readably in
            // English and vice versa. `value`/`unit` are nullable because `value_kind=boolean`
            // ("did it happen") has neither.
            """
            CREATE TABLE journal_entries (
              id TEXT PRIMARY KEY, behavior_id TEXT, custom_label TEXT, value_kind TEXT NOT NULL,
              value REAL, unit TEXT, occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, note TEXT,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_journal_occurred ON journal_entries(occurred_at);",
            "CREATE INDEX idx_journal_behavior_occurred ON journal_entries(behavior_id, occurred_at);",
            // §9.10. `end_at` is nullable and that is the normal case, not an edge case: a status
            // is declared when it starts ("I'm travelling") and closed later, so an open-ended row
            // means "still active as of now". Readers must treat NULL as ongoing rather than as
            // malformed. These intervals only ever ANNOTATE confidence ("computed during travel —
            // your baseline may not apply"); no engine may silently alter a value because a
            // status is active, or the displayed number stops being the measured one.
            """
            CREATE TABLE context_statuses (
              id TEXT PRIMARY KEY, status_id TEXT, custom_label TEXT, start_at INTEGER NOT NULL,
              end_at INTEGER, tz_id TEXT NOT NULL, note TEXT,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_context_status_start ON context_statuses(start_at);",
            // §9.11. Feeds the `Baseline.covariate_context` column reserved in migration 1 —
            // additive exactly as that schema anticipated, so no baseline table change is needed.
            // `phase` includes an explicit `unknown` case rather than leaving it NULL: a cycle
            // whose phase cannot be determined is a real, displayable state ("not enough data"),
            // and collapsing it into NULL loses the difference between "we don't know" and "no
            // one has looked".
            //
            // Superseded later by the fuller cycle model in plan §9.15 (CycleRecord, FlowLog,
            // CyclePhaseEstimate, …). That supersession arrives as its own forward migration —
            // this table is not a placeholder to be edited in place, and migrations are
            // forward-only regardless.
            """
            CREATE TABLE cycle_contexts (
              id TEXT PRIMARY KEY, cycle_start_at INTEGER NOT NULL, phase TEXT NOT NULL,
              source_kind TEXT NOT NULL, confidence REAL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_context_start ON cycle_contexts(cycle_start_at);",
        ]),
        // Version 4 (EPIC-29): the correlation engine's findings — `derived_values` and
        // `input_manifests` again, but in the SENSITIVE file this time.
        //
        // **Why a second copy of two tables that already exist in `badan.db`.** A correlation
        // finding's metric id IS the disclosure: `journal.correlation.alcohol.readiness.score`
        // says the user logs alcohol, in a column, in plain text. Writing that row to the main
        // database would put a lifestyle-revealing fact outside the namespace whose whole purpose
        // is that turning sensitive records off is a file deletion — the row would survive
        // `purgeSensitiveNamespace()` and keep saying it. `stress.day_trend` is sensitive-plus and
        // does live in the main db, and that is consistent rather than contradictory: its ID names
        // no behaviour, so only its VALUE is sensitive, and the registry's sensitiveClass gate is
        // enough for it. Here the identifier itself would leak, so placement has to do the work.
        //
        // Same DDL as main migration 1's pair, deliberately byte-for-byte: `DerivedValue` and
        // `InputManifest` are one domain shape, and a divergent column list would mean two readers
        // and two ways to be wrong. `CorrelationRepository` is the only writer and holds the
        // sensitive connection alone (structural I7, exactly as `JournalRepository` does).
        //
        // Append-only (I2) is unchanged by the move: a recompute inserts a fresh row with a new
        // `computed_at` and the previous belief stays readable.
        Migration(version: 4, statements: [
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
        ]),
        // Version 5 (plan §9.17 / EPIC-41, Phase 3E MVP): the lab-notebook entity set — manual entry
        // + on-device-OCR-only ingestion, four-concept reference ranges, append-only trends. Purely
        // additive (CREATEs only), so an upgrading v4 sensitive install reaches v5 without touching
        // an existing row.
        //
        // SENSITIVE, not main (I7): a lab result's identifier space can itself disclose (a result
        // naming e.g. an HIV or fertility-treatment marker says something about the user before any
        // VALUE is read) — the exact same reasoning `CorrelationRepository`'s header gives for why
        // its `derived_values` copy lives here rather than in `badan.db`; placement carries the
        // guarantee for these seven tables, not a per-row consent flag alone. `lab_reports`/
        // `lab_results` additionally carry an explicit `sensitivity_tier` column
        // (standard/high/veryHigh) for finer-grained UI/export treatment ON TOP of the namespace
        // boundary — never as a SUBSTITUTE for it.
        //
        // SCOPE, stated plainly: this migration creates exactly the tables `LabModels.swift` needs
        // for its non-vault, non-OCR-pipeline entities. `SourceDocument`/`OCRExtraction` (the
        // encrypted document vault + OCR pipeline itself) are a PARALLEL lane's tables —
        // `lab_reports.document_ref` below is an OPAQUE reference string into whatever table that
        // lane creates, never a foreign key this migration defines.
        //
        // FOUR-CONCEPT REFERENCE-RANGE LAW (hard schema requirement, plan §7A.4): `reference_ranges`
        // below carries ONLY the source-printed interval + the source-printed flag — concepts 1 and
        // 2. Personal baseline (concept 3) lives in `derived_trends`; a user-defined threshold
        // (concept 4) is not persisted at all this slice (see `ReferenceRangeEngine.UserLabThreshold`
        // for why). No table here has a column that could hold more than one of the four concepts,
        // which makes conflating them a compile-time impossibility rather than a discipline someone
        // has to remember to uphold.
        Migration(version: 5, statements: [
            // `LabReport`. `ingestion_path` is a bare column (not embedded `provenanceCols`) because
            // a report's provenance story this slice ever produces is exactly one of two values —
            // manual or fileImport (an on-device-OCR-parsed document) — and the measurement-bearing
            // half of provenance (WHEN was an analyte actually measured, in what timezone, by what
            // algorithm/OCR version) belongs on each `LabResult` below, not duplicated here across
            // every result in the report (the same reason migration 9's `strength_sets` does not
            // repeat its parent session's provenance). `collection_at`/`tz_id` are NOT NULL — even
            // the smallest quick single-marker manual entry needs a date its one result is filed
            // under. `reported_at` is nullable and never invented when absent.
            """
            CREATE TABLE lab_reports (
              id TEXT PRIMARY KEY, source_lab_name TEXT, collection_at INTEGER NOT NULL,
              reported_at INTEGER, tz_id TEXT NOT NULL, document_ref TEXT, review_state TEXT NOT NULL,
              ingestion_path TEXT NOT NULL, sensitivity_tier TEXT NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_lab_reports_collection ON lab_reports(collection_at DESC);",
            // `LabPanel`. A named group within one report ("CBC", "Lipid Panel") — `name` is kept as
            // printed (notebook law: structure where safe, source wording where not); `sort_order`
            // preserves the order panels appeared on the source document/entry.
            """
            CREATE TABLE lab_panels (
              id TEXT PRIMARY KEY, report_id TEXT NOT NULL, name TEXT NOT NULL,
              sort_order INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_lab_panels_report ON lab_panels(report_id, sort_order);",
            // `LabResult`. The one table in this migration carrying full embedded `provenanceCols`
            // (I1): unlike `strength_sets`/`route_points` (children whose parent's ONE provenance
            // covers every child row), different results within the SAME report can legitimately
            // have different `measured_at` instants (a glucose-tolerance panel draws at 0/60/120
            // minutes) and, after a LAB-16 amendment or a manual correction, a different
            // `ingestion_path`/`algorithm_version_id` than their siblings (an OCR-parsed value
            // corrected by hand is a DIFFERENT provenance story for that one result alone).
            // `analyte_id`/`custom_label` mirror the `journal_entries`/`strength_sets` "dictionary
            // key OR free text" split — exactly one is set — so an unrecognized marker is never
            // blocked (§7A.4 reject: no closed analyte dictionary). `numeric_value`/`raw_unit` are
            // the as-reported parse; `canonical_value`/`canonical_unit` are the ADDITIONAL
            // safe-class-only conversion (`UnitNormalization`) — two independent column pairs, so a
            // non-safe-class result can carry the first without the second ever being fabricated.
            // `original_id`/`supersedes`/`revision` are the same append-first revision chain
            // `hydration_entries`/`strength_sets` already established: a correction or a LAB-16
            // amendment APPENDS a new row, never UPDATEs a logged result.
            """
            CREATE TABLE lab_results (
              id TEXT PRIMARY KEY, report_id TEXT NOT NULL, panel_id TEXT, analyte_id TEXT,
              custom_label TEXT, raw_value_text TEXT NOT NULL, comparator TEXT, numeric_value REAL,
              raw_unit TEXT, canonical_value REAL, canonical_unit TEXT, result_type TEXT NOT NULL,
              review_state TEXT NOT NULL, sensitivity_tier TEXT NOT NULL, original_id TEXT NOT NULL,
              supersedes TEXT, revision INTEGER NOT NULL, \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_lab_results_report ON lab_results(report_id);",
            "CREATE INDEX idx_lab_results_panel ON lab_results(panel_id) WHERE panel_id IS NOT NULL;",
            // The marker-browser/trend read (LAB-04/LAB-12): one analyte's history across time,
            // mirroring `idx_journal_behavior_occurred`'s (dictionary-key, timestamp) shape exactly.
            "CREATE INDEX idx_lab_results_analyte_measured ON lab_results(analyte_id, measured_at);",
            "CREATE INDEX idx_lab_results_original ON lab_results(original_id);",
            "CREATE INDEX idx_lab_results_supersedes ON lab_results(supersedes) WHERE supersedes IS NOT NULL;",
            // `ReferenceRange`. Concepts 1+2 of the four-concept law ONLY (see migration-level
            // comment above) — one row per result, both fields left NULL exactly when the source
            // printed nothing (never backfilled from a generic table at write time or read time).
            // `source_interval_text` holds a printed interval that isn't a clean low/high pair
            // ("Negative", "<5", "Not established") so source wording is preserved even when it
            // can't be structured into two numbers.
            """
            CREATE TABLE reference_ranges (
              id TEXT PRIMARY KEY, result_id TEXT NOT NULL, source_interval_low REAL,
              source_interval_high REAL, source_interval_text TEXT, source_interval_unit TEXT,
              source_flag TEXT, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_reference_ranges_result ON reference_ranges(result_id);",
            // `UserCorrection`. An append-only overlay, never destructive — covers a field-level fix
            // on either a `LabReport` or a `LabResult` (`target_type` discriminates) for the cases
            // that don't warrant minting a whole new `LabResult` revision (e.g. a `LabReport`'s
            // `source_lab_name` was mistyped). NO update/delete path is ever defined against this
            // table in the repository (I2-flavored) — a correction, once recorded, is permanent
            // audit trail.
            """
            CREATE TABLE user_corrections (
              id TEXT PRIMARY KEY, target_type TEXT NOT NULL, target_id TEXT NOT NULL,
              field_name TEXT NOT NULL, previous_value_text TEXT, corrected_value_text TEXT NOT NULL,
              reason TEXT, corrected_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_user_corrections_target ON user_corrections(target_type, target_id, corrected_at DESC);",
            // `LabAnnotation`. A free-text note or clinician question tied to a report or result —
            // the visit-prep differentiator. `resolved` is a plain user-toggled flag
            // (asked-and-answered), never a diagnostic state.
            """
            CREATE TABLE lab_annotations (
              id TEXT PRIMARY KEY, target_type TEXT NOT NULL, target_id TEXT NOT NULL,
              kind TEXT NOT NULL, text TEXT NOT NULL, resolved INTEGER NOT NULL,
              created_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_lab_annotations_target ON lab_annotations(target_type, target_id);",
            // `DerivedTrend`. Concept 3 of the four-concept law, computed by `ReferenceRangeEngine`
            // and append-only (I2) exactly like `baselines`/the sensitive DB's own `derived_values`
            // (migration 4) — a recompute appends a fresh row at a new `computed_at`/`valid_from`
            // rather than overwriting the prior belief. `analyte_id` holds `LabResult.analyteKey`
            // (the dictionary id OR a normalized custom-label key), so an unrecognized marker still
            // accumulates a trend. NO unique natural-key index — mirrors migration 6's FIX to
            // `idx_baseline_lookup`, not the original `idx_baseline_identity` bug it replaced — a
            // plain lookup index only, so a plain INSERT can never collide and silently
            // delete-then-replace prior history.
            """
            CREATE TABLE derived_trends (
              id TEXT PRIMARY KEY, analyte_id TEXT NOT NULL, window_days INTEGER NOT NULL,
              method TEXT NOT NULL, center REAL NOT NULL, spread REAL NOT NULL, band_low REAL NOT NULL,
              band_high REAL NOT NULL, n_points INTEGER NOT NULL, provisional INTEGER NOT NULL,
              algorithm_version TEXT NOT NULL, unit TEXT NOT NULL, valid_from INTEGER NOT NULL,
              computed_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_derived_trends_lookup ON derived_trends(analyte_id, valid_from DESC);",
            // `SourceDocument` (LAB-02). The document-vault lane's metadata row for a vaulted
            // PDF/photo — the encrypted bytes themselves live on disk (`DocumentVault.swift`),
            // never in this database; this row is hash+metadata only. Schema reproduced verbatim
            // from `SourceDocumentRepository.swift`'s own header, which was written against this
            // exact DDL ahead of this migration landing (parallel-lane build, EPIC-41). The
            // partial-unique index on `sha256` backs the "same PDF imported twice" duplicate check
            // (LAB-02) without letting a soft-deleted document permanently squat on a hash a user
            // might legitimately re-import later — the same live-row-only-uniqueness pattern
            // `idx_export_templates_name`/`idx_reports_period_algorithm` already use.
            """
            CREATE TABLE source_documents (
              id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, mime_type TEXT NOT NULL,
              original_file_name TEXT, page_count INTEGER NOT NULL, ocr_status TEXT NOT NULL,
              vault_file_ref TEXT NOT NULL, sensitivity_tier TEXT NOT NULL, imported_at INTEGER NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_source_documents_imported ON source_documents(imported_at DESC);",
            "CREATE UNIQUE INDEX idx_source_documents_sha256 ON source_documents(sha256) WHERE deleted_at IS NULL;",
        ]),
        // Version 6 (plan §9.15 / EPIC-39 CYCLE-01, Phase 3F slice 1): the cycle-intelligence
        // module's full entity set (`CycleModels.swift`), superseding the placeholder
        // `cycle_contexts` table sensitive migration 3 introduced and deliberately left as a
        // to-be-superseded stub. Purely additive (CREATEs only) — `cycle_contexts` itself is left
        // untouched (forward-only; migrations never rewrite or drop a prior table), so an
        // upgrading v5 sensitive install reaches v6 without touching an existing row. A future
        // slice that actually migrates any `cycle_contexts` data into these tables is a separate,
        // explicit forward migration, not something bundled into this one.
        //
        // SENSITIVE, not main (I7) — the single highest-sensitivity data family this app handles,
        // per `docs/legal/reproductive-threat-model.md` §1: period dates, contraceptive use, and
        // anomaly flags can be used as evidence in a legal proceeding and are the most likely
        // real-world abusive-partner harm surface BADAN has. All six tables below MUST live only
        // here — never in `badan.db` — exactly like `journal_entries`/`lab_results` already do.
        // `CycleModelsTests.testCycleTablesExistOnlyInTheSensitiveDatabase` is the architecture
        // test that blocks a future accidental main-DB placement.
        //
        // TWO SHAPES, six tables, split exactly like migration 5 (Labs) splits `lab_results` from
        // `derived_trends` — and for the identical reason:
        //   * RAW/MEASURED (`cycle_records`, `flow_logs`, `contraceptive_context_logs`) carry the
        //     FULL `provenanceCols` (I1) + `conventionCols` (D-7): each is a user-asserted fact
        //     with an origin (`ingestion_path = manual` today; no platform cycle read exists yet).
        //   * DERIVED (`cycle_predictions`, `cycle_phase_estimates`, `cycle_anomaly_events`) carry
        //     `conventionCols` ONLY, no provenance — a forecast/estimate/anomaly is COMPUTED from
        //     already-provenanced rows above, not measured with its own source, mirroring
        //     `derived_trends`'/`derived_values`' own shape exactly. All three are APPEND-ONLY
        //     (I2): a recompute INSERTs a fresh row, nothing here is ever UPDATEd to change its
        //     computed content — the sole exception is `cycle_anomaly_events.state`, which
        //     transitions via a plain UPDATE through `CycleAnomalyEventRepository.updateState`
        //     (acknowledge/dismiss is a user lifecycle action, not a re-derivation), the same
        //     "detection facts frozen, only lifecycle state transitions" shape
        //     `data_conflicts`/`DataConflictRepository.markResolved` already establish.
        //
        // NO SINGLE-DATE PREDICTION COLUMN EXISTS, structurally, not by convention:
        // `cycle_predictions` has `predicted_next_start_low/center/high` (a range) plus `method`
        // and `confidence` — there is no column that could hold one bare "predicted date". This is
        // both this codebase's standing false-precision rule and, per the threat model §5, a
        // safety property: a falsely-confident single date is a worse harm surface than an honest
        // range, including for anyone who might see the screen over the user's shoulder.
        //
        // `cycle_anomaly_events.message_key` is a KEY into a bilingual message-template lookup a
        // separate lane owns — this table has NO column that could hold rendered/diagnostic text,
        // which is what makes "no diagnostic language" a schema-level guarantee here rather than a
        // discipline every future writer has to remember. `severity` is a surfacing priority only,
        // never a clinical-importance claim (research doc §10) — repeated here because a schema
        // is the one place this invariant is cheapest to enforce permanently.
        //
        // OUT OF SCOPE, stated plainly so a future reader doesn't assume otherwise: no table here
        // backs fertile-window/ovulation estimation (gated on founder decision A17), BBT/ovulation-
        // test/cervical-mucus logging, sexual-activity logging, or sharing of any kind — see
        // `CycleModels.swift`'s own header for the full out-of-scope list this migration honors.
        Migration(version: 6, statements: [
            // `CycleRecord`. `original_id`/`supersedes`/`revision` are the same append-first
            // revision chain `lab_results`/`strength_sets` already establish: a correction (a
            // mis-entered start date) APPENDS a new row, never UPDATEs a logged period.
            """
            CREATE TABLE cycle_records (
              id TEXT PRIMARY KEY, start_at INTEGER NOT NULL, end_at INTEGER, ongoing INTEGER NOT NULL,
              note TEXT, original_id TEXT NOT NULL, supersedes TEXT, revision INTEGER NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_records_start ON cycle_records(start_at DESC);",
            // Backs `CycleRecordRepository.history(originalId:)` — the whole audit chain of one
            // logical period, mirroring `idx_lab_results_original` exactly.
            "CREATE INDEX idx_cycle_records_original ON cycle_records(original_id);",
            // Backs the live-view anti-join subquery ("which rows are superseded by a non-deleted
            // revision"), mirroring `idx_lab_results_supersedes` exactly. Partial, because only
            // revisions carry a non-NULL `supersedes`.
            "CREATE INDEX idx_cycle_records_supersedes ON cycle_records(supersedes) WHERE supersedes IS NOT NULL;",
            // `FlowLog`. No revision chain (unlike `cycle_records`) — a flow-intensity correction
            // is expected to be a plain tombstone-and-relog; see the type's own doc for why.
            """
            CREATE TABLE flow_logs (
              id TEXT PRIMARY KEY, cycle_id TEXT NOT NULL, occurred_at INTEGER NOT NULL,
              original_label TEXT NOT NULL, normalized_intensity REAL NOT NULL, note TEXT,
              \(provenanceCols), \(conventionCols)
            );
            """,
            // The one real read shape: one period's own flow history, in order.
            "CREATE INDEX idx_flow_logs_cycle_occurred ON flow_logs(cycle_id, occurred_at);",
            // `ContraceptiveContextLog`. `end_at IS NULL` is the normal "still active" case, not a
            // malformed edge case — same posture `context_statuses.end_at` already takes.
            """
            CREATE TABLE contraceptive_context_logs (
              id TEXT PRIMARY KEY, method_type TEXT NOT NULL, start_at INTEGER NOT NULL,
              end_at INTEGER, adherence_note TEXT, \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_contraceptive_context_start ON contraceptive_context_logs(start_at DESC);",
            // `CyclePrediction`. Append-only (I2); no unique natural-key index, mirroring migration
            // 6 (main db)'s FIX to `idx_baseline_lookup` — a plain lookup index only, so a plain
            // INSERT can never collide and silently delete-then-replace prior forecast history.
            // `input_cycle_ids` is a JSON array (not a join table), the same reason
            // `data_conflicts.candidate_record_ids` is JSON: the input set is fixed at generation
            // time and never independently queried by a third table.
            """
            CREATE TABLE cycle_predictions (
              id TEXT PRIMARY KEY, generated_at INTEGER NOT NULL, predicted_next_start_low INTEGER,
              predicted_next_start_center INTEGER, predicted_next_start_high INTEGER,
              confidence REAL NOT NULL, method TEXT NOT NULL, status TEXT NOT NULL,
              suppression_reason TEXT, algorithm_version TEXT NOT NULL, input_cycle_ids TEXT NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_predictions_generated ON cycle_predictions(generated_at DESC);",
            // `CyclePhaseEstimate`. Append-only (I2), one row per computed window — the input
            // `BaselineEngine`'s phase-conditioned baselines read as a covariate.
            """
            CREATE TABLE cycle_phase_estimates (
              id TEXT PRIMARY KEY, date_range_start INTEGER NOT NULL, date_range_end INTEGER NOT NULL,
              phase TEXT NOT NULL, confidence REAL NOT NULL, evidence_basis TEXT NOT NULL,
              algorithm_version TEXT NOT NULL, computed_at INTEGER NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_phase_estimates_start ON cycle_phase_estimates(date_range_start DESC);",
            // `CycleAnomalyEvent`. Append-only at creation (I2); `state` is the one column this
            // migration expects to be UPDATEd in place (acknowledge/dismiss/suppress), mirroring
            // `data_conflicts.status`'s exact shape. `message_key` is a KEY only — see the
            // migration-level comment above for why this table has no rendered-text column at all.
            """
            CREATE TABLE cycle_anomaly_events (
              id TEXT PRIMARY KEY, type TEXT NOT NULL, detected_at INTEGER NOT NULL,
              basis_window_cycle_ids TEXT NOT NULL, severity TEXT NOT NULL, message_key TEXT NOT NULL,
              state TEXT NOT NULL, algorithm_version TEXT NOT NULL, confidence REAL NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_anomaly_events_detected ON cycle_anomaly_events(detected_at DESC);",
            // `baselines` — CYCLE-06's phase-conditioned bands ONLY (audit fix, I7). Byte-identical
            // DDL/index to `mainMigrations` version 1's `baselines` table (see that migration for
            // the canonical shape) — deliberately duplicated here rather than shared, because a
            // `covariate_context` value here is a real reproductive-phase word ("menstrual"/
            // "follicular"/"ovulatory"/"luteal"), which is itself cycle-derived, sensitive-plus
            // information (the same "the identifier itself is the disclosure" reasoning
            // `CorrelationRepository`'s own header documents for `journal.correlation.*` ids). This
            // table exists SOLELY so `CyclePhaseCovariateCoordinator` can construct a
            // sensitive-backed `DerivationRepository`/`BaselineEngine` pair for phase-conditioned
            // recomputes — the unconditioned `"default"` baseline for every metric, cycle-aware or
            // not, continues to live only in `badan.db`'s own `baselines` table, untouched by this
            // one. `Database.purgeSensitiveNamespace()` needs no extension: deleting the whole
            // `badan_sensitive.db` file covers this table by construction, like every other one here.
            """
            CREATE TABLE baselines (
              id TEXT PRIMARY KEY, metric_id TEXT NOT NULL, covariate_context TEXT NOT NULL,
              window_days INTEGER NOT NULL, method TEXT NOT NULL, center REAL NOT NULL,
              spread REAL NOT NULL, band_low REAL NOT NULL, band_high REAL NOT NULL,
              n_points INTEGER NOT NULL, provisional INTEGER NOT NULL, algorithm_version TEXT NOT NULL,
              valid_from INTEGER NOT NULL, computed_at INTEGER NOT NULL, unit TEXT NOT NULL
            );
            """,
            "CREATE INDEX idx_baseline_lookup ON baselines(metric_id, covariate_context, valid_from DESC);",
        ]),
        // Version 7 (EPIC-39 CYCLE-12, A17/ADR-0010/D-24): fertile-window estimation. Purely
        // additive (one CREATE + one index), same forward-only posture every migration in this file
        // follows — nothing from migration 6 is touched.
        //
        // SENSITIVE (I7), same reasoning as every other table this migration file's version-6 header
        // already gives at length: a fertile-window estimate is, per
        // `docs/legal/reproductive-threat-model.md` §1's own asset inventory, in the SAME
        // highest-sensitivity family as period dates and contraceptive-context — arguably a more
        // acute disclosure risk, since it bears more directly on conception timing.
        //
        // DERIVED shape (`conventionCols` only, no provenance) — a fertile-window estimate is
        // COMPUTED from already-provenanced `cycle_records` rows, mirroring `cycle_predictions`/
        // `cycle_phase_estimates` exactly, not measured with its own source. APPEND-ONLY (I2): a
        // recompute INSERTs a fresh row, nothing here is ever UPDATEd.
        //
        // NO SINGLE-DATE COLUMN, structurally: `window_start`/`window_end` are the only date-bearing
        // columns, both nullable and populated ONLY together (see
        // `CycleFertileWindowEstimate`'s own header) — there is no column that could hold one bare
        // estimated date, the same guarantee `cycle_predictions` already established for the
        // next-period forecast, applied here to the fertile window instead.
        Migration(version: 7, statements: [
            """
            CREATE TABLE cycle_fertile_window_estimates (
              id TEXT PRIMARY KEY, generated_at INTEGER NOT NULL, window_start INTEGER, window_end INTEGER,
              confidence REAL NOT NULL, mode TEXT NOT NULL, evidence_basis TEXT NOT NULL,
              status TEXT NOT NULL, suppression_reason TEXT, algorithm_version TEXT NOT NULL,
              input_cycle_ids TEXT NOT NULL, \(conventionCols)
            );
            """,
            "CREATE INDEX idx_cycle_fertile_window_estimates_generated ON cycle_fertile_window_estimates(generated_at DESC);",
        ]),
        // Version 8 (A18/ADR-0010/D-25, EPIC-40 PREG-01/02/04/05, P0 slice): the pregnancy module's
        // entity set. Purely additive (CREATEs only) — nothing from any prior migration is touched,
        // so an upgrading v7 sensitive install reaches v8 without touching an existing row.
        //
        // SENSITIVE, not main (I7) — pregnancy data inherits every reason `cycle_records` et al. are
        // sensitive-plus (migration 6's own header), plus its own sharper edge documented in
        // `Domain/Pregnancy/PregnancyModels.swift`'s file header: a loss-suppression failure here is
        // a re-traumatizing harm, not an inconvenience. All four tables below MUST live only here —
        // never in `badan.db`. `PregnancyModelsTests.testPregnancyTablesExistOnlyInTheSensitiveDatabase`
        // is the architecture test that blocks a future accidental main-DB placement.
        //
        // TWO SHAPES, four tables, the identical RAW/DERIVED split migration 6's own header
        // documents for the cycle module:
        //   * RAW/MEASURED (`pregnancy_records`, `due_date_source_entries`, `loss_declaration_records`)
        //     carry the FULL `provenanceCols` (I1) + `conventionCols` (D-7): each is a user-asserted
        //     fact with an origin (`ingestion_path = manual` always — no platform pregnancy-state
        //     read exists; PREG-09/HealthKit `Pregnancy` category is deferred and would be
        //     write-only even once built).
        //   * DERIVED (`due_date_estimates`) carries `conventionCols` ONLY, no provenance — a due-date
        //     estimate is COMPUTED from already-provenanced `due_date_source_entries` rows, mirroring
        //     `cycle_predictions`'/`cycle_fertile_window_estimates`' own shape exactly.
        //
        // APPEND-ONLY (I2) is load-bearing for THIS module specifically, per the founder's own
        // non-negotiable requirement: "a loss declaration or any other state change is a new row,
        // never a mutation/deletion of prior history."
        //   * `pregnancy_records` is an append-first REVISION CHAIN (`original_id`/`supersedes`/
        //     `revision`), byte-identical in shape to `cycle_records` — a mode transition (including
        //     a loss declaration) APPENDS a new revision, never UPDATEs `mode` in place. This is what
        //     makes the whole journey's mode history — TTC, confirmed, loss, whatever came before —
        //     permanently reconstructable via `history(originalId:)`, exactly like a corrected period.
        //   * `due_date_source_entries` is append-only per `(pregnancy_record_original_id,
        //     source_type)` — a correction inserts a fresh row for the same pair rather than
        //     UPDATEing a prior one; see that type's own doc for why a full revision chain isn't
        //     needed here (no branching "supersede a specific revision" case exists).
        //   * `due_date_estimates` is append-only (I2), identical reasoning to `cycle_predictions`.
        //   * `loss_declaration_records` is append-only AT CREATION — a loss is declared once; the
        //     ONE column this migration expects to be UPDATEd in place is `data_disposition`
        //     (research doc §9: "revisitable later, not a one-time forced decision"), mirroring
        //     `cycle_anomaly_events.state`'s exact "detection fact frozen, one lifecycle field
        //     transitions" shape. It is also INDEPENDENTLY DELETABLE via its own `deleted_at`
        //     tombstone, separate from deleting the `pregnancy_records` chain it references.
        //
        // NO SINGLE-DATE ESTIMATE COLUMN EXISTS, structurally: `due_date_estimates` has
        // `range_low/center/high` (a range) plus `resolved_source_type`, `confidence` and
        // `algorithm_version` — there is no column that could hold one bare "due on X" date, the
        // identical guarantee `cycle_predictions` already established, applied here to due dates.
        Migration(version: 8, statements: [
            // `PregnancyRecord`. `original_id`/`supersedes`/`revision` mirror `cycle_records` exactly
            // — see this migration's own header.
            """
            CREATE TABLE pregnancy_records (
              id TEXT PRIMARY KEY, mode TEXT NOT NULL, multiples_flag INTEGER NOT NULL,
              fertility_treatment_context INTEGER NOT NULL, original_id TEXT NOT NULL,
              supersedes TEXT, revision INTEGER NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            // Backs `PregnancyRecordRepository.history(originalId:)` — the whole audit chain of one
            // logical journey, mirroring `idx_cycle_records_original` exactly.
            "CREATE INDEX idx_pregnancy_records_original ON pregnancy_records(original_id);",
            // Backs the live-view anti-join subquery, mirroring `idx_cycle_records_supersedes`
            // exactly. Partial, because only revisions carry a non-NULL `supersedes`.
            "CREATE INDEX idx_pregnancy_records_supersedes ON pregnancy_records(supersedes) WHERE supersedes IS NOT NULL;",
            // `DueDateSourceEntry`. No revision chain (see this migration's own header) — the live
            // read is "most recently recorded live row per (pregnancy_record_original_id,
            // source_type) pair", backed by this composite index.
            """
            CREATE TABLE due_date_source_entries (
              id TEXT PRIMARY KEY, pregnancy_record_original_id TEXT NOT NULL, source_type TEXT NOT NULL,
              entered_date INTEGER NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_due_date_source_entries_lookup ON due_date_source_entries(pregnancy_record_original_id, source_type, updated_at DESC);",
            // `DueDateEstimate`. Append-only (I2); no unique natural-key index, mirroring
            // `idx_cycle_predictions_generated`'s own fix — a plain lookup index only, so a plain
            // INSERT can never collide and silently delete-then-replace prior estimate history.
            """
            CREATE TABLE due_date_estimates (
              id TEXT PRIMARY KEY, pregnancy_record_original_id TEXT NOT NULL, generated_at INTEGER NOT NULL,
              range_low INTEGER, range_center INTEGER, range_high INTEGER, resolved_source_type TEXT,
              confidence REAL NOT NULL, algorithm_version TEXT NOT NULL, input_source_entry_ids TEXT NOT NULL,
              \(conventionCols)
            );
            """,
            "CREATE INDEX idx_due_date_estimates_lookup ON due_date_estimates(pregnancy_record_original_id, generated_at DESC);",
            // `LossDeclarationRecord`. Minimal fields (research doc §9 line 126) — no required
            // "cause"/explanation column exists, structurally, not just by UI convention. Highest
            // privacy tier of the four tables in this migration (research doc §12).
            """
            CREATE TABLE loss_declaration_records (
              id TEXT PRIMARY KEY, pregnancy_record_original_id TEXT NOT NULL, declared_at INTEGER NOT NULL,
              approximate_date INTEGER NOT NULL, gestational_stage TEXT, free_text_note TEXT,
              data_disposition TEXT NOT NULL, fertility_treatment_context INTEGER NOT NULL,
              \(provenanceCols), \(conventionCols)
            );
            """,
            "CREATE INDEX idx_loss_declaration_records_pregnancy ON loss_declaration_records(pregnancy_record_original_id);",
        ]),
        // Version 9 (A21/D-26 scope-gap closure): the measurement-chain tables, mirrored into the
        // sensitive namespace so `sensitiveClass: sensitivePlus` metrics ingested through
        // `IngestionPipeline` land HERE instead of `badan.db`. Today that is exactly one metric —
        // `body.glucose` — but the rule `MeasurementRouting` applies is the registry's own
        // `sensitiveClass`, not a glucose special case, so any future sensitive-plus measured
        // metric inherits this placement without another migration.
        //
        // WHY THIS EXISTS AT ALL: D-26 shipped glucose ingestion into `badan.db` because
        // `IngestionPipeline` had no per-metric routing seam. An independent audit found that was
        // never a founder decision — D-23/A16's own text names glucose as one of the datasets whose
        // arrival justified adopting SQLCipher, so main-DB placement contradicted the approval it
        // claimed to rest on. Two concrete consequences it left open, both closed by this migration
        // plus `MeasurementRouting`: glucose was not SQLCipher-encrypted at rest (unlike every other
        // sensitive-plus metric post-D-23), and it was NOT covered by `purgeSensitiveNamespace()` —
        // a user who turned off "Sensitive records" to erase their sensitive health data silently
        // kept their entire glucose history on the device.
        //
        // The DDL and indexes below are byte-identical to `mainMigrations` version 1's
        // `raw_samples`/`interval_records` (plus version 2's two `_live` partial indexes), following
        // the SAME deliberate-duplication precedent this file's sensitive `baselines` table
        // established for CYCLE-06 — one shared reader (`MeasurementRepository.readRawSample` etc.)
        // over two structurally identical tables in two physically separate files, rather than one
        // table whose rows carry a sensitivity flag that some future query forgets to filter on.
        //
        // `Database.purgeSensitiveNamespace()` needs no extension: it deletes the whole
        // `badan_sensitive.db` file, so these two tables are covered by construction — which is
        // precisely the property glucose lacked before.
        Migration(version: 9, statements: [
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
            "CREATE INDEX idx_raw_metric_measured_live ON raw_samples(metric_id, measured_at) WHERE deleted_at IS NULL AND suppressed_by IS NULL;",
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
            "CREATE INDEX idx_interval_metric_span_live ON interval_records(metric_id, start_at, end_at) WHERE deleted_at IS NULL AND suppressed_by IS NULL;",
        ])]
    }
}
