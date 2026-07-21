# Health Monitor — `DeviationEngine`

> Status: **published** · Engine: `DeviationEngine` (iOS `apps/ios/Sources/Domain/Derivation/DeviationEngine.swift`,
> Android `apps/android/.../domain/derivation/DeviationEngine.kt`) · Reads: `Baseline` rows
> (`baseline.rolling_median_mad`, see [`baselines.md`](baselines.md)) + `sensor_quality.json` ·
> Owner: EPIC-27.

The Health Monitor is a vitals dashboard — resting heart rate, heart-rate variability, respiratory
rate, blood-oxygen, and wrist-temperature **deviation** — that shows each vital against **your own**
personal band and labels **how much the sensor behind the number is worth**. It is `whoop.md` §5's
trust differentiator: transparent bands and honest source labels instead of an opaque colour.

## What the engine does — and, deliberately, does not do

`DeviationEngine` **writes nothing**. It is a read model, the same shape as
`BaselineEngine.calibration(...)`: for each vital it reads the latest raw reading and the personal
`Baseline` band EPIC-23 already materialized, and classifies where the reading sits.

There is **no new score and no new `DerivedValue` row here**. Band classification is a deterministic
position comparison — is the value below `bandLow`, above `bandHigh`, or between — and the tile
exposes the value **and** the band edges, so the user can verify the position themselves. The band it
compares against carries its own `AlgorithmVersion` and input manifest (documented in
[`baselines.md`](baselines.md)); the Health Monitor inherits that provenance rather than inventing a
second number that would need auditing of its own. A stored "health score" with no formula behind it
is exactly what the anatomy sheet exists to prevent, so the engine does not create one.

The classification core (`makeTile`, `tempDirection`, `buildSparkline`, `resolveSourceQuality`, and
all the copy) is **pure and identical on both platforms** — the same input produces the same tile and
the same bilingual string on iOS and Android, asserted by mirrored golden tests
(`DeviationEngineTests` / `DeviationEngineTest`).

## The read model

One `VitalTile` per tracked vital, plus a mandatory footer. Per tile:

- **current value** — the latest reading, or `null` (a first-class *no-data* state, never a zero);
- **personal band** — `low`/`high`/`center` from the `Baseline` row, with its `provisional` flag,
  point count, window, and the `baselineId` + `algorithmVersion` that drew it (for the anatomy sheet);
- **state** — `withinBand` / `belowBand` / `aboveBand` for an established band; `calibrating` while
  the band is provisional or absent; `noData`; or, for temperature, `deviation(direction)`;
- **staleness** — `isStale` when the reading's day is older than the freshness horizon; the last
  known position is still shown, framed "as of <day>" rather than as a live verdict;
- **calm annotation** — a wellness-safe, directional note when the reading sits outside the usual
  range (see *Wellness-safe language*); suppressed when stale, absent when within band / no data;
- **sparkline** — recent per-day series, with missing days preserved as **gaps, never zeros**;
- **sensor-quality label** — resolved for the source that produced the latest reading (see below).

## Band classification

Given an established (non-provisional) band, the latest value is classed by `Baseline.position(of:)`:

| Value vs band | State | Annotation |
|---|---|---|
| `value < bandLow` | `belowBand` | "Your latest reading sits below your usual range." |
| `bandLow ≤ value ≤ bandHigh` | `withinBand` | *(none — calm silence)* |
| `value > bandHigh` | `aboveBand` | "Your latest reading sits above your usual range." |

A band edge is **inclusive** (`within`), matching `Baseline.position(of:)`. While the band is
`provisional` or absent, the state is **`calibrating`** — the reading is shown but **no in/out-of-range
verdict is made**. This is the plan §18 cold-start rule: nothing renders as a judgement until the
personal band is honest (`n ≥ 7` and half the window filled — see [`baselines.md`](baselines.md)).

## Temperature is deviation-only, by construction

Wrist temperature is stored as `body.wrist_temp_deviation` — the value **is** the deviation from the
person's own overnight usual level (°C), never an absolute skin temperature. The registry marks it
**non-baseline-eligible** for this reason, so no band is ever drawn for it.

The read model enforces this **in its shape**: `VitalReading` has two cases, `absolute(Double)` and
`deviation(Double)`, and there is deliberately **no case that can hold an absolute temperature**.
`makeTile` gives any id in `deviationVitals` (currently just wrist temperature) a `deviation` reading
and a `null` band **regardless of what is passed in**. A reviewer cannot surface an absolute skin
temperature in the UI without first adding a case to `VitalReading` — the friction is the point.

Direction comes from the sign of the deviation only (`aboveUsual` / `belowUsual` / `atUsual`). No
magnitude threshold is applied: without a personal spread of deviations, any "how far is meaningful"
cut-off could only be a population norm, which v1 does not use.

## Per-source sensor-quality

Every tile is labelled with how much the **sensor class** behind its latest reading is worth for that
metric's family, resolved from `packages/contracts/sensor_quality.json` via `SensorQualityMap`:

1. the source's devices are matched to a **sensor class** by keyword (`classId(for:devices:)`);
2. the class's entry for the metric's **family** gives the level (`level(sourceClassId:family:)`).

This is an **honesty surface, not a ranking**: a `low` label never suppresses, hides, downweights, or
paywalls a reading — raw data is not paywalled, and which of two duplicate readings survives is
decided by source priority + the dedup journal (I3, I4), not by this file. `low` on wrist temperature
is a statement about optical wrist sensors, never about the person.

Resolved levels for the Health-Monitor vitals (from the published contract):

| Sensor class | RHR / HRV (`heart`) | RR / SpO₂ (`respiratory`) | Wrist-temp deviation (`body`) |
|---|---|---|---|
| Watch / wristband (`wrist_wearable`) | high | medium | low |
| Smart ring (`ring_wearable`) | high | medium | low |
| Chest strap (`chest_strap`) | high | medium | *(unsupported)* |
| Phone (`phone_handset`) | *(unsupported)* | *(unsupported)* | *(unsupported)* |
| Clinical device / lab (`clinical_device`) | high | high | high |

An unrecognised source falls back to its source-type default (`unknown` → `medium` everywhere) — an
honest "we can't tell you more about this sensor", never a guess dressed as a fact. Class assignment
lives in code, not in the contract, exactly as the contract instructs (model strings churn faster
than a shared contract should). The label copy (`SensorQualityLevel.label`/`.explainer`) is authored
bilingually and describes the **method** ("Measured directly" / "Estimated"), never a grade.

## No-data and stale are first-class

- **No data** — a vital with no reading in the store renders a `noData` tile: no value, no band
  verdict, no crash, and never a fabricated zero. Missing days inside a sparkline are `null` points
  (gaps), never zero-filled.
- **Stale** — a reading older than `staleAfterDays` (below) is marked `isStale`. The engine still
  shows the last known position but suppresses the "latest reading" annotation, because "your latest
  reading sits above your usual range" would misread as *current* when the reading is days old; the
  tile's `asOfDay` carries the honest "as of <day>" framing instead.

## Wellness-safe language

Every string ships **en + ar**, authored (never machine-translated), and stays calm:

- annotations are **directional and personal** ("above your usual range"), never a verdict, a
  diagnosis, or an instruction — no "abnormal", no "do not…", no alarm;
- the mandatory persistent footer states what the surface is, not a judgement:
  > **en:** "This is a wellness overview, not a medical evaluation. It reflects your own past readings."
  > **ar:** "هذه نظرة عامة على العافية، وليست تقييماً طبياً. تعكس قراءاتك السابقة الخاصة بك."

Both the footer's presence and a banned-frame lint over the annotations are asserted by the engine
tests (`testDisclaimerIsThePersistentMedicalFooter`, `testAnnotationsCarryNoAlarmOrDiagnosisFrames`)
so a future copy edit cannot quietly reintroduce alarm or diagnosis language.

## Presentation parameters (`DeviationConfig`)

These are **read-model presentation** parameters, **not** score constants — the band math and its
constants live in `algorithms.json` and belong to `BaselineEngine`. They are named, documented
defaults, identical on both platforms by construction:

| Parameter | Default | Meaning |
|---|---|---|
| `sparklineDays` | 14 | calendar days of recent per-day history a tile's sparkline covers |
| `staleAfterDays` | 2 | a reading whose day is more than this many days before the as-of day is stale |

`staleAfterDays` is 2 because the tracked vitals are overnight and roughly once-daily; a two-day-old
resting heart rate is honestly "as of Tuesday", not a live "now".
