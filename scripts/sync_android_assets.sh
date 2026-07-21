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
# EPIC-07: algorithm params and the sensor-quality map are shared contracts loaded exactly like
# registry.json — mirrored here so both platforms evaluate the same constants (plan §15) and show
# the same honesty labels. Destination basenames are flattened (no directory) because BundleJson
# resolves assets by bare name.
cp "$ROOT/packages/contracts/algorithms/algorithms.json" "$DEST/algorithms.json"
cp "$ROOT/packages/contracts/sensor_quality.json"        "$DEST/sensor_quality.json"
# EPIC-23: algorithms.json ALSO gets a JVM-classpath copy under src/main/resources. Assets need an
# AssetManager (an Android Context); BaselineEngine's default spec is built at a call site (the
# composition root) EPIC-23 must not modify, and the pure-JVM baseline goldens have no AssetManager
# either — a classpath resource is the one load path both take with no Context, so the app and its
# tests read byte-identical constants. AlgorithmResourceMirrorTest fails if this copy drifts from the
# assets one. Only algorithms.json needs the classpath route (it is the only asset the domain layer
# loads without a Context); the rest stay assets-only.
RES="$ROOT/apps/android/app/src/main/resources"
mkdir -p "$RES"
cp "$ROOT/packages/contracts/algorithms/algorithms.json" "$RES/algorithms.json"
echo "Synced canonical data -> $DEST (+ $RES/algorithms.json)"
