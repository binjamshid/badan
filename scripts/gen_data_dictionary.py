#!/usr/bin/env python3
"""Generate DATA_DICTIONARY.md from the export contracts and the metric registry.

EPIC-22: "every export can carry its own docs; the repo publishes the contract."

The dictionary is GENERATED, never hand-written, for the reason every generated doc exists: a
hand-written column list is correct on the day it is written and wrong on the day after the next
schema change, and nothing tells you which day you are on. Everything below is read from the
files the apps actually build against:

    packages/export-schemas/csv_columns.json     -> the CSV column contract
    packages/export-schemas/json_bundle.schema.json -> the JSON bundle envelope
    packages/metric-ontology/registry.json       -> metric ids, units, families

Usage:
    scripts/gen_data_dictionary.py            # rewrite DATA_DICTIONARY.md
    scripts/gen_data_dictionary.py --check    # fail if the file on disk is stale (CI)

`--check` is the CI mode. It regenerates in memory and diffs, so a contract change that forgets
to regenerate the dictionary fails the build with the exact command to run, rather than shipping
documentation that describes a schema BADAN no longer writes.
"""

import argparse
import difflib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CSV_COLUMNS = ROOT / "packages/export-schemas/csv_columns.json"
JSON_SCHEMA = ROOT / "packages/export-schemas/json_bundle.schema.json"
REGISTRY = ROOT / "packages/metric-ontology/registry.json"
OUTPUT = ROOT / "DATA_DICTIONARY.md"

# Arrays documented in their §22.2 reading order rather than the schema's alphabetical key order:
# someone opening a bundle for the first time reads raw before derived, and the point of this
# document is to be read.
BUNDLE_ARRAY_ORDER = [
    "raw_samples",
    "interval_records",
    "sessions",
    "workouts",
    "derived_values",
    "baselines",
    "deletions",
]


def load(path):
    if not path.is_file():
        sys.exit(f"error: {path.relative_to(ROOT)} is missing — the contract moved or vanished")
    with path.open() as handle:
        return json.load(handle)


def escape_cell(text):
    """Markdown table cells cannot contain a bare pipe or a newline."""
    return str(text).replace("|", "\\|").replace("\n", " ").strip()


def resolve(schema, node):
    """Follow a single `$ref` into `$defs`. Deliberately not a general resolver.

    The bundle schema only ever refs `#/$defs/<name>`, and a full JSON-Reference implementation
    here would be code nothing exercises — the kind that rots quietly and then mis-renders a
    contract document. If a `$ref` shape appears that this cannot follow, it fails loudly below
    rather than silently emitting an empty row.
    """
    ref = node.get("$ref")
    if not ref:
        return node
    if not ref.startswith("#/$defs/"):
        sys.exit(f"error: gen_data_dictionary cannot resolve $ref '{ref}' — extend resolve()")
    target = schema["$defs"].get(ref[len("#/$defs/"):])
    if target is None:
        sys.exit(f"error: $ref '{ref}' does not exist in $defs")
    return target


def type_of(schema, node):
    """A human-readable type for one property, including enums and consts."""
    node = resolve(schema, node)
    if "const" in node:
        return f"`{json.dumps(node['const'])}` (constant)"
    if "enum" in node:
        return " \\| ".join(f"`{v}`" for v in node["enum"])
    if "oneOf" in node:
        parts = [type_of(schema, branch) for branch in node["oneOf"]]
        return " or ".join(parts)
    declared = node.get("type")
    if isinstance(declared, list):
        return " \\| ".join(f"`{t}`" for t in declared)
    if declared == "array":
        item = node.get("items")
        return f"array of {type_of(schema, item)}" if item else "array"
    if declared == "object":
        return "object"
    return f"`{declared}`" if declared else "any"


def describe(schema, node, own_description=None):
    """The description written at the use site wins over the one on the $def it points at.

    A `$ref`'d definition says what the type IS; the property that uses it says what it MEANS
    here. `hr_series_ref` and `route_ref` both resolve to generic shapes and both carry the
    load-bearing sentence at the use site.
    """
    if own_description:
        return own_description
    return resolve(schema, node).get("description", "")


def object_table(schema, node, name):
    """One markdown table for an object definition's properties."""
    node = resolve(schema, node)
    required = set(node.get("required", []))
    properties = node.get("properties", {})
    if not properties:
        return []
    lines = [
        f"#### `{name}`",
        "",
    ]
    if node.get("description"):
        lines += [escape_cell(node["description"]), ""]
    lines += [
        "| Field | Type | Required | Notes |",
        "|---|---|---|---|",
    ]
    for key, prop in properties.items():
        lines.append(
            "| `{}` | {} | {} | {} |".format(
                key,
                type_of(schema, prop),
                "yes" if key in required else "no",
                escape_cell(describe(schema, prop, prop.get("description"))),
            )
        )
    lines.append("")
    return lines


def csv_section(columns):
    contract = columns["csvColumns"]
    lines = [
        "## 1. CSV columns",
        "",
        f"Export schema **{columns['version']}** — {len(contract)} columns, in this exact order.",
        "",
        "Line endings are CRLF (RFC 4180). The header row is always written, even for zero data",
        "rows, so an empty file is still a valid self-describing table. Numbers are",
        "locale-independent, never exponential, and rounded to 6 decimal places below 1e9 so",
        "unit-conversion float residue does not surface as spurious precision. Timestamps are",
        "ISO-8601 with a **numeric** offset (`+00:00`, never `Z`) rendered in the record's own",
        "timezone.",
        "",
        "Raw and derived rows are written to **separate files** and never share columns (invariant",
        "I5). Every row carries `value_type` and `is_derived` so the separation survives a consumer",
        "that concatenates them.",
        "",
        "| # | Column | Type | Since | Description |",
        "|---|---|---|---|---|",
    ]
    for index, column in enumerate(contract, start=1):
        enum_values = column.get("enumValues")
        type_text = f"`{column['type']}`"
        if enum_values:
            type_text += "<br>" + " \\| ".join(f"`{v}`" for v in enum_values)
        lines.append(
            "| {} | `{}` | {} | {} | {} |".format(
                index,
                column["name"],
                type_text,
                column.get("since", "0.1.0"),
                escape_cell(column["description"]),
            )
        )
    lines += ["", "### Contract notes", ""]
    for note in columns.get("notes", []):
        lines += [f"- {escape_cell(note)}"]
    lines.append("")
    return lines


def manifest_section(columns, schema):
    lines = [
        "## 2. Manifest",
        "",
        "Every artifact carries a manifest — embedded in the JSON bundle, written as",
        "`manifest.json` beside a CSV export. It makes truncation and tampering detectable and the",
        "export reproducible from its own description.",
        "",
    ]
    lines += object_table(schema, schema["$defs"]["manifest"], "manifest")
    lines += [
        "### Field summary from the CSV contract",
        "",
        "`csv_columns.json` documents the same manifest in prose; both are listed so a drift",
        "between them is visible rather than a matter of which file you happened to open.",
        "",
    ]
    for field in columns.get("manifestFields", []):
        lines.append(f"- {escape_cell(field)}")
    lines.append("")
    return lines


def bundle_section(schema):
    lines = [
        "## 3. JSON bundle",
        "",
        escape_cell(schema.get("description", "")),
        "",
        "### Envelope",
        "",
        "| Key | Type | Required | Notes |",
        "|---|---|---|---|",
    ]
    required = set(schema.get("required", []))
    for key, prop in schema["properties"].items():
        lines.append(
            "| `{}` | {} | {} | {} |".format(
                key,
                type_of(schema, prop),
                "yes" if key in required else "no",
                escape_cell(describe(schema, prop, prop.get("description"))),
            )
        )
    lines += ["", "### Record shapes", ""]
    for name in BUNDLE_ARRAY_ORDER:
        prop = schema["properties"].get(name)
        if prop is None:
            continue
        items = prop.get("items")
        if items is None:
            continue
        lines += object_table(schema, items, name + "[]")
    # The log arrays live one level down and are the sensitive-class ones, so they get their own
    # heading rather than being folded in above.
    logs = schema["properties"]["logs"]
    lines += ["#### `logs`", "", escape_cell(logs.get("description", "")), ""]
    for name, prop in logs["properties"].items():
        items = prop.get("items")
        if items is not None:
            lines += object_table(schema, items, f"logs.{name}[]")
    lines += object_table(schema, schema["$defs"]["provenance"], "provenance")
    return lines


def registry_section(registry, columns):
    metrics = registry["metrics"]
    families = {}
    for metric in metrics:
        families.setdefault(metric.get("family", "(none)"), []).append(metric)

    lines = [
        "## 4. Metrics",
        "",
        f"{len(metrics)} metrics across {len(families)} families, from",
        "`packages/metric-ontology/registry.json`. `metric_id` is the language-stable join key in",
        "every export; `canonical_unit` is what `canonical_value` is always expressed in,",
        "regardless of the unit profile applied to the `value` column. Both display names are",
        "listed because `metric_display` in a CSV follows the export's `display_language`, so a",
        "consumer holding an Arabic export needs the Arabic column to map back to a metric id.",
        "`sensitive_class` is what decides whether a metric can appear without its own opt-in.",
        "",
    ]
    for family in sorted(families):
        lines += [
            f"### `{family}`",
            "",
            "| Metric id | Canonical unit | Display units | Kind | Name (en) | Name (ar) | Sensitive class |",
            "|---|---|---|---|---|---|---|",
        ]
        for metric in sorted(families[family], key=lambda m: m["metricId"]):
            display_units = metric.get("displayUnits") or []
            lines.append(
                "| `{}` | `{}` | {} | {} | {} | {} | {} |".format(
                    metric["metricId"],
                    metric.get("canonicalUnit", ""),
                    " \\| ".join(f"`{u}`" for u in display_units) or "—",
                    escape_cell(metric.get("kind", "")),
                    escape_cell(metric.get("nameEn", "")),
                    escape_cell(metric.get("nameAr", "")),
                    escape_cell(metric.get("sensitiveClass", "")),
                )
            )
        lines.append("")
    return lines


def render():
    columns = load(CSV_COLUMNS)
    schema = load(JSON_SCHEMA)
    registry = load(REGISTRY)

    version = columns["version"]
    schema_version = schema["properties"]["export_schema_version"].get("const")
    if schema_version != version:
        sys.exit(
            f"error: csv_columns.json says export schema {version} but json_bundle.schema.json "
            f"says {schema_version} — the two halves of one contract cannot disagree"
        )

    lines = [
        "<!-- GENERATED FILE — do not edit by hand.",
        "     Run scripts/gen_data_dictionary.py after changing packages/export-schemas/ or",
        "     packages/metric-ontology/registry.json. CI runs it with --check. -->",
        "",
        "# BADAN export data dictionary",
        "",
        f"**Export schema version {version}.**",
        "",
        "This is the contract a downstream consumer — a script, a notebook, an analysis agent, a",
        "clinician's spreadsheet — can rely on. It is generated from the same files the iOS and",
        "Android apps build against, so it cannot describe a schema BADAN does not write.",
        "",
        "Versioning policy: **additive changes bump the minor** (a new column appended, a new",
        "optional key), **breaking changes bump the major** and ship migration notes in",
        "`packages/export-schemas/CHANGELOG.md`. A consumer pinned to an older minor keeps working;",
        "a consumer pinned to an older major is told exactly what moved.",
        "",
        "Raw data is never paywalled. Every column, every array and every format described here is",
        "available in every build, to every user, without a subscription.",
        "",
        "---",
        "",
    ]
    lines += csv_section(columns)
    lines += ["---", ""]
    lines += manifest_section(columns, schema)
    lines += ["---", ""]
    lines += bundle_section(schema)
    lines += ["---", ""]
    lines += registry_section(registry, columns)
    return "\n".join(lines).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail if DATA_DICTIONARY.md is stale instead of rewriting it")
    args = parser.parse_args()

    generated = render()
    if not args.check:
        OUTPUT.write_text(generated)
        print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(generated.splitlines())} lines)")
        return 0

    if not OUTPUT.is_file():
        print(f"::error::{OUTPUT.relative_to(ROOT)} is missing — run scripts/gen_data_dictionary.py")
        return 1
    current = OUTPUT.read_text()
    if current == generated:
        print(f"ok: {OUTPUT.relative_to(ROOT)} is up to date")
        return 0
    diff = difflib.unified_diff(current.splitlines(), generated.splitlines(),
                                fromfile="DATA_DICTIONARY.md (on disk)",
                                tofile="DATA_DICTIONARY.md (regenerated)", lineterm="")
    print("\n".join(list(diff)[:80]))
    print("::error::DATA_DICTIONARY.md is stale — run scripts/gen_data_dictionary.py and commit it")
    return 1


if __name__ == "__main__":
    sys.exit(main())
