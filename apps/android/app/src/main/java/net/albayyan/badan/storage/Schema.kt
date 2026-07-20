package net.albayyan.badan.storage

/**
 * Forward-only, numbered migrations (D-policy: no down-migrations, ever). Migration 001 is
 * the §4 schema adapted to MVP scope. Every row table carries the sync-ready convention
 * columns (`updated_at`, `origin_device_id`, `deleted_at`) from day one (D-7), and every
 * health datum carries embedded provenance columns (D-3, I1).
 *
 * Mirror of iOS `Schema` (Storage/Migrations.swift). The `Migration(version, statements)`
 * data class lives in Database.kt.
 */
object Schema {
    // Provenance columns shared by measurement tables (embedded, never a join).
    private val provenanceCols = """
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

    private val conventionCols = """
        updated_at INTEGER NOT NULL,
        origin_device_id TEXT NOT NULL,
        deleted_at INTEGER
    """

    // MARK: - Main DB (badan.db)

    val mainMigrations: List<Migration>
        get() = listOf(
            Migration(
                version = 1,
                statements = listOf(
                    """
                    CREATE TABLE sources (
                      id TEXT PRIMARY KEY, type TEXT NOT NULL, display_name TEXT NOT NULL,
                      platform_bundle_id TEXT, status TEXT NOT NULL, connected_at INTEGER,
                      last_delivery_at INTEGER, $conventionCols
                    );
                    """,
                    """
                    CREATE TABLE source_devices (
                      id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL, model TEXT,
                      first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, $conventionCols
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
                      $provenanceCols, $conventionCols
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
                      $provenanceCols, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_interval_metric_span ON interval_records(metric_id, start_at, end_at);",
                    "CREATE UNIQUE INDEX idx_interval_identity ON interval_records(metric_id, external_id, source_id) WHERE external_id IS NOT NULL;",
                    """
                    CREATE TABLE sessions (
                      id TEXT PRIMARY KEY, kind TEXT NOT NULL, subtype TEXT,
                      start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, tz_id TEXT NOT NULL,
                      local_night TEXT, detail TEXT NOT NULL,
                      $provenanceCols, $conventionCols
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
                      computed_at INTEGER NOT NULL, $conventionCols
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
                      $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_workout_start ON workout_entries(start_at);",
                    """
                    CREATE TABLE nutrition_entries (
                      id TEXT PRIMARY KEY, description TEXT NOT NULL, meal_type TEXT NOT NULL,
                      energy_kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
                      water_ml REAL, caffeine_mg REAL, low_detail INTEGER NOT NULL,
                      occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, note TEXT, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_nutrition_occurred ON nutrition_entries(occurred_at);",
                    """
                    CREATE TABLE note_entries (
                      id TEXT PRIMARY KEY, text TEXT NOT NULL, occurred_at INTEGER NOT NULL,
                      tz_id TEXT NOT NULL, tags TEXT NOT NULL, $conventionCols
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
                    // Reserved, unused in MVP (sync-ready / import-ready scaffolding).
                    "CREATE TABLE read_anchors (store TEXT NOT NULL, platform_type TEXT NOT NULL, anchor BLOB, updated_at INTEGER NOT NULL, PRIMARY KEY (store, platform_type));",
                    "CREATE TABLE import_batches (id TEXT PRIMARY KEY, source_kind TEXT NOT NULL, file_name TEXT, state TEXT NOT NULL, chunk_cursor TEXT, counts TEXT, created_at INTEGER NOT NULL);",
                    "CREATE TABLE sync_cursors (scope_key TEXT NOT NULL, device_id TEXT NOT NULL, lamport INTEGER NOT NULL, last_synced_at INTEGER, PRIMARY KEY (scope_key, device_id));",
                )
            ),
            // Additive indexes for query shapes identified after the initial schema shipped —
            // no table changes, so this is a cheap, low-risk forward-only migration.
            Migration(
                version = 2,
                statements = listOf(
                    // devices(sourceId) is filtered every Sources-screen load and on every
                    // ingest's upsertSourcesAndDevices call; previously an unindexed scan.
                    "CREATE INDEX idx_source_devices_source ON source_devices(source_id);",
                    // Matches latestBaseline()'s actual query shape (metric_id, covariate_context,
                    // ORDER BY valid_from DESC) rather than the 4-column identity index, which
                    // also groups by window_days and isn't an ideal covering order for this read.
                    "CREATE INDEX idx_baseline_lookup ON baselines(metric_id, covariate_context, valid_from DESC);",
                    // ExportJobRepository.recent() sorts by created_at on every Export screen load.
                    "CREATE INDEX idx_export_jobs_created ON export_jobs(created_at DESC);",
                )
            ),
            // Version 4 (plan §9): the route + export/automation entity set. Purely additive — no
            // existing table, index or row is touched, so an upgrading install reaches v4 by
            // running CREATEs only and cannot lose data.
            //
            // Byte-equivalent mirror of iOS `Schema.mainMigrations` version 4: same table names,
            // same column names, same column ORDER, same indexes. Cross-platform export fixtures
            // diff the two schemas, so a "harmless" reordering here is a test failure there.
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
            Migration(
                version = 4,
                statements = listOf(
                    // §9.2. `consent_snapshot` records the route-consent state as it stood at
                    // ingest, not as it stands now: routes are location data under their own
                    // toggle (§4.11), and a later toggle-off must not retroactively relabel rows
                    // that were captured while consent was genuinely granted. Export gating reads
                    // the *current* toggle; this column exists so "was this row allowed to exist
                    // when it was written" stays answerable after the fact, which is the same
                    // question I1 answers for sources.
                    """
                    CREATE TABLE workout_routes (
                      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, point_count INTEGER NOT NULL,
                      start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, consent_snapshot TEXT NOT NULL,
                      $provenanceCols, $conventionCols
                    );
                    """,
                    // §9.2. Deliberately NO per-point provenance and NO convention columns — the
                    // same shape decision `session_stages` already makes, for the same reasons,
                    // and it is load-bearing in both directions:
                    //   * Provenance would be pure duplication. Every point in a route came from
                    //     the one device, one ingestion path and one batch that produced its
                    //     parent `workout_routes` row; stamping 12 provenance columns onto each of
                    //     ~3,000 points in a single 30-minute run multiplies the table's size
                    //     several-fold to store the same answer the parent already gives. I1 is
                    //     satisfied by the route: "where did this point come from" resolves
                    //     through `route_id` in one join, never through a separate audit trail
                    //     that could drift.
                    //   * Convention columns would be actively wrong. A point has no independent
                    //     lifecycle — you do not soft-delete or sync one GPS fix out of a trace.
                    //     Routes are replaced wholesale (delete by `route_id`, bulk re-insert), so
                    //     a per-point `deleted_at` would create a state — half a route — that no
                    //     reader knows how to interpret.
                    // If someone later "normalizes" this by adding provenance here, the bulk-insert
                    // path gets several times slower and the route stops being the unit of consent.
                    """
                    CREATE TABLE route_points (
                      route_id TEXT NOT NULL, seq INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
                      altitude_m REAL, hacc_m REAL, timestamp INTEGER NOT NULL,
                      PRIMARY KEY (route_id, seq)
                    );
                    """,
                    // The (route_id, seq) PK already covers ordered point reads; this covers the
                    // other direction — finding a workout's routes from the session it belongs to.
                    "CREATE INDEX idx_workout_routes_session ON workout_routes(session_id);",
                    // §9.3. `scope` holds the existing `ExportScope` JSON verbatim rather than
                    // being shredded into columns, so a template keeps working unchanged when
                    // `ExportScope` gains a field — the same reason `sessions.detail` is JSON.
                    // `aggregation_method` is nullable because it is only meaningful when
                    // `aggregation` is not `raw`; a raw export has nothing to aggregate *by*.
                    """
                    CREATE TABLE export_templates (
                      id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL, range_rule TEXT NOT NULL,
                      format TEXT NOT NULL, aggregation TEXT NOT NULL, aggregation_method TEXT,
                      layout TEXT NOT NULL, include_schema_docs INTEGER NOT NULL, destination_id TEXT,
                      created_at INTEGER NOT NULL, $conventionCols
                    );
                    """,
                    // §9.3 specifies unique(name); the partial predicate is the part that isn't
                    // obvious. `export_templates` carries `deleted_at`, so a plain UNIQUE(name)
                    // would let a soft-deleted template permanently squat on its own name — the
                    // user deletes "Weekly to Dropbox", tries to recreate it, and gets a
                    // constraint failure over a row they cannot see. Scoping uniqueness to live
                    // rows makes the index enforce what the user actually experiences. Any
                    // `ON CONFLICT(name)` written against this table must repeat the
                    // `WHERE deleted_at IS NULL` predicate verbatim — SQLite requires an
                    // ON CONFLICT target to match a real unique index including its predicate.
                    "CREATE UNIQUE INDEX idx_export_templates_name ON export_templates(name) WHERE deleted_at IS NULL;",
                    // §9.4. `credential_ref` is a Keystore key — never a secret. The column is
                    // named `_ref` rather than `token`/`secret` so that a future reviewer grepping
                    // this schema for credential leakage gets an answer from the column name
                    // alone, and so that anyone tempted to stash a bearer token here has to first
                    // rename the column. `config` holds the non-secret half (folder ref, URL,
                    // header template ids).
                    """
                    CREATE TABLE export_destinations (
                      id TEXT PRIMARY KEY, kind TEXT NOT NULL, display_name TEXT NOT NULL, config TEXT NOT NULL,
                      credential_ref TEXT, tls_policy TEXT NOT NULL, created_at INTEGER NOT NULL,
                      last_verified_at INTEGER, status TEXT NOT NULL, $conventionCols
                    );
                    """,
                    // §9.5, the trust ledger. NO convention columns, and that is the whole design:
                    //   * `deleted_at` would defeat the table. A ledger whose rows can be
                    //     soft-deleted cannot answer "did my Tuesday export actually run", which
                    //     is the only question it exists to answer. Rows are append-only (I2's
                    //     spirit) and leave only via the pruning job.
                    //   * `updated_at`/`origin_device_id` describe cross-device reconciliation,
                    //     which does not apply: a run is an event that happened on THIS device.
                    //     Merging another device's run log into this one would produce a history
                    //     the user never observed here. The rows ride along in a full backup as a
                    //     record, not as sync state.
                    // `error_detail` is sanitized, value-free text by contract — a failed export
                    // must never smuggle a health value into a log line.
                    //
                    // Column named `trigger_kind`, not §9.5's `trigger`: TRIGGER is a SQL reserved
                    // word. SQLite happens to accept it bare as a column name, but it is a keyword
                    // every other engine and most schema tooling will reject or demand quoting
                    // for, and a column that only works because one parser is lenient is a trap
                    // for whoever ports this next. The `_kind` suffix also matches how this schema
                    // already names discriminators (`sessions.kind`, `export_destinations.kind`,
                    // `background_runs.kind`). The domain field is still `trigger`; only the
                    // storage identifier differs.
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
                    // §9.6. `high_watermark` tracks max `ingested_at`, NOT `measured_at` — the
                    // plan is explicit and the distinction is the difference between a correct
                    // delta export and a silently lossy one. A watch that syncs Saturday's workout
                    // on Monday writes a row whose `measured_at` is already behind a Sunday
                    // watermark; only `ingested_at` (stamped when BADAN wrote the row) is
                    // monotonic with respect to what this device has actually had available to
                    // export.
                    //
                    // `destination_id` is NOT NULL despite §9.3 making a *template's* destination
                    // optional, because those are different things: a template need not pin a
                    // destination, but a run always resolves to one — `shareSheet` is itself a
                    // destination kind (§9.4), not the absence of a destination. It matters
                    // mechanically too: SQLite permits NULL in a non-INTEGER PRIMARY KEY column
                    // and NULLs never compare equal, so a nullable destination here would let one
                    // template accumulate unlimited duplicate "no destination" cursor rows, each
                    // with its own watermark, and `sinceLastRun` would start re-exporting or
                    // skipping ranges depending on which row it happened to read.
                    //
                    // No convention columns: `updated_at` is declared explicitly per §9.6, while
                    // `deleted_at` is meaningless (a checkpoint is deleted by deleting the row —
                    // resurrecting a soft-deleted watermark would resume from a stale position)
                    // and `origin_device_id` is redundant since a cursor describes only this
                    // device's export progress.
                    """
                    CREATE TABLE export_cursors (
                      template_id TEXT NOT NULL, destination_id TEXT NOT NULL, high_watermark INTEGER NOT NULL,
                      last_manifest_sha TEXT, last_run_id TEXT, updated_at INTEGER NOT NULL,
                      PRIMARY KEY (template_id, destination_id)
                    );
                    """,
                    // §9.7. `tier` is stored, never inferred, because it is a *promise to the
                    // user* and §4.10 requires that promise be labeled honestly at every surface:
                    // an `opportunisticBackground` schedule says "best-effort", a `shortcutDriven`
                    // one says "device must be unlocked". `next_expected_window` is a display-only
                    // estimate — it is never read back as a due-time to fire on, or the honest
                    // tier label would be quietly contradicted by a scheduler behaving as if it
                    // had a wall clock.
                    """
                    CREATE TABLE automation_schedules (
                      id TEXT PRIMARY KEY, template_id TEXT NOT NULL, tier TEXT NOT NULL,
                      desired_cadence TEXT NOT NULL, quiet_hours TEXT, enabled INTEGER NOT NULL,
                      consecutive_failures INTEGER NOT NULL, last_success_at INTEGER,
                      next_expected_window INTEGER, created_at INTEGER NOT NULL, $conventionCols
                    );
                    """,
                    // Matches the scheduler's only real query shape: "which enabled schedules of
                    // this tier are due to be considered on this kind of wakeup".
                    "CREATE INDEX idx_automation_enabled_tier ON automation_schedules(enabled, tier);",
                    // §9.8. Substrate-level log, wider than `export_runs`: it also covers ingest
                    // wakeups, so a user asking "why is my data stale" can be answered from wakeup
                    // history rather than guesswork. Same no-convention-columns rationale as
                    // `export_runs` (append-only, device-local, pruned at 90 days).
                    // `work_done` holds COUNTS ONLY, never values — "42 samples" is diagnostics,
                    // "42 bpm" is a health value in a log, which this codebase does not do
                    // anywhere.
                    // `completion_handler_called_in_ms` is iOS-specific but present here too so
                    // the two platforms' schemas stay byte-identical and a cross-platform fixture
                    // can diff them; Android writes NULL. On iOS it guards the BGTaskScheduler
                    // budget (three missed expiration handlers and the OS revokes background
                    // refresh); WorkManager has no equivalent cliff, so there is nothing for
                    // Android to record — but dropping the column would fork the schema.
                    """
                    CREATE TABLE background_runs (
                      id TEXT PRIMARY KEY, kind TEXT NOT NULL, started_at INTEGER NOT NULL, duration_ms INTEGER,
                      outcome TEXT NOT NULL, work_done TEXT, completion_handler_called_in_ms INTEGER
                    );
                    """,
                    "CREATE INDEX idx_background_runs_started ON background_runs(started_at DESC);",
                )
            ),
        )

    // MARK: - Sensitive DB (badan_sensitive.db)

    val sensitiveMigrations: List<Migration>
        get() = listOf(
            Migration(
                version = 1,
                statements = listOf(
                    """
                    CREATE TABLE medication_regimens (
                      id TEXT PRIMARY KEY, name TEXT NOT NULL, strength TEXT, form TEXT,
                      schedule TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER, notes TEXT,
                      $conventionCols
                    );
                    """,
                    """
                    CREATE TABLE adherence_events (
                      id TEXT PRIMARY KEY, regimen_id TEXT NOT NULL, kind TEXT NOT NULL, scheduled_for INTEGER,
                      occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, skip_reason TEXT, skip_note TEXT,
                      $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_adherence_regimen ON adherence_events(regimen_id, occurred_at);",
                    "CREATE INDEX idx_adherence_occurred ON adherence_events(occurred_at);",
                    """
                    CREATE TABLE symptom_entries (
                      id TEXT PRIMARY KEY, symptom_id TEXT, custom_label TEXT, severity INTEGER NOT NULL,
                      occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, duration_s REAL, body_location TEXT,
                      triggers TEXT NOT NULL, note TEXT, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_symptom_occurred ON symptom_entries(occurred_at);",
                    """
                    CREATE TABLE conditions (
                      id TEXT PRIMARY KEY, label TEXT NOT NULL, status TEXT NOT NULL, onset_at INTEGER,
                      linked_regimen_ids TEXT NOT NULL, linked_symptom_ids TEXT NOT NULL, notes TEXT,
                      $conventionCols
                    );
                    """,
                )
            ),
            // Version 3 (plan §9.9–§9.11): journal / context / cycle. Byte-equivalent mirror of
            // iOS `Schema.sensitiveMigrations` version 3.
            //
            // These live in the SENSITIVE database rather than the main one, and the placement is
            // the point — I7 makes "turn this off" a literal file deletion
            // (`Database.purgeSensitiveNamespace`) instead of a row-by-row purge that has to be
            // trusted. Putting any of these three in `badan.db` would silently downgrade that
            // guarantee to best-effort.
            //
            // Each is sensitive-plus for a distinct reason, and they gate INDEPENDENTLY (§4.11) —
            // there is no single "sensitive" switch that covers all three:
            //   * `journal_entries` — behavior tags (alcohol, late meal, supplements) are
            //     lifestyle-revealing in a way a step count is not.
            //   * `context_statuses` — travel/illness/injury intervals disclose circumstance.
            //   * `cycle_contexts` — double-gated: its own consent toggle AND the general
            //     sensitive toggle, with a cycle-specific export opt-in on top. It is never
            //     included by the general sensitive toggle alone.
            // Consent is enforced at the repository/export layer; the schema's job is to make the
            // separation structural. All three carry full embedded provenance (I1): a manually
            // asserted fact is still a fact with an origin, and `ingestion_path=manual` is what
            // distinguishes "the user told us" from "a device measured it" at read time.
            Migration(
                version = 3,
                statements = listOf(
                    // §9.9. `behavior_id` (dictionary key) and `custom_label` are both nullable
                    // because exactly one is set per row: a curated bilingual dictionary entry, or
                    // the user's own words. Storing the dictionary KEY rather than its rendered
                    // label is what keeps Arabic/RTL a first-order concern — the row stays
                    // language-neutral and renders in whichever locale reads it, so a journal
                    // written in Arabic exports readably in English and vice versa. `value`/`unit`
                    // are nullable because `value_kind=boolean` ("did it happen") has neither.
                    """
                    CREATE TABLE journal_entries (
                      id TEXT PRIMARY KEY, behavior_id TEXT, custom_label TEXT, value_kind TEXT NOT NULL,
                      value REAL, unit TEXT, occurred_at INTEGER NOT NULL, tz_id TEXT NOT NULL, note TEXT,
                      $provenanceCols, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_journal_occurred ON journal_entries(occurred_at);",
                    "CREATE INDEX idx_journal_behavior_occurred ON journal_entries(behavior_id, occurred_at);",
                    // §9.10. `end_at` is nullable and that is the normal case, not an edge case: a
                    // status is declared when it starts ("I'm travelling") and closed later, so an
                    // open-ended row means "still active as of now". Readers must treat NULL as
                    // ongoing rather than as malformed. These intervals only ever ANNOTATE
                    // confidence ("computed during travel — your baseline may not apply"); no
                    // engine may silently alter a value because a status is active, or the
                    // displayed number stops being the measured one.
                    """
                    CREATE TABLE context_statuses (
                      id TEXT PRIMARY KEY, status_id TEXT, custom_label TEXT, start_at INTEGER NOT NULL,
                      end_at INTEGER, tz_id TEXT NOT NULL, note TEXT,
                      $provenanceCols, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_context_status_start ON context_statuses(start_at);",
                    // §9.11. Feeds the `baselines.covariate_context` column reserved in migration
                    // 1 — additive exactly as that schema anticipated, so no baseline table change
                    // is needed. `phase` includes an explicit `unknown` case rather than leaving
                    // it NULL: a cycle whose phase cannot be determined is a real, displayable
                    // state ("not enough data"), and collapsing it into NULL loses the difference
                    // between "we don't know" and "no one has looked".
                    //
                    // Superseded later by the fuller cycle model in plan §9.15 (CycleRecord,
                    // FlowLog, CyclePhaseEstimate, …). That supersession arrives as its own
                    // forward migration — this table is not a placeholder to be edited in place,
                    // and migrations are forward-only regardless.
                    """
                    CREATE TABLE cycle_contexts (
                      id TEXT PRIMARY KEY, cycle_start_at INTEGER NOT NULL, phase TEXT NOT NULL,
                      source_kind TEXT NOT NULL, confidence REAL,
                      $provenanceCols, $conventionCols
                    );
                    """,
                    "CREATE INDEX idx_cycle_context_start ON cycle_contexts(cycle_start_at);",
                )
            ),
        )
}
