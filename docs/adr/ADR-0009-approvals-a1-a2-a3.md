# ADR-0009 — Approvals A1, A2, A3 (WHOOP/HAE execution plan gates)

**Status:** Accepted — 2026-07-20
**Context:** `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §28 action 1: "Approve A1–A3 — everything below assumes them."
**Decider:** Founder.

## A1 — Widen the frozen CSV export contract (24 → 26 columns)

**Decision:** Approved.

`packages/export-schemas/csv_columns.json` gains `granularity` and `aggregation_method`,
and the export schema version bumps `0.1.0 → 1.0.0`.

The 24-column set was declared frozen. This change is *additive* (no column removed,
no column reordered ahead of an existing one, no semantic redefinition) and *versioned*
(the schema version bump is the contract's own escape hatch). Consumers pinned to the
24-column read continue to parse a 26-column file correctly by name.

**Consequence:** every export golden fixture is regenerated at v1.0.0, and
`docs/` gains a schema changelog so the widening is discoverable rather than silent.

## A2 — HealthKit background delivery entitlement + BGTaskScheduler

**Decision:** Approved.

`apps/ios/App/BADAN.entitlements` gains
`com.apple.developer.healthkit.background-delivery`; `Info.plist` gains
`BGTaskSchedulerPermittedIdentifiers` for `net.albayyan.badan.refresh`
(BGAppRefreshTask) and `net.albayyan.badan.processing` (BGProcessingTask).

**Consequence — this changes the App Store review story.** BADAN now wakes in the
background. The privacy posture is unchanged in substance (still no network, still no
collected data, `PrivacyInfo.xcprivacy` stays honest) but the *justification* must be
prepared for review: background wakes exist to keep the user's own on-device repository
fresh, and no data leaves the device as a result.

**Binding constraints** (plan §13.3, from `HAE.md` §4/§6) — these are build rules, not
aspirations:

- The observer completion handler is called within seconds on **every** wake, regardless
  of work outcome. HealthKit silently disables background delivery after 3 missed
  handlers; that budget is never spent.
- An observer wake means "something changed", never a payload. Always follow with an
  anchored re-query.
- `enableBackgroundDelivery` is re-registered defensively on every app open.
- A locked store is not a failure. Detect via protected-data availability, log
  `skippedLocked`, wait for the next wake. Never surfaced to the user as an error.
- No UI copy ever promises a wall-clock time for a background wake. The honest labels
  are in plan §13.7 and are load-bearing.

## A3 — Score naming and formula publication

**Decision:** Approved.

Scores ship as **Readiness**, **Effort**, and **Sleep score**. Effort uses a 0–21 scale
(WHOOP-comparable shape, BADAN's own published curve) — chosen over 0–100 so the
number is legible to users arriving from WHOOP without implying it *is* WHOOP's number.

Formulas are published: in-app via the existing anatomy-sheet pattern, and in
`docs/algorithms/`. Algorithm constants live in
`packages/contracts/algorithms/algorithms.json` as data, so both platforms evaluate
identical curves and a version bump is a reviewable diff.

**Consequence:** BADAN cannot quietly change a score. An algorithm change is an app
update with a changelog and an `AlgorithmVersion` row — which is the entire point.
Remote configuration of algorithm parameters is explicitly *not* introduced (plan §15).

## Not decided here

A4 (backend activation / ADR-0002 supersession), A5 (Vitality Trend), and the v1.1
sensitivity gates A17–A25 remain open. Work that depends on them is out of scope until
each gets its own memo.
