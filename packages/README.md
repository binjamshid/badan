# packages/ — Shared source of truth

Language-neutral contracts and data consumed by **both** the iOS and Android apps. A metric,
symptom, insight, or export column is authored **once** here and mirrored into each app.

| File | Purpose | Consumed as |
|---|---|---|
| `metric-ontology/registry.json` | 75 metrics: dot-namespaced id, family, kind, canonical + display units, en/ar names, casual/precise labels, chart hint, baseline eligibility, sensitivity, explainer | iOS `MetricRegistry`; Android `MetricRegistry` (asset, loaded via framework SQLite — **not Room**, see ADR-0007) |
| `contracts/insights/templates.json` | 13 deterministic, wellness-safe insight templates (en/ar) + wellness-language rules | iOS `InsightTemplateStore`; Android equivalent |
| `contracts/dictionaries/symptoms.json` | 47-symptom localized dictionary (id, en/ar, category) | iOS `SymptomDictionary`; Android equivalent |
| `export-schemas/csv_columns.json` | The frozen 26-column export contract (name, type, description) + 23 manifest fields + separation policy notes | iOS `CSVWriter`; Android writer |
| `metric-ontology/src/metric_families.md` | Human notes on families | reference |
| `contracts/src/health_contracts.md` | Original entity seed (superseded; see EXECUTION_PLAN §3 rename map) | historical |
| `export-schemas/src/export_bundle.md` | Original export notes | reference |

## Editing workflow

1. Edit the JSON here (this is the source of truth).
2. Run `scripts/sync_ios_resources.sh` to mirror into `apps/ios/Sources/Resources/`.
3. (Android) the asset-copy step mirrors the same files into the Android assets.

## Invariants

The canonical entity names, the ULID/timestamp/tombstone conventions, and the I1–I8 invariants
that all of this data serves are documented in `EXECUTION_PLAN.md §3` and `docs/adr/`. These
files must never encode entitlement state (I6) and must keep en+ar parity for every user-facing
string.
