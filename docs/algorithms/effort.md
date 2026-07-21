# Effort — `effort.day` / `effort.workout`

> Status: **provisional, semver 0.1.0** (curve constants not yet validated against data; every row is
> flagged `provisional`) · Engine: `EffortEngine` (iOS `Sources/Domain/Derivation/EffortEngine.swift`,
> Android `domain/derivation/EffortEngine.kt`) · Zone model: `HRZoneModel` (iOS
> `Sources/Domain/HRZoneModel.swift`, Android `domain/HRZoneModel.kt`) · Constants:
> `packages/contracts/algorithms/algorithms.json` (`effort.day`, `effort.workout`) · Owner: EPIC-26 ·
> Approval: **A3** (naming + scale + publication).

Effort is BADAN's **cardiovascular-load** score — WHOOP's "strain"-equivalent — a single number
answering *"how much cardiovascular work did today (or this workout) actually carry?"* It is a
transparency differentiator: where a black-box strain score hands you a number and asks for trust,
every Effort score ships with this published formula, a versioned `AlgorithmVersion`, an
`InputManifest` naming the minutes spent in each zone, and a provisional flag.

Everything below is **data**, not code: the scale, the zone weights, the curve steepness and the zone
floors live in `algorithms.json` and are loaded identically on both platforms (`EffortSpec`). Changing
any of them is a semver bump and a new `AlgorithmVersion` row — and because derived values are
append-only (INVARIANT I2), old rows keep the version and the constants that produced them and are
never rewritten.

## The model in one line

Minutes are attributed to five heart-rate zones, weighted by intensity into a **weighted-minutes
load** `L`, and mapped through a saturating curve:

```
L      = Σ_zones ( minutes_in_zone · zoneWeight )
Effort = scaleMax · ( 1 − e^(−k · L) )
```

The curve is **monotonic** (more time, or the same time at a higher zone, never lowers the score) and
**diminishing** (each extra weighted-minute adds less than the last — WHOOP's "harder at the top"
shape). Both properties are asserted as property tests on both platforms
(`EffortEngineTests` / `EffortEngineGoldenTest`), so a constant edit that broke either would fail CI.

## The zone model

Zones are defined by their **lower edge in bpm**, taken as a percentage of the person's maximum heart
rate. Classification is floor-based — a reading lands in the **highest zone whose floor it meets** —
and the top zone is **open** above Z5's floor: an estimated HR max is not a ceiling, so a reading above
it is still Z5, never dropped.

| Zone | Default floor (% max HR) | Weight |
|---|---|---|
| Z1 | 50 % | 1.0 |
| Z2 | 60 % | 1.6 |
| Z3 | 70 % | 2.6 |
| Z4 | 80 % | 4.2 |
| Z5 | 90 % | 6.8 |

A reading below the Z1 floor is **zone 0** and carries no load. The weights are roughly geometric so
intensity is rewarded without letting a single hard interval swamp a long easy day.

### Where the max HR comes from

`HRZoneModel` resolves the effective max in this order:

1. a **well-formed stored `HRZones` override** (the user's edited bpm zones) → its floors win outright;
2. else the profile's **`hrMax`** override, if set;
3. else the **age-derived Tanaka (2001) default**: `208 − 0.7 · age`, from `birthYear`;
4. else **nothing** — no override, no `hrMax`, no age → no zones can be drawn, and the day degrades to
   the reduced-input activity variant rather than inventing an age it does not have.

The user can edit `hrMax` or the zones directly; `HRZoneModel.defaultZones(hrMax:)` seeds the editor
with whole-bpm defaults from the max.

**Honesty note on the age default.** The `208 − 0.7 · age` formula carries a real ±10–12 bpm standard
error. That uncertainty is exactly why the EPIC-03 `WorkoutEffortBands` display bars *avoid* HR-max
zones and use session-relative "easy/steady/brisk/peak" bands instead — labelling five confident-looking
boundaries from a possibly-two-bands-off number would be false precision. EPIC-26 uses the max
differently: only to **weight a single provisional score** that is shown as a directional number, never
as a per-zone prescription, and always overridable. The two surfaces coexist: `WorkoutEffortBands` is
the per-workout *shape*; `EffortEngine` is the *load number*.

## Time-in-zone attribution

Continuous HR is a series of samples, not intervals. Each sample "holds forward" (zero-order hold)
until the next sample or the window end, contributing that dwell to its zone. A gap longer than
`maxAttributableGapSeconds` is **clamped** — a recording dropout (wrist lifted, session paused) is not
credited as time spent at the last reading, or a five-minute sensor gap would invent five minutes of
whatever zone the last sample fell in.

`maxAttributableGapSeconds` is **derived from the sparse-density threshold**, not a second magic
literal: if HR is sampled at least at `sparseHrFallbackMinSamplesPerMinute` per minute, consecutive
samples are at most `60 / that` seconds apart, so a longer gap is a dropout. With the shipped
`0.5`/min that is **120 s** — one source of truth for "what counts as continuous HR". (The EPIC-03
`WorkoutEffortBands` guard is a fixed 90 s with the same purpose; EPIC-26 derives it from the contract
so a change to the density gate moves both in lockstep.)

## Day vs workout

- **`effort.day`** — the curve over the whole local day's HR series, keyed `day:<YYYY-MM-DD>`.
- **`effort.workout`** — the *same* curve over one session's window, keyed `session:<id>`. The contract
  requires `effort.workout`'s `scaleMax` and `logCurveK` to be **identical** to `effort.day`'s (a
  golden test pins this), or a workout's effort would not be comparable with the day it sits inside.

The `InputManifest` on a zone-based row carries **one input per zone**: `value` = minutes in that zone
(what the zone-time bars render), `weight` = that zone's weighted-minutes contribution to `L`.

## Reduced-input activity load — never a shaming zero

A phone-only user has **no continuous heart rate**. Scored on zones they would read **0** ("you did
nothing") on a day they may have walked 12,000 steps. The engine detects this and emits a
distinctly-labelled **activity load** instead:

- **Day sparse gate:** a day falls to the activity variant when its attributable HR coverage is below
  one full continuous-sampling interval (`< maxAttributableGapSeconds` of covered time). A phone-only
  user has zero `heart.hr` and clears the gate immediately; a watch worn during *any* activity — or
  even passively all day — accrues covered-seconds fast and stays zone-based (correctly scoring a
  low-but-real effort on a rest day, not a mislabelled reduced-input one).
- **Workout sparse gate:** a session whose HR sample density is below
  `sparseHrFallbackMinSamplesPerMinute` (samples/min) uses the activity variant.
- **No-max fallback:** if no HR max can be established at all (no override, no age), the day/session
  uses the activity variant too, with a distinct reason (`noHeartRateMax` vs `sparseHeartRate`).

The activity load is the day's **active energy** (preferred — it captures cycling and the like), or
**steps** when there is no energy record, or a workout's **recorded energy total**. It is a truthful
raw magnitude, **not a fabricated 0–100 score** — steps and energy carry no intensity information, so
dressing them as an effort score would be exactly the false precision the house rules forbid.

**How it is stored and told apart.** The reduced-input row is written under the same `effort.day` /
`effort.workout` id but with the **activity metric's unit** (`kJ`, `count`, or a workout's `kcal`),
never `score_0_100`. A day is *either* zone-based *or* reduced-input, never both, so the two are
mutually exclusive per period and a reader distinguishes them by the row's unit. *(Known limitation: a
dedicated registry id such as `effort.activity_load` would separate the two series more cleanly than a
unit discriminator does; that is a registry-lane follow-up, tracked as a gap — the engine keeps the
task's `effort.day` id in the meantime.)*

## HR-max edit → historical backfill (append + supersede, I2)

Editing HR max or zones changes every zone edge, and therefore every past score. `EffortEngine.recompute(from:to:)`
re-derives the whole window and **appends** fresh rows with a new `computedAt`; the superseded rows keep
their `computedAt`, value and algorithm id, so "what BADAN believed before the edit" survives and the
change is auditable. It is idempotent over unchanged data (a re-run writes nothing) and ordered
oldest→newest so a checkpointed background job resumes cleanly. The composition lane wires this to the
background job; the engine only exposes the entry point.

## Guidance range (readiness-linked, wellness-safe)

The engine offers an **optional, non-prescriptive** daily guidance read model linked to Readiness. It
reads the day's `readiness.score` and returns a **direction** — a gentler range may suit a low-readiness
day (lowest third of 0–100), there is headroom on a high one (highest third) — plus, only on a gentler
day with an *established personal effort baseline*, a soft ceiling equal to the user's **own** typical
effort (`effort.day` baseline centre), never a population number. It is never stored and never a
command; the UI lane owns the bilingual, copy-linted strings ("a gentler range may suit today: under
your typical"). The engine supplies the band and the optional number so the surface never invents
either.

## The scale is data, and A3 is not yet propagated

Plan §28 **A3 selected a 0–21 WHOOP-shaped scale**. The shipped contract, however, still carries
`scaleMax = 100` (and the registry still calls `effort.day`'s unit `score_0_100`). `EffortEngine` reads
`scaleMax` from the contract and stamps the registry's canonical unit — it hard-codes **neither** 21
nor 100 — so the day the contract is updated to `scaleMax = 21` (and the zone weights and `k` are
re-tuned for the compressed range, and the registry unit is changed to a 0–21 unit that exists in
`Units.table`), the engine produces 0–21 **with no code change**. That is the whole point of
constants-as-data. Until that propagation lands, Effort renders on 0–100; the numbers are provisional
regardless.

## Constants (from `algorithms.json`)

| Param | Entry | Value | Meaning |
|---|---|---|---|
| `scaleMax` | `effort.day` / `effort.workout` | 100 | top of the scale (A3-pending → 21; see above) |
| `zone1..5Weight` | `effort.day` | 1.0 / 1.6 / 2.6 / 4.2 / 6.8 | per-zone intensity multipliers |
| `logCurveK` | `effort.day` / `effort.workout` | 0.045 | curve steepness `k` |
| `zone1..5FloorPctHrMax` | `effort.day` | 50 / 60 / 70 / 80 / 90 | default zone floors, % of max HR |
| `hrMaxConstant` / `hrMaxAgeCoefficient` | `effort.day` | 208 / 0.7 | Tanaka default max = `208 − 0.7·age` |
| `sparseHrFallbackMinSamplesPerMinute` | `effort.workout` | 0.5 | sparse-HR gate; also derives the 120 s attribution clamp |

## Versioning

`effort.day` and `effort.workout` are **`0.1.0`, provisional** — the constants are a stated default, not
yet validated against data, so every row they produce is flagged `provisional`. Resolving A3's scale and
tuning the curve is a semver bump and a new `AlgorithmVersion`; old rows keep `0.1.0` under I2 and are
never rewritten.
