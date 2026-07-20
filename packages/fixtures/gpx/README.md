# Cross-platform GPX fixtures (EPIC-12)

These files make "the same workout produces the same GPX on both platforms" a fact rather than an
intention. One frozen input, two goldens, read from the repo by **both** suites.

| File | Role |
|---|---|
| `gpx-input-v1.json` | the shared **input** — workouts, routes, points, and the two gate flags |
| `route_01JQZ8WKATRN00000000000001.gpx` | golden for the trail-run workout (segment splitting) |
| `route_01JQZ8WKACTY00000000000002.gpx` | golden for the city-loop workout (two routes, coordinate edges) |

| Read by | Asserts |
|---|---|
| `apps/ios/Tests/GPXAggregationParityTests.swift` | the input, through iOS `GPXWriter`, produces the goldens byte for byte |
| `apps/android/app/src/test/java/net/albayyan/badan/GpxAggregationParityTest.kt` | the same input, through Android `GpxWriter`, produces the same bytes |

Neither suite may copy the input or the goldens into its own source — a copy is one more thing that
can drift from the artifact it polices (same reasoning as `packages/fixtures/export/README.md`).

## Why bytes, not parsed XML

BADAN publishes a `sha256` for every file it exports and tells people the artifact is verifiable.
Two platforms producing different bytes for the same trace makes that promise vacuous — and a
parsed-XML comparison passes while the exact float rendering that a checksum sees still differs.

## What the input covers

- **Segment splitting on time.** The trail run has a gap of exactly 60s (which must **not** split —
  the boundary is strictly `>60s`) immediately followed by a 61s gap (which must), so the golden has
  two `<trkseg>`s and the off-by-one is caught in either direction.
- **Segment splitting on route boundary.** The city loop stores two `workout_routes` rows; they
  become two segments even though their timestamps abut, because two separately-captured traces
  cannot honestly claim continuity across the join.
- **A conditional `<ele>`.** One point carries no elevation, so the writer must omit the element
  rather than emit an empty or zero one.
- **Coordinate rounding parity.** A latitude of `25.00390625` (= 25 + 1/256, an exact binary
  fraction) is the value where C's `printf("%.7f")` and the JVM's `String.format("%.7f")` round in
  opposite directions (`…062` vs `…063`). Both writers round in integer space instead, and this
  fixture is what proves they agree — it would have been silent otherwise.
- **Sign near zero.** A longitude of `-0.0000001` must keep its minus sign even though its whole
  part is `0`; a `0.0000000` must not gain one. Negative (southern/western) coordinates and a
  below-sea-level elevation exercise the same sign path.
- **XML text escaping** in the workout name (`<`, `>`, `&`, `"`).

## The gates are tested in code, not here

`gpx-input-v1.json` sets `routeExportEnabled: true` and the suites build a matching confirmation, so
the golden run exercises the happy path. The **refusal** paths — the export toggle being off, and a
confirmation that acknowledges a different route set — are asserted directly in the suites
(`testGPXRefusesWithoutToggleAndOnStaleConfirmation`), because a golden can only demonstrate output
that was produced, not output that was correctly withheld.

## Regenerating (rare — read this first)

Do **not** regenerate a golden to make a failing test pass. A mismatch you did not intend means the
two platforms disagree, and regenerating converts a real cross-platform disagreement into a silent
one-platform contract — the entire failure this fixture set exists to prevent.

```sh
# from apps/android
BADAN_REGENERATE_EXPORT_GOLDENS=true ./gradlew :app:testDebugUnitTest --tests '*GpxAggregationParityTest'
# or from apps/ios
BADAN_REGENERATE_EXPORT_GOLDENS=true xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BADANTests/GPXAggregationParityTests test
```

Both switches **always fail the run**, whatever the goldens ended up containing. Then rewrite the
hashes and run **both** suites with the switch off — a golden verified on one platform is not a
parity fixture:

```sh
scripts/check_fixture_hashes.sh --update
scripts/check_fixture_hashes.sh
```
