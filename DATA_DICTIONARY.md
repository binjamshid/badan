<!-- GENERATED FILE — do not edit by hand.
     Run scripts/gen_data_dictionary.py after changing packages/export-schemas/ or
     packages/metric-ontology/registry.json. CI runs it with --check. -->

# BADAN export data dictionary

**Export schema version 1.1.0.**

This is the contract a downstream consumer — a script, a notebook, an analysis agent, a
clinician's spreadsheet — can rely on. It is generated from the same files the iOS and
Android apps build against, so it cannot describe a schema BADAN does not write.

Versioning policy: **additive changes bump the minor** (a new column appended, a new
optional key), **breaking changes bump the major** and ship migration notes in
`packages/export-schemas/CHANGELOG.md`. A consumer pinned to an older minor keeps working;
a consumer pinned to an older major is told exactly what moved.

Raw data is never paywalled. Every column, every array and every format described here is
available in every build, to every user, without a subscription.

---

## 1. CSV columns

Export schema **1.1.0** — 26 columns, in this exact order.

Line endings are CRLF (RFC 4180). The header row is always written, even for zero data
rows, so an empty file is still a valid self-describing table. Numbers are
locale-independent, never exponential, and rounded to 6 decimal places below 1e9 so
unit-conversion float residue does not surface as spurious precision. Timestamps are
ISO-8601 with a **numeric** offset (`+00:00`, never `Z`) rendered in the record's own
timezone.

Raw and derived rows are written to **separate files** and never share columns (invariant
I5). Every row carries `value_type` and `is_derived` so the separation survives a consumer
that concatenates them.

| # | Column | Type | Since | Description |
|---|---|---|---|---|
| 1 | `record_id` | `string (ULID)` | 0.1.0 | Stable per-record identifier, unchanged across re-exports; dedup lineage target. |
| 2 | `record_kind` | `enum`<br>`sample` \| `interval` \| `session` \| `event` \| `derived` \| `baseline` | 0.1.0 | Record shape: sample \| interval \| session \| event \| derived \| baseline (instant vs aggregate vs typed-event vs computed). |
| 3 | `metric_id` | `string` | 0.1.0 | Registry metric id (e.g. vitals.hrv_rmssd); language-stable join key. |
| 4 | `metric_display` | `string` | 0.1.0 | Localized display name of the metric in the export's display_language. |
| 5 | `value` | `decimal string` | 0.1.0 | Recorded value in the active unit profile (canonical unless a display/custom unit profile overrides). |
| 6 | `unit` | `string` | 0.1.0 | UCUM-style unit token for value, from the metric registry. |
| 7 | `canonical_value` | `decimal string` | 0.1.0 | Same measurement in the metric's canonical unit, independent of unit profile — raw provenance anchor. |
| 8 | `canonical_unit` | `string` | 0.1.0 | Canonical UCUM unit token paired with canonical_value. |
| 9 | `value_type` | `enum`<br>`raw` \| `derived` \| `aggregate` | 0.1.0 | raw \| derived \| aggregate — separates measured rows from computed/rolled-up rows. |
| 10 | `is_derived` | `boolean` | 0.1.0 | True when the row is engine-computed (score/baseline); false for measured/raw — explicit raw-vs-derived flag. |
| 11 | `timestamp_start` | `ISO-8601 w/ offset` | 0.1.0 | Measured-at start instant (offset carried, not normalized). |
| 12 | `timestamp_end` | `ISO-8601 w/ offset (nullable)` | 0.1.0 | Interval/session end; null for instant samples. |
| 13 | `timezone` | `IANA tz string` | 0.1.0 | Timezone at measurement; basis for day-boundary computation (§30.1 provenance). |
| 14 | `recorded_at` | `ISO-8601 w/ offset` | 0.1.0 | Ingestion timestamp; retro/backdated logging detectable by divergence from timestamp_start. |
| 15 | `source_app` | `string (nullable)` | 0.1.0 | Bundle/package id of the app that produced the record. |
| 16 | `source_device` | `string (nullable)` | 0.1.0 | Capturing device model + name. |
| 17 | `ingestion_path` | `enum`<br>`platformStore` \| `manual` \| `import` \| `derived` \| `vendor` | 0.1.0 | How the record entered BADAN. Emitted as the domain IngestionPath token (platformStore \| manual \| import \| derived \| vendor); the blueprint's prose spelling 'platform \| vendor_direct \| broker \| import \| manual' names the same five paths. |
| 18 | `source_external_id` | `string (nullable)` | 0.1.0 | Upstream system's own id for the record; source-lineage and dedup correlation key. |
| 19 | `import_batch_id` | `string (nullable)` | 0.1.0 | One-tap-undo import lineage id (§30.5). |
| 20 | `quality_flags` | `string (nullable)` | 0.1.0 | Semicolon-delimited quality flags (e.g. artifact_suspect;low_coverage). |
| 21 | `confidence` | `decimal 0–1 (nullable)` | 0.1.0 | Per-record confidence score when the metric defines one. |
| 22 | `algorithm_id` | `string (nullable)` | 0.1.0 | Algorithm id on derived rows; keys the manifest methodology link. |
| 23 | `algorithm_version` | `string (nullable)` | 0.1.0 | Version of the algorithm on derived rows; enables reproducibility across schema majors. |
| 24 | `suppressed_by` | `string (nullable)` | 0.1.0 | record_id of the winning record when this row was dedup-suppressed; present only when scope includes suppressed duplicates. |
| 25 | `granularity` | `enum (nullable)`<br>`raw` \| `second` \| `minute` \| `hour` \| `day` \| `week` \| `month` \| `year` | 1.0.0 | The time resolution the row's value describes: 'raw' for an as-measured sample, otherwise the whole calendar unit the row covers. Empty when the emitting path has not declared one — an arbitrary-length interval is not a calendar unit, and no value is preferable to a rounded-off claim. Appended at position 25 by A1; never reorder ahead of an existing column. |
| 26 | `aggregation_method` | `enum (nullable)`<br>`none` \| `sum` \| `mean` \| `min` \| `max` \| `min_avg_max` \| `duration` \| `latest` | 1.0.0 | How multiple underlying readings were combined into this row's value. 'none' means the value is a single reading (or an algorithm output that is not an aggregation of like readings), not that the question is unanswered — an unanswered one is empty. Appended at position 26 by A1. |

### Contract notes

- Raw and derived are physically separated, never merged into shared columns: ExportScope.payloadKinds {RAW, DERIVED} are 'separated in output, never merged columns' — CSV routes measured rows to per-metric-family files (sleep.csv, vitals.csv) and computed scores/baselines to derived.csv, and every row is tagged with value_type + is_derived. (Column authority: §20.2's full contract governs; §56.2's CsvWriter parenthetical lists only an abbreviated subset — the fuller §20.2/§20.5 set is the frozen contract.)
- Canonical value survives unit-profile changes: canonical_value/canonical_unit always carry the metric's canonical unit regardless of the display/custom unit profile applied to value/unit, so raw provenance is preserved and conversions (mmol/L vs mg/dL) live only in ExportMapping — impossible-by-construction unit errors, tested per-locale.
- Derived rows are self-documenting and auditable: algorithm_id + algorithm_version on each derived row key into manifest.methodology_links (and the JSON bundle's derived_values[] carry input_manifest refs to their contributing inputs), so every computed value traces back to method + version + inputs and is never presented as if it were raw.
- Suppressed duplicates are excluded by default and opt-in only, as lineage not deletion: ExportScope.includeSuppressedDuplicates defaults false; when included, each suppressed row keeps suppressed_by = winning record_id (chain preserved), manifest.dedup_policy records the policy/version and inclusion state, and the on/off row-count delta equals exactly the count of suppressed_by IS NOT NULL rows.
- Provenance is complete and row-level: every row carries source_app, source_device, ingestion_path, source_external_id, import_batch_id, recorded_at and timezone so the source chain → dedup decision is fully reconstructable, while manifest per_metric_row_counts + checksums make truncation and tampering detectable.
- granularity and aggregation_method (1.0.0, A1) answer the two questions the 24-column set left to inference: what window does this number describe, and how were the underlying readings combined. Before them a daily step total and a single step sample were distinguishable only by reading record_kind and guessing at timestamp_end - timestamp_start. Both are nullable rather than defaulted, because a wrong claim about a row's resolution is worse than an absent one.
- A CSV DELTA run (§22.6 / EPIC-17, ExportRangeRule.sinceLastRun with a cursor) writes two extra self-describing tables beside raw.csv/derived.csv/events.csv: deletions.csv (record_id, entity, deleted_at) and corrections.csv (record_id, suppressed_by, changed_at). They are the CSV projection of the JSON bundle's deletions[] and corrections[] arrays — same records, same ordering — because a delta gathers only live rows and a consumer that only ever receives additions can otherwise never learn that a record was removed or that a dedup decision flipped. Both files are written on EVERY delta run, header-only when there is nothing to report: the CSV manifest carries no is_delta field, so their presence is what marks the artifact as a delta and a header-only file is the affirmative 'nothing was removed'. Neither file is written on a non-delta run, and neither is written by an aggregated (bucketed) run, whose rows are buckets with no record ids for a tombstone to name. A CSV delta carries no previous_manifest_sha, so its artifacts can be reconciled one by one but the sequence cannot be proven complete — chaining stays a JSON-bundle property.
- Line endings are CRLF (RFC 4180) and the header is always emitted, even for zero rows. Numbers are locale-independent, never exponential, and rounded to 6 decimal places below 1e9 so unit-conversion float residue does not leak into a column as spurious precision. Both platforms share these rules exactly — packages/fixtures/export/ is the artifact that proves it.

---

## 2. Manifest

Every artifact carries a manifest — embedded in the JSON bundle, written as
`manifest.json` beside a CSV export. It makes truncation and tampering detectable and the
export reproducible from its own description.

#### `manifest`

The §22.5 manifest contract, embedded so the artifact is reproducible from its own description (D-8). The standalone manifest.json written alongside a CSV export carries the same fields.

| Field | Type | Required | Notes |
|---|---|---|---|
| `export_id` | `string` | yes |  |
| `export_schema_version` | `"1.1.0"` (constant) | yes |  |
| `app_version` | `string` | yes |  |
| `platform` | `string` | yes |  |
| `generated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `scope` | object | yes | Full echo of the scope that produced this artifact. A null list means 'all', which is not the same as an empty list. |
| `date_range` | `string` | yes |  |
| `display_language` | `string` | yes |  |
| `unit_profile` | `string` | yes |  |
| `timezone_policy_note` | `string` | yes |  |
| `dedup_policy_note` | `string` | yes |  |
| `per_metric_row_counts` | object | yes |  |
| `row_counts` | object | yes | Rows actually serialized per top-level array, counted by the writer from what it emitted rather than from what it was handed. Makes truncation detectable. |
| `checksums` | object | yes | sha256 per file. Always describes the PLAINTEXT content, whether or not the artifact was encrypted on the way to disk. A self-contained bundle cannot checksum itself, so the bundle's own sha is recorded on the export job, not here. |
| `data_quality_note` | `string` | yes |  |
| `sample_data_row_count` | `integer` | yes | How many rows in THIS artifact were fabricated by sample/demo mode. Counted from the rows' own quality flags, not from an app-level demo switch, so it stays true for a store holding both kinds. |
| `is_delta` | `boolean` | yes |  |
| `cursor_before` | `string` or `null` | yes |  |
| `cursor_after` | `string` or `null` | yes |  |
| `previous_manifest_sha` | `string` \| `null` | yes |  |
| `destination` | object or `null` | yes | Where the artifact was written, as name and kind ONLY. Credentials, tokens, account identifiers and secret-bearing paths are never recorded here — a manifest travels with the file it describes. |
| `encryption` | `none` \| `badanenc-v1` | yes |  |

### Field summary from the CSV contract

`csv_columns.json` documents the same manifest in prose; both are listed so a drift
between them is visible rather than a matter of which file you happened to open.

- export_id (ULID) — names the artifact and echoes into every file
- generated_at (ISO-8601 w/ numeric offset) — generation timestamp
- app_version — emitting app version
- platform — emitting platform (iOS/Android)
- export_schema_version (semver, per-format) — the schemaVersion; frozen contract with changelog
- scope (serialized ExportScope) — full scope echo; export is reproducible from its manifest
- date_range (closed-open, per timezone_policy) — the exported period
- unit_profile (string) — unit choices applied to value/unit columns (canonical \| display \| custom)
- display_language (BCP-47) — language of the metric_display / *_display columns
- timezone_policy (string) — 'timestamps carry original offsets; day boundaries computed in tz-at-measurement' + notes
- dedup_policy (string) — policy description + version, and whether suppressed rows are included
- per_metric_row_counts (map metric_id → count) — makes truncation detectable
- row_counts (map array-or-file → count) — per-artifact totals; the §22.5 sibling of per_metric_row_counts
- methodology_links (map algorithm_id → public methodology URL) — for every derived metric present
- checksums (map file → sha256) — canonical-serialization integrity per file
- data_quality_note (string) — coverage-gap summary for the period
- sample_data_row_count (int) — rows fabricated by sample/demo mode; 0 on a purely real export (honesty field, §22.5)
- is_delta (bool) — true when the run exported only rows newer than cursor_before (§22.6)
- cursor_before (ISO-8601 w/ numeric offset, nullable) — the incremental cursor this run started from; null on a full run
- cursor_after (ISO-8601 w/ numeric offset, nullable) — the cursor a subsequent delta run should start from
- previous_manifest_sha (sha256, nullable) — the prior manifest's bundle sha; chains delta runs (§22.6)
- destination (object, nullable) — {name, kind} of where the artifact was written. NEVER credentials, tokens, paths with secrets, or account identifiers
- encryption (enum: none \| badanenc-v1) — how the artifact reached disk; checksums always describe the plaintext either way

---

## 3. JSON bundle

The 1.1.0 JSON bundle envelope (execution plan §22.2). This is the PUBLIC face of an export: snake_case keys, ISO-8601 timestamps with a numeric offset, raw and derived in physically separate arrays (I5). BADAN's internal storage is unchanged by this schema — timestamps are epoch-millis in SQLite and are rendered on the way out; do not read this file as a description of the database. Written as a real JSON Schema rather than prose so a downstream consumer can validate a bundle mechanically; scripts/gen_data_dictionary.py reads it to generate DATA_DICTIONARY.md. 1.1.0 is additive over 1.0.0 — nothing was removed, renamed or retyped; `logs.hydration`, `logs.journal`, `logs.context_statuses` and the root `corrections[]` are the four optional keys it adds. Each is absent-when-empty, so a bundle that carries none of them is shaped exactly as 1.0.0 described.

### Envelope

| Key | Type | Required | Notes |
|---|---|---|---|
| `export_schema_version` | `"1.1.0"` (constant) | yes | Semver of the export contract this bundle was written against. Additive changes bump the minor, breaking changes bump the major with migration notes in CHANGELOG.md. A `const` rather than a pattern: this document describes exactly one version, so a bundle declaring another one fails here by name instead of half-validating against a shape it was never written to. |
| `generated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `app` | object | yes |  |
| `manifest` | object | yes | The §22.5 manifest contract, embedded so the artifact is reproducible from its own description (D-8). The standalone manifest.json written alongside a CSV export carries the same fields. |
| `dictionaries` | object | yes | Self-description of the ids used in this bundle, derived from the bundle's own contents so the artifact stays readable without the app, the registry, or a network. Every array is sorted by its own id for byte-stability. |
| `raw_samples` | array of object | yes | As-measured readings (I1: each carries full provenance). Never contains a computed value — see derived_values. |
| `interval_records` | array of object | yes | Normalized aggregates over a window (daily steps, nightly time-asleep). Measured-derived, not engine-computed: is_derived is false and value_type is 'aggregate'. |
| `sessions` | array of object | yes | Sleep episodes. Workout episodes are NOT here — they are promoted to `workouts` as parent objects and are not duplicated. |
| `workouts` | array of object | yes | Workout episodes as parent objects with references, never flattened. A workout's heart-rate series is referenced by query descriptor into raw_samples, never copied. |
| `derived_values` | array of object | yes | Engine-computed values. Physically separate from raw (I5) and self-documenting: every row names the algorithm and version that produced it. |
| `baselines` | array of object | yes |  |
| `logs` | object | yes | User-entered structured logs, kept apart from the measurement chain. `symptoms` and `adherence` are sensitive-class (I7) and appear only under an explicit includeSensitive scope. `hydration` is normal-class (a logged drink is the user's own data, never paywalled) and appears in a DEFAULT export, but is added ONLY when the export caught at least one drink — an install without the module, or an export whose scope caught no drinks, omits the key entirely rather than emitting an empty block that would assert 'this user logged no drinks'. `journal` and `context_statuses` (EPIC-29) are sensitive-plus and follow BOTH rules at once: they require includeSensitive, and each is added only when its own array has rows — an empty array in a default export would assert 'this user logged no behaviors' AND disclose that the behavior log was read at all, which for a lifestyle-revealing family is itself a leak. |
| `deletions` | array of object | yes | Tombstones: rows present in this bundle that carry a deleted_at. Deletion is recorded, not enacted by omission — a consumer syncing against a prior bundle needs to know a record went away rather than infer it from absence (§22.6). |
| `corrections` | array of object | no | Suppression-flip corrections (§22.6): records whose dedup verdict CHANGED since the delta's cursor_before. Present only on a delta bundle that actually has flips — absent, not empty, because a full export makes no claim about what changed since a cursor it never had. This section exists because a delta that only ever adds rows silently desyncs a downstream store when a dedup decision reverses: the row the consumer holds as authoritative is now suppressed (or a suppressed one now wins) and no added row would say so. suppressed_by names the winning record, or is null when the flip CLEARED a prior suppression (the record wins again) — null is meaningful and must not be confused with an absent key. Sorted by record_id so two platforms emit identical bytes. |
| `config` | object | no | The user's own export configuration, included so a backup restores settings rather than only data. Absent — not empty — when the emitting path did not supply it; an empty object would claim the user has no templates. |

### Record shapes

#### `raw_samples[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `metric_id` | `string` | yes |  |
| `value` | `number` | yes | The stored value, always in the metric's canonical unit. Unlike CSV's `value` column, the bundle does not apply a display unit profile — it publishes the canonical number plus what the source actually reported, and lets the consumer convert. |
| `unit` | `string` | yes |  |
| `canonical_value` | `number` | yes |  |
| `canonical_unit` | `string` | yes |  |
| `original_value` | `number` | yes | The value exactly as the source reported it. |
| `original_unit` | `string` | yes |  |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` or `null` | yes |  |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `granularity` | `"raw"` (constant) | yes |  |
| `aggregation_method` | `"none"` (constant) | yes |  |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `interval_records[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `metric_id` | `string` | yes |  |
| `value` | `number` | yes |  |
| `unit` | `string` | yes |  |
| `canonical_value` | `number` | yes |  |
| `canonical_unit` | `string` | yes |  |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `coverage` | `number` | yes | 0–1 fraction of the window actually covered by underlying readings. Below 1 means the aggregate is over a partial window, which is a data-quality fact the consumer needs and BADAN does not silently backfill. |
| `granularity` | `raw` \| `second` \| `minute` \| `hour` \| `day` \| `week` \| `month` \| `year` or `null` | yes | The time resolution a value describes. 'raw' is an as-measured reading. Null when the row's window is not a whole calendar unit — an arbitrary-length interval has no honest granularity, and a rounded-off guess would be worse than an absent one. |
| `aggregation_method` | `none` \| `sum` \| `mean` \| `min` \| `max` \| `min_avg_max` \| `duration` \| `latest` or `null` | yes | How underlying readings were combined. 'none' asserts the value is a single reading (or an algorithm output that is not an aggregation of like readings) — it is an answer, not a missing one. Null is the missing one. |
| `value_type` | `"aggregate"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `sessions[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `kind` | `sleepPrimary` \| `sleepNap` | yes |  |
| `subtype` | `string` \| `null` | yes |  |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `local_night` | `string` \| `null` | yes | YYYY-MM-DD attribution key computed in the record's own timezone. This is what makes 'last night' survive DST and a post-midnight bedtime. |
| `detail` | object | yes |  |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `workouts[]`

A workout episode as a parent object. `strength_sets` from the plan's §22.2 sketch is NOT emitted: BADAN has no strength-set entity yet, and an empty array would claim the user recorded no sets rather than that the feature does not exist. It is reserved, not silently dropped.

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes | The session ULID. Route filenames are derived from it (§22.4). |
| `activity_type` | `string` | yes | A stable BADAN slug, never a platform's numeric enum value. |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `totals` | object | yes | The totals the SOURCE reported. Absent keys stay absent and are never coerced to zero: '0 kcal' and 'not recorded' are different claims. KNOWN PLATFORM DIVERGENCE: energy appears as `energy_kcal` from iOS and `energy_kj` from Android, because the two builds' WorkoutTotals landed on different stored units in EPIC-03. Exactly one of the two keys appears, and the key names the unit — a consumer must read whichever is present rather than assume. This is declared rather than papered over with a conversion, which would introduce float residue into a lineage record; see packages/fixtures/export/README.md knownDivergences. |
| `hr_series_ref` | object | no | A QUERY DESCRIPTOR into raw_samples, never a copy of the series. Absent when no HR linkage was recorded. Resolve it by selecting raw_samples where metric_id matches and start_at falls in [start_at, end_at]. KNOWN PLATFORM DIVERGENCE: only iOS can emit this today — Android's WorkoutDetail has no hrSeriesRef field, so an Android bundle omits the key even for a workout that has an HR series in raw_samples. Declared in packages/fixtures/export/README.md. |
| `route_ref` | `string` | no | Filename of the workout's GPX trace inside the artifact (§22.4). Location data gates independently of every other health class: this key is absent unless the export was built with the explicit route opt-in, and it is never present in a Quick Export. |
| `source_workout_id` | `string` \| `null` | yes | The platform's own workout id, so an exported workout correlates against Apple Health / Health Connect without the reader knowing how BADAN composes external ids. |
| `detail_version` | `string` or `null` | yes | Version of the typed workout payload the row was read from. iOS stores it as an integer and Android as this string; both render into this one spelling so the bundle does not leak which platform wrote it. |
| `local_night` | `string` \| `null` | no |  |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `derived_values[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `metric_id` | `string` | yes |  |
| `value` | `number` | yes |  |
| `unit` | `string` | yes |  |
| `period_key` | `string` | yes | day:YYYY-MM-DD \| week:YYYY-Www \| month:YYYY-MM \| year:YYYY \| session:<ulid>. granularity is read from this prefix, which is why it is null for a session-keyed value. |
| `granularity` | `raw` \| `second` \| `minute` \| `hour` \| `day` \| `week` \| `month` \| `year` or `null` | yes | The time resolution a value describes. 'raw' is an as-measured reading. Null when the row's window is not a whole calendar unit — an arbitrary-length interval has no honest granularity, and a rounded-off guess would be worse than an absent one. |
| `aggregation_method` | `"none"` (constant) | yes | 'none' on every derived value today: an algorithm output is not an aggregation of like readings, and claiming 'mean' would misdescribe how the number was produced. The algorithm's own composition is published in docs/algorithms/ and keyed by algorithm_id. |
| `value_type` | `"derived"` (constant) | yes |  |
| `is_derived` | `true` (constant) | yes |  |
| `confidence` | `number` \| `null` | yes |  |
| `provisional` | `boolean` | yes | True while the inputs are too thin to be honest about. A provisional value is published, not hidden — hiding it would make the app look more certain than it is. |
| `algorithm_id` | `string` | yes |  |
| `algorithm_version` | `string` | yes |  |
| `input_manifest_ref` | `string` \| `null` | yes | Id of the input manifest listing the records this value was computed from. |
| `computed_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `baselines[]`

A materialized personal-normal band. Timestamps render at +00:00 because a baseline spans many days and has no single measurement timezone to be faithful to.

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `metric_id` | `string` | yes |  |
| `unit` | `string` | yes |  |
| `covariate_context` | `string` | yes |  |
| `window_days` | `integer` | yes |  |
| `method` | `medianMAD` | yes |  |
| `center` | `number` | yes |  |
| `spread` | `number` | yes |  |
| `band_low` | `number` | yes |  |
| `band_high` | `number` | yes |  |
| `n_points` | `integer` | yes |  |
| `provisional` | `boolean` | yes |  |
| `algorithm_version` | `string` | yes |  |
| `valid_from` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `computed_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `value_type` | `"derived"` (constant) | yes |  |
| `is_derived` | `true` (constant) | yes |  |

#### `deletions[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `entity` | `raw_sample` \| `interval_record` \| `session` \| `workout` \| `derived_value` \| `symptom` \| `adherence` \| `workout_log` \| `nutrition` | yes |  |
| `deleted_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |

#### `logs`

User-entered structured logs, kept apart from the measurement chain. `symptoms` and `adherence` are sensitive-class (I7) and appear only under an explicit includeSensitive scope. `hydration` is normal-class (a logged drink is the user's own data, never paywalled) and appears in a DEFAULT export, but is added ONLY when the export caught at least one drink — an install without the module, or an export whose scope caught no drinks, omits the key entirely rather than emitting an empty block that would assert 'this user logged no drinks'. `journal` and `context_statuses` (EPIC-29) are sensitive-plus and follow BOTH rules at once: they require includeSensitive, and each is added only when its own array has rows — an empty array in a default export would assert 'this user logged no behaviors' AND disclose that the behavior log was read at all, which for a lifestyle-revealing family is itself a leak.

#### `logs.symptoms[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `symptom_id` | `string` \| `null` | yes |  |
| `custom_label` | `string` \| `null` | yes |  |
| `severity` | `integer` | yes |  |
| `occurred_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `duration_seconds` | `number` \| `null` | yes |  |
| `body_location` | `string` \| `null` | yes |  |
| `triggers` | array of `string` | yes |  |
| `note` | `string` \| `null` | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.adherence[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `regimen_id` | `string` | yes |  |
| `kind` | `taken` \| `skipped` \| `late` | yes |  |
| `scheduled_for` | `string` or `null` | yes |  |
| `occurred_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `skip_reason` | `forgot` \| `sideEffects` \| `ranOut` \| `doctorAdvice` \| `notNeeded` \| `other` or `null` | yes |  |
| `skip_note` | `string` \| `null` | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.workouts[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `activity_type` | `string` | yes |  |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `energy_kcal` | `number` \| `null` | yes |  |
| `distance_m` | `number` \| `null` | yes |  |
| `avg_hr` | `number` \| `null` | yes |  |
| `max_hr` | `number` \| `null` | yes |  |
| `perceived_effort` | `integer` \| `null` | yes |  |
| `note` | `string` \| `null` | yes |  |
| `ingestion_path` | `platformStore` \| `manual` \| `import` \| `derived` \| `vendor` | yes | How the datum entered BADAN. 'vendor' is reserved for direct vendor/broker ingestion. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.nutrition[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `description` | `string` | yes |  |
| `meal_type` | `breakfast` \| `lunch` \| `dinner` \| `snack` \| `drink` | yes |  |
| `energy_kcal` | `number` \| `null` | yes |  |
| `protein_g` | `number` \| `null` | yes |  |
| `carbs_g` | `number` \| `null` | yes |  |
| `fat_g` | `number` \| `null` | yes |  |
| `fiber_g` | `number` \| `null` | yes |  |
| `water_ml` | `number` \| `null` | yes |  |
| `caffeine_mg` | `number` \| `null` | yes |  |
| `low_detail` | `boolean` | yes | True for a 'quick calories' entry — honestly flagged rather than presented as a measured macro breakdown. |
| `occurred_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `note` | `string` \| `null` | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.hydration`

The `logs.hydration` block (EPIC-38 / §9.14). Present only when the export caught at least one drink. REDACTION is structural, not blanked: the default export withholds `note` (the key is absent from every entry) and the `redaction` object names every field a default file leaves out (§7A.1). The hydration CSV set (hydration_entries.csv etc.) carries the same rows and a byte-identical redaction manifest.

| Field | Type | Required | Notes |
|---|---|---|---|
| `redaction` | object | yes | The machine-readable statement of what a default hydration export leaves out (§7A.1). `notes_included` is false in a default export; `excluded_by_default` lists `note` (while withheld) plus the contexts this phase never models at all (fasting/cycle/pregnancy/location/reminder history), so the omission is disclosed rather than invisible. |
| `entries` | array of object | yes |  |
| `summaries` | array of object | yes | Per-local-day rollups with a frozen goal snapshot. Manual/imported/estimated totals are kept separate (I5) so an imported or estimated volume is never silently blended into what the user logged; only manual is populated this phase. |
| `goals` | array of object | yes |  |
| `beverages` | array of object | yes | The custom beverage definitions the exported entries reference, so a reader can name each drink without the app or a separate catalog. Built-ins are not repeated here. |
| `sources` | array of object | yes | The provenance apps/paths the entries came from, aggregated and sorted — the hydration-scoped answer to 'where did this come from' (I1), matching hydration_sources.csv. |

#### `logs.hydration.redaction`

The machine-readable statement of what a default hydration export leaves out (§7A.1). `notes_included` is false in a default export; `excluded_by_default` lists `note` (while withheld) plus the contexts this phase never models at all (fasting/cycle/pregnancy/location/reminder history), so the omission is disclosed rather than invisible.

| Field | Type | Required | Notes |
|---|---|---|---|
| `notes_included` | `boolean` | yes |  |
| `excluded_by_default` | array of `string` | yes |  |

#### `logs.hydration.entries[]`

One logged drink from the append-first revision ledger (§9.14). A volume is always canonical mL — a fluid type is a display/grouping category, NEVER a hydration weight, so 500 mL of coffee is 500 mL exactly like water (§7A.1). `note` is present ONLY when the export explicitly opted notes in; a default export omits the key entirely.

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes | This revision's ULID. |
| `original_id` | `string` | yes | The stable identity of the logical drink across every revision. Equal to record_id for an un-revised entry. |
| `supersedes` | `string` \| `null` | yes | record_id of the revision this one replaces; null for an original (I2 append-never-overwrite). |
| `revision` | `integer` | yes | 1-based; 1 is the original. |
| `volume_ml` | `number` | yes | Canonical mL, always > 0. |
| `canonical_unit` | `"mL"` (constant) | yes |  |
| `fluid_type` | `string` | yes | Open-vocabulary category key (water, coffee, tea, …) for grouping/display only — never a hydration multiplier. |
| `beverage_id` | `string` \| `null` | yes |  |
| `container_id` | `string` \| `null` | yes |  |
| `occurred_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `note` | `string` \| `null` | no | Free-text note. Structurally redacted from a default export: the key is absent unless notes were explicitly opted in, never present-but-blank. |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.hydration.summaries[]`

A day's hydration rollup with a frozen goal snapshot: raising a goal next month does not retroactively mark last month's days as missed (§9.14). value_type is 'derived' — this is a computed rollup, physically separable from the raw entries (I5).

| Field | Type | Required | Notes |
|---|---|---|---|
| `day_key` | `string` | yes | Local calendar day, YYYY-MM-DD, computed in `timezone`. |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `manual_ml` | `number` | yes |  |
| `imported_ml` | `number` | yes |  |
| `estimated_ml` | `number` | yes |  |
| `total_ml` | `number` | yes |  |
| `entry_count` | `integer` | yes |  |
| `goal_kind` | `none` \| `manual` | yes |  |
| `goal_target_ml` | `number` \| `null` | yes | The snapshotted target, or null for a no-goal day (equal-status, never 0). |
| `goal_progress_pct` | `number` \| `null` | yes | Progress against the snapshotted target, or null for a no-goal day — a percentage of nothing is the streak-guilt framing §7A.1 rejects, so it is null, never 0. |
| `value_type` | `"derived"` (constant) | yes |  |
| `is_derived` | `true` (constant) | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |

#### `logs.hydration.goals[]`

A hydration goal. `none` is a first-class, equal-status value — tracking without a target, never nagged (§7A.1) — so `target_ml` is null exactly when `kind` is `none`. `day_type` is a user-authored label (nothing infers it); null is the default goal.

| Field | Type | Required | Notes |
|---|---|---|---|
| `goal_id` | `string` | yes |  |
| `kind` | `none` \| `manual` | yes |  |
| `target_ml` | `number` \| `null` | yes |  |
| `day_type` | `string` \| `null` | yes |  |
| `active` | `boolean` | yes |  |
| `created_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |

#### `logs.hydration.beverages[]`

A user-added beverage definition referenced by an exported entry. caffeine/alcohol/electrolyte are DISPLAY METADATA ONLY — carried so a reader sees the catalog fact, never read into a hydration total or a 'net hydration' multiplier (§7A.1 Reject).

| Field | Type | Required | Notes |
|---|---|---|---|
| `beverage_id` | `string` | yes |  |
| `name_en` | `string` | yes |  |
| `name_ar` | `string` | yes |  |
| `fluid_type` | `string` | yes |  |
| `default_volume_ml` | `number` \| `null` | yes |  |
| `is_builtin` | `boolean` | yes |  |
| `caffeine_mg_per_100ml` | `number` \| `null` | yes |  |
| `alcohol_pct` | `number` \| `null` | yes |  |
| `electrolyte_note` | `string` \| `null` | yes |  |

#### `logs.hydration.sources[]`

| Field | Type | Required | Notes |
|---|---|---|---|
| `source_app` | `string` | yes |  |
| `ingestion_paths` | array of `platformStore` \| `manual` \| `import` \| `derived` \| `vendor` | yes |  |
| `entry_count` | `integer` | yes |  |

#### `logs.journal[]`

One behavior tag from the journal (EPIC-29 / §9.9) — a raw user assertion, sensitive-plus (I7). Exactly one of `behavior_id` (a behaviors.json key) and `custom_label` (the user's own words) is non-null; the KEY is stored rather than a rendered label so an Arabic-logged journal reads in English and back. `value_kind` says which shape to expect: `boolean` carries a null `value` and null `unit` (the row's existence is the assertion — it is NOT 'happened once'), `count` an integer with no physical unit, `quantity` an amount in `unit`. `recalled` is derived from occurred_at vs provenance.recorded_at and marks the yesterday-recall path; it is DISCLOSURE, not a discount — a recalled entry counts exactly like a live one.

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `behavior_id` | `string` \| `null` | yes |  |
| `custom_label` | `string` \| `null` | yes |  |
| `value_kind` | `boolean` \| `count` \| `quantity` | yes |  |
| `value` | `number` \| `null` | yes |  |
| `unit` | `string` \| `null` | yes |  |
| `occurred_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `recalled` | `boolean` | yes |  |
| `note` | `string` \| `null` | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `logs.context_statuses[]`

A user-declared interval that conditions how values from that period should be READ (EPIC-29 / §9.10) — travel, illness, fasting, altitude, injury, or the user's own label. Sensitive-plus (I7). `end_at` is null exactly when the status is still open, and `open_ended` names that rather than leaving a consumer to infer the null; an export NEVER substitutes 'now' for an end the user did not declare. No confidence, ceiling or adjustment is serialized: a status annotates interpretation and never alters a stored value, so there is no adjusted number here to carry.

| Field | Type | Required | Notes |
|---|---|---|---|
| `record_id` | `string` | yes |  |
| `status_id` | `string` \| `null` | yes |  |
| `custom_label` | `string` \| `null` | yes |  |
| `start_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `end_at` | `string` or `null` | yes |  |
| `open_ended` | `boolean` | yes |  |
| `timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `note` | `string` \| `null` | yes |  |
| `provenance` | object | yes | Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut. |
| `value_type` | `"raw"` (constant) | yes |  |
| `is_derived` | `false` (constant) | yes |  |
| `updated_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `origin_device_id` | `string` | yes |  |
| `deleted_at` | `string` or `null` | yes |  |

#### `provenance`

Embedded on the row itself, never a join (I1/D-3). A record without provenance is a bug, not a shortcut.

| Field | Type | Required | Notes |
|---|---|---|---|
| `source_app` | `string` | yes | Bundle/package id of the app that produced the record. |
| `source_device` | `string` \| `null` | yes |  |
| `ingestion_path` | `platformStore` \| `manual` \| `import` \| `derived` \| `vendor` | yes | How the datum entered BADAN. 'vendor' is reserved for direct vendor/broker ingestion. |
| `external_id` | `string` \| `null` | yes | The upstream system's own id — the idempotency key for re-ingest. |
| `import_batch_id` | `string` \| `null` | yes |  |
| `measured_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `measured_timezone` | `string` | yes | IANA tz id at measurement (e.g. Asia/Dubai). The basis for day-boundary attribution. |
| `recorded_at` | `string` | yes | ISO-8601 with a NUMERIC offset, rendered in the record's own timezone so the offset is carried rather than normalized to UTC. 'Z' is never emitted; a zero offset renders as +00:00 (§22.1). |
| `ingested_at` | `string` | yes | When BADAN stored it. The incremental-export cursor is the max of this field (§22.6), which is why a backfilled row still appears in a later delta run. |
| `algorithm_version_id` | `string` \| `null` | yes |  |
| `quality_flags` | array of `gapFilled` \| `artifactSuspected` \| `userCorrected` \| `provisionalBaseline` \| `estimate` \| `tzAssumed` \| `lowCoverage` \| `sampleData` | yes |  |
| `suppressed_by` | `string` \| `null` | yes | record_id of the winning record when dedup suppressed this row. Suppression is reversible and journaled; it is never a deletion (I3). |

---

## 4. Metrics

74 metrics across 16 families, from
`packages/metric-ontology/registry.json`. `metric_id` is the language-stable join key in
every export; `canonical_unit` is what `canonical_value` is always expressed in,
regardless of the unit profile applied to the `value` column. Both display names are
listed because `metric_display` in a CSV follows the export's `display_language`, so a
consumer holding an Arabic export needs the Arabic column to map back to a metric id.
`sensitive_class` is what decides whether a metric can appear without its own opt-in.

### `activity`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `activity.active_energy` | `kJ` | `kcal` \| `kJ` | intervalAggregate | Active energy | الطاقة النشطة | normal |
| `activity.distance` | `m` | `km` \| `mi` | intervalAggregate | Distance | المسافة | normal |
| `activity.exercise_minutes` | `s` | `min` | intervalAggregate | Exercise minutes | دقائق التمرين | normal |
| `activity.floors` | `count` | `floors` | intervalAggregate | Floors climbed | عدد الطوابق المصعودة | normal |
| `activity.resting_energy` | `kJ` | `kcal` \| `kJ` | intervalAggregate | Resting energy | طاقة الراحة | normal |
| `activity.steps` | `count` | `steps` | intervalAggregate | Steps | عدد الخطوات | normal |
| `activity.walking_speed` | `m/s` | `km/h` \| `mph` | rawSample | Walking speed | سرعة المشي | normal |

### `body`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `body.bmi` | `kg/m^2` | `kg/m^2` | derived | Body mass index | مؤشر كتلة الجسم | normal |
| `body.fat_pct` | `percent` | `percent` | rawSample | Body fat percentage | نسبة دهون الجسم | normal |
| `body.glucose` | `mmol/L` | `mmol/L` \| `mg/dL` | rawSample | Blood glucose | سكر الدم | sensitivePlus |
| `body.lean_mass` | `kg` | `kg` \| `lb` | rawSample | Lean body mass | الكتلة الخالية من الدهون | normal |
| `body.waist` | `m` | `cm` \| `in` | rawSample | Waist circumference | محيط الخصر | normal |
| `body.weight` | `kg` | `kg` \| `lb` \| `st` | rawSample | Weight | الوزن | normal |
| `body.wrist_temp_deviation` | `degC` | `degC` | intervalAggregate | Wrist temperature deviation | انحراف حرارة المعصم | normal |

### `cycle`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `cycle.day` | `count` | `count` | derived | Cycle day | يوم الدورة | sensitivePlus |
| `cycle.flow` | `scale_1_5` | `level` | event | Flow | غزارة الطمث | sensitivePlus |
| `cycle.length` | `count` | `count` | derived | Cycle length | طول الدورة | sensitivePlus |
| `cycle.period_length` | `count` | `count` | derived | Period length | مدة الطمث | sensitivePlus |
| `cycle.phase` | `` | — | derived | Cycle phase | مرحلة الدورة | sensitivePlus |

### `effort`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `effort.day` | `score_0_100` | `points` | derived | Day effort | مجهود اليوم | normal |
| `effort.workout` | `score_0_100` | `points` | derived | Workout effort | مجهود التمرين | normal |

### `heart`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `heart.bp_diastolic` | `mmHg` | `mmHg` | rawSample | Blood pressure (diastolic) | ضغط الدم الانبساطي | normal |
| `heart.bp_systolic` | `mmHg` | `mmHg` | rawSample | Blood pressure (systolic) | ضغط الدم الانقباضي | normal |
| `heart.hr` | `bpm` | `bpm` | rawSample | Heart rate | معدل ضربات القلب | normal |
| `heart.hrr_1min` | `bpm` | `bpm` | derived | Heart rate recovery (1 min) | تعافي النبض بعد دقيقة | normal |
| `heart.hrv` | `ms` | `ms` | derived | Heart rate variability | تغيّر معدل ضربات القلب | normal |
| `heart.rhr` | `bpm` | `bpm` | derived | Resting heart rate | معدل ضربات القلب أثناء الراحة | normal |
| `heart.vo2max` | `mL/kg/min` | `mL/kg/min` | derived | VO2 max | الحد الأقصى لاستهلاك الأكسجين | normal |

### `hydration`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `hydration.goal_pct` | `percent` | `percent` | derived | Hydration goal progress | نسبة تحقيق هدف السوائل | normal |
| `hydration.volume` | `L` | `mL` \| `L` \| `fl_oz` | derived | Fluid intake | كمية السوائل | normal |

### `journal`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `journal.correlation` | `index` | `index` | derived | Behaviour correlation | ارتباط بين سلوك ومؤشر | sensitivePlus |

### `lab`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `lab.out_of_range_count` | `count` | `count` | derived | Results outside reference range | نتائج خارج النطاق المرجعي | sensitivePlus |
| `lab.result` | `` | — | rawSample | Lab result | نتيجة تحليل مخبري | sensitivePlus |
| `lab.result_count` | `count` | `count` | derived | Lab results recorded | عدد نتائج التحاليل | sensitivePlus |

### `nutrition`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `nutrition.caffeine` | `mg` | `mg` | intervalAggregate | Caffeine | الكافيين | normal |
| `nutrition.carbs` | `g` | `g` \| `oz` | intervalAggregate | Carbohydrates | الكربوهيدرات | normal |
| `nutrition.energy_in` | `kJ` | `kcal` \| `kJ` | intervalAggregate | Energy intake | الطاقة المتناولة | normal |
| `nutrition.fat` | `g` | `g` \| `oz` | intervalAggregate | Fat | الدهون | normal |
| `nutrition.fiber` | `g` | `g` \| `oz` | intervalAggregate | Fiber | الألياف | normal |
| `nutrition.protein` | `g` | `g` \| `oz` | intervalAggregate | Protein | البروتين | normal |
| `nutrition.water` | `L` | `mL` \| `L` \| `fl_oz` | intervalAggregate | Water intake | كمية الماء | normal |

### `readiness`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `readiness.score` | `score_0_100` | `points` | derived | Readiness | مؤشر الجاهزية | normal |

### `respiratory`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `respiratory.rate` | `breaths/min` | `breaths/min` | intervalAggregate | Respiratory rate | معدل التنفس | normal |
| `respiratory.spo2` | `percent` | `percent` | rawSample | Blood oxygen (SpO2) | تشبّع الأكسجين في الدم | normal |

### `sleep`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `sleep.awake` | `s` | `min` | intervalAggregate | Awake time | زمن اليقظة أثناء الليل | normal |
| `sleep.consistency` | `score_0_100` | `points` | derived | Sleep consistency | انتظام النوم | normal |
| `sleep.debt` | `s` | `h` \| `min` | derived | Sleep debt | دين النوم | normal |
| `sleep.deep` | `s` | `h` \| `min` | intervalAggregate | Deep sleep | النوم العميق | normal |
| `sleep.disturbances` | `count` | `count` | derived | Sleep disturbances | مرات الاستيقاظ أثناء النوم | normal |
| `sleep.efficiency` | `percent` | `percent` | derived | Sleep efficiency | كفاءة النوم | normal |
| `sleep.latency` | `s` | `min` | derived | Sleep latency | زمن الخلود إلى النوم | normal |
| `sleep.light` | `s` | `h` \| `min` | intervalAggregate | Light sleep | النوم الخفيف | normal |
| `sleep.midpoint` | `time_of_day` | `clock_24h` \| `clock_12h` | derived | Sleep midpoint | منتصف النوم | normal |
| `sleep.need` | `s` | `h` \| `min` | derived | Sleep need | حاجة النوم | normal |
| `sleep.performance` | `percent` | `percent` | derived | Sleep performance | نسبة تحقيق حاجة النوم | normal |
| `sleep.rem` | `s` | `h` \| `min` | intervalAggregate | REM sleep | نوم حركة العين السريعة | normal |
| `sleep.score` | `score_0_100` | `points` | derived | Sleep score | مؤشر جودة النوم | normal |
| `sleep.time_asleep` | `s` | `h` \| `min` | intervalAggregate | Time asleep | زمن النوم الفعلي | normal |
| `sleep.time_in_bed` | `s` | `h` \| `min` | intervalAggregate | Time in bed | الوقت في السرير | normal |

### `stress`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `stress.day_trend` | `score_0_100` | `points` | derived | Daily stress trend | اتجاه التوتر اليومي | sensitivePlus |

### `subjective`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `subjective.energy` | `scale_1_5` | `level` | event | Energy level | مستوى الطاقة | normal |
| `subjective.mood` | `scale_1_5` | `level` | event | Mood | الحالة المزاجية | sensitivePlus |
| `subjective.perceived_stress` | `scale_1_5` | `level` | event | Perceived stress | مستوى التوتر | sensitivePlus |
| `subjective.soreness` | `scale_0_10` | `level` | event | Muscle soreness | وجع العضلات | normal |

### `symptoms`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `symptoms.count` | `count` | `count` | derived | Symptom count | عدد الأعراض | sensitivePlus |
| `symptoms.severity_avg` | `scale_0_10` | `level` | derived | Symptom severity | شدة الأعراض | sensitivePlus |

### `workout`

| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |
|---|---|---|---|---|---|---|
| `workout.avg_hr` | `bpm` | `bpm` | session | Average heart rate | متوسط النبض في التمرين | normal |
| `workout.distance` | `m` | `km` \| `mi` | session | Workout distance | مسافة التمرين | normal |
| `workout.duration` | `s` | `h` \| `min` | session | Workout duration | مدة التمرين | normal |
| `workout.energy` | `kJ` | `kcal` \| `kJ` | session | Workout energy | طاقة التمرين | normal |
| `workout.max_hr` | `bpm` | `bpm` | session | Peak heart rate | أعلى نبض في التمرين | normal |
| `workout.strength.e1rm` | `kg` | `kg` \| `lb` | derived | Estimated one-rep max | أقصى وزن مقدر لتكرار واحد | normal |
| `workout.strength.pr` | `count` | `count` | event | Personal record | أفضل رقم شخصي | normal |
| `workout.strength.volume` | `kg` | `kg` \| `lb` | derived | Training volume | حجم التدريب | normal |
