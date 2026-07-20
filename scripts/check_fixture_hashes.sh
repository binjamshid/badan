#!/usr/bin/env bash
# Verify that every fixture named in a packages/fixtures/*/manifest.json still hashes to the
# SHA-256 the manifest records.
#
# Why this exists as a script rather than only inside the two test suites: both suites already
# check the hash before they parse a fixture, but they only run where a JVM or an iOS simulator
# is available. A mangled fixture (a text-mode checkout rewriting LF to CRLF, a bad merge, a
# well-meaning reformat of canonical-rows-v1.json) should be caught on a plain checkout too, in
# one second, naming the file — not surface later as a cross-platform "the two disagree" failure
# that sends someone hunting through Units tables for a bug that is not there.
#
# Usage:
#   scripts/check_fixture_hashes.sh            # verify; non-zero exit on any mismatch
#   scripts/check_fixture_hashes.sh --update   # rewrite the manifests' sha256 fields in place
#
# --update is for the one legitimate case: you deliberately changed a fixture's contents. It is
# NOT a way to make a failing test pass. A hash mismatch you did not intend means the fixture
# changed underneath you, and the answer is to find out how — see each fixture directory's
# README.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-verify}"

python3 - "$ROOT" "$MODE" <<'PY'
import hashlib, json, pathlib, re, sys

root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
if mode not in ("verify", "--update"):
    print(f"error: unknown argument '{mode}' (expected --update or nothing)", file=sys.stderr)
    sys.exit(2)

def entries(node):
    """Every object in the tree carrying both a 'file' and a 'sha256'.

    Walked structurally rather than by a fixed key path so this stays correct across the two
    manifest shapes already in the tree (encryption/ nests them under 'containers', the
    canonicalization set under 'files') and any third one added later without editing this
    script — a check that needs updating for every new fixture set is a check that stops being
    run for every new fixture set.
    """
    if isinstance(node, dict):
        if "file" in node and "sha256" in node:
            yield node
        for value in node.values():
            yield from entries(value)
    elif isinstance(node, list):
        for value in node:
            yield from entries(value)

manifests = sorted((root / "packages" / "fixtures").glob("*/manifest.json"))
if not manifests:
    print("::error::no packages/fixtures/*/manifest.json found — the fixture sets moved or vanished")
    sys.exit(1)

failed = updated = checked = 0
for manifest in manifests:
    raw = manifest.read_text()
    data = json.loads(raw)
    for entry in entries(data):
        target = manifest.parent / entry["file"]
        rel = target.relative_to(root)
        if not target.is_file():
            print(f"::error::{rel} is named in {manifest.relative_to(root)} but does not exist")
            failed += 1
            continue
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        checked += 1
        if digest == entry["sha256"]:
            continue
        if mode == "--update":
            # Textual substitution rather than json.dump, so the manifest's formatting, key
            # order and comments-in-note stay byte-stable and the diff is exactly one line.
            raw = raw.replace(entry["sha256"], digest)
            print(f"updated {rel}: {entry['sha256'][:12]}… -> {digest[:12]}…")
            updated += 1
        else:
            print(f"::error::{rel} does not match {manifest.relative_to(root)}: "
                  f"recorded {entry['sha256']}, found {digest}")
            failed += 1
    if mode == "--update" and raw != manifest.read_text():
        manifest.write_text(raw)

if failed:
    print(f"{failed} fixture(s) failed verification")
    sys.exit(1)
print(f"ok: {checked} fixture(s) verified across {len(manifests)} manifest(s)"
      + (f", {updated} hash(es) rewritten" if updated else ""))
PY
