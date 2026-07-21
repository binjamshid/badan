# Behaviour correlations — `journal.correlation`

> Status: **provisional, semver 0.1.0** (constants are a stated default, not yet validated against
> data; every row is flagged `provisional`) · Engine: `CorrelationEngine` (iOS
> `Sources/Domain/Derivation/CorrelationEngine.swift`, Android
> `domain/derivation/CorrelationEngine.kt`) · Constants:
> `packages/contracts/algorithms/algorithms.json` (`journal.correlation`) · Owner: EPIC-29 ·
> Approval: **stats-copy review**.
>
> **Where this runs.** The correlations screen is the caller, on both platforms:
> `CorrelationsViewModel.fetch` (`apps/ios/Sources/Features/Insights/CorrelationsScreen.swift`) and
> `loadCorrelations` (`features/insights/CorrelationsScreen.kt`) construct `CorrelationEngine` off
> the main thread and call `recompute`, which evaluates every behaviour × score pair and appends the
> ones that clear the gates. The screen is reached from the correlations card on the Insights feed,
> which is itself behind the sensitive-records toggle. Nothing else constructs the engine — it is not
> in `DerivationCoordinator`'s produce order, so a finding row exists only after that screen has been
> opened. A nightly job is the right long-term home for the *write* half; the *read* half would still
> have to run the evaluation, because a suppression is deliberately never persisted and the "not yet,
> about N more days" rows can only come from a live run.
>
> Reading a stored finding back (`CorrelationFinding.from`) is a written, round-trip-tested contract
> with **no app caller yet**: both surfaces render the outcomes `recompute` just returned, not rows
> re-read from the database.

## What this answers, and what it refuses to answer

The question is: *"on the days I logged X, did the next day's score tend to look different?"*

It is **not**: "does X cause Y", "is this statistically significant", or "should I stop doing X".
The engine emits an association between two groups of the user's own days, with the sample size and
the uncertainty attached, and every rendered card carries a locked line saying exactly that.

The valuable part of this feature is what it *declines* to say. Any arithmetic can produce a
difference between two groups of days; a correlations screen that only ever shows hits is a slot
machine with a health theme. Three rules make this one different, and all three are enforced in code
and pinned by goldens on both platforms:

1. **Minimum-n suppression is mandatory.** Below the gates, nothing is computed, nothing is stored,
   and nothing is shown but "not yet, and here's how far off you are".
2. **Null results are reported.** Above the gates, an interval that straddles zero renders as "no
   clear association" — a first-class outcome with authored bilingual copy, not an empty state and
   not a quiet omission from the list.
3. **Nothing parametric.** Cliff's delta and a bootstrap, both distribution-free.

## The day model

For one behaviour and one score, each local day the user **journaled at all** becomes one
observation:

| field | meaning |
|---|---|
| `dayKey` | the local day, in the timezone the entry was recorded in |
| `present` | the behaviour was asserted that day (`JournalEntry.isPresent`) |
| `nextDayScore` | the score for `dayKey + 1` |
| `inDeclaredContext` | a `ContextStatus` (travel/illness/fasting/altitude/injury) overlapped the day |

Three choices in that table are load-bearing:

**Only journaled days count.** A day with no journal activity is *not* evidence the behaviour was
absent — it is evidence of nothing. Filing such days in the "without" arm would manufacture an arm
out of days the user simply did not open the app, and would make every behaviour look rarer and more
consequential than it is. So the observation frame is "days with at least one journal entry", and
everything else is outside the analysis.

**An explicit zero is an absence.** "I had no coffee today" is real information a user can enter
(`valueKind: count`, `value: 0`), and it lands in the *without* arm. `JournalEntry.isPresent` is the
single definition of that split.

**The score is the NEXT day's.** The behaviours in `behaviors.json` happen during a day; the score
they could plausibly line up with is the one computed from the night that follows. Days whose next
day has no score are dropped **before** the gates are judged — they can pair with nothing, so
counting them toward a minimum would let the gate be cleared by days that contribute nothing.

Scores correlated against (`MetricID.correlatedScores`): `readiness.score`, `sleep.performance`,
`effort.day`. Deliberately a short closed list rather than "every derived metric" — correlating a
behaviour against every id in the registry would be a multiple-comparisons machine that manufactures
findings.

## The gates

Both are mandatory and are checked **before** any effect size is computed. (Computing first and
gating afterwards would give the same visible result today and a tempting `if showAnyway` tomorrow.)

| gate | constant | value |
|---|---|---|
| paired days, both arms together | `minObservedDays` | **14** |
| days in **each** arm | `minDaysPerArm` | **5** |

Below either gate the outcome is `suppressed`, carrying which gate failed and how many more days
would clear it. **Nothing is written to the database.** That is the storage half of the invariant: a
suppressed finding must not exist as a row that some future read path could pick up and render
without re-checking the gate.

Three suppression messages exist rather than one, because the shortfalls are different and so is
what resolves them: too few days overall ("keep journaling"), too few days *with* the behaviour, and
too few days *without* it (the near-daily-habit case, where a comparison has almost nothing to
compare against).

## Effect size — Cliff's delta

For the behaviour-present arm *X* and the behaviour-absent arm *Y*:

```
delta = ( #{(x,y) : x > y} − #{(x,y) : x < y} ) / (|X| · |Y|)
```

Positive means the next-day score tended to be **higher** after the behaviour. Ties count for
neither side, so identical arms give exactly `0` rather than a small artefact. The range is −1…+1.

**Why not a t-test, a mean difference, or Cohen's d.** The arms are two handfuls of daily scores —
often 7 against 9 — drawn from bounded, skewed distributions: a readiness score is capped at 100 and
piles up near the person's own typical band. A t-test would assume approximate normality and return
a precise-looking p-value computed from a shape the data does not have; the number would be the most
confident-sounding thing on the screen and the least earned. Cliff's delta assumes only that the
values can be **ordered**, which is exactly what is true of them.

Implementation is the naive `O(n·m)` double loop rather than the sorted rank form: the double loop
*is* the definition — a reader can check it against the formula above without trusting a rank trick,
which for the one number this feature rests on is worth more than the asymptotics. The cost was
measured rather than assumed, because this runs 2000 times per finding inside the bootstrap: the
true worst case — every one of ~28 behaviours × 3 scores clearing the gates with both arms at 60
days, the most `lookbackDays` allows — is **1.1 s for the whole batch** in an optimised build. That
batch runs from the correlations screen's load path, on a background thread, so the cost lands as
*time to first render on that screen* and never as main-thread jank; the screen shows its loading
state until it finishes. If `lookbackDays` or the behaviour vocabulary grows by an order of
magnitude, measure again rather than assuming it still holds.

Magnitude wording (Romano et al. 2006 thresholds) is used **only** to pick a strength word in copy,
never to decide whether a finding is shown — the interval decides that:

| \|delta\| | word | constant |
|---|---|---|
| < 0.147 | negligible | `negligibleDeltaThreshold` |
| < 0.33 | small | `smallDeltaThreshold` |
| < 0.474 | moderate | `mediumDeltaThreshold` |
| ≥ 0.474 | large | — |

## Interval — percentile bootstrap

95% interval, percentile method, **stratified** and **seeded**.

- `bootstrapIterations` = **2000** resamples.
- Each resample draws each arm **with replacement to its own original size**, so the with/without
  balance of the real sample is preserved. Pooling the two arms and re-splitting would silently
  answer a different question.
- Draw order per iteration is fixed: all "with" draws, then all "without" draws.
- Percentile indices, over the `B` sorted resample deltas:

  ```
  lowIndex  = floor(ciLowerPercentile · B)                  = floor(0.025 · 2000) = 50
  highIndex = min(B − 1, ceil(ciUpperPercentile · B) − 1)   = ceil(0.975 · 2000) − 1 = 1949
  ```

  Written out because "the 2.5th percentile" is not one definition — statistical libraries
  interpolate differently — and this one has to be reproducible by hand and identical on two
  platforms.

### The seed, and why it is published

A bootstrap is random by nature. An unseeded one would return a slightly different interval on every
recompute and a different interval on each platform, and **a confidence interval that changes when
you reopen the app is not a confidence interval**. So:

- `bootstrapSeed` = **29**, a published constant in `algorithms.json`. The value is arbitrary (the
  epic number); what is load-bearing is that it never changes.
- The generator is **splitmix64**, written out in both codebases rather than taken from either
  platform's standard library — `SystemRandomNumberGenerator` and `kotlin.random.Random` produce
  different sequences from the same seed. splitmix64 is arithmetic only (wrapping multiply, xor,
  logical shift), so Swift's `UInt64` and Kotlin's `Long` with `ushr` produce the identical bit
  sequence. Draw indices take the high 31 bits (`>> 33`), because splitmix64's low bits are its
  weakest.

The result is that `delta`, `ciLow` and `ciHigh` are pure functions of the input days. The shared
fixture (`packages/fixtures/correlation/`) asserts the exact doubles on both platforms to `1e-12`.

### The interval decides the direction

| condition | outcome | template |
|---|---|---|
| `ciLow > 0` | next-day score ran higher | `journal_correlation_higher` |
| `ciHigh < 0` | next-day score ran lower | `journal_correlation_lower` |
| interval spans 0 | **no clear association** | `journal_correlation_none` |

A delta of −0.4 whose interval runs from −0.8 to +0.1 is "no clear association". Reading it as
"lower" because the centre happens to be negative is precisely the failure this engine exists to
refuse, and it is pinned by its own test.

## Confidence

Not a p-value, and never rendered as one. It is a display weight, published as the product of two
factors:

```
sampleFactor    = min(1, nPaired / confidenceFullNDays)     (confidenceFullNDays = 30)
precisionFactor = 1 − (ciHigh − ciLow) / 2                  (2 = the full range of Cliff's delta)
confidence      = sampleFactor × precisionFactor
```

More days and a tighter interval earn more weight; a near-total interval earns almost none. The
numbers it is derived from — `n` and the interval — are shown next to it in power mode, so a reader
can check it rather than take it on faith.

## Context statuses annotate; they never edit

If the window overlaps a declared `ContextStatus`, the overlapping days are **counted, kept, and
disclosed**, and the confidence is capped at `ContextAnnotator.activeContextConfidenceCeiling`
(0.7). The days are not dropped, weighted down, or adjusted:

- Removing a travel week would silently change what the finding is about, and the resulting number
  would describe a life the user did not live.
- The stored `value`, the interval and the arm counts are byte-identical with and without the
  annotation — only the confidence and the copy change. There is a test that asserts exactly that.

The ceiling lives once, in `ContextAnnotator`, alongside the caveat sentences it belongs with. It is
deliberately **not** re-declared in the correlation params block — the same rule `stress.day_trend`
follows for `madToSigma`, and there is a test asserting the duplicate does not exist.

## Storage — and why it is in the sensitive database

A finding is a `DerivedValue`:

| field | value |
|---|---|
| `metricId` | `journal.correlation.<behaviorId>.<scoreId>` |
| `value` | Cliff's delta |
| `unit` | `index` |
| `periodKey` | `window:<firstDayKey>..<lastDayKey>` |
| `confidence` | as above |
| `provisional` | `true` while the contract entry is provisional |
| `inputManifestId` | the manifest below |

`DerivedValue` carries one number, and a correlation is `n`, an effect size, two interval bounds and
two arm counts. Rather than a parallel table or a JSON blob in a column, the statistics ride in the
**`InputManifest`** — which is what the manifest is for ("the records that fed a derived value") —
under reserved `stat:` record ids: `stat:n`, `stat:n_with`, `stat:n_without`, `stat:delta`,
`stat:ci_low`, `stat:ci_high`, `stat:median_with`, `stat:median_without`, `stat:context_days`. The
per-day inputs follow, each carrying the score row's id, its value, and the **arm in `weight`**
(1 = behaviour-present, 0 = absent). `CorrelationFinding.from(...)` is the matching reader and the
round trip is asserted, so this is a contract rather than a convention someone has to know.

**The reader fails closed.** A manifest that is missing, undecodable, or short of any statistic the
reader needs — either interval bound above all — rebuilds **nothing**. It does not fall back to the
point estimate: `ciLow = ciHigh = delta` would make [the interval decide](#the-interval-decides-the-direction)
a confident "higher"/"lower" out of an interval nobody computed, over `n = 0`, which is the worst
failure this feature has available to it. Both suites pin that a finding rebuilt without its bounds
is refused rather than rendered as a direction.

**Placement (I7).** These rows live in `badan_sensitive.db` (sensitive migration v4), not in
`badan.db`. The metric id *is* the disclosure: `journal.correlation.alcohol.readiness.score` says
the user logs alcohol, in a column, in plain text, before any value is read. A row in the main
database would survive `Database.purgeSensitiveNamespace()` — a literal file deletion — and keep
disclosing it after the user had turned sensitive records off.

This is deliberately not how `stress.day_trend` works, and the difference is principled rather than
inconsistent: that metric is sensitive-plus too, but its id names no behaviour, so only its *value*
is revealing and the registry's `sensitiveClass` gate on the export path is enough. Here the
identifier itself leaks, so placement has to carry the guarantee.

Findings are append-only (I2): a recompute inserts a fresh row with a new `computedAt`, and an
unchanged recompute writes nothing at all.

## The registry rows

`registry.json` carries **one** row for this family: `journal.correlation`, the namespace. Concrete
finding ids extend it as `journal.correlation.<behaviorId>.<scoreId>`, and they are deliberately not
enumerated — the set is a product of `behaviors.json` and the three scored ids, so listing it would
add ~90 catalogue rows that never carry data and would rot the moment a behaviour is added. The
namespace row is what fixes the family's unit, chart hint, bilingual name and `sensitiveClass:
sensitivePlus`.

The id pattern splits at the **first** dot after the namespace (the score id keeps its own), which
depends on behaviour ids containing no dot. Both suites assert that against the shipped dictionary.

## Copy

Rendered through the existing `InsightTemplateStore` and `InsightEngine.fill` — the same templates
file, the same `{placeholder}` substitution, the same `Insight` vocabulary the rest of the app uses.
Nine templates, all `metricFamily: journal`, all authored in English and Arabic.

**The locked line.** `journal_correlation_not_cause` — *"This is an association in your own logged
data, not a cause."* / *"هذا ارتباط في بياناتك المسجّلة، وليس سببًا."* — is appended by the renderer
to **every** card: the positive, the negative, the null and every suppression alike. It is not
conditional and it is not a caller's responsibility, because a caller that forgot it would ship a
card that reads as causal. Both suites assert it on every outcome the engine can produce, and both
run a wellness lint over every string this feature can put on screen (causal verbs, alarm words,
directives, and their Arabic equivalents).

**Two altitudes, one computation (D-5).** Casual mode renders one sentence; power mode renders
`n = 15 (7 with / 8 without) · Cliff's delta 0.93 · 95% CI [0.68, 1.00] · bootstrap 2000 resamples`.
Both are built from the same `CorrelationFinding` — there is no second computation for the detailed
view, which is what stops the two from disagreeing.

Correlation insights are **not** persisted to the main `insights` table. The rendered sentence names
the behaviour, so storing it in `badan.db` would leak through the front door what putting the
findings in the sensitive database closed the back one on.

## Tests

`apps/ios/Tests/CorrelationEngineTests.swift` (34 cases) and
`apps/android/app/src/test/java/net/albayyan/badan/CorrelationEngineGoldenTest.kt` (25 cases), plus
the shared goldens in `packages/fixtures/correlation/` — read by both, authored by a third
independent implementation of this page so that agreement means all three match the *document*
rather than each other's arithmetic.

Named cases: exactly-at-gate, one-below each of the three gates, unpaired-days-dropped, strong
positive, strong negative, **the null case**, and a context-annotated window. Plus: splitmix64's
first words and draw indices pinned identically on both platforms, repeat-run determinism, the
locked line on every outcome, the manifest round trip and its **fail-closed refusal** (nine degraded
manifests, each of which must rebuild nothing rather than a direction), and a source scan asserting
no parametric machinery has appeared in either engine file.

## Known limits

- **Association only, and next-day only.** A behaviour that matters on a longer horizon, or that
  co-varies with another behaviour, is not modelled. Confounding is not adjusted for and is not
  claimed to be.
- **No multiplicity correction.** Each behaviour × score pair is evaluated independently; with many
  logged behaviours some intervals will exclude zero by chance. The mitigations today are the
  minimum-n gates, the closed score list, and copy that never claims significance. A false-discovery
  correction is the obvious next step and is deliberately not silently implied.
- **Free-text behaviours are not correlated.** Two spellings of one habit would split into two
  under-powered behaviours and both would be suppressed, which reads as a bug rather than as the
  honest statement that BADAN cannot tell they are the same thing.
- **Constants are provisional.** They are a stated default, not validated against data, and every
  row says so.
