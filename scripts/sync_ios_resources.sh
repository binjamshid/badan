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
sync_file "$ROOT/packages/export-schemas/csv_columns.json"      "$DEST/csv_columns.json"
echo "Synced canonical data -> $DEST"
