# Strength — `workout.strength.e1rm` / `workout.strength.pr` / `workout.strength.volume`

> Status: **provisional, semver 0.1.0** (constants are stated defaults, not yet validated against
> data; every row is flagged `provisional`) · Engine: `WorkoutQuality`
> (`apps/ios/Sources/Domain/Workout/WorkoutQuality.swift`) · Set model:
> `StrengthSessionRunner`/`StrengthSetLedger` (same file's neighbor,
> `apps/ios/Sources/Domain/Workout/StrengthSessionRunner.swift`) · Constants:
> `packages/contracts/algorithms/algorithms.json` (`workout.strength.e1rm`,
> `workout.strength.e1rm_brzycki`, `workout.strength.pr`, `workout.strength.volume`) · Owner:
> EPIC-42 (absorbs EPIC-28).

This is BADAN's strength-training analytics: an estimated one-rep max (e1RM) from a logged set,
and personal-record (PR) detection built on top of it. Both are computed as pure, deterministic
functions over already-logged `StrengthSet` rows — no HealthKit, no live session, no device
required — so every published number ships with the exact formula and version that produced it
(the same I1/I2 discipline as every other engine in `Domain/Derivation/`).

## e1RM: two published formulas, shown side by side

`WorkoutQuality.epley1RM` / `WorkoutQuality.brzycki1RM` implement two well-known published
formulas for estimating a one-repetition maximum from a lighter set taken to (or near) failure:

```
Epley:   e1RM = weight * (1 + reps / 30)
Brzycki: e1RM = weight * 36 / (37 - reps)
```

Neither is shown as authoritative over the other — they diverge meaningfully at higher rep counts
and neither is universally more accurate, so both are computed independently and labeled with
which formula produced them (`EstimatedOneRepMax.formula`). This mirrors how
`composite.readiness_score`'s versions coexist under I2: two methods producing the same kind of
number, distinguished by `algorithmId`/`algorithmVersion` on the row rather than a single method
being declared "the" answer.

**Both refuse rather than guess.** Each formula independently returns `nil` (no estimate at all,
never a fabricated or overstated one) when:
- the weight is non-finite or not positive, or the reps are not positive;
- the reps exceed that formula's own `maxRepsForEstimate` ceiling (`12` for Epley, `10` for
  Brzycki — Brzycki's is lower because it is widely considered to drift further from a true max at
  higher rep counts);
- for Brzycki specifically, the reps reach or exceed `brzyckiRepsCeiling` (`37`) — the formula's
  own mathematical singularity, where the denominator hits zero and the estimate goes negative.
  This is checked independently of `maxRepsForEstimate` so a future param edit can never
  accidentally raise the cap past the point where the formula stops meaning anything.

`WorkoutQuality.estimatedOneRepMaxes(for:)` computes both formulas for one set and is itself empty
— not a guessed pair — for a partial set (`StrengthSet.isComplete == false`, e.g. missing its own
weight or reps): estimating a max off data that was never really recorded is exactly the false
precision this module exists to refuse.

## PR detection: per (movement, rep-range) bucket, never one global number

A PR is tracked **per rep bracket** (`RepRangeBucket`: 1 / 2-3 / 4-6 / 7-10 / 11-15 / 16-20 / 21+),
never as a single number per movement. "Heaviest ever for 1 rep" and "heaviest ever for 10 reps"
are different claims about different kinds of strength; collapsing them into one PR would silently
answer a question ("is 200 kg × 1 more impressive than 120 kg × 10?") this module has no business
deciding.

`WorkoutQuality.evaluatePR` is the pure decision core — no I/O, an injected `now` — so every named
edge case is a plain value-in/value-out assertion in `WorkoutQualityTests`:

- **Refuses** (never evaluates as a record either way) a warm-up set (`StrengthSet.isWarmUp`,
  excluded from PR logic by default per plan §7A.5/§9.18), a partial/incomplete set (missing
  movement, weight, reps, or unit), or a rep count with no defined bucket.
- **Tie:** the comparison is strictly greater-than a floor —
  `candidate.weightKg > previous.weightKg * (1 + prMinImprovementFraction)`
  (`prMinImprovementFraction = 0.005`) — so a floating-point tie, or a rounding-noise
  "improvement" of a hundredth of a kilogram, never registers as a new record.
- **Unit switch:** the comparison always happens in canonical kilograms
  (`StrengthSet.weightKg`), so logging in kg one session and lb the next can never fabricate a PR
  from a raw-number unit-conversion artifact.
- **Deload:** a lighter, easier week is compared against the same threshold as any other set — it
  simply does not clear it, and `evaluatePR` returns `.notARecord`, never a spurious record in the
  wrong direction.
- **Lookback expiry (`prLookbackDays = 365`):** a stored record older than this no longer gates a
  new one. A PR set once and never approached again should not stand forever as an unbeatable
  historical ceiling that quietly discourages logging; after the window, the next complete,
  non-warm-up set in that bucket is treated as a fresh record.

`WorkoutQuality.recordIfPR` is the only I/O wrapper: read the current stored record for the
(movement, bucket) key, decide with the pure function above, and — **only** on a genuine
`.newRecord` — **append** a `DerivedValue` row (I2: never `UPDATE`/`REPLACE` a prior PR row, so an
earlier PR row keeps describing exactly what BADAN believed the record was at the time). The shape
mirrors `CorrelationEngine.persist` / `StressEngine.compute` precisely: read-latest, pure-decide,
append-if-changed. A repeat evaluation that does not beat the stored record appends nothing.

`workout.strength.pr`'s registry row is `kind: "event"`, `canonicalUnit: "count"` — the
`DerivedValue` itself is an occurrence flag (`value == 1`); the actual weight/reps that earned it
ride in the `InputManifest` under the same `stat:`-prefixed convention `CorrelationEngine`
established for its own findings. The (movement, bucket) pair is encoded into `periodKey` as
`"movement:<id>:reps:<bucket>"` (`StrengthPRPeriodKey`) rather than into `metricId`, because
`workout.strength.pr` is already one complete registry row, not a namespace awaiting per-pair
suffixes the way `journal.correlation.*` is.

## Session quality (strength)

`WorkoutQuality.computeStrengthQuality` is a pure function over a session's live `StrengthSet`
rows, producing the `workout_quality` row shape for `metricFamily == "strength"`:

- **completeness** — share of logged sets that are not partial. A session interrupted mid-set
  (crash, phone locked) leaves a real, honest gap here rather than a padded number.
- **continuity** — share of the session's `seq` run (1...max) actually present. A hole in the
  sequence (not merely "fewer sets than planned," an actual missing seq number) is the signature
  of a lost write or a deliberately deleted set.
- **accuracy** — share of sets tagged with a canonical `movementId` rather than only a free-text
  `customLabel`. A recognized movement is what lets e1RM/PR/volume compute at all, so this is a
  genuine analytical-accuracy signal, never a judgment about the workout itself.

All three are `nil` — never a fabricated `0` or `1` — when the session has no live sets to
measure at all.

## `workout.strength.volume` — contract published, engine not yet built

`algorithms.json` already carries a `workout.strength.volume` entry (volume load: the sum of
weight × reps across a session's working sets, `includeWarmupSets` toggling whether warm-ups
count) from an earlier planning pass. As of this writing **no code computes it** — it is a
published, versioned placeholder the way several `registry.json` metrics preceded their engines.
Do not read its presence in `algorithms.json` as "shipped"; the first PR that implements it should
update this section rather than leave the doc silently more complete than the code.

## Versioning

`workout.strength.e1rm` (Epley), `workout.strength.e1rm_brzycki` (Brzycki), and
`workout.strength.pr` are **`0.1.0`, provisional** — the constants are stated defaults, not yet
validated against data, so every row they produce is flagged `provisional`. Changing any of them
(the rep ceilings, the PR improvement floor, the lookback window) is a semver bump and a new
`AlgorithmVersion`; old rows keep their version and constants under I2 and are never rewritten.
