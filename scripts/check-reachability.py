#!/usr/bin/env python3
"""Fails when a top-level SwiftUI View/Screen type is never constructed anywhere outside its own
#Preview block or its own test target.

Why this exists: adapted from `ghawazi/scripts/check-reachability.py`, written after that repo's
portfolio review found features that shipped compiled, tested, and localized but were constructed
NOWHERE except their own `#Preview` — wired to nothing a user or Apple could ever reach. Human
review does not catch this reliably (grep finds the type; nothing but actually tapping through the
app finds the missing navigation path), so this is a build-time check, not a checklist item. BADAN
has no equivalent audit finding yet, but the failure mode is generic to any SwiftUI codebase with
more than a handful of screens, so this check is added proactively as a ratchet rather than reactively
after a real incident.

What it does: enumerates every top-level `struct X: ...View...` declaration under BADAN's shipping
iOS source set (`apps/ios/App` + `apps/ios/Sources` — the same tree `apps/ios/project.yml`'s BADAN
target compiles, see its `sources:` list), then for each one searches that same source set — with
every `#Preview { ... }` block's body stripped out first — for a construction site (`X(`). A type
with zero such sites is UNREACHABLE: nothing outside its own preview (and nothing in `apps/ios/Tests`,
which lives outside this source set already) ever builds one.

It is a RATCHET: BASELINE records today's known-unreachable count. CI fails only if the count goes
UP. Lower BASELINE by hand whenever a fix lands; never raise it to make CI pass.

LIMITS OF THIS CHECK — false negatives (reachable views wrongly missed) are the failure direction
this check biases against, at the cost of occasional false positives it can't help:
  - Pure TEXT search, not an AST: a construction mentioned only in a `// comment` or a doc string
    still counts as "reachable". This can only hide a real gap, never invent one.
  - A view built via runtime reflection / a string-keyed router table (no literal `TypeName(` in
    source) would show up as unreachable even if it IS wired. Use the allowlist for that.
  - A type used only as a *generic parameter* or *type annotation* (never constructed) still needs
    a real `TypeName(` call site somewhere to count as reachable — by design: SwiftUI views exist to
    be instantiated, so a type that is only ever named, never built, has not shipped a reachable
    screen.
  - Root screens legitimately constructed only by a navigation-destination closure keyed on an enum
    case, or only from `App`'s scene graph (BADAN has exactly one `@main App` entry point, e.g.
    `BadanApp`), are real reachability, not a false positive — but this checker's plain `TypeName(`
    search still finds them as long as the literal name appears at the call site, which it does for
    every pattern in this codebase today.

Usage:
  scripts/check-reachability.py            # ratchet check (CI)
  scripts/check-reachability.py --list     # print every unreachable (non-allowlisted) view, file:line
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Shipping Swift: the BADAN app target's own source set per `apps/ios/project.yml`
# (`targets.BADAN.sources: [App, Sources]`, both rooted at `apps/ios/`).
SOURCE_DIRS = ["apps/ios/App", "apps/ios/Sources"]

# Deep-link-only / dynamically-constructed surfaces this check cannot see a literal call site for
# (see LIMITS above). One bare type name per line; '#' starts a trailing or whole-line comment. Keep
# this list narrow and justified — it is a permanent exemption, not a snooze button for a real gap.
ALLOWLIST_PATH = ROOT / "scripts" / "reachability-allowlist.txt"

# Known-unreachable count, set from the actual count at the 2026-07-22 baselining run: BADAN's 90
# top-level View types were ALL reachable at baselining time (0 unreachable) — an honest zero, not
# a placeholder. Lower this by hand whenever it would go lower (it can't); it must never be raised
# to make CI pass.
BASELINE = 0

TOP_LEVEL_VIEW_RE = re.compile(
    r"^struct\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*:\s*(?P<conformances>[^{]*)\{",
    re.MULTILINE,
)
# `#Preview` (SwiftUI's iOS 17+ preview macro) with an optional argument list, e.g. `#Preview("Dark") {`.
PREVIEW_START_RE = re.compile(r"#Preview(?:\([^)]*\))?\s*\{")


# A construction site is `Name(` — or `Name {`, which is what a SwiftUI view built with ONLY a
# trailing closure looks like: there are no parentheses in the call at all.
#
# (2026-08-06) Searching just `Name(` produced a FALSE POSITIVE, which is the direction that makes a
# ratchet untrustworthy — a wired screen reported as dead code invites the next person to lower the
# bar or allowlist a real gap. `IntervalPlanBuilderScreen { plan in ... }`, wired at
# `WorkoutHomeScreen`'s navigation-destination switch, is reachable and was flagged. Any view whose
# only call site passes a trailing closure had the same problem.
#
# `Name {` must not let a type satisfy its own declaration: `struct Name: View {` and
# `extension Name {` both end in those same two tokens. Both are excluded by looking at what
# immediately precedes the name, which is also why this stays a false-POSITIVE-averse check —
# an unrecognised construction form can only over-report, never hide real dead code.
DECL_KEYWORD_RE = re.compile(r"\b(?:struct|class|enum|protocol|actor|extension)\s+$")


def is_constructed(name: str, text: str) -> bool:
    """Whether `text` contains a construction of `name`, ignoring its own declaration/extensions."""
    pattern = re.compile(r"\b" + re.escape(name) + r"\s*[({]")
    for match in pattern.finditer(text):
        prefix = text[max(0, match.start() - 40):match.start()]
        if DECL_KEYWORD_RE.search(prefix):
            continue
        return True
    return False


def find_swift_files() -> list[Path]:
    files: list[Path] = []
    for rel in SOURCE_DIRS:
        base = ROOT / rel
        if not base.is_dir():
            continue
        files.extend(sorted(base.rglob("*.swift")))
    return files


def strip_preview_blocks(text: str) -> str:
    """Return `text` with every `#Preview { ... }` block BODY removed (brace-matched, so nested braces in
    the preview body don't truncate early), so a construction site that exists only inside a preview does
    not count as "reachable"."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        m = PREVIEW_START_RE.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i:m.start()])
        depth = 1
        j = m.end()  # just past the opening '{'
        while j < n and depth > 0:
            c = text[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        i = j  # resume scanning after the matched (and now-dropped) preview block
    return "".join(out)


def load_allowlist() -> set[str]:
    if not ALLOWLIST_PATH.exists():
        return set()
    names: set[str] = set()
    for line in ALLOWLIST_PATH.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def main() -> int:
    list_mode = "--list" in sys.argv[1:]
    files = find_swift_files()
    if not files:
        print("check-reachability: no Swift sources found under", SOURCE_DIRS, "- nothing to check.")
        return 0

    # Pass 1: enumerate every top-level `struct X: ...View...` and where it's declared.
    declarations: dict[str, tuple[Path, int]] = {}
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in TOP_LEVEL_VIEW_RE.finditer(text):
            conformances = m.group("conformances")
            if not re.search(r"\bView\b", conformances):
                continue
            name = m.group("name")
            line_no = text.count("\n", 0, m.start()) + 1
            # First declaration wins if a name is (unusually) declared twice; either way it is enumerated.
            declarations.setdefault(name, (path, line_no))

    # Pass 2: build the preview-stripped corpus once, then search it for each declared name's construction.
    stripped_by_file: dict[Path, str] = {}
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        stripped_by_file[path] = strip_preview_blocks(text)

    unreachable: list[tuple[str, Path, int]] = []
    for name, (decl_path, decl_line) in sorted(declarations.items()):
        reachable = any(is_constructed(name, stripped_by_file[p]) for p in files)
        if not reachable:
            unreachable.append((name, decl_path, decl_line))

    allowlist = load_allowlist()
    unknown_allowlist_entries = allowlist - {n for n, _, _ in unreachable} - set(declarations.keys())
    violations = [(n, p, ln) for (n, p, ln) in unreachable if n not in allowlist]

    if list_mode:
        for n, p, ln in unreachable:
            tag = "ALLOWLISTED" if n in allowlist else "VIOLATION  "
            print(f"{tag}  {n}  {p.relative_to(ROOT)}:{ln}")
        print()

    print(f"Top-level View types: {len(declarations)}")
    print(f"Unreachable (no construction outside #Preview): {len(unreachable)} "
          f"({len(unreachable) - len(violations)} allowlisted, {len(violations)} counted)")
    print(f"Baseline: {BASELINE}")

    if unknown_allowlist_entries:
        print("NOTE: reachability-allowlist.txt lists name(s) that are not (or no longer) unreachable — "
              "harmless, but consider pruning: " + ", ".join(sorted(unknown_allowlist_entries)))

    if len(violations) > BASELINE:
        print(f"FAIL: {len(violations) - BASELINE} NEW unreachable View(s) since the baseline.")
        print("Wire each into a real navigation path (or add it to scripts/reachability-allowlist.txt "
              "with a reason, if it is genuinely deep-link-only). Run with --list to see them all.")
        return 1
    if len(violations) < BASELINE:
        print(f"Baseline is stale: {len(violations)} < {BASELINE}. Lower BASELINE in this script to "
              f"{len(violations)} to lock the gain in.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
