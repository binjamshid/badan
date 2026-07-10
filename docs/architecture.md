# BADAN Architecture

> Status: living document, updated 2026-07-10. Scope: the iOS flagship app plus the shared,
> cross-platform contracts. See `docs/EXECUTION_PLAN.md` for sequencing and `docs/adr/` for
> the decision records this doc references (D-1…D-11, ADR-0001…0006).

BADAN is a privacy-respecting, local-first personal health repository. One canonical data
model is rendered at two altitudes (casual / power). This document describes how the code is
organized and why.

## 1. Layer map

```
packages/                     ← shared source of truth (language-neutral)
  metric-ontology/registry.json      44 metrics: id, units, en+ar names, chart hint, sensitivity
  contracts/insights/templates.json  13 wellness-safe insight templates (en+ar) + rules
  contracts/dictionaries/symptoms.json  47-symptom localized dictionary
  export-schemas/csv_columns.json    the 24-column export contract
  contracts/src/health_contracts.md  original seed (superseded note)

apps/ios/Sources/                ← the runnable flagship (single Swift module "BADAN")
  Core/            ULID, Clock, Units, Localization (AppLanguage, LocalizedString, Loc catalog)
  Domain/          canonical entities (see §2), day-attribution, ingestion, derivation
  Ontology/        loaders that compile packages/*.json into typed registries
  Platform/Health/ HealthStorePort + FakeHealthStore (seed source) + HealthKitAdapter (boundary)
  Storage/         SQLite wrapper, Database (two files), Migrations (DDL), Repositories/
  Export/          CSV/JSON writers + ExportRunner (offline)
  DesignSystem/    tokens, theme, reusable components
  Features/        one folder per screen: <X>State/<X>ViewModel/<X>View
  App/             BADANApp entry, AppEnvironment (DI), RootView (navigation)
  Resources/       mirrored packages JSON, bundled into the app
  Tests/           domain/dedup/baseline/export/repository tests

apps/android/                 ← parallel native path (Kotlin/Compose), mirrors this architecture
backend/, infra/              ← dormant in MVP (ADR-0002)
```

Dependency direction is strictly downward: `Features → ViewModels → Repositories/Services →
Storage/Ontology → Core`. Features never touch the DB or health adapters directly (D-5).

## 2. Canonical domain (D-1)

Entities live in `apps/ios/Sources/Domain/`. The invariants (`packages/contracts/INVARIANTS.md`)
are the constitution: I1 every health datum carries full provenance · I2 derived values append,
never overwrite · I3 dedup suppresses, never deletes · I4 manual wins for weight/BP/labs, device
wins elsewhere by source priority · I5 raw and derived separable everywhere · I6 no entity
references entitlement state · I7 sensitive-plus is a separate purgeable namespace · I8 all ids
are on-device ULIDs.

- **Reference & identity:** `MetricDefinition` (from the registry), `Source`, `Device`,
  `PermissionState`, `UserProfile`.
- **Provenance:** an embedded, denormalized struct on every measurement row (D-3) — source,
  device, ingestion path, external id, batch id, three timestamps, quality flags, `suppressedBy`.
- **Measurements:** `RawSample` (instant, lineage), `IntervalRecord` (normalized daily facts,
  the default chart layer), `Session`/`SessionStage` (sleep/workout episodes with `localNight`).
- **Derivation:** `AlgorithmVersion`, `DerivedValue` (append-only, latest-read), `InputManifest`
  (what fed a value — the anatomy sheet), `Baseline` (median/MAD personal band with `position`/`z`).
- **Interpretation:** `Insight` (template-rendered, en+ar) + `InsightTemplate`.
- **Dedup:** `ReconciliationDecision` (reversible journal).
- **Logging:** `MedicationRegimen`, `AdherenceEvent`, `SymptomEntry`, `Condition` (sensitive);
  `WorkoutEntry`, `NutritionEntry`, `NoteEntry` (normal).
- **Ownership/presentation:** `ExportJob`/`ExportScope`/`ExportManifest`; `CustomizationProfile`
  (the dual-altitude switch + units + language + theme + dashboard layout); `Goal`.
- **Read model:** `TimelineEvent` (assembled at query time, not stored).

## 3. Storage (ADR-0005, D-9)

Raw SQLite via a thin wrapper (`SQLiteConnection`) — no ORM, no package dependency. Two
physical DB files: `badan.db` (main) and `badan_sensitive.db` (meds/symptoms/conditions), so
module-disable = file deletion. Migration 001 is the whole schema; forward-only, numbered.
Every row table has sync-ready convention columns and (for measurements) embedded provenance
columns. Named indexes back every hot query; identity indexes make re-ingest idempotent.

Repositories are the only code that speaks SQL. Each maps rows ↔ entities and names its index.

## 4. Ingestion → normalization → dedup

`HealthStorePort` is the seam: `FakeHealthStore` (deterministic 90-day seed, the simulator
data source) and `HealthKitAdapter` (the real integration boundary) both conform. The
`IngestionPipeline`: upserts sources/devices, normalizes DTO values to canonical SI units,
attaches provenance, upserts idempotently, computes `localNight`, then runs `DedupLite`
(sleep session-overlap ≥70%, source-priority winner) — suppressing losers and journaling a
reversible `ReconciliationDecision`. Re-running is a no-op.

## 5. Derivation & insight

`BaselineEngine` computes 14-day rolling median/MAD baselines for eligible metrics and appends
composite `DerivedValue`s (sleep efficiency, a readiness score) with input manifests. The
`InsightEngine` selects a wellness-safe template by the value's position relative to its
personal band and renders it in both languages. No LLM in MVP (deterministic templates).

## 6. Export (D-8, ADR-0002)

`ExportRunner` gathers rows honoring scope, routes measured rows and computed rows to separate
files (raw vs derived never merged), tags every row, computes SHA-256 checksums, and writes a
versioned `ExportManifest`. Fully offline; the export module imports no networking/entitlement
API. CSV follows the 24-column contract; JSON is a separated bundle.

## 7. Presentation & dual altitude (D-5)

`CustomizationProfile.depthPolicy` (casual/balanced/power) is a presentation switch over
identical queries — casual hides power affordances (raw values, lineage rows, dense tables,
algorithm strings); the numbers are the same. Language is a runtime switch that flips
`layoutDirection` (RTL) so Arabic is structural, not a restart-only locale. The DesignSystem
never moralizes state: out-of-band is one calm amber with an arrow + text, never red/green.

## 8. Android parity (ADR-0006)

Android is the next milestone, not a rewrite. It consumes the same `packages/` data, implements
the same logical schema in Room, mirrors these screens in Compose, and passes the same
conformance fixtures. The Kotlin scaffold under `apps/android/` is the starting point.

## 9. Build & run

```
cd apps/ios && xcodegen generate            # project.yml is source of truth (.xcodeproj is gitignored)
xcodebuild -scheme BADAN -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```
See `README.md` for the full developer workflow and `scripts/` for helpers.
