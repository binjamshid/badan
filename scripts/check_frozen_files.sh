#!/usr/bin/env bash
# Fail if any path listed in scripts/frozen-files.txt differs from the `android-port-scaffold`
# baseline tag. This is the BACKSTOP for the Android parity port's ownership rule — it only
# catches an edit to a file someone remembered to list. The PRIMARY control is
# scripts/check_task_ownership.sh, which catches an edit to any out-of-scope file, listed or not.
# See docs/android-port-conventions.md, section 2, for why the two are ordered that way.
#
# Usage:
#   scripts/check_frozen_files.sh [baseline-ref]
#
# baseline-ref defaults to the tag `android-port-scaffold`, cut once Batch 1 of the port lands
# every magnet file in its final, registry-based shape. Until Batch 1 cuts that tag, there is
# nothing to diff against — this script detects that and degrades to a no-op (exit 0) with a
# clear message, rather than failing every task that runs it before Batch 1 exists.
#
# Exit codes: 0 clean (or ref doesn't exist yet), 1 a frozen file changed, 2 usage/setup error.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FROZEN_LIST="scripts/frozen-files.txt"
REF="${1:-android-port-scaffold}"

if [ ! -f "$FROZEN_LIST" ]; then
  echo "error: $FROZEN_LIST not found" >&2
  exit 2
fi

PATHSPECS=()
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  PATHSPECS+=("$line")
done < "$FROZEN_LIST"

if [ "${#PATHSPECS[@]}" -eq 0 ]; then
  echo "$FROZEN_LIST has no active entries — nothing to check"
  exit 0
fi

if ! git rev-parse --verify --quiet "$REF" >/dev/null 2>&1; then
  echo "scripts/check_frozen_files.sh: baseline ref '$REF' does not exist yet."
  echo "This is expected before Batch 1 of the Android parity port cuts the '$REF' tag — there is"
  echo "nothing to diff a frozen file against yet, so this check degrades to a no-op rather than"
  echo "failing every task that runs it ahead of Batch 1. Once Batch 1 lands and tags '$REF',"
  echo "this check starts enforcing for real."
  exit 0
fi

if ! git diff --exit-code "$REF" -- "${PATHSPECS[@]}"; then
  echo >&2
  echo "::error::one or more frozen files (see $FROZEN_LIST) differ from '$REF' — diff above." >&2
  echo "These files were deliberately rewritten into their final, registry-based shape by Batch 1" >&2
  echo "and frozen so no two concurrent tasks collide on them. Editing one is a magnet-amendment" >&2
  echo "task, run solo at a batch barrier with the scaffold tag re-cut afterwards — not a change" >&2
  echo "made inside a normal task. STOP AND REPORT." >&2
  exit 1
fi

echo "frozen files unchanged since '$REF' (${#PATHSPECS[@]} path(s) checked)"
