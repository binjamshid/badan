# Cross-platform canonicalization fixtures

`canonical-rows-v1.json` is the artifact that makes "the two platforms store the same number for
the same reading" a fact rather than an intention. It is one file, read from the repo by **both**
suites:

| Read by | Asserts |
|---|---|
| `apps/android/app/src/test/java/net/albayyan/badan/HealthConnectCanonicalParityTest.kt` | every row's as-received value, through Android's `Units`, produces the row's `canonicalValue`/`canonicalUnit` |
| `apps/ios/Tests/CanonicalizationParityTests.swift` | the same rows, through iOS's `Units`, produce the same values |

Neither side may copy the rows into its own source. A copy is one more thing that can drift from
the artifact it is supposed to police — which is exactly what happened before this file existed:
the fourteen golden rows lived as a hardcoded Kotlin list inside
`HealthConnectCanonicalParityTest`, whose docstring claimed "iOS's equivalent fixture feeds the
same as-received values through its own `Units` and must produce a byte-identical block". There
was no iOS equivalent. Nothing on iOS compared against those rows, nothing would have failed if
iOS's `Units` had diverged, and the Phase-0 exit criterion ("widened ingestion fixtures pass
identically both platforms", plan §19) rested entirely on a one-platform assertion.

## What a row pins

Each row is an as-received reading — `(metricId, value, unit)`, exactly the triple an adapter
hands `IngestionPipeline` — and the exact pair BADAN must store for it,
`(canonicalValue, canonicalUnit)`. That is the layer where the two platforms can actually diverge
silently: a kcal/kJ mix-up, a percent-versus-fraction slip, a missing dimension. It is also
reachable in a pure unit test on both sides, which the database layer is not.

`emittedBy` names which adapter table rows actually arrive through this path, as
`HcTypeMap:<platformType>` / `HKTypeMap:<HKQuantityTypeIdentifier rawValue>`. Each suite asserts
its own table's unit column matches the row, so the fixture breaks if either adapter starts
emitting a different unit — the property the old inline test had, kept.

The two platforms deliberately do **not** emit the same as-received units for every metric
(Health Connect gives kilojoules and `%`, HealthKit gives kilocalories and a 0–1 fraction), so
the fixture covers both spellings of the metrics where they differ and asserts the two land on
the identical canonical number. `emittedBy: []` marks rows no adapter produces today — imperial
mass and length, `km/h`, `mL` — kept because manual entry and third-party imports walk them and
a factor typo there is invisible on a chart.

## Why the numbers are strings

`"canonicalValue": "2092.0000012049923"`, not `2092.0000012049923`.

The values are compared for **exact IEEE-754 equality**, so how they are parsed matters. Written
as JSON numbers they would go through each platform's JSON number handling — Foundation's
`JSONSerialization` and kotlinx-serialization make their own choices about `Double` vs `Decimal`
vs `Long`, and that is a difference in the *harness*, not in the thing under test. As strings
they go through `Double(String)` on Swift and `String.toDouble()` on Kotlin, both correctly
rounded, both landing on identical bits for the same decimal literal.

The values themselves are written at shortest-round-trip precision, residue included:
`2092.0000012049923` rather than `2092`. `Units.table` stores the kJ leg as `0.239005736`
(1/4.184 rounded to nine places) and divides by it, so the residue is what is genuinely stored.
Rounding it away in the fixture would mean asserting a number BADAN does not hold.

**A `%.6f` golden string was considered and rejected.** The previous inline version compared
`String.format("%.6f", …)` output. Java's `Formatter` rounds HALF_UP on the exact decimal value;
C's `printf`, which Swift's `String(format:)` uses, rounds half-to-even on the exact binary
value. For a value that lands exactly halfway at the sixth decimal — possible, if uncommon, for a
dyadic rational — the two platforms print different strings for identical `Double`s. A parity
fixture whose failure mode includes "both platforms are correct and the test fails anyway" is
worse than no fixture: it teaches people to relax the assertion.

## Why `Units.convert`, not only `Units.toCanonical`

Both suites assert `Units.convert` does **not throw** for every row, in addition to asserting
`toCanonical` produces the expected value.

`toCanonical` swallows an unknown or incompatible unit and returns the value unchanged, which is
right for the pipeline (a bad unit must not crash ingestion; it is flagged `.estimate` upstream)
and useless for a fixture. For every identity row — most of the file — an entirely *missing*
unit produces the same number as a correct conversion. A fixture built on `toCanonical` alone
would pass while a platform's `Units` table had lost the dimension. The `ml/kg/min` row is a
promoted example of precisely that: it read correctly through `toCanonical` on Android for a
whole round while being absent from the table entirely.

## `knownDivergences`

Rows where the two platforms provably do **not** agree today, stated with each platform's actual
behaviour and the fix rather than quietly left out of the row set.

**The array is currently empty: the two platforms agree on every unit in this fixture.** It is
kept in the schema, and both suites keep iterating it, so the next divergence has somewhere to be
declared without a fixture-format change.

Two entries lived here and have been promoted into `rows`:

- **`ml/kg/min`** (lowercase L) — added to iOS by EPIC-01 and to `Units.kt` in the same
  integration round. While it was iOS-only, the Android value fell through `toCanonical`'s catch
  and was stored unconverted and stamped `.estimate`, which for VO2 max happens to be numerically
  right, which is why nothing noticed.
- **`brpm`** — re-based from `count/min` to `breaths/min` on iOS by EPIC-01, then on Android in
  the same round. Latent throughout, because nothing in-tree emits that spelling yet.

Both suites assert the divergence entries describe *current* behaviour on their own platform, so
an entry that gets fixed and stays listed fails the suite that fixed it. That is deliberate: a
divergence that gets fixed and stays listed is a lie with a longer half-life than the bug was.

## Regenerating (rare — read this first)

Do **not** regenerate a hash to make a failing test pass. A hash mismatch you did not intend
means the fixture changed underneath you.

`manifest.json` records the SHA-256 of `canonical-rows-v1.json`, and both suites verify it before
parsing. Without that check, a fixture mangled in transit (a text-mode checkout, a bad merge)
would surface as a canonicalization mismatch — technically true, and precisely the wrong thing to
hand someone debugging a cross-platform disagreement. `.gitattributes` marks the file `-text` so
a checkout cannot rewrite its line endings under the hash.

When you deliberately add or change a row:

```sh
scripts/check_fixture_hashes.sh --update   # rewrites the sha256 in manifest.json
scripts/check_fixture_hashes.sh            # verify
```

Then run **both** suites. A row added on one platform's say-so is not a parity fixture.

## Known gap

The temperature-offset path (`degF` → `degC`) is not covered. It is the only conversion in
`Units.table` with a non-zero offset, and therefore the one most likely to diverge if a platform
reorders the arithmetic — but there is no honest row to write for it: the registry's only
temperature metric is `body.wrist_temp_deviation`, which is a *difference*, and applying the
freezing-point offset to a difference is the exact bug `HcTypeMap` warns about. Covering this
needs a registry metric with an absolute-temperature canonical, which is a contract change.
Stated here rather than papered over with a fabricated metric id.
