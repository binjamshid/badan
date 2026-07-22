#!/usr/bin/env bash
# Mirror the canonical ontology/insight/symptom/export data (source of truth in
# packages/) into the iOS app bundle's Resources directory. Run after editing any
# packages/ data file. Android will consume the same packages/ files via its own
# asset-copy step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/apps/ios/Sources/Resources"
mkdir -p "$DEST"

# Copy a canonical file and verify the destination actually landed (non-empty), so a silent
# cp edge-case failure can't masquerade as a successful sync.
sync_file() {
  local src="$1" dest="$2"
  cp "$src" "$dest"
  if [ ! -s "$dest" ]; then
    echo "error: $dest is missing or empty after copying from $src" >&2
    exit 1
  fi
}

sync_file "$ROOT/packages/metric-ontology/registry.json"        "$DEST/registry.json"
sync_file "$ROOT/packages/contracts/insights/templates.json"    "$DEST/insight_templates.json"
sync_file "$ROOT/packages/contracts/dictionaries/symptoms.json" "$DEST/symptoms.json"
# EPIC-38: the curated bilingual beverage vocabulary the hydration quick-log picks from.
sync_file "$ROOT/packages/contracts/dictionaries/beverages.json" "$DEST/beverages.json"
# EPIC-29: the curated bilingual behavior vocabulary the daily journal's chips draw from. The
# DICTIONARY is shipped data (not sensitive — it names what is loggable, not what was logged);
# the journal ROWS that reference it are sensitive-plus and live in badan_sensitive.db.
sync_file "$ROOT/packages/contracts/dictionaries/behaviors.json" "$DEST/behaviors.json"
sync_file "$ROOT/packages/export-schemas/csv_columns.json"      "$DEST/csv_columns.json"
# EPIC-07: algorithm params and the sensor-quality map are shared contracts loaded exactly like
# registry.json — mirrored here so both platforms evaluate the same constants (plan §15) and show
# the same honesty labels. Destination basenames are flattened (no directory) because BundleJSON
# resolves resources by bare name.
sync_file "$ROOT/packages/contracts/algorithms/algorithms.json" "$DEST/algorithms.json"
sync_file "$ROOT/packages/contracts/sensor_quality.json"        "$DEST/sensor_quality.json"
# EPIC-42: the activity/workout taxonomy (29 modalities as shipped — the plan's own "28-modality"
# label is a round number, not a hard count) the workout OS's activity picker and per-modality
# metric bundles read from.
sync_file "$ROOT/packages/contracts/dictionaries/activities.json" "$DEST/activities.json"
# EPIC-28/42: the curated bilingual strength-movement dictionary the set logger's movement
# picker draws from (dictionary-vs-custom split, same as beverages.json/behaviors.json).
sync_file "$ROOT/packages/contracts/dictionaries/movements.json" "$DEST/movements.json"
# EPIC-41 (Phase 3E, lab notebook MVP): the curated bilingual analyte ontology + its unit
# vocabulary. Same dictionary-vs-custom split as beverages.json/behaviors.json/movements.json — an
# analyte not listed here is still fully loggable via LabResult.customLabel, never blocked.
sync_file "$ROOT/packages/contracts/analytes/analytes.json" "$DEST/analytes.json"
sync_file "$ROOT/packages/contracts/analytes/units.json"    "$DEST/lab_units.json"
echo "Synced canonical data -> $DEST"
