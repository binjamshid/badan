# Personal baselines — `baseline.rolling_median_mad`

> Status: **published, semver 2.0.0** · Engine: `BaselineEngine` (iOS `Sources/Domain/Derivation/BaselineEngine.swift`,
> Android `domain/derivation/BaselineEngine.kt`) · Constants: `packages/contracts/algorithms/algorithms.json`
> (`baseline.rolling_median_mad`) · Owner: EPIC-23.

A personal baseline is BADAN's answer to **"what is normal *for you*"** for one metric — a centre
and a band the app draws every reading against. It is the input the four Phase‑2 score engines
(sleep, readiness, effort, health monitor) all read, so this page is the one the others build on.

Everything below is **data**, not code: the windows, the transform table, the MAD constants, the
outlier threshold and the confidence thresholds live in `algorithms.json` and are loaded identically
on both platforms (`BaselineSpec`). Changing any of them is a semver bump and a new
`AlgorithmVersion` row — old rows keep their old id and are never rewritten (INVARIANT I2).

## What is computed

For each baseline-eligible metric, over its own trailing window of local days (one value per day —
the latest-written record for that day):

1. **Optional transform.** Log-normal vitals are transformed to `ln(value)` before anything else
   (see *Log-domain banding*). Everything else is banded directly.
2. **Outlier rejection.** A day whose (transformed) value is more than `outlierMadThreshold` MADs
   from the in-window median is dropped, so one artefact cannot move the personal normal.
3. **Robust centre + spread.** `centre = median`, `spread = MAD` (median absolute deviation) of the
   surviving days.
4. **Band.** `± madToSigma · bandSigmas · MAD` around the centre; for a log metric this is computed
   in log space and exponentiated back, giving an **asymmetric** linear band.
5. **Confidence tier.** `provisional` → `establishing` → `established`, from how full the window is.

The result is appended as a `Baseline` row carrying its window, point count, `provisional` flag,
`covariateContext`, and the `algorithm_version` that produced it.

## Per-metric window & transform table

The window is **not** one size. Different signals stabilise over different horizons; a single window
would either lag a fast signal or over-react to a slow one. Published table (plan §18):

| Metric(s) | Window | Transform | Why |
|---|---|---|---|
| `heart.hrv` | **60 days** | **log** | HRV is the slowest-moving and noisiest daily vital; a long window is needed to see the person under the day-to-day scatter (`whoop.md` §5). It is log-normal, so it is banded in the log domain. |
| `heart.rhr`, `respiratory.rate`, `body.wrist_temp_deviation` | **14 days** | identity | Resting HR, respiratory rate and temperature track recent state closely; two weeks captures the personal normal without dragging in stale context. |
| `sleep.time_asleep`, `sleep.time_in_bed` | **28 days** | identity | Sleep-need inputs want a month so ordinary weekday/weekend structure is inside the window, not aliased by it. |
| *(everything else baseline-eligible)* | **28 days** (default) | identity | A solid general-purpose personal-normal horizon. |

The window is stepped with calendar-day arithmetic (`DayAttribution.addingDays`), **not** fixed
86 400‑second multiples, so it is correct across DST transitions. The **evaluation day itself is
excluded** from the window its own band is built from — otherwise today's reading would be judged
against a band that already contains it.

## Log-domain banding

HRV (RMSSD/SDNN) is right-skewed: the same person's good and bad nights are not symmetric around the
median. A plain linear band would put the lower edge below what the body ever produces and clip the
long upper tail. So for a `log`-transform metric the median and MAD are taken on `ln(value)`, and
the centre and band edges are exponentiated back:

```
centre   = exp( median(ln x) )                    # the geometric median, in linear units
bandLow  = exp( median(ln x) − madToSigma·bandSigmas·MAD(ln x) )
bandHigh = exp( median(ln x) + madToSigma·bandSigmas·MAD(ln x) )
```

The band that comes back is **asymmetric in linear units** (upper edge farther from centre than the
lower) — which is the correct shape for a log-normal vital.

**Stored `spread`.** For a log metric the stored `spread` is the linear-equivalent *upper* half-width
divided by `madToSigma·bandSigmas`. For an identity metric this is exactly the MAD; for a log metric
it keeps `(bandHigh − centre) / spread == madToSigma·bandSigmas`, so the anatomy sheet's derived
multiplier stays honest and `Baseline.z(of:)` remains a sensible near-centre approximation without the
band having to be symmetric. The **displayed band range is authoritative**; the "centre + k·spread"
caption reflects the upper edge. Non-positive values are dropped before the log (a sensor `0` is
missing data, not `ln(0)`).

The transform is **not** stored on the baseline row — it is reconstructable from the metric id via
this published window table (the row's `algorithm_version` points here), so nothing is stored
redundantly. The calibration read model surfaces it for the UI.

## Outlier rejection (MAD-based)

Before the band is drawn, a day is rejected if `|value − median| > outlierMadThreshold · MAD`
(in the transform's working domain). `outlierMadThreshold = 3.5` follows the Iglewicz–Hoaglin
modified‑z convention. This removes a single wild reading — a bad HRV sample after a late meal, a
sensor spike — so it cannot become part of "your normal."

Rejection is **skipped when the MAD is exactly 0**: a zero spread cannot define an outlier, and a
lone differing value in an otherwise-flat window is data, not noise. The point count that drives the
confidence tier is counted **after** rejection, so a window padded with rejected spikes never reads
as more calibrated than it is.

## Confidence tiers

| Tier | Condition | Meaning |
|---|---|---|
| `provisional` | `n < minPoints` **or** `n < ceil(windowDays · establishingFraction)` | Not enough to be honest about. **Nothing renders as a score while a contributing baseline is provisional.** |
| `establishing` | provisional cleared, but `n < windowDays` | Usable, still filling the window ("day 9 of 14"). |
| `established` | `n ≥ windowDays` | Window full. |

Constants: `minPoints = 7`, `establishingFraction = 0.5` (plan §18: "provisional clears at `n ≥ 7`
**and** ≥ half the window"). For the 60‑day HRV window this means a cold-start user waits ~30 days
before HRV is treated as established — but a first-connect **history backfill** can clear it on day
one, because the 90‑day backfill fills the window immediately. Reduced-input variants are the score
engines' concern and are labelled distinctly there, never silently degraded here.

## Retroactive scores — "computed later from history"

A per-day derived score can be computed **after** the day it describes — e.g. a readiness day
recomputed once an import backfilled that week. EPIC-23's decision:

- **Add a dedicated `QualityFlag.retroactive`, do not reuse `.estimate`.** A retroactively-computed
  score can *also* be an estimate; the two facts are independent ("how confident is this number" vs
  "when / from what history was it computed"), so collapsing them would erase one.
- **It is a read-time-derived label, not a stored column.** `BaselineEngine.isRetroactive(periodDay,
  computedAt, …)` decides it from two fields the row already carries: a value whose `computedAt` day
  is more than `retroactiveGraceDays` (= 2) after the day it describes was computed later from
  history. The fact is answerable directly from the data (INVARIANT I1), needs no migration, and is
  attached at read/export time exactly as `provisionalBaseline` is derived from a baseline's
  `provisional` flag. `graceDays = 2` covers the normal nightly + post-ingest-debounce cadence.

Recommended copy for the UI lane (this engine ships the flag, not the string): en *"computed later
from history"* / ar *"محسوب لاحقًا من السجل"*.

## Covariate-conditioned baselines (EPIC-39 prep)

`recompute`/`recomputeAll` accept a `covariateContext`. `"default"` is the unconditioned baseline;
any other context stores a **parallel** band **additively** (the baselines table is unique on
`(metric, context, window, valid_from)`, so contexts coexist and the default is always the fallback).
A cycle phase will feed this in Phase 3 (EPIC-30). This engine deliberately **does not read cycle
data** — it stores under whatever context it is handed; the conditioning source is a later epic.

## Append-only & recompute

`recomputeAll` is the single recompute entry point the background lane (BGProcessing / WorkManager)
calls for both the nightly pass and a post-import backfill. It is:

- **Idempotent** — a repeat run over unchanged data writes nothing (a fresh row is skipped when it is
  numerically identical to the latest stored one).
- **Append-only (I2)** — a run over *new* history appends fresh rows; the per-day composite scores
  append a new `DerivedValue` (new `computed_at`) and the prior row is retained, so "what BADAN
  believed at the time" is preserved and auditable. Baselines are keyed by their as-of day
  (`valid_from`); a later as-of day appends a new row rather than mutating the prior one.

Full recompute (60 days × 20 metrics) stays under the 5‑second device budget (`BaselineEngineTests
.testFullRecomputePerformanceBudget`).

## Testing

Cross-platform golden numerics (`BaselineEngineTests` on iOS, `BaselineEngineGoldenTest` on Android)
assert **identical** centre/spread/band/point-count/tier for the same inputs against the same
published constants. iOS additionally covers the DB orchestration — per-metric windows, log-band
asymmetry, the covariate-context hook, append-only recompute, a DST window, and the performance
budget (Android has no DB-backed test harness; the pure core is what both share).
