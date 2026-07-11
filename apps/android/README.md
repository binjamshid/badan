# BADAN Android

The native **Kotlin / Jetpack Compose** parallel path. Currently a scaffold; it is the next
milestone (ADR-0006), not a rewrite — it consumes the **same shared truth** as iOS and mirrors
the same architecture, so parity is structural.

## What Android reuses (no re-authoring)

Everything language-neutral in `packages/` is the single source of truth for both apps:

| Shared artifact | iOS consumes as | Android consumes as |
|---|---|---|
| `packages/metric-ontology/registry.json` | `MetricRegistry` | `MetricRegistry` (bundled asset) |
| `packages/contracts/insights/templates.json` | `InsightTemplateStore` | insight template store |
| `packages/contracts/dictionaries/symptoms.json` | `SymptomDictionary` | symptom dictionary |
| `packages/export-schemas/csv_columns.json` | `CSVWriter` | CSV writer |
| The logical schema (`docs/data-model.md`) | raw SQLite (`Database`) | **Room** (same table/column names) |
| Invariants I1–I8, ADRs, vertical slices | — | — |

An asset-copy step (mirroring `scripts/sync_ios_resources.sh`) copies the `packages/` JSON into
`app/src/main/assets/`.

## Mapping the iOS architecture to Android

| iOS | Android |
|---|---|
| SwiftUI + `@Observable` view models | Compose + `ViewModel` + `StateFlow` |
| raw SQLite via `SQLiteConnection` | Room (same DDL; schemas exported to `schemas/` for migration tests) |
| `HealthStorePort` + `FakeHealthStore` + `HealthKitAdapter` | same port; `FakeHealthStore` + `HealthConnectAdapter` |
| `IngestionPipeline` / `DedupLite` / `BaselineEngine` | mirrored (duplicated-logic budget, D-4) |
| two DB files (`badan.db` + `badan_sensitive.db`) | two Room databases |
| `CustomizationProfile.depthPolicy` dual-altitude | same presentation switch |

## Conformance parity

A behavior "exists" only when both platforms pass the same fixtures (the drift firewall). The
iOS unit/pipeline tests (`apps/ios/Tests/`) define the expected canonical rows, dedup outcomes,
baseline numerics, and export bytes that the Android suite must reproduce identically.

## Build (once the Gradle project is added)

The current `app/src/main/java/com/badan/app/` tree holds Compose scaffolds (shell + Home /
Metrics→Body / Log / Settings). Bringing it to parity means: Gradle bootstrap
(`settings.gradle.kts`, `build.gradle.kts`, version catalog, wrapper), Room storage + the same
migration 001, the Health Connect adapter, and the mirrored screens — see EXECUTION_PLAN §11
(AP-06/08/10/12) for the packet breakdown.
