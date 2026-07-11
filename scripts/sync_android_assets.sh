#!/usr/bin/env bash
# Mirror the canonical ontology/insight/symptom/export data (source of truth in packages/)
# into the Android app's assets. Run after editing any packages/ data file. The iOS mirror is
# scripts/sync_ios_resources.sh — both platforms consume the same packages/ files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/apps/android/app/src/main/assets"
mkdir -p "$DEST"
cp "$ROOT/packages/metric-ontology/registry.json"        "$DEST/registry.json"
cp "$ROOT/packages/contracts/insights/templates.json"    "$DEST/insight_templates.json"
cp "$ROOT/packages/contracts/dictionaries/symptoms.json" "$DEST/symptoms.json"
cp "$ROOT/packages/export-schemas/csv_columns.json"      "$DEST/csv_columns.json"
echo "Synced canonical data -> $DEST"
