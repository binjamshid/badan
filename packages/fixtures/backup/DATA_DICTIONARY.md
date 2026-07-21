# BADAN backup — data dictionary

This file travels inside every BADAN backup. It documents the layout of `bundle.json`
(export schema 1.0.0) and the backup wrapper (backup schema 1.0) so the
data stays readable without the app.

## The backup

A backup contains three files:

- `backup_manifest.json` — backup schema version, creation time, originating app/platform,
  per-file SHA-256, and a summary of contents.
- `DATA_DICTIONARY.md` — this file.
- `bundle.json` — the full-scope data bundle plus a `config` section.

A plaintext backup is a single JSON object whose `files` array carries the three files as
text. An encrypted backup is a `badanenc-v1` container (AES-256-GCM, PBKDF2-HMAC-SHA256)
holding the same three files; the passphrase covers the whole backup, not only sensitive
records.

## bundle.json — data

Raw and derived values are physically separate and never share a row shape:

- `raw_samples` — point-in-time measurements, each with full provenance.
- `interval_records` — aggregates over a window, with a 0–1 `coverage` fraction.
- `sessions` — sleep and other non-workout episodes.
- `workouts` — workout episodes; `hr_series_ref` is a query descriptor into `raw_samples`,
  not a copy of the series.
- `derived_values` — engine-computed values; each carries `algorithm_id` and
  `algorithm_version`.
- `baselines` — personal baselines with center/spread/band and `n_points`.
- `logs.symptoms`, `logs.adherence` — the sensitive namespace (present only with consent).
- `logs.workouts`, `logs.nutrition` — manual logs.
- `logs.hydration` — the drink ledger: entries (with their revision chains), day summaries,
  goals, and referenced beverages. Carried whole in a backup, notes included.
- `deletions` — tombstones (id + `deleted_at`) so a consumer can reconcile removals.

Every timestamp is ISO-8601 with a numeric offset (never `Z`). Every value is in its
canonical unit; `original_value`/`original_unit` record what the source reported.

## bundle.json — config

- `export_templates` — saved export configurations.
- `automation_schedules` — saved automation entries.
- `customization` — presentation preferences (language, depth, units).
- `export_destinations` — present in encrypted backups only, and always without any
  credential or credential reference. Destinations must be re-authorized after a restore.

## Restore

Restoring stages the bundle as an import batch with a preview before anything is written,
matches records you already have rather than duplicating them, and keeps the sensitive
namespace behind its own consent toggle. A backup written by a newer version of BADAN than
the one restoring it is refused rather than partially imported.