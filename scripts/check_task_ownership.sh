#!/usr/bin/env bash
# Fail if the working tree has any changed or untracked file outside a task's declared owned
# paths. This is the PRIMARY guard for the Android parity port's "one agent owns one area" rule
# (see docs/android-port-conventions.md, section 2) — the frozen-file check
# (scripts/check_frozen_files.sh) is the backstop, not the mechanism. A frozen-file list only
# catches an edit to a file someone remembered to list; this check catches an edit to ANY file
# outside a task's declared scope, named in advance or not, which is the failure mode that
# actually happens.
#
# Declare owned paths either way — whichever is cleaner for the calling agent:
#
#   scripts/check_task_ownership.sh path/to/owned-paths.txt
#   TASK_OWNED_PATHS=$'path/one.kt\npath/two/\napps/android/**/CycleStrings.kt' scripts/check_task_ownership.sh
#
# Each entry is exactly ONE PER LINE — never space-separated on one line, because a real path in
# this repo can contain a space (e.g. "badan design pt/"), and splitting on whitespace would
# silently shred it into unmatched fragments. Each entry is one of:
#   - an exact file path                 docs/android-port-conventions.md
#   - a directory prefix (trailing "/")  apps/android/app/src/main/java/net/albayyan/badan/features/cycle/
#   - a glob                             apps/android/**/CycleStrings.kt   (** and * behave the same — both
#                                         match across path separators)
# Blank lines and lines starting with # are ignored, so an owned-paths file can carry comments.
#
# The changed-file set is `git status --porcelain=v1 -z`, not `git diff --name-only` — the -z
# form is used so this is correct on filenames with spaces/newlines, and --porcelain (rather than
# a diff against HEAD) is used specifically so brand-new, never-added files are caught too. A task
# that creates a file outside its scope is exactly as much a violation as one that edits an
# existing file outside its scope.
#
# Deliberately NOT `-uall`: on a large monorepo that mode walks every untracked directory in full,
# which is slow and can spike memory on CI runners. The tradeoff is that git collapses a brand-new
# (entirely untracked) directory to ONE line for the directory itself rather than one line per
# file inside it. Practical effect: if your task introduces a new directory, declare the
# directory (trailing "/") in your owned paths, not just the individual files inside it — once
# any file in that directory is tracked (e.g. after your first commit), git stops collapsing it
# and reports files individually, at which point per-file entries also work.
#
# Exit codes: 0 clean, 1 an out-of-scope path was found, 2 usage error (no owned paths given).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PATHS_FILE="${1:-}"
if [ -n "$PATHS_FILE" ]; then
  if [ ! -f "$PATHS_FILE" ]; then
    echo "error: owned-paths file '$PATHS_FILE' not found" >&2
    exit 2
  fi
  TASK_OWNED_PATHS="$(cat "$PATHS_FILE")"
  export TASK_OWNED_PATHS
elif [ -n "${TASK_OWNED_PATHS:-}" ]; then
  export TASK_OWNED_PATHS
else
  echo "usage: $(basename "$0") <owned-paths-file>" >&2
  echo "   or: TASK_OWNED_PATHS=\$'path/one\\npath/two/' $(basename "$0")" >&2
  echo >&2
  echo "No owned paths were given — nothing to check against. This is a usage error, not a" >&2
  echo "pass: a task must declare its scope before this script can do anything." >&2
  exit 2
fi

python3 - <<'PY'
import fnmatch
import os
import subprocess
import sys

owned_raw = os.environ["TASK_OWNED_PATHS"]
owned = []
for line in owned_raw.splitlines():
    # Only strip trailing newline/CR artifacts, not internal spaces — a path may legitimately
    # contain one (e.g. "badan design pt/"). Leading/trailing whitespace around the path itself
    # is still trimmed since it's never meaningful in a pathspec.
    line = line.strip("\r\n").strip()
    if not line or line.startswith("#"):
        continue
    owned.append(line)

if not owned:
    print("usage error: TASK_OWNED_PATHS/owned-paths file contained no entries", file=sys.stderr)
    sys.exit(2)


def matches(changed_path, pattern):
    if any(ch in pattern for ch in "*?["):
        # ** and * are equivalent here: fnmatch's "*" already matches across "/" (it has no
        # directory-aware special-casing), so there is nothing extra "**" needs to do.
        return fnmatch.fnmatch(changed_path, pattern.replace("**", "*"))
    normalized = pattern.rstrip("/")
    return changed_path == normalized or changed_path.startswith(normalized + "/")


# git status --porcelain=v1 -z: NUL-separated records. A rename/copy record is TWO consecutive
# NUL-terminated fields — "XY newpath" followed by a bare "oldpath" with no status prefix — so
# both the new and old location are checked against the owned scope.
out = subprocess.run(
    ["git", "status", "--porcelain=v1", "-z"],
    capture_output=True, text=True, check=True,
).stdout
tokens = out.split("\0")
if tokens and tokens[-1] == "":
    tokens.pop()

changed = []
i = 0
while i < len(tokens):
    tok = tokens[i]
    code, path = tok[:2], tok[3:]
    changed.append(path)
    if code[0] in ("R", "C") or code[1] in ("R", "C"):
        i += 1
        if i < len(tokens):
            changed.append(tokens[i])
    i += 1

offending = sorted({p for p in changed if not any(matches(p, pat) for pat in owned)})

if offending:
    print("::error::OWNERSHIP VIOLATION — this task's working-tree diff touches file(s) outside "
          "its declared owned paths.")
    print()
    print("Declared scope:")
    for pat in owned:
        print(f"  - {pat}")
    print()
    print("Out-of-scope file(s):")
    for p in offending:
        print(f"  - {p}")
    print()
    print("This file belongs to another task's area (or to no task's declared scope at all).")
    print("STOP AND REPORT. Do not edit it to work around this failure, and do not widen your")
    print("declared scope to cover it after the fact — that defeats the check. If your task")
    print("genuinely must change a file outside its scope, that is a magnet-amendment task run")
    print("solo at a barrier, not a change you make inside this task.")
    sys.exit(1)

print(f"ownership OK — {len(changed)} changed path(s), all within declared scope ({len(owned)} "
      f"pattern(s))")
PY
