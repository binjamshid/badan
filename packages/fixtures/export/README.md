# Cross-platform export fixtures

These files are what makes "the same store and scope produce byte-identical output on both
platforms" a fact rather than an intention. One frozen input, three goldens, read from the repo by
**both** suites:

| File | Role |
|---|---|
| `export-input-v1.json` | the shared **input** — records, manifest fields, and the primitive cases |
| `bundle-v1.json` | the exact bytes `JSONBundleWriter` / `JsonBundleWriter` must produce |
| `raw-v1.csv` | the exact bytes `CSVWriter` / `CsvWriter` must produce for the raw rows |
| `derived-v1.csv` | the same, for the derived rows (I5: never the same file as raw) |

| Read by | Asserts |
|---|---|
| `apps/ios/Tests/ExportSchemaParityTests.swift` | the input, through iOS's writers, produces the goldens byte for byte |
| `apps/android/app/src/test/java/net/albayyan/badan/ExportSchemaParityTest.kt` | the same input, through Android's writers, produces the same bytes |

Neither side may copy the records or the goldens into its own source. A copy is one more thing
that can drift from the artifact it is supposed to police — the failure mode
`packages/fixtures/canonicalization/README.md` documents at length, and the reason that fixture
set exists in this shape.

## `bundle-hydration-v1.json` — a CI schema instance, not a parity golden

`bundle-v1.json` carries no drinks, so validating it against `json_bundle.schema.json` (the CI step
"The export bundle fixtures validate against their own JSON Schema") never touches the
`logs.hydration` section EPIC-38 added. That left the hydration schema **documented but unexercised**:
a writer or schema drift on the hydration block — a renamed key, a `const` that moved, a
required field dropped — would have passed CI unnoticed.

`bundle-hydration-v1.json` closes that: it is `bundle-v1.json` plus a realistic `logs.hydration`
block shaped as `ExportRunner` / `HydrationExportJSON.log` emits it — canonical-mL entries including
an **append-first revision** (`revision: 2`, `supersedes` the original id, `original_id` preserved,
per I2), a day summary **with** a goal and one **without** (null `goal_target_ml` / `goal_progress_pct`,
never `0`), a manual goal and an explicit no-goal, the referenced custom beverage, the aggregated
provenance sources (I1), and the redaction manifest with `note` structurally withheld (the key is
absent from every entry, per §7A.1). CI validates **both** files, so the hydration section is now
schema-checked.

It is deliberately **not** a cross-platform parity golden. The three goldens above are asserted
byte-identical by both suites; this file is not — it is a schema-validation instance only, read by
`.github/workflows/ci.yml`. Do **not** wire it into `ExportSchemaParityTest(s)` and do **not** edit
`bundle-v1.json` to carry hydration: keeping the no-hydration golden byte-stable is what lets a
pre-hydration store stay byte-for-byte reproducible (the absent-not-empty rule `JSONBundleWriter`
documents). If the hydration schema changes on purpose, regenerate this file to match the writer's
new output, then `scripts/check_fixture_hashes.sh --update` to re-record its sha256.

## Why bytes, not parsed structures

A parsed comparison passes while key order, number spelling, string escaping and timestamp
rendering all differ — which is exactly the set of things export schema 1.0.0 promises are
identical, and exactly what a consumer checksumming the file cares about. BADAN publishes a
`sha256` per file in every manifest and tells people the artifact is verifiable; two platforms
producing different bytes for the same data makes that promise vacuous.

The divergences were not hypothetical. When this fixture was written, three were live at once and
both suites were green:

- `JSONEncoder` sorted keys; kotlinx emitted them in declaration order.
- Swift rendered an integral `Double` as `512`; Kotlin as `512.0`. Below 1e-9 Kotlin switched to
  `1.0E-9` where Swift produced `0`.
- Both platforms rendered a zero UTC offset as `Z` while §22.1 requires a numeric offset.

None of it is visible from inside one platform, because each file parses perfectly well on the
machine that wrote it. That is why the writers now build a `CanonicalJSON` tree and render it
themselves rather than handing anything to a platform encoder.

## What the input covers

Beyond one row of each entity, the record set is chosen to walk the parts that actually break:

- a sample with a null `end_at`, and one that is **soft-deleted and dedup-suppressed** (so
  `deletions[]` and `provenance.suppressed_by` are both exercised)
- an interval spanning exactly one local day (`granularity: "day"`) and one spanning 20 minutes
  (`granularity: null` — an arbitrary window is not a calendar unit)
- a derived value keyed `day:` and one keyed `session:` (the second yields a null granularity)
- a **workout session**, to prove it is promoted into `workouts[]` and left out of `sessions[]`
- CSV rows carrying a comma, an embedded double quote, Arabic text, and four
  formula-injection triggers (`=`, `@`, and a leading `-` in a numeric column that must **not** be
  sanitized)
- a symptom note mixing Arabic with an embedded tab, which pins both the JSON escaping rules and
  the decision to emit non-ASCII as raw UTF-8 rather than `\u` escapes

`decimalCases` and `timestampCases` pin the two primitives every other assertion rests on. They
are separate from the goldens on purpose: when a golden breaks, the first question is whether a
number or a timestamp moved, and these answer it directly instead of leaving someone diffing an
11 KB file.

`route_ref` is deliberately **not** in the golden. The writers take `includeRoutes: false` here,
so a regression that starts emitting route references into a normal export fails loudly.

## Why the numbers are strings

`"canonicalValue": "0.0621"`, not `0.0621`. Same reasoning as
`packages/fixtures/canonicalization/README.md`: the values are compared for exact IEEE-754
equality, so the parse has to be the correctly-rounded one on both platforms rather than whatever
each platform's JSON number handling decides a bare numeric literal is. As strings they go through
`Double(String)` on Swift and `String.toDouble()` on Kotlin, both correctly rounded, both landing
on identical bits.

Epoch milliseconds are strings for the same reason, one step worse: Foundation's
`JSONSerialization` hands back an `NSNumber` whose backing type depends on magnitude, and a
13-digit integer read as a `Double` is a bug waiting for a timestamp past 2^53.

## `bundleManifest.platform` is `"ios"` on both sides

It is an *input*, not a claim about which machine ran the test. The fixture says "here is a
manifest; serialize it", and both platforms must serialize it identically. A neutral value like
`"fixture"` was tried and rejected: `json_bundle.schema.json` constrains `app.platform` to
`ios | android`, and a golden that cannot pass the schema it is supposed to demonstrate is worse
than no golden.

## `knownDivergences`

Three field-level differences could not be closed inside the writers, because they are domain
differences: EPIC-03 landed the typed workout payload independently on the two platforms, and the
sample-data honesty counter was added to one manifest entity and not the other.

They are **declared, with the fix**, rather than quietly omitted — same discipline as the
canonicalization fixture's divergence block:

| id | What differs | Fix |
|---|---|---|
| `workout-totals-energy-unit` | iOS `WorkoutTotals.energyKcal` -> `energy_kcal`; Android `energyKj` -> `energy_kj` | pick one stored unit in both domains, migrate the stored payloads, delete the losing key from the schema |
| `workout-hr-series-ref` | only iOS's `WorkoutDetail` has `hrSeriesRef`, so only iOS emits the key | add `hrSeriesRef` to Android's `WorkoutDetail` and stamp it where iOS does |
| `manifest-sample-data-row-count` | iOS reads a stored manifest field; Android takes a writer parameter defaulting to `0` | add `sampleDataRowCount` to Android's `ExportManifest` and compute it in that `ExportRunner` |

The fixture **routes around** each one — the workout carries no energy total and no HR reference —
so the goldens stay byte-identical while the divergences exist. That is a deliberate trade: it
keeps the parity assertion strong everywhere else instead of disabling it wholesale.

Both suites assert the entries are still present while the divergence is real, and reference the
diverging field **by name** (`WorkoutTotals(energyKj:)` on Android, `WorkoutDetail(hrSeriesRef:)`
on iOS) so that closing one breaks compilation on the platform that closed it. A divergence that
gets fixed and stays listed is a lie with a longer half-life than the bug was.

## Regenerating (rare — read this first)

Do **not** regenerate a golden to make a failing test pass. A mismatch you did not intend means
the two platforms disagree, and regenerating converts a real cross-platform disagreement into a
silent one-platform contract — which is the entire failure this fixture set exists to prevent.

Either platform may regenerate, deliberately:

```sh
# from apps/android
BADAN_REGENERATE_EXPORT_GOLDENS=true ./gradlew :app:testDebugUnitTest --tests '*ExportSchemaParityTest'

# or from apps/ios
BADAN_REGENERATE_EXPORT_GOLDENS=true xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BADANTests/ExportSchemaParityTests test
```

Both switches **always fail the run**, whatever the goldens ended up containing. A switch that
rewrote the fixtures and reported success would let a broken run end green, and nobody afterwards
could tell a verified artifact from one that was overwritten by whatever the code happened to emit
that afternoon.

Then:

```sh
scripts/check_fixture_hashes.sh --update   # rewrite the sha256 fields in manifest.json
scripts/check_fixture_hashes.sh            # verify
```

Then run **both** suites with the switch off. A golden verified on one platform is not a parity
fixture.

> `check_fixture_hashes.sh --update` rewrites hashes by whole-file textual substitution, so two
> entries that currently share a sha256 value collapse into one. That only bites while several
> fixtures are empty or identical — as they are the moment you create them — but if you are
> bootstrapping a new fixture, check `manifest.json` by eye afterwards.

`manifest.json` records the SHA-256 of every file here, and both suites verify it before parsing.
Without that check, a fixture mangled in transit (a text-mode checkout, a bad merge, a
well-meaning reformat) would surface as a byte mismatch in the goldens — technically true, and
precisely the wrong thing to hand someone debugging a cross-platform disagreement.

## Known gaps

- **Encrypted artifacts are not covered here.** `packages/fixtures/encryption/` pins the container
  format at byte parity; this set pins the plaintext. Nothing yet asserts that an encrypted export
  of *this* record set decrypts to *these* bytes on the other platform — the two fixture sets meet
  only by inspection.
- **`ExportRunner` is not exercised.** These tests drive the writers directly with a frozen record
  set. What is proven is that identical inputs serialize identically; what is *not* proven is that
  each platform's runner selects and orders the same records from the same store. That needs a
  database-level fixture, which is not reachable in a pure-JVM test today.
