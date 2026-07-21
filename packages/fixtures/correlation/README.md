# Correlation fixtures (EPIC-29)

Shared goldens for the journal correlation engine — `apps/ios/Sources/Domain/Derivation/CorrelationEngine.swift`
and `apps/android/app/src/main/java/net/albayyan/badan/domain/derivation/CorrelationEngine.kt`.

- `correlation-input-v1.json` — the INPUT. Each case is one behaviour × score pair already reduced
  to the engine's day view (`dayKey`, `present`, `nextDayScore`, `inDeclaredContext`), which is
  exactly what `CorrelationEngine.evaluate` takes on both platforms. No database, no clock, no
  timezone: the decision path under test is the same one the app runs, with the plumbing lifted off
  so the two suites can be compared line for line.
- `correlation-expected-v1.json` — the OUTPUT both platforms must reproduce.

Read by `apps/ios/Tests/CorrelationEngineTests.swift` and
`apps/android/app/src/test/java/net/albayyan/badan/CorrelationEngineGoldenTest.kt`.

## Why the expected numbers are exact

There is nothing stochastic left to tolerate. The bootstrap is seeded from a published constant in
`packages/contracts/algorithms/algorithms.json` (`journal.correlation.bootstrapSeed`) and draws
through a splitmix64 generator both platforms implement from the same specification, so
`delta`, `ciLow` and `ciHigh` are deterministic doubles. Both suites assert them to 1e-12.

If a run produces a *slightly* different interval, that is not floating-point noise to be widened
away — it means one platform's generator, draw order or percentile index rule has drifted from the
document, and the answer is in `docs/algorithms/correlations.md`, not in the tolerance.

## What each case is for

| case | asserts |
| --- | --- |
| `strong-positive` | a real association, interval entirely above zero → renders "tended to be higher" |
| `strong-negative` | interval entirely below zero → renders "tended to be lower" |
| `null-no-association` | **the null case.** Both gates cleared, interval straddles zero → renders "no clear association". This must never render as an empty state or be dropped from the list |
| `exactly-at-gate` | n = 14 with a 5/9 split — the minimum that is allowed to produce a finding |
| `one-below-gate-total` | n = 13 → SUPPRESSED, "about 1 more day" |
| `one-below-gate-with-arm` | n = 14 but only 4 days with the behaviour → SUPPRESSED |
| `one-below-gate-without-arm` | n = 14 but only 4 days without it (the near-daily-habit case) → SUPPRESSED |
| `context-annotated` | a finding over a window containing 6 declared context days: every day is still counted, the count is disclosed, and confidence is capped at `ContextAnnotator.activeContextConfidenceCeiling` (uncapped it would be ≈0.87) |
| `unpaired-days-dropped` | 16 logged days, 3 with no following score → 13 paired → SUPPRESSED. Days that can pair with nothing are removed *before* the gates are judged, never counted toward them |

## Regenerating

Don't, casually. The expected file was authored by a third, independent implementation of the
published method — a throwaway Python transcription of `docs/algorithms/correlations.md`, written
from the doc and deliberately **not** checked in, so nobody can "regenerate" by re-running the same
code the apps run. That is the whole point: agreement between iOS, Android and this file means all
three match the *document*, not each other's arithmetic. Regenerating from one platform's output
would throw that away and turn the parity test into a tautology.

If the method genuinely changes: bump `journal.correlation`'s semver in `algorithms.json`, update
the doc, re-derive the expectations from the doc, then run `scripts/check_fixture_hashes.sh --update`
and both suites.
