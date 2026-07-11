#!/usr/bin/env bash
# Mirror the canonical ontology/insight/symptom/export data (source of truth in
# packages/) into the iOS app bundle's Resources directory. Run after editing any
# packages/ data file. Android will consume the same packages/ files via its own
# asset-copy step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/apps/ios/Sources/Resources"
mkdir -p "$DEST"
cp "$ROOT/packages/metric-ontology/registry.json"        "$DEST/registry.json"
cp "$ROOT/packages/contracts/insights/templates.json"    "$DEST/insight_templates.json"
cp "$ROOT/packages/contracts/dictionaries/symptoms.json" "$DEST/symptoms.json"
cp "$ROOT/packages/export-schemas/csv_columns.json"      "$DEST/csv_columns.json"
echo "Synced canonical data -> $DEST"
