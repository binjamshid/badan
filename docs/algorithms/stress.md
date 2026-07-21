# Stress — `stress.day_trend` (device-gated)

> Status: **provisional, semver 0.2.0** (constants are a stated default, not yet validated against
> data; every row is flagged `provisional`) · Engine: `StressEngine` (iOS
> `Sources/Domain/Derivation/StressEngine.swift`, Android `domain/derivation/StressEngine.kt`) ·
> Constants: `packages/contracts/algorithms/algorithms.json` (`stress.day_trend`) · Owner: EPIC-34 ·
> Approval: **confidence-copy review**.
>
> **Where this runs.** Two entry points, and the difference between them is the point. `evaluate` is
> the **surface read**: the Health Monitor's stress card (`StressTrendCard` on iOS, `StressCard` on
> Android) constructs the engine on load, calls it, and renders whichever of the three states comes
> back. It writes nothing — the right contract for a surface whose common answer is "hidden", because
> an absence must not be stored at all. `compute` runs the same decision and then **appends** a
> `stress.day_trend` row on a day the gate allows a trend; that is the derivation pipeline's call, not
> a screen's, and it is step 5 of `DerivationCoordinator`'s produce order on iOS. The Android
> coordinator has not picked it up yet, so on that platform the card's gate is live but no row is
> written outside the test suite.

## The gate is the feature

Plan §11 calls a real-time stress monitor *"the biggest false-precision trap in the plan"*, and the
reason is physical rather than editorial. A continuous stress index needs **dense daytime
heart-rate-variability sampling** — a reading every few minutes, all day. An Apple-Watch-class
wearable writes a handful of HRV samples a day, most of them overnight. Fitting a live "your stress
is 62 right now" to that data would be fiction with a progress ring around it, and it would be the
most confident-sounding thing in the app.

So the primary output of this algorithm is not a number. It is a **decision about whether BADAN has
earned the right to say anything at all**, and the honest answer for most users today is *no* —
shipped as a first-class state with an explanation, not as an empty view and not as a number with a
caveat under it.

## Three surface states, and only three

The density detector classifies the trailing week into exactly one of three states. The read model
(`StressSurface`) is a closed enum on both platforms specifically so a surface cannot assemble a
fourth state out of the parts.

| State | Condition | What may be shown |
|---|---|---|
| **dense** | ≥ `denseMinSamplesPerHour` daytime samples per waking hour | Would support a full intraday index. **Not implemented in this phase** — the flag is `false` in code (`StressEngine.intradayIndexImplemented` on iOS, `StressEngine.INTRADAY_INDEX_IMPLEMENTED` on Android), and a dense-classified window renders the same *daily* trend plus an honest "the intraday view isn't available yet". Vendor-dense ingestion is Phase 4. |
| **moderate** | ≥ `moderateMinSamplesPerHour` | A **daily** trend, and nothing finer. Confidence is capped at `moderateConfidenceCap` by the engine, so "low confidence" is structural rather than a copy choice. Never a live number. |
| **insufficient** | below the moderate floor, or too few covered days, or too little recorded waking time | **Hidden**, with an explanation. This is the default for Apple-Watch-only data. |

### The absence copy is about the device

Every hidden state names its reason (`StressAbsenceReason`), and each reason carries its own
bilingual sentence — English and Arabic, authored on the reason itself so there is no code path that
produces a hidden surface without a rendered explanation.

| Reason | English |
|---|---|
| `daytimeHrvTooSparse` | "Your device doesn't record daytime heart-rate variability often enough for this." |
| `noDaytimeHrv` | "No daytime heart-rate variability readings arrived this week, so there's nothing to read here." |
| `tooFewDaysCovered` | "Daytime readings arrived on too few days this week to describe a pattern." |
| `notEnoughWakingCoverage` | "There aren't enough recorded waking hours this week to judge how often your device samples." |
| `stillLearningDaytimePattern` | "Still learning your usual daytime pattern — this needs a few more weeks of readings." |
| `tooFewRecentDays` | "Too few days with daytime readings in the last week to show a trend." |
| `contractUnavailable` | "This measure isn't available in this version of the app." |

Two properties of this table are asserted by tests rather than left to review. First, the sparse-device
sentence is a statement about **the device's sampling** — it names the device, and a copy lint fails
the build if it drifts into blaming the user ("wear your watch more") or reading as a BADAN error.
Second, `stillLearningDaytimePattern` deliberately does **not** mention the device: it is the
cold-start state a vendor-dense user hits in their first fortnight, and telling an Oura user their
device samples too rarely would simply be false.

## Density detection

```
daytime hours (per day) = local day length − ∪ (sleep sessions overlapping the day)
daytime samples         = heart.hrv readings whose instant falls outside every sleep session
samplesPerHour          = Σ daytime samples ÷ Σ daytime hours     (over densityWindowDays)
```

Details that matter:

- **Sleep windows are excluded, naps included as sleep.** Daytime is the entire point: an overnight
  HRV series says nothing about waking autonomic load, and counting it would unlock the gate for
  exactly the users the gate exists to protect. A nap is chronologically daytime and physiologically
  sleep, so it is excluded too.
- **Overlapping sleep sessions are unioned, not summed.** Two devices recording the same night both
  survive ingestion (dedup suppresses, never deletes — I3). Summing them would shrink the waking day
  and *inflate* samples-per-hour, which is the one direction the gate must never err in.
- **Day length is calendar-derived**, so a 23- or 25-hour DST day is 23 or 25 hours of denominator.
- **Three independent gates**, all of which must pass: the rate, at least
  `minDaysWithDaytimeSamples` of the window's days carrying a reading (one dense day cannot unlock a
  week), and at least `minDaytimeHoursInWindow` of recorded waking time (three samples in one waking
  hour is 3.0/hr arithmetically and evidence of nothing).
- **Boundaries are inclusive**: a rate exactly on a threshold clears it. Both platforms pin every
  boundary at the exact sample count, one sample either side.

For scale: an Apple-Watch-only user typically lands near **0.1 samples per waking hour**; the
moderate floor is **0.5**; vendor-grade continuous sampling is **4.0+**.

## The daily trend index (moderate and dense states)

A four-step method, all of it published and all of it per-day:

1. **Daily value.** Each day's daytime HRV samples collapse to their **median**. A day with fewer than
   `minDaytimeSamplesPerDay` samples produces no value at all — it is a gap, never imputed (plan §18:
   "no imputation of physiological inputs, ever").
2. **Personal daytime reference.** Robust centre and spread of `ln(dayValue)` over the trailing
   `referenceWindowDays`, requiring at least `minReferenceDays` daily values. Log domain because HRV
   is right-skewed, matching [baselines.md](baselines.md). Below the minimum the surface is hidden as
   *still learning*.
3. **Daily load sub-score.**

   ```
   z      = ( ln(dayValue) − logCentre ) / ( madToSigma · logMAD )
   load_d = 50 − clamp(z, ±zClampSigmas) / zClampSigmas · 50
   ```

   **50 is your own usual.** The sign is inverted relative to HRV: a daytime median *below* your
   reference reads *above* 50 (more autonomic load), above it reads below 50. A perfectly flat
   reference (zero spread) yields exactly 50 rather than an infinite z — flat data is not evidence.
4. **Recency-weighted trend.**

   ```
   w_d   = 0.5 ^ ( ageInDays / trendHalfLifeDays )
   trend = Σ ( load_d · w_d ) / Σ w_d          over the trailing trendWindowDays
   ```

   requiring at least `minTrendDays` present days. The smoothing constant is in **days** by
   construction: there is no intraday smoothing parameter in this algorithm because there is no
   intraday output to smooth.

The value is rendered as a coarse direction — below / about / above your usual, using
`bandNeutralHalfWidth` either side of 50 — at the casual altitude, with the number, the day count and
the confidence available at the power altitude. Same computation, two altitudes (D-5).

### Why not the `heart.hrv` baseline?

EPIC-23 already maintains a personal `heart.hrv` baseline, and reusing it would have been the obvious
shortcut. It would also have been wrong: that baseline is dominated by **overnight** readings, and
overnight HRV runs systematically higher than daytime HRV. Reading a daytime median against an
overnight-weighted centre would report "elevated load" every single day of a user's life — a bias
that would look like a signal. Daytime is compared with daytime, or with nothing.

The engine still reuses the baseline layer's published robust-statistics primitives (median, MAD) and
reads `madToSigma` from the **baseline contract entry** rather than re-declaring it, so there is
exactly one definition of each in the codebase.

### Confidence and the provisional flag

```
confidence = min( cap , (daysPresent / trendWindowDays) × (referenceDays / referenceWindowDays) )
cap        = denseConfidenceCap   (dense)  |  moderateConfidenceCap  (moderate)
```

A moderate-density trend is stamped `provisional = true` **by construction**, independent of whether
the algorithm's own constants are validated: sparse daytime sampling cannot produce an established
reading, and the row must say so wherever it is read.

## What this engine will not do

- **No live or instantaneous value, in any state.** Every row is keyed `day:<YYYY-MM-DD>` and
  `StressTrend` carries the window it describes; the type has no timestamp field, so it structurally
  cannot express "now".
- **No notifications.** Plan §5.4 defers stress-spike alerts behind a confident index that does not
  exist yet; this engine raises none.
- **No writes on a hidden day.** An absence is not stored as a zero, a null row or a "no data"
  sentinel. It is simply absent, and the surface explains it.
- **No population norms.** Every comparison is against the person's own recent daytime pattern.

## Storage and sensitivity (I7)

`stress.day_trend` is classed `sensitivePlus` in the metric ontology — an inference about someone's
daily state is lifestyle-revealing in the way the raw HRV it is computed from is not. That class is
what excludes it from any export that has not opted into sensitive data
(`ExportRunner.metricAllowed`), and a test pins the classification so a future ontology edit cannot
silently downgrade it.

**Known gap, stated plainly:** the row itself is written to the main derivation table, because
`derived_values` exists only in the main database — there is no derived-value table in
`badan_sensitive.db` today. So a sensitive-namespace purge (`Database.purgeSensitiveNamespace()`)
removes the medications/symptoms/journal namespace but does **not** remove `stress.day_trend` rows.
Closing that requires a sensitive-side derived store (a migration, and a decision about every
sensitive-class derived metric — `cycle.*`, `lab.*`, `subjective.*` are in the same position), which
is deliberately out of EPIC-34's scope rather than half-done inside it.

## Constants (from `algorithms.json`)

| Param | Value | Meaning |
|---|---|---|
| `densityWindowDays` | 7 | trailing days the density detector measures over |
| `denseMinSamplesPerHour` | 4.0 | dense floor (~a reading every 15 waking minutes) |
| `moderateMinSamplesPerHour` | 0.5 | the floor for saying anything at all |
| `minDaysWithDaytimeSamples` | 5 | of the 7, days that must carry a reading |
| `minDaytimeHoursInWindow` | 24 | waking hours before a rate is meaningful |
| `minDaytimeSamplesPerDay` | 2 | below this, the day is a gap |
| `referenceWindowDays` | 28 | trailing window of the personal daytime reference |
| `minReferenceDays` | 14 | below this → hidden as *still learning* |
| `trendWindowDays` | 7 | the sliding window the value describes |
| `minTrendDays` | 4 | present days required inside it |
| `trendHalfLifeDays` | 2.0 | recency weighting `0.5^(age/halfLife)` |
| `zClampSigmas` | 2.5 | robust-z clamp (shared convention with readiness) |
| `bandNeutralHalfWidth` | 10 | half-width of the "about your usual" band |
| `moderateConfidenceCap` | 0.5 | hard ceiling on a moderate-density trend's confidence |
| `denseConfidenceCap` | 1.0 | the ceiling that would apply to vendor-dense data |
| `madToSigma` | 1.4826 | read from `baseline.rolling_median_mad`, never re-declared here |

## Versioning

`stress.day_trend` is **`0.2.0`, provisional**. `0.1.0` was a Phase-0 placeholder param schema seeded
before the engine existed (`minSamplesPerHour` / `minCoveredHours` / `smoothingHalfLifeHours`); no
`StressEngine` ever loaded it, so no `DerivedValue` anywhere carries `stress.day_trend@0.1.0`. The
version was still bumped rather than edited in place, because a shipped bundle contained those
constants and I2 auditability is only worth anything if version ids are never quietly reused. Tuning
any constant above is a further semver bump; old rows keep the version that produced them (I2) and
are never rewritten.

## Tests

`StressEngineTests` (iOS) and `StressEngineGoldenTest` (Android) assert the same numbers against the
same published constants. The Android suite is pure-JVM (no DB harness on that platform, per
`BaselineEngineGoldenTest`'s note) and carries the gate, the trend math, the surface states and the
copy lint; the iOS suite adds the DB-backed paths — daytime bucketing, sleep-window exclusion,
append-only persistence and idempotency. Between them they pin: every density threshold at its exact
boundary (one sample either side), the Apple-Watch-only fixture as hidden, overnight readings as *not*
daytime evidence, the moderate confidence cap, thin days as gaps, and the fact that no state emits
anything other than a day-keyed trend.
