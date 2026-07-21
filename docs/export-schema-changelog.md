# BADAN export schema — what changed, and what you need to do

For people **reading** BADAN exports: a script, a notebook, an analysis agent, a clinician's
spreadsheet. If you are changing the schema instead, the engineering-facing history is
[`packages/export-schemas/CHANGELOG.md`](../packages/export-schemas/CHANGELOG.md) and the full
field reference is [`DATA_DICTIONARY.md`](../DATA_DICTIONARY.md).

## How to know what you are holding

Every export says so, in two places:

- **JSON bundle** — `export_schema_version` at the top level, and again in `manifest`.
- **CSV export** — `export_schema_version` in the `manifest.json` written beside the CSV files.

Branch on that string. Do not sniff the shape.

## The promise

- **Additive changes bump the minor** (`1.0.0 -> 1.1.0`). New columns are appended at the end;
  new JSON keys are optional. If you select columns by name, or read only the columns you already
  knew about, a minor bump cannot break you.
- **Breaking changes bump the major** (`1.0.0 -> 2.0.0`) and arrive with migration notes saying
  exactly what moved.
- **Columns are never reordered, and a retired column never has its slot reused.** Positional
  readers exist; the contract does not pretend otherwise.
- **Raw data is never paywalled.** Every column, every array, every format described here is in
  every build, for every user, with no subscription. This is a product guarantee, not a tier.

## What is stable across versions

- `record_id` — stable across re-exports. Safe as a join key and for deduplicating between runs.
- `metric_id` — language-stable. `metric_display` follows the export's language and is for
  humans; never join on it.
- `canonical_value` / `canonical_unit` — always the metric's canonical (SI) unit regardless of
  what unit profile the user has chosen for the `value` column.
- Provenance columns — `source_app`, `source_device`, `ingestion_path`, `source_external_id`,
  `import_batch_id`, `recorded_at`, `timezone`. Every row has them.

---

## 1.1.0 (2026-07-22)

**Nothing you already parse has changed.** No column was added, removed or moved; no JSON key was
renamed or retyped. If you read 1.0.0 exports today, a 1.1.0 export parses identically — the only
difference is four optional keys that may be present.

### What is new

| Where | Key | What it is |
|---|---|---|
| bundle root | `corrections[]` | Dedup decisions that changed during the run's window, **including reversals** — a `suppressed_by` of `null` means a record you hold as a suppressed duplicate is authoritative again. Present on delta runs only. |
| CSV folder | `deletions.csv`, `corrections.csv` | The same two facts as CSV tables, written on every delta run. Header-only when there is nothing to report — that empty file is the affirmative "nothing was removed", not a missing file. |
| `logs` | `hydration` | The drink ledger: entries in mL with their revision chains, per-day summaries, goals, the beverages they reference, and a `redaction` block naming what a default export withholds. |
| `logs` | `journal[]` | Behavior tags — what the person logged doing. Read `behavior_id` (a stable key) or `custom_label` (their own words); exactly one is set. `value_kind` tells you whether `value`/`unit` are populated. |
| `logs` | `context_statuses[]` | Declared intervals — travel, illness, fasting, altitude, injury — that say how to *read* values from that period. They never change a stored number. |

### Reading them correctly

- **Absent is not zero.** Each of these keys is written only when it has something to say. A bundle
  with no `logs.journal` does not tell you the person logged no behaviors; it tells you this export
  carries none. Do not infer an empty log from an absent key.
- **`logs.journal` and `logs.context_statuses` require an explicit sensitive-records scope**, the
  same gate that governs symptoms and medication adherence. A default export never contains them,
  and such an export is always encrypted.
- **`logs.hydration` is not sensitive-class** and appears in ordinary exports. Notes on drinks are
  withheld by default; `logs.hydration.redaction` lists exactly what was left out.
- **`context_statuses[].end_at` is null when the interval is still open**, and `open_ended` says so
  explicitly. BADAN never fills in "now" for an end the person did not declare.
- **A `boolean` journal entry carries a null `value`.** The row's existence is the assertion. It
  does not mean "once".

### If you validate against the JSON Schema

Fetch [`json_bundle.schema.json`](../packages/export-schemas/json_bundle.schema.json) for the
version the file declares. The bundle's `logs` object is closed (`additionalProperties: false`), so
a 1.1.0 bundle checked against the 1.0.0 schema **fails validation** on the new keys even though
nothing you read has changed. Branch on `export_schema_version`, as above.

---

## 1.0.0 (2026-07-20)

### If you already parse 0.1.0, read this

**CSV — you are almost certainly fine.** The 24 columns you know are unchanged and in the same
positions. Two columns are appended:

| New column | Values | Means |
|---|---|---|
| `granularity` | `raw`, `second`, `minute`, `hour`, `day`, `week`, `month`, `year`, or empty | The window the value describes. Empty means the row's window is not a whole calendar unit — an arbitrary 20-minute aggregate, for instance. Empty is "not stated", never "raw". |
| `aggregation_method` | `none`, `sum`, `mean`, `min`, `max`, `min_avg_max`, `duration`, `latest`, or empty | How multiple readings became one number. `none` is an answer — the value is a single reading. Empty is the absent answer. |

Together they replace the guesswork that used to be needed to tell a daily step total from a
single step sample.

**Timestamps: a zero UTC offset is now `+00:00`, not `Z`.** Same instant, different spelling. If
you parse with a real ISO-8601 parser, nothing changes. If you compare timestamp strings
literally, this will bite you.

**JSON bundles changed shape. This is the breaking one.**

| 0.1.0 | 1.0.0 |
|---|---|
| `startAt: 1784509920000` (camelCase, epoch ms) | `start_at: "2026-07-20T03:12:00+04:00"` (snake_case, ISO-8601 with offset) |
| Workouts were `sessions[]` rows with a nested `detail.workout` | Workouts are their own `workouts[]` array and are **not** in `sessions[]`; `sessions[]` is sleep |
| No schema document | [`json_bundle.schema.json`](../packages/export-schemas/json_bundle.schema.json) — a real JSON Schema you can validate against |

### What is new and worth using

- **`dictionaries`** — the metrics, sources, algorithms and units that appear in this bundle,
  built from the bundle's own contents. You can read a BADAN export years from now on a machine
  that has never had the app.
- **`workouts[].hr_series_ref`** — a *query descriptor*, not a copy of the heart-rate series.
  Resolve it by selecting `raw_samples` where `metric_id` matches and `start_at` falls inside the
  workout window. The series is not duplicated, so the file stays small.
- **`deletions[]`** — records that were deleted, with the time. If you are syncing against a
  previous export, this is how you learn something went away instead of inferring it from
  absence.
- **Manifest fields** — `row_counts` (truncation is detectable), `sample_data_row_count`,
  `is_delta`, `cursor_before` / `cursor_after`, `previous_manifest_sha`, and `encryption`.
- **Checksums.** `manifest.checksums` is a sha256 per file and always describes the **plaintext**
  content, whether or not the artifact was encrypted on the way to disk.

### Two things the files will tell you that you should not ignore

- **`sample_data_row_count`** — how many rows were fabricated by BADAN's "explore with sample
  data" mode and were never measured by anyone. On a real export it is `0`. The individual rows
  also carry the `sampleData` quality flag, so a mixed file stays legible row by row.
- **`quality_flags`** — `estimate`, `gapFilled`, `lowCoverage`, `tzAssumed`, `artifactSuspected`,
  `userCorrected`, `provisionalBaseline`. BADAN annotates rather than quietly cleaning up.

### Privacy defaults you should expect to see

- **Location (`route_ref`) is absent unless the export was built with an explicit route opt-in.**
  It never appears in a Quick Export. Its absence tells you nothing about whether a route exists.
- **Symptoms and medication adherence** appear only under an explicit sensitive-records scope, and
  such an export is always encrypted.
- **`manifest.destination` carries a name and a kind only.** No credentials, tokens, account
  identifiers, or secret-bearing paths are ever written into a manifest, because a manifest
  travels with the file it describes.

### Known cross-platform differences at 1.0.0

An export written on iOS and one written on Android from the same data are byte-identical, with
three declared exceptions in the workout and manifest areas:

| Field | iOS | Android |
|---|---|---|
| `workouts[].totals` energy | `energy_kcal` (kilocalories) | `energy_kj` (kilojoules) |
| `workouts[].hr_series_ref` | emitted when a linkage was recorded | not emitted — that build records no linkage |
| `manifest.sample_data_row_count` | computed from the exported rows | `0` unless the export path supplies it |

**Read whichever energy key is present rather than assuming one.** These are tracked in
`packages/fixtures/export/export-input-v1.json` under `knownDivergences`, each with the fix that
closes it, and will be resolved in a future release.

---

## 0.1.0

The original 24-column CSV contract and a JSON bundle that serialized BADAN's internal entities
directly — camelCase field names, epoch-millisecond timestamps, workouts nested inside sleep
sessions.
