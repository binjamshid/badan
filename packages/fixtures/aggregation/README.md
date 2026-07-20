# Cross-platform aggregation + wide-layout fixtures (EPIC-13)

These files make "the same canonical rows aggregate to the same numbers, in the same bytes, on both
platforms" a fact rather than an intention. One frozen input, three goldens, read from the repo by
**both** suites.

| File | Role |
|---|---|
| `aggregation-input-v1.json` | the shared **input** — canonical rows + a minimal metric-definition map |
| `records-hint-v1.csv` | golden: the aggregator's records for a **hint** run (`method = null`) |
| `records-minavgmax-v1.csv` | golden: the records for a **min/avg/max** run |
| `wide-v1.csv` | golden: `WideCSVProjector` over the min/avg/max run's records |

| Read by | Asserts |
|---|---|
| `apps/ios/Tests/GPXAggregationParityTests.swift` | the input, through iOS `MetricAggregator` + `WideCSVProjector`, produces the goldens byte for byte |
| `apps/android/app/src/test/java/net/albayyan/badan/GpxAggregationParityTest.kt` | the same input, through Android's writers, produces the same bytes |

Neither suite may copy the input or goldens into its own source (same reasoning as
`packages/fixtures/export/README.md`).

## The two `records-*.csv` are a test-only serialization

They are **not** the product's 26-column tidy CSV — `CSVWriter`/`CsvWriter` owns that and
`ExportRunner` emits it. They are a dump of every `AggregateRecord` field
(`metric_id, bucket_key, granularity, aggregation_method, value, unit, bucket_start_ms,
bucket_end_ms, tz_id, contributing_tzs, sample_count`), so the fields the wide layout *drops* — the
bucket instants and the mixed-zone provenance — are still pinned across platforms. `wide-v1.csv` is
the real product wide layout. Both serializations round the `value` column through
`CSVWriter.decimal`, the one number-rendering rule the whole export contract shares.

## What the input covers

- **DST spring-forward.** `activity.steps` on 2026-03-08 in `America/New_York` is a **23-hour** day;
  `bucket_end_ms - bucket_start_ms` must be `82_800_000`.
- **DST fall-back.** `activity.steps` on 2026-11-01 is a **25-hour** day; the difference must be
  `90_000_000`. Getting either wrong by an hour is the single easiest thing to do silently in an
  aggregation layer, which is why both are goldened and re-asserted in
  `testAggregationHandlesDstAndTimezoneChanges`.
- **Timezone change mid-range.** Two `heart.hr` rows recorded 2026-06-20 08:00 in `Asia/Dubai` and
  2026-06-20 20:00 in `America/New_York` share the local date and land in **one** bucket; its
  boundaries are anchored in the earliest row's zone (Dubai) and `contributing_tzs` records
  `America/New_York;Asia/Dubai`. A third row the next day is a separate bucket.
- **Every default-stat path.** `activity.distance` (stored `sum`, all agree) → `sum`;
  `respiratory.rate` (stored `mean`, a rate) → `mean`; `activity.steps` (no stored aggregation,
  cumulative unit) → `sum`; `heart.hr` (a `rawSample` rate) → `mean`; `activity.floors` (stored
  `sum` and `max` **disagree**) falls through to `sum`.
- **`min/avg/max` expansion.** In the second run each metric·bucket becomes three records (`min`,
  `mean`, `max`), and `wide-v1.csv` shows them as three adjacent columns per metric with empty cells
  where a metric has no data in a bucket — a blank is "not recorded", distinct from a `0`.
- **Non-integer decimal rendering.** `heart.hr` mean of 62 and 79 is `70.5`.
- **`duration` and `latest`** are asserted directly in the suites (`activity.distance` rows carry
  `endMs`, so a duration run totals `7200`s and a latest run yields `1500`) rather than goldened.

## Regenerating (rare — read this first)

Same discipline as every other fixture set: do **not** regenerate to make a failing test pass. A
mismatch you did not intend means the platforms disagree.

```sh
# from apps/android
BADAN_REGENERATE_EXPORT_GOLDENS=true ./gradlew :app:testDebugUnitTest --tests '*GpxAggregationParityTest'
# or from apps/ios
BADAN_REGENERATE_EXPORT_GOLDENS=true xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BADANTests/GPXAggregationParityTests test
```

Both switches always fail the run. Then `scripts/check_fixture_hashes.sh --update`, verify, and run
**both** suites with the switch off.
