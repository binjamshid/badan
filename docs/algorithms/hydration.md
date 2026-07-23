# Hydration — `hydration.volume` / `hydration.goal_pct`

> Status: **provisional, semver 0.1.0** · Engine: `GoalEngine`
> (`apps/ios/Sources/Domain/Hydration/GoalEngine.swift`) · Ledger (revision-chain bookkeeping,
> no formulas of its own): `HydrationLedger`/`HydrationEntry`
> (`apps/ios/Sources/Domain/Hydration/HydrationLedger.swift`) · Constants:
> `packages/contracts/algorithms/algorithms.json` (`hydration.day_total`) · Owner: EPIC-38
> (§7A.1 of the WHOOP+HAE execution plan).

This is BADAN's hydration rollup: how a day's logged drinks become one total volume, and how
that total is expressed against the user's own goal — never a population target, never a target
computed for them. The append-first ledger (`HydrationLedger`) is deliberately formula-free: it
parses volumes, builds originals and revisions, and resolves the LIVE set for a chain. Every
actual number this page documents is produced by `GoalEngine`, which is pure, storage-free, and
total over its inputs (`resolveGoal`, `makeSummary`), so every published total and percentage
ships with the exact rule that produced it — the same I1/I2 discipline as every other engine in
this directory. `algorithms.json`'s `hydration.day_total` row lists `nutrition.water` as an input
metric id: that is the seam for HealthKit/Health Connect `dietaryWater` imports landing in
`HydrationDailySummary.importedMl`, which exists in the schema today but is not yet populated —
see "Contract vs. code" below.

One `hydration.day_total` row produces two metric ids together, `hydration.volume` and
`hydration.goal_pct`, the same one-algorithm/multiple-metric-id shape `sleep.md` uses for its
five outputs.

## Goal kinds — `.none` is an equal-status value, not "unset"

`HydrationGoalKind` has exactly two members that exist in code today:

- **`.none`** — tracking without a target. This is a first-class, equal-status state, not the
  absence of one: §7A.1 requires that a user with no goal set is never nagged and never shown a
  shaming 0%-of-nothing bar. A summary snapshotted under `.none` records that the user was
  tracking *without* a target — a legitimate, complete state, distinct from "we don't know."
- **`.manual`** — a user-entered daily target (`HydrationGoal.targetMl`).

**`.estimated`** (body-weight / activity / climate-adjusted goal models) is **not built**. It is
named only in a code comment as a Phase 3+, opt-in, off-by-default future case (§7A.1: "Build
(opt-in, off by default)... never silent"). There is no `HydrationGoalKind.estimated` case, no
estimation model, and no UI for it as of this writing. Do not read its mention in source comments
as a shipped feature.

`HydrationGoal.hasTarget` is the guard every progress computation uses: `true` only when
`kind != .none` **and** `targetMl` is present and positive. A `.manual` goal with a missing or
non-positive target is treated exactly like no active goal — it never falls through to a crash or
a divide-by-zero.

## `hydration.volume` — the day total

```
totalMl = manualMl + importedMl + estimatedMl
```

`HydrationDailySummary.totalMl` sums three separately-tracked buckets (kept apart per I5, so an
imported or estimated volume can never be silently blended into what the user actually typed).
**Only `manualMl` is populated this phase** — it is `GoalEngine.manualTotalMl`, the sum of
`volumeMl` across the day's LIVE ledger entries (`HydrationLedger.liveEntries`, which already
resolves the revision chain so an edited or undone drink is counted exactly once, correctly).
`importedMl` and `estimatedMl` exist in the struct and default to `0` — the fields reserved for
HealthKit/Health Connect import and for a future estimated-intake model — but nothing writes to
them yet.

## `hydration.goal_pct` — progress against the user's own target, or nothing at all

```
goalProgressPct = totalMl / goalTargetMl * 100.0     (nil when goalKind == .none, or no valid target)
```

`HydrationDailySummary.goalProgressPct` guards on `goalKind != .none` and a positive
`goalTargetMl` before dividing; otherwise it returns **`nil`, never `0`**. This is deliberate: a
user with no goal set has nothing to fall short of, and rendering "0%" would be exactly the
streak-guilt framing §7A.1 rejects ("Missing logs do not mean the user did not drink"). A `nil`
tells the surface to withhold the progress bar entirely rather than show an empty one.

The division itself is stored **uncapped** — the same posture `sleep.performance` takes — so the
raw ratio stays inspectable even on an unusually heavy logging day. Capping the *displayed* number
is `algorithms.json`'s job via `goalPctCapPercent`; see "Contract vs. code" below for whether that
cap is actually wired up yet.

## Goal resolution — day-type override, then the default goal, then nothing

```
resolveGoal(dayType, from: goals):
    active = goals where active == true and deletedAt == nil
    if dayType is given and some active goal has that exact dayType → that goal wins
    else → the active goal whose dayType == nil (the default goal), if one exists
    else → nil (no active goal at all)
```

`GoalEngine.resolveGoal(dayType:from:)` never infers a day type — callers always supply it (or
`nil`). The priority is strict: a matching day-type override always wins over the default goal,
which always wins over "no active goal." Tombstoned (`deletedAt != nil`) and inactive
(`active == false`) goals are filtered out before any of this runs, so an undone or deleted goal
can never resurface as the resolved one.

## The frozen snapshot — a goal edited today never rewrites yesterday's target

`GoalEngine.makeSummary` recomputes a day's **totals** from `liveEntries` every time it runs (a
backdated drink can legitimately change a past day's total), but the **goal it is measured
against is frozen on first summarization**:

- If `existing` (a prior summary for that `dayKey`) already carries a goal snapshot
  (`goalKind` / `goalTargetMl` / `goalId`), that snapshot is preserved **verbatim** — the resolved
  goal passed in on this call is ignored for those three fields.
- Only when there is no `existing` summary yet does the day capture `resolvedGoal` (if it
  `hasTarget`) as its permanent snapshot, or `.none` if there is no active goal.

This is the I2-flavored half of the rule: a historical record's own context does not silently
drift when the user changes settings tomorrow. Raising next month's goal from 2 L to 3 L must not
retroactively mark last month's "met" days as missed. The consequence for callers: re-snapshotting
*today's* day after the user edits their goal is an explicit choice (pass `existing: nil` for
today), not something that happens automatically on the next recompute.

## The standing rule: one logged mL is always one logged mL

`HydrationLedger.swift` states this twice, once on `HydrationFluidType` and once on
`BeverageDefinition`:

> "A fluid type is *never* a hydration weight. §7A.1 rejects 'net hydration' multipliers
> outright: 500 mL of coffee is logged as 500 mL, exactly like 500 mL of water. The category is
> for grouping and display, nothing more." (~line 10)

> "`caffeineMgPer100ml` / `alcoholPct` / `electrolyteNote` are **display metadata only** this
> phase. They are carried so a later phase can *show* them, but nothing reads them into a
> hydration total or a 'net hydration' multiplier — that is a §7A.1 Reject item. A logged mL is
> always one logged mL." (~line 40)

Concretely, this forbids BADAN from ever converting a beverage's composition into an "effective
water value" behind the user's back: a cup of coffee is not discounted for caffeine, an
electrolyte drink is not boosted for its salts, an alcoholic drink is not penalized as net-negative
hydration. `BeverageDefinition.caffeineMgPer100ml` / `.alcoholPct` / `.electrolyteNote` may be
*shown* to the user in a later phase (§7A.1: "Build" at Phase 3), but no formula on this page — nor
any future one — may fold them into `totalMl` or `goalProgressPct`. `totalMl` is, and must remain,
a literal sum of logged volume.

## Contract vs. code — what `algorithms.json` publishes that isn't wired up yet

`algorithms.json`'s `hydration.day_total` entry publishes two constants:

- **`defaultGoalLitres` (2.0)** — documented as "a STARTING POINT ONLY, never presented as a
  medical recommendation. The user's own goal, once set, always wins." As shipped, `GoalEngine`
  does not read this constant at all: `resolveGoal` returns `nil` (no active goal) whenever there
  is no matching `HydrationGoal` row, full stop — there is no automatic fallback that manufactures
  a 2 L default goal for a user who never set one. A day with no goal row is a genuine `.none` day,
  not a silently-applied 2 L target.
- **`goalPctCapPercent` (150.0)** — documented as "Display clamp so an unusually heavy day does not
  render an alarming percentage." As shipped, `HydrationDailySummary.goalProgressPct` returns the
  raw, uncapped ratio (see above); no code in `Domain/Hydration` or `Features/Hydration` currently
  clamps a displayed percentage at 150.

Both constants are real, versioned, and already load identically on both platforms — they are not
placeholders in the sense of being wrong — but neither is consumed by any engine or view yet. This
mirrors `strength.md`'s treatment of `workout.strength.volume`: a published, versioned contract
entry that precedes its implementation. The first change that reads either constant should update
this section rather than leave the doc silently more complete than the code.

## Versioning

`hydration.day_total` is **`0.1.0`, provisional** — both constants below are stated defaults, not
yet validated against data, so every `DerivedValue` this entry's engine eventually writes must
carry `provisional = true`. Changing either constant, or wiring one up for the first time, is a
semver bump and a new `AlgorithmVersion` row; old rows keep the version and constants that produced
them and are never rewritten (I2).

| constant | value | role | wired into code? |
|---|---|---|---|
| `defaultGoalLitres` | 2.0 | Provisional starting-point default goal, never a medical recommendation | **No** — see "Contract vs. code" |
| `goalPctCapPercent` | 150.0 | Display clamp so an unusually heavy day doesn't render an alarming percentage | **No** — see "Contract vs. code" |

`producesMetricIds`: `hydration.volume`, `hydration.goal_pct`. `inputMetricIds`: `nutrition.water`
(the HealthKit/Health Connect import seam for `importedMl`, not yet populated). `methodologyUrl`
in `algorithms.json` points at this file.
