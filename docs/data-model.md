# BADAN Data Model (iOS logical schema)

The one logical schema, implemented in raw SQLite (ADR-0005). Two physical files. Android
implements the same table/column names on framework SQLite (ADR-0007), not Room. Timestamps
are INTEGER epoch-millis (UTC); booleans are 0/1; JSON payloads are TEXT; ids are TEXT ULIDs.
Every row table carries the sync-ready convention columns `updated_at, origin_device_id,
deleted_at` (D-7); measurement tables additionally carry the 12 embedded provenance columns
(D-3).

## `badan.db` (main)

| Table | Key columns (beyond conventions/provenance) | Primary index |
|---|---|---|
| `sources` | type, display_name, platform_bundle_id, status, connected_at, last_delivery_at | pk |
| `source_devices` | source_id, name, model, first_seen, last_seen | pk |
| `permission_states` | (store, platform_type) pk, status, last_checked_at, last_read_at | pk |
| `user_profile` | display_name, height_m, birth_year, bio_note | pk |
| `raw_samples` | metric_id, value, unit, original_value, original_unit, start_at, end_at, tz_id, +prov | `(metric_id, measured_at)`; unique `(metric_id, external_id, source_id)` partial |
| `interval_records` | metric_id, value, unit, start_at, end_at, tz_id, aggregation, coverage, +prov | `(metric_id, start_at, end_at)`; unique identity partial |
| `sessions` | kind, subtype, start_at, end_at, tz_id, local_night, detail(JSON), +prov | `(kind, start_at)`; `(local_night)` partial for sleep |
| `session_stages` | (session_id, seq) pk, stage, start_at, end_at | pk |
| `derived_values` | metric_id, value, unit, period_key, confidence, provisional, algorithm_id, algorithm_version, input_manifest_id, computed_at | `(metric_id, period_key, computed_at DESC)` |
| `input_manifests` | inputs(JSON) | pk |
| `baselines` | metric_id, covariate_context, window_days, method, center, spread, band_low, band_high, n_points, provisional, valid_from | unique `(metric_id, covariate_context, window_days, valid_from)` |
| `insights` | insight_type, template_id, template_version, metric_ids, period_key, depth_variant, rendered_en, rendered_ar, evidence_refs, generated_at, feedback | `(insight_type, generated_at)` |
| `dedup_decisions` | batch_id, rule, rule_version, kept_record_id, suppressed_record_id, score, reversible, reversed_at, decided_at, detail | `(suppressed_record_id)` |
| `workout_entries` | activity_type, start_at, end_at, tz_id, energy_kcal, distance_m, avg_hr, max_hr, perceived_effort, note, ingestion_path | `(start_at)` |
| `nutrition_entries` | description, meal_type, energy_kcal, protein_g, carbs_g, fat_g, fiber_g, water_ml, caffeine_mg, low_detail, occurred_at, tz_id | `(occurred_at)` |
| `note_entries` | text, occurred_at, tz_id, tags | `(occurred_at)` |
| `goals` | metric_id, target, unit, direction, active, created_at | pk |
| `export_jobs` | scope(JSON), format, status, manifest(JSON), output_path, row_count, timestamps | pk |
| `customization_profile` | id=1 singleton, json(TEXT) | pk |
| `metric_pins` | metric_id pk, pinned_at | pk |
| `read_anchors` *(reserved)* | (store, platform_type) pk, anchor BLOB | pk |
| `import_batches` *(reserved)* | source_kind, file_name, state, chunk_cursor, counts | pk |
| `sync_cursors` *(reserved)* | (scope_key, device_id) pk, lamport, last_synced_at | pk |

## `badan_sensitive.db` (sensitive-plus — separate file, purge = delete)

| Table | Key columns | Index |
|---|---|---|
| `medication_regimens` | name, strength, form, schedule(JSON), started_at, ended_at, notes | pk |
| `adherence_events` | regimen_id, kind, scheduled_for, occurred_at, tz_id, skip_reason, skip_note | `(regimen_id, occurred_at)`, `(occurred_at)` |
| `symptom_entries` | symptom_id, custom_label, severity, occurred_at, tz_id, duration_s, body_location, triggers, note | `(occurred_at)` |
| `conditions` | label, status, onset_at, linked_regimen_ids, linked_symptom_ids, notes | pk |

## Provenance columns (embedded on measurement tables)

`source_id, device_id, ingestion_path, external_id, batch_id, measured_at, measured_tz,
recorded_at, ingested_at, algorithm_version_id, quality_flags, suppressed_by`

## Query & integrity discipline

- Every repository query targets a named index; scans over `raw_samples`/`sessions` are avoided.
- Re-ingest is idempotent via the partial-unique identity indexes.
- Dedup suppresses (`suppressed_by` pointer) and journals a reversible decision; it never deletes.
- Derived values append; reads take the latest `computed_at`. Raw and derived are always separable.
