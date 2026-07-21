# Readiness — `composite.readiness_score`

> Status: **provisional, semver 2.0.0** (launch weights not yet validated against data — pending A3;
> every row is flagged `provisional`) · Engine: `ReadinessEngine` (iOS
> `Sources/Domain/Derivation/ReadinessEngine.swift`, Android `domain/derivation/ReadinessEngine.kt`) ·
> Constants: `packages/contracts/algorithms/algorithms.json` (`composite.readiness_score`) · Owner:
> EPIC-25 · Approval: A3 (naming + publication, ADR-0009).

Readiness is BADAN's morning **recovery-equivalent**: a single 0–100 number answering *"how do your
overnight signals compare with your **own** usual pattern this morning?"* It is the product's
transparency differentiator — where a black-box score hands you a number and asks for trust, every
Readiness score ships with this published formula, a versioned `AlgorithmVersion`, an `InputManifest`
naming the exact records that fed it, and a confidence flag. See
[readiness-vs-whoop.md](readiness-vs-whoop.md) for the honest "why our number differs from WHOOP's"
narrative.

Everything below is **data**, not code: the weights, the z clamp and the completeness gates live in
`algorithms.json` and are loaded identically on both platforms (`ReadinessSpec`). Changing any of them
is a semver bump and a new `AlgorithmVersion` row — and because derived values are append-only
(INVARIANT I2), old rows keep the version that produced them and are never rewritten.

## The four inputs

| Input | Metric id | Enters as | Direction |
|---|---|---|---|
| Overnight HRV | `heart.hrv` | personal **z-position** vs its EPIC-23 baseline | higher is favourable (+) |
| Resting heart rate | `heart.rhr` | personal **z-position** vs its baseline | higher is unfavourable (−) |
| Respiratory rate | `respiratory.rate` | personal **z-position** vs its baseline | higher is unfavourable (−) |
| Sleep performance | `sleep.performance` | its **own normalized value** (see below) | higher is favourable (+) |

Every input is read **against the person, never a population norm** (plan §18). The three vitals use
their EPIC-23 [personal baselines](baselines.md): the z-position `Baseline.z(value)` places today's
reading where it sits within *your* usual spread, so your own median is the neutral middle of the
score and a good/poor night moves it up or down.

**Why sleep performance is the exception.** `sleep.performance` (from the concurrent
`SleepIntelligenceEngine`, EPIC-24) is *already* last night's sleep expressed as a share of your
personal need — and need is itself baseline-derived. Re-baselining it would double-count the
personalisation, so it enters as its own value: **100 % of need met is a full sub-score, not a neutral
one.** The three vitals are framed around "typical for you" (neutral 50); sleep is framed around
"enough for you" (100 = enough). This deliberate frame difference is documented here so the anatomy
sheet can explain it rather than hide it.

Sleep is a **soft dependency**: if the sleep engine has not produced a `sleep.performance` for the
day, its term simply drops and the score runs as a labelled reduced-input variant — it is **never
imputed** (plan §18: "no imputation of physiological inputs, ever").

## The weights (BADAN's own, deliberately not WHOOP's)

| Input | Weight |
|---|---|
| HRV | **0.50** |
| RHR | **0.20** |
| Sleep performance | **0.20** |
| Respiratory rate | **0.10** |

These are **BADAN's own launch weights** (plan §11 EPIC-25), chosen — and published — rather than
copied from any competitor's undisclosed formula. The directional rationale, stated plainly and
without overclaiming:

- **HRV carries the most weight (0.5)** because overnight heart-rate variability is the most direct
  everyday window onto autonomic (parasympathetic) recovery state, and it is the signal that moves
  most with sleep quality, training load and illness. It is also the noisiest, which is why it is
  banded over a long 60-day log-domain window ([baselines.md](baselines.md)) before it is judged.
- **RHR (0.2)** is a slower, steadier recovery signal — an elevated resting heart rate against your
  own normal is a well-established sign of incomplete recovery or oncoming strain.
- **Sleep performance (0.2)** brings behaviour into the score: how much of the sleep your body needed
  it actually got.
- **Respiratory rate (0.1)** is a smaller, corroborating signal — stable within a person night to
  night, and a rise against your own baseline can accompany strain or illness, but it carries the
  least independent information of the four, hence the smallest weight.

They are **provisional pending A3 validation** — the entry is marked `provisional: true`, so every
score produced under them is flagged, and a later re-weighting will be a semver bump with an in-app
changelog entry, never a silent change.

## How the number is computed

For each **present** input:

1. **Sub-score (0–100).**
   - Vitals: `subScore = 50 + direction · clamp(z, ±zClampSigmas) / zClampSigmas · 50`.
     Your own median (`z = 0`) is 50; `+zClamp` maps to 100, `−zClamp` to 0. `zClampSigmas = 2.5`
     bounds the input so one wild reading (a bad HRV sample after a late meal) cannot dominate the
     composite.
   - Sleep performance: `subScore = clamp(sleep.performance, 0, 100)` — its own value, as explained
     above.
2. **Renormalize the present weights.** Weights are renormalized over whatever inputs are available:
   a dropped input **redistributes** its weight across the rest — it is never replaced by a default or
   an average.
3. **Composite = the weighted mean of the present sub-scores**, always in `[0, 100]`.

Each input's **contribution** = `normalizedWeight · subScore`; the contributions sum to the score by
construction, which is exactly what the anatomy sheet's contribution bars render.

```
score = Σ  (weightᵢ / Σ presentWeights) · subScoreᵢ        over present inputs i
```

## Input-completeness rules (the missing-input matrix)

Two gates, both published constants:

- `minInputsToScoreAtAll = 2` — below this, **no score is emitted at all**. An honest absence beats a
  confident number built from one signal.
- `minInputsForFullScore = 3` — a **full** score requires the HRV anchor **and** at least this many
  inputs. Anything else that still scores is a **reduced-input variant**, labelled distinctly (the
  variant names exactly which inputs are missing) so a thinner score is never passed off as the full
  one.

A vital with **no personal baseline yet** is treated as absent — scoring it would require a population
norm, which v1 forbids.

| HRV | RHR | RR | Sleep | n | Scoreable? | Variant | Confidence cap¹ |
|:---:|:---:|:--:|:-----:|:-:|:----------:|---------|:---------------:|
| ✓ | ✓ | ✓ | ✓ | 4 | yes | full | 1.0 |
| ✓ | ✓ | ✓ | ✗ | 3 | yes | full | 0.8 |
| ✓ | ✓ | ✗ | ✓ | 3 | yes | full | 0.9 |
| ✓ | ✗ | ✓ | ✓ | 3 | yes | full | 0.8 |
| ✓ | ✓ | ✗ | ✗ | 2 | yes | reduced (n < 3) | 0.7 |
| ✓ | ✗ | ✗ | ✓ | 2 | yes | reduced (n < 3) | 0.7 |
| ✓ | ✗ | ✗ | ✗ | 1 | **no** | — | — |
| ✗ | ✓ | ✓ | ✓ | 3 | yes | reduced (no HRV) | **0.5** |
| ✗ | ✓ | ✗ | ✓ | 2 | yes | reduced (no HRV) | **0.4** |
| ✗ | ✗ | ✓ | ✓ | 2 | yes | reduced (no HRV) | **0.3** |
| ✗ | ✓ | ✓ | ✗ | 2 | yes | reduced (no HRV) | **0.3** |
| ✗ | (any single) | | | 1 | **no** | — | — |

¹ The cap is the **weight-coverage** — the fraction of the intended weight mass actually present
(HRV 0.5 + RHR 0.2 + RR 0.1 + Sleep 0.2). Because a missing HRV removes 0.5 of the mass, a missing-HRV
score can **never** exceed 0.5 confidence — the reduced-input cap falls out of the published weights
with **no separate magic constant**.

## Confidence

`confidence = weightCoverage × baselineMaturity`, in `[0, 1]`, stored on the row's `confidence`
column:

- **weightCoverage** — as above, the present weight mass over the full mass (the completeness cap).
- **baselineMaturity** — the *least* mature contributing baseline's maturity (`points / window`,
  clamped), so a still-calibrating input honestly drags the number down; the sleep term contributes
  its own `sleep.performance` confidence.

Surfaced as words in casual mode ("early estimate" / "established") and as the number in power mode
(plan §18).

## Provisional / cold start

`provisional` is a **cold-start / not-yet-validated** fact, independent of completeness: a row is
provisional when the **algorithm** is provisional (it is, today, pending A3), or **any** contributing
baseline (or the sleep term) is still provisional. Nothing renders as a confident score while a
contributing baseline is provisional — the cold-start rule (§18) is upheld here, and the reduced-input
completeness signal lives separately in `confidence`, so the two facts are never collapsed.

## Two-source conflict — which device fed the score

Interval-record vitals are **not** run through dedup-lite (that reconciles sleep/workout *sessions*),
so when a phone and a watch both report last night's HRV, **both** survive as live rows (I3 — nothing
is deleted). `ReadinessEngine` resolves the conflict at read time using the **same source-priority
order** ingestion assigns (a wrist device outranks a phone): the highest-priority source wins, ties
break by most-recent `updatedAt` then `sourceId`. The **winning record's id** is what the
`InputManifest` carries, so the anatomy sheet can resolve it to the device and show **which watch fed
the score** — the loser stays in the database, inspectable (plan §18: "anatomy sheet shows which
device fed the score").

## Morning trigger, append-only recompute & the v1 → v2 migration

- **Trigger.** `compute(asOf:)` runs once per morning when overnight data lands (the composition lane
  owns the schedule). It computes the score for `asOf`'s local day and appends it.
- **Late data (I2).** If late overnight data arrives, a recompute **appends** a fresh `DerivedValue`
  with a new `computed_at`; the prior row is retained, so "what BADAN believed at the time" is
  preserved. A repeat trigger over unchanged data is idempotent (an identical v2 row is skipped).
- **v1 → v2 migration.** The interim MVP composite (`BaselineEngine.appendReadinessScore`) stamped
  `composite.readiness_score@1.0.0`. This engine writes **new** rows stamped `@2.0.0`. Migration is
  **not a rewrite**: every `@1.0.0` row keeps its old id and is never touched (I2); the "latest
  `computed_at` wins" read then naturally surfaces the v2 value. A v1 row never blocks the first v2
  write.

## Anatomy sheet

The `InputManifest` is the anatomy sheet's source of truth. Each input row carries the raw measured
`value` (which resolves, via `recordId`, to the exact record and its device — lineage, I1/I5) and, in
`weight`, that input's **additive contribution** to the composite (points out of 100). Σ(contributions)
== the score, so the contribution bars, the formula above, and the stamped `algorithm_version` are all
the sheet needs to answer "why is it saying that?".

## Testing

Cross-platform composite goldens (`ReadinessEngineTests` on iOS, `ReadinessEngineGoldenTest` on
Android) assert **identical** scores, confidences, variants and per-input contributions for the same
inputs against the same published weights — including the full missing-input matrix and the confidence
cap. iOS additionally covers the DB orchestration the pure core cannot: the two-source-HRV conflict
resolving to the priority device (visible in the manifest lineage), reduced-input confidence capping
through the engine, append-only recompute on late data (I2), and the v1 row surviving untouched while
v2 supersedes it.
