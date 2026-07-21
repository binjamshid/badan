# BADAN algorithm methodology

This directory is the human-readable half of the algorithm contract. The machine-readable half is
`packages/contracts/algorithms/algorithms.json` — the versioned constants both apps load — and every
entry there carries a `methodologyUrl` pointing back here.

**Why both exist.** A score BADAN cannot explain is a bug. Every score ships with a published
formula (here *and* in its in-app anatomy sheet), an `AlgorithmVersion` row, an `InputManifest` of
its contributing inputs, and a confidence/provisional flag. The constants are **data**, never
hardcoded in an engine, so a change is a reviewable diff plus a semver bump — and, because derived
values are append-only (INVARIANT I2), old rows keep the version that produced them and are never
rewritten. This is the transparency that separates BADAN from a black-box wellness score.

## Ground rules for every page here

- **Personal baselines only** in v1 — never population norms. Population context ("typical for
  adults") appears only on education pages, clearly separated from the user's own band.
- **No false precision** — directional bands over decimal absolutes; a range when confidence is low,
  never fake-exact numbers.
- **Honest cold start** — nothing renders as a score while its inputs are provisional; reduced-input
  variants are labelled distinctly, never silently degraded, never imputed.
- **Wellness-safe language** — never diagnostic, never alarmist.
- **Association, never cause** — where an algorithm relates two things (EPIC-29's behaviour
  correlations today), it publishes its sample size and its uncertainty, suppresses below its
  minimum-n gates rather than hedging, reports null results as results, and says on every card that
  what it found is a pattern in the user's own numbers and not a cause.

## Index

| Algorithm | Doc | Status | Epic |
|---|---|---|---|
| `baseline.rolling_median_mad` | [baselines.md](baselines.md) | **Published (2.0.0)** | EPIC-23 |
| `sleep.need` / `.performance` / `.debt` / `.consistency` / `.disturbances` | [sleep.md](sleep.md) | **Published (0.1.0, provisional)** | EPIC-24 |
| `composite.readiness_score` | [readiness.md](readiness.md) · [readiness-vs-whoop.md](readiness-vs-whoop.md) | **Published (2.0.0, provisional)** | EPIC-25 |
| `effort.day` / `effort.workout` | [effort.md](effort.md) | **Published (0.1.0, provisional)** | EPIC-26 |
| `stress.day_trend` | [stress.md](stress.md) | **Published (0.2.0, provisional)** | EPIC-34 |
| `journal.correlation` | [correlations.md](correlations.md) | **Published (0.1.0, provisional)** | EPIC-29 |
| `workout.strength.*` | _forthcoming_ | Provisional constants seeded | EPIC-28 |
| `hydration.day_total` | _forthcoming_ | Provisional constants seeded | EPIC-07A |
| `cycle.descriptive` | _forthcoming_ | Provisional constants seeded | EPIC-30 |

Baselines land first because the four Phase‑2 score engines all read baseline output — it is the
keystone the rest build on. The other pages join this index as their epics land; their constants are
already seeded in `algorithms.json` (marked `provisional`, so any value they produce is flagged) so
those engines tune numbers rather than invent structure.
