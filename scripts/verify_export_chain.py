#!/usr/bin/env python3
"""Verify a folder of BADAN delta-export JSON bundles forms an intact incremental chain.

EPIC-17 / §22.6. A delta export lets automation ship only what is new — but "only what is new"
is a claim a consumer has to be able to *check*, or a dropped run silently desyncs their store.
Each delta bundle's manifest therefore carries a `previous_manifest_sha` (the prior bundle's
sha256) plus `cursor_before` / `cursor_after` watermarks. This script reads a folder of those
bundles and proves three things a healthy chain must satisfy:

  1. LINKS      every non-root bundle's `previous_manifest_sha` equals sha256(the prior bundle
                file) — the hashes actually chain, so no bundle was altered in transit.
  2. NO GAPS    the bundles form a single unbroken chain: exactly one root, every other bundle
                reachable by following the links, nothing orphaned or forked.
  3. MONOTONIC  cursors never move backwards — `cursor_before[n] == cursor_after[n-1]` where both
                are present, and `cursor_after` is non-decreasing — so no run re-opened a window
                an earlier run already closed or skipped one.

A "bundle" here is any *.json file in the folder whose top-level object carries a `manifest`
object with an `export_id` (BADAN's JSON export shape). Files that don't match are ignored, so a
folder that also holds README/manifest-index files is fine.

The chain link is deliberately the sha of the *bundle file on disk*, not of the embedded manifest
object (which cannot contain its own hash). That is exactly what a consumer can recompute, so this
script and a downstream store agree by construction.

Usage:
    verify_export_chain.py <folder> [--json]

Exit code 0 when the chain verifies, 1 when it does not (or on a usage error). `--json` prints a
machine-readable result instead of human text; either way a failure lists every problem found, not
just the first.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path


def _instant(value: str | None) -> datetime | None:
    """Parse a §22.1 timestamp into an aware datetime, or None if it isn't one.

    Cursors are compared as INSTANTS, not as strings. BADAN renders both manifest cursors in UTC
    today, where lexical order happens to equal chronological order — but that is a property of the
    current writer, not of the contract (§22.1 timestamps carry their original offset), and a
    string comparison would silently call `…T10:40:00+02:00` "later than" the identical instant
    written `…T08:40:00+00:00`. Parsing costs nothing and cannot be wrong for the right reason.
    """
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


@dataclass
class Bundle:
    """One parsed delta bundle: its file, its own sha256, and the manifest fields the chain needs."""
    path: Path
    sha256: str
    export_id: str
    is_delta: bool
    cursor_before: str | None
    cursor_after: str | None
    previous_manifest_sha: str | None
    generated_at: str | None


@dataclass
class Result:
    ok: bool
    order: list[str] = field(default_factory=list)  # export_ids in chain order
    errors: list[str] = field(default_factory=list)
    count: int = 0


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _load_bundle(path: Path) -> Bundle | None:
    """Parse one file as a BADAN JSON bundle, or return None if it isn't one.

    A parse error on a *.json that looks like a bundle is reported by the caller as a hard error;
    a file that simply isn't a bundle (no `manifest.export_id`) is silently skipped.
    """
    try:
        doc = json.loads(path.read_bytes())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(doc, dict):
        return None
    manifest = doc.get("manifest")
    if not isinstance(manifest, dict) or "export_id" not in manifest:
        return None
    return Bundle(
        path=path,
        sha256=_sha256_file(path),
        export_id=str(manifest.get("export_id")),
        is_delta=bool(manifest.get("is_delta", False)),
        cursor_before=manifest.get("cursor_before"),
        cursor_after=manifest.get("cursor_after"),
        previous_manifest_sha=manifest.get("previous_manifest_sha"),
        generated_at=manifest.get("generated_at"),
    )


def verify_folder(folder: Path) -> Result:
    if not folder.is_dir():
        return Result(ok=False, errors=[f"not a directory: {folder}"])

    bundles = [b for b in (_load_bundle(p) for p in sorted(folder.glob("*.json"))) if b is not None]
    if not bundles:
        return Result(ok=False, errors=[f"no JSON export bundles found in {folder}"])

    errors: list[str] = []
    by_sha: dict[str, Bundle] = {}
    for b in bundles:
        if b.sha256 in by_sha:
            # Two byte-identical bundles: the chain can't be a line if a node has two identities.
            errors.append(
                f"duplicate bundle bytes: {b.path.name} and {by_sha[b.sha256].path.name} "
                f"have the same sha256 {b.sha256}"
            )
        by_sha[b.sha256] = b

    # A "root" is a bundle whose predecessor is not in this folder — either it declares no
    # previous_manifest_sha (a fresh chain, or a post-"re-export everything" restart) or it points at
    # a bundle outside the folder. The latter is only legitimate for ONE bundle (the chain's window
    # starting mid-history); a second one means a link is dangling — a gap or a tampered file.
    declared_roots = [b for b in bundles if not b.previous_manifest_sha]
    dangling = [b for b in bundles if b.previous_manifest_sha and b.previous_manifest_sha not in by_sha]
    roots = declared_roots + dangling

    if len(roots) != 1:
        # Name the actual defect per bundle rather than only "N roots" — a dangling
        # previous_manifest_sha is a missing or altered predecessor, which is what the reader needs.
        for b in dangling:
            errors.append(
                f"{b.path.name}: previous_manifest_sha {b.previous_manifest_sha} matches no bundle in "
                f"the folder — the predecessor is missing (gap) or a file was altered"
            )
        if len(declared_roots) > 1:
            names = ", ".join(sorted(r.path.name for r in declared_roots))
            errors.append(
                f"{len(declared_roots)} bundles declare no previous_manifest_sha ({names}) — "
                f"a folder holding more than one chain start is not a single chain"
            )
        if not roots:
            errors.append("no chain root: every bundle chains to another (the links form a cycle)")
        errors.append(f"expected exactly one chain root, found {len(roots)} — the folder is not a single chain")
        # Without a unique root there is no defined order to walk; report what we have.
        return Result(ok=False, errors=errors, count=len(bundles))

    # Walk forward from the root, following previous_manifest_sha links (child.prev == parent.sha).
    children_by_prev: dict[str, list[Bundle]] = {}
    for b in bundles:
        if b.previous_manifest_sha:
            children_by_prev.setdefault(b.previous_manifest_sha, []).append(b)

    chain: list[Bundle] = []
    current: Bundle | None = roots[0]
    seen: set[str] = set()
    while current is not None:
        if current.sha256 in seen:
            errors.append(f"cycle detected at {current.path.name}")
            break
        seen.add(current.sha256)
        chain.append(current)
        nexts = children_by_prev.get(current.sha256, [])
        if len(nexts) > 1:
            names = ", ".join(sorted(n.path.name for n in nexts))
            errors.append(f"fork after {current.path.name}: {len(nexts)} bundles chain to it ({names})")
            break
        current = nexts[0] if nexts else None

    if len(chain) != len(bundles) and not any("fork" in e or "cycle" in e for e in errors):
        unreached = sorted(b.path.name for b in bundles if b.sha256 not in seen)
        errors.append(f"{len(unreached)} bundle(s) not part of the chain from the root: {', '.join(unreached)}")

    # Cursor monotonicity along the walked chain.
    for parent, child in zip(chain, chain[1:]):
        # The link itself (redundant with the walk, asserted explicitly for a clear message).
        if child.previous_manifest_sha != parent.sha256:
            errors.append(
                f"{child.path.name}: previous_manifest_sha {child.previous_manifest_sha} "
                f"does not equal sha256({parent.path.name}) = {parent.sha256}"
            )
        # A watermark that is present but unparseable is a defect in its own right: every later
        # check would silently skip it and the run would pass on a file nobody can interpret.
        for bundle, field_name, raw in ((parent, "cursor_after", parent.cursor_after),
                                        (child, "cursor_before", child.cursor_before),
                                        (child, "cursor_after", child.cursor_after)):
            if raw is not None and _instant(raw) is None:
                errors.append(f"{bundle.path.name}: {field_name} {raw!r} is not an ISO-8601 timestamp")
        parent_after = _instant(parent.cursor_after)
        child_before = _instant(child.cursor_before)
        child_after = _instant(child.cursor_after)
        # cursor_before[n] must meet cursor_after[n-1] where both sides declare a watermark. A
        # parent that carried no rows (cursor_after null) leaves the boundary undefined — skip it
        # rather than invent a mismatch.
        if parent_after is not None and child_before is not None:
            if child_before != parent_after:
                errors.append(
                    f"{child.path.name}: cursor_before {child.cursor_before} != previous "
                    f"cursor_after {parent.cursor_after} — the window skipped or overlapped"
                )
        # cursor_after must never move backwards across the chain.
        if parent_after is not None and child_after is not None:
            if child_after < parent_after:
                errors.append(
                    f"{child.path.name}: cursor_after {child.cursor_after} is before previous "
                    f"cursor_after {parent.cursor_after} — the cursor moved backwards"
                )

    return Result(ok=not errors, order=[b.export_id for b in chain], errors=errors, count=len(bundles))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Verify a folder of BADAN delta-export bundles chains intact.")
    parser.add_argument("folder", type=Path, help="folder containing the delta *.json bundles")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable JSON result")
    args = parser.parse_args(argv)

    result = verify_folder(args.folder)

    if args.json:
        print(json.dumps({"ok": result.ok, "count": result.count, "order": result.order, "errors": result.errors}))
    elif result.ok:
        print(f"OK — {result.count} bundle(s) form an intact delta chain.")
        for i, export_id in enumerate(result.order):
            print(f"  [{i}] {export_id}")
    else:
        print(f"FAIL — chain did not verify ({result.count} bundle(s) inspected):", file=sys.stderr)
        for e in result.errors:
            print(f"  - {e}", file=sys.stderr)

    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
