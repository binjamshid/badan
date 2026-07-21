# Sleep intelligence — `sleep.need` / `.performance` / `.debt` / `.consistency` / `.disturbances`

> Status: **provisional, semver 0.1.0 (all five)** · Engine: `SleepIntelligenceEngine`
> (iOS `Sources/Domain/Derivation/SleepIntelligenceEngine.swift`, Android
> `domain/derivation/SleepIntelligenceEngine.kt`) · Constants:
> `packages/contracts/algorithms/algorithms.json` (`sleep.need`, `sleep.performance`, `sleep.debt`,
> `sleep.consistency`, `sleep.disturbances`) · Owner: EPIC-24.

This is the sleep-intelligence cluster: from the sleep sessions and stages BADAN already ingests, it
computes — per **local night** — an estimate of how much sleep the body was looking for, how much of
that last night covered, an accumulated-debt trend, a timing-regularity score, and a count of
overnight wake-ups. It reads its personal sleep-duration baseline from `BaselineEngine`
(`sleep.time_asleep`) and, when available, the prior day's Effort score (`effort.day`, EPIC-26).

**Every constant below is data, not code.** The windows, half-lives, fractions and thresholds live
in `algorithms.json` and are loaded identically on both platforms (`SleepSpec`). Changing any of them
is a semver bump and a new `AlgorithmVersion` row — old rows keep their old id and are never rewritten
(INVARIANT I2).

**All five outputs are `provisional` today.** The constants are stated defaults that have not been
validated against data, so every `DerivedValue` this engine writes carries `provisional = true` — the
surface must present these as estimates (plan §11: "ship as range + 'estimated' label until
validated"), never as settled numbers.

## Honesty rules this engine keeps

- **No fake-precision minutes.** Need is emitted as a **range**, never a single exact target. The
  band widens as confidence falls, so an uncertain estimate *looks* uncertain (§*Need*).
- **Honest cold start.** Without a personal `sleep.time_asleep` baseline there is no need,
  performance or debt at all — those cannot exist without it. Consistency and disturbances do not
  depend on the baseline and stand alone.
- **Reduced-input is labelled, never imputed.** Effort is a *soft* dependency: when `effort.day` is
  absent the need model drops the effort term and lowers confidence (`effortPresent = false`); it
  never substitutes a default.
- **Missing nights are gaps, not zeros.** A night with no primary sleep session produces no row. A
  night with no stage data produces no disturbance count — unknown is not zero.
- **Personal baselines only.** The only "normal" this engine uses is the wearer's own
  `sleep.time_asleep` baseline; no population sleep norms enter v1.

## The state machine (the hard part)

Sessions are folded into per-night records by `assembleNights`, which is where nap days, split
nights, DST and travel are handled:

- **Local night.** An episode is attributed to the night it **ends** in, computed in the episode's
  **own** timezone — so a Riyadh night stays a Riyadh night after you fly to London, and a
  post-midnight bedtime lands on the right morning.
- **Split night.** Two or more primary clusters on one night fold into a single night: asleep seconds
  sum, bedtime is the earliest cluster's start, wake is the latest cluster's end, and the awake gap
  **between** clusters becomes a disturbance (the sleeper was genuinely up).
- **Naps.** A nap accrues against its own local day and credits the **following** night's need (a 2pm
  nap does not shorten the sleep you already had — it lowers the need for the night to come). Night
  `K` draws its nap credit from day `K − 1`.
- **DST.** Bed/wake times are **wall-clock** second-of-day (not elapsed-since-midnight), so a 07:00
  wake is `25200` both sides of a spring-forward and consistency is not thrown by the missing hour.

## `sleep.need` — an estimate, as a range

```
need = baselineDuration
     + debtRepaymentFraction · needDebt          (recent shortfall, decayed — see below)
     + priorDayEffort · effortFactorSecondsPerPoint   (0 when Effort is absent)
     − napCreditFraction · priorDayNapSeconds
need = clamp(need, minNeedSeconds, maxNeedSeconds)
```

- `baselineDuration` is the centre of the personal `sleep.time_asleep` baseline (seconds).
- `needDebt` is a **short-memory** view of accumulated shortfall (§*Debt*), decayed with
  `sleep.need.debtDecayHalfLifeDays` (4 days) rather than the displayed-debt half-life — tonight's
  target should react to the last few nights, while the surfaced debt trend has a longer memory. Two
  half-lives, both published, both used. Only `debtRepaymentFraction` (0.35) of it is folded in, so a
  large debt never produces an unreachable target that only shames the user.
- The effort term is the **reduced-input seam**: absent `effort.day`, it is 0 and the estimate is
  flagged `effortPresent = false`.

**Range.** `confidence = baselineMaturity × inputCompleteness`, where `baselineMaturity =
min(1, nPoints / windowDays)` of the sleep-duration baseline and `inputCompleteness` is `1.0` with
Effort present, `0.5` without. The displayed half-width is
`rangeHalfWidthSeconds · (2 − confidence)` — ±30 min at full confidence, widening toward ±60 min as
confidence falls. The surface renders `[low, high]`, never the bare centre.

| constant | value | role |
|---|---|---|
| `debtRepaymentFraction` | 0.35 | share of debt folded into tonight's need |
| `debtDecayHalfLifeDays` | 4.0 | half-life of the debt view that feeds need |
| `effortFactorSecondsPerPoint` | 42.0 | extra need seconds per point of `effort.day` |
| `napCreditFraction` | 0.5 | share of prior-day nap seconds credited off need |
| `rangeHalfWidthSeconds` | 1800 | base ± half-width of the displayed range |
| `minNeedSeconds` / `maxNeedSeconds` | 18000 / 39600 | display clamps (5h–11h) |

## `sleep.performance` — share of need fulfilled

```
performance = actualAsleep ÷ need.centre × 100        (stored uncapped)
```

Stored **uncapped** so the raw ratio stays inspectable; the surface caps the shown value at
`upperBoundPercent` (120). The band inverts the need band — `low = actual ÷ need.high`,
`high = actual ÷ need.low` — and `showRange` fires when `confidence < lowConfidenceThreshold` (0.6),
so a low-confidence performance is shown as a band, not a point.

## `sleep.debt` — rolling accumulator with decay

```
debt(asOf) = clamp( Σ  shortfall_i · 0.5^(ageDays_i / decayHalfLifeDays) , 0, maxDebtSeconds )
             over nights i within lookbackDays
shortfall_i = need_i − actual_i        (signed: a catch-up night pays debt down)
```

- `decayHalfLifeDays` = 7. Without decay a single bad fortnight would follow a user for months, which
  is neither true nor wellness-safe.
- Signed shortfall means oversleeping **reduces** debt ("easing off as you catch up"); the clamp to
  `[0, maxDebtSeconds]` (0–20h) floors a well-rested surplus at "no debt" and caps the surface so it
  can never show an alarming, ever-growing number.
- Debt is a **forward recurrence**: tonight's need depends only on *past* shortfalls, so there is no
  circularity. The displayed debt at each night includes that night; the `needDebt` fed to need
  excludes it (tonight's shortfall is not yet known). Across a missed night the decay spans the real
  day-gap, so a gap is handled without fabricating a shortfall for the night with no data.

## `sleep.consistency` — 0–100 timing regularity

```
spread   = wrapAwareStdev(times)        (population stdev, times unwrapped to ±12h of the first)
component = max(0, 1 − spread / zeroScoreStdevSeconds)
consistency = 100 · ( bedWakeWeightSplit · bedComponent + (1 − bedWakeWeightSplit) · wakeComponent )
```

Over the trailing `windowDays` (14) nights. The spread is **wrap-aware** — a 23:50 and a 00:10
bedtime are 20 minutes apart, not 23h40m — computed with only `+ − × ÷` and `sqrt` (IEEE-754,
correctly rounded), so it is bit-identical across platforms without any trig. `zeroScoreStdevSeconds`
(3h) is the spread that maps to 0, chosen so ordinary weekend drift does not floor the score. Below
`minNights` (5) the value is emitted with confidence 0 so the surface withholds it rather than scoring
someone on two nights.

## `sleep.disturbances` — overnight wake-ups

```
merge awake episodes closer than mergeGapSeconds; count merged episodes ≥ minEpisodeSeconds
```

Awake episodes are the explicit awake-stage rows **plus** the gaps between clusters of a split night.
`mergeGapSeconds` (120) collapses stage-classifier flapping into one disturbance; `minEpisodeSeconds`
(300) drops sub-5-minute blips that the sleeper did not experience. Emitted only for nights that
carry stage data.

## Confidence, provenance, versioning

Each row carries a `confidence` (need/performance from `baselineMaturity × inputCompleteness`;
consistency from data sufficiency; disturbances 1.0 when staged) and an `InputManifest` naming the
records that fed it (the baseline, the prior-day Effort row, the night's sessions). Recompute is
append-only: a nightly run over unchanged data writes nothing, a run over new or corrected data
appends fresh rows and never mutates the old ones (I2). Because every output is `provisional`, a
future validation pass that tunes any constant is a semver bump per output and a new `AlgorithmVersion`
row — the numbers already written keep the version that produced them.
