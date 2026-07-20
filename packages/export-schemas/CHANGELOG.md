# Export schema changelog

The versioned contract for everything BADAN writes out: CSV columns, the JSON bundle envelope,
and the manifest that describes both. `export_schema_version` appears in every manifest and every
bundle; this file is what that number means.

`docs/export-schema-changelog.md` is the reader-facing version of this file — same history,
written for someone consuming an export rather than someone changing one.

## Versioning policy

- **Patch** (`1.0.0 -> 1.0.1`) — wording of a description, a fixed typo in a note. No consumer
  needs to do anything.
- **Minor** (`1.0.0 -> 1.1.0`) — **additive only**. A column appended at the end, a new optional
  JSON key, a new enum value in a field documented as extensible. A consumer pinned to the older
  minor keeps parsing correctly, because nothing it already reads has moved or changed meaning.
- **Major** (`1.0.0 -> 2.0.0`) — anything else: a column removed, reordered, renamed, retyped, or
  given a new meaning under the same name; a required JSON key removed; a rendering rule changed.
  A major ships **migration notes in this file** stating, per change, what a consumer must do.

Two rules that make the policy real rather than aspirational:

1. **Never reorder or reuse.** A column is appended at the end or not added. A retired column
   keeps its position and is documented as deprecated rather than being deleted and its slot
   reused — positional readers exist whether or not we approve of them.
2. **The version is emitted by the writer, not stored.** `ExportSchema.version` /
   `ExportSchema.VERSION` is what goes into the file, because the version describes the shape of
   the bytes around it. A persisted `ExportManifest.schemaVersion` records which run produced a
   job and may legitimately be older.

---

## 1.0.0 — 2026-07-20

First stable version. Approved as **A1** in
[`docs/adr/ADR-0009-approvals-a1-a2-a3.md`](../../docs/adr/ADR-0009-approvals-a1-a2-a3.md);
specified in `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §22.

### Added — CSV (additive, safe for a 24-column reader)

- **`granularity`** (column 25) — `raw | second | minute | hour | day | week | month | year`, or
  empty. The time resolution the row's value describes. Empty when the row's window is not a whole
  calendar unit; an arbitrary-length interval has no honest granularity and a rounded-off guess
  would be worse than an absent one.
- **`aggregation_method`** (column 26) — `none | sum | mean | min | max | min_avg_max | duration |
  latest`, or empty. How the underlying readings were combined. `none` is an *answer* ("this is a
  single reading"); empty means the emitting path has not declared one.

The original 24 columns are unchanged and un-reordered. A consumer that selects columns by name,
or reads only the first 24 positionally, parses a 1.0.0 file correctly.

### Added — JSON bundle

The bundle envelope is specified as a real JSON Schema for the first time
(`json_bundle.schema.json`), so a consumer can validate mechanically instead of reading prose.

- `export_schema_version`, `generated_at`, and an `app` block at the envelope root.
- `dictionaries` — `metrics`, `sources`, `algorithms`, `units`, derived from the bundle's own
  contents so the file stays readable without the app or the registry.
- `workouts[]` — workout episodes as **parent objects**, promoted out of `sessions` and not
  duplicated there. Carries `hr_series_ref`, a *query descriptor* into `raw_samples` rather than a
  copy of the series, and `route_ref`, which is present only under an explicit route opt-in.
- `deletions[]` — tombstones for rows carrying a `deleted_at`, so a consumer syncing against a
  prior bundle learns a record went away instead of inferring it from absence.
- `config` — the user's export configuration, **absent rather than empty** when the emitting path
  did not supply it.
- `granularity` / `aggregation_method` on `raw_samples`, `interval_records` and `derived_values`,
  matching the new CSV columns.

### Added — manifest (§22.5)

`row_counts`, `is_delta`, `cursor_before`, `cursor_after`, `previous_manifest_sha`, `destination`
(**name and kind only — never credentials, tokens, or account identifiers**), and `encryption`
(`none | badanenc-v1`). `sample_data_row_count` is retained: it reports how many rows in the
artifact were fabricated by sample/demo mode and never measured.

### Changed — **breaking for byte-comparing consumers**

- **Public timestamps always carry a numeric offset.** A zero offset now renders `+00:00`; it
  previously rendered `Z`. Both spellings parse to the same instant under any conformant ISO-8601
  reader, so this breaks only a consumer doing literal string comparison. §22.1 requires a numeric
  offset, and one renderer serving CSV, the bundle and the manifest is what keeps the three from
  drifting apart.
- **The JSON bundle's public face is snake_case with ISO-8601 timestamps.** 0.1.0 emitted the
  domain's camelCase field names and epoch-millisecond integers — the storage shape leaking into
  the published contract. `raw_samples[].startAt: 1784509920000` is now
  `raw_samples[].start_at: "2026-07-20T03:12:00+04:00"`.
  **Internal storage is unchanged**; there is no database migration in this release. If you parse
  0.1.0 bundles, key off `export_schema_version` and branch.
- **Workout sessions moved.** They were `sessions[]` entries with a nested `detail.workout`; they
  are now `workouts[]` entries and are no longer present in `sessions[]`. `sessions[]` is sleep.
- **Number rendering is pinned and identical on both platforms.** Values are rounded to 6 decimal
  places below 1e9 and never rendered in scientific notation. Android previously fell through to
  `Double.toString()`, which emitted `1.0E-9` where iOS emitted `0`.

### Fixed

- **Android CSV output was not formula-injection-sanitized.** `metric_display`, `source_app`,
  `source_device` and `source_external_id` are now prefixed with `'` when they begin with `=`,
  `+`, `-`, `@`, tab or CR, matching iOS (DATA-13). The mitigation was documented as the writer's
  behaviour while only one writer had it, so the same store exported from an Android device
  produced a file iOS considered unsafe to open in a spreadsheet.

### Parity

`packages/fixtures/export/` is the artifact that makes "both platforms write the same bytes" a
fact rather than an intention: one frozen input record set, three goldens, read by both suites.
Three field-level divergences that could not be closed inside the writers are **declared** in that
fixture's `knownDivergences` (workout energy unit, `hr_series_ref` availability, and the manifest
sample-data counter) rather than being papered over. Each is stated with the platform behaviour
and the fix.

---

## 0.1.0 — initial

The 24-column CSV contract compiled from `BADAN_MASTER_BLUEPRINT.md` §20/§56, plus a JSON bundle
that serialized the domain entities directly (camelCase keys, epoch-millisecond timestamps) with
the manifest embedded.
