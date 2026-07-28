# CLAUDE.md

BADAN — health and body-metrics app. Native, local-first. A repository that keeps your readings on
your device, shows where each number came from, and says plainly when it doesn't know.

## Current state (2026-07-28, v1.1 build 4 on TestFlight)

**iOS is the live surface. Android is paused** (founder, 2026-07-22) — `apps/android` still holds a
real Kotlin mirror of the domain/ontology layer, but it is NOT kept in step and its notification
registry, budget constant and metric set have already diverged. Do not read either platform as
evidence of what the other does, and do not claim parity.

Shipping today:

- **Ingestion** — ~15 HealthKit types (sleep sessions + stages, HR, RHR, HRV, steps, energy,
  distance, floors, weight, body fat, lean mass, VO₂ max, SpO₂, respiratory rate, glucose).
  Nutrition is still 0 of 7. Clinical records import via FHIR.
- **Derivation** — personal baselines, readiness, the sleep cluster (need/performance/debt/
  consistency/disturbances/**score**), day and workout effort, a density-gated daytime stress trend,
  and a multi-input mood estimate. Every derived row carries an input manifest, a confidence and a
  provisional flag; engines compute nothing when their contract entry is missing.
- **Surfaces** — Home/Body/Log/Insights/Settings, Home-Screen and Lock-Screen widgets, a watchOS
  companion app with readiness/sleep/effort complications, a budgeted notification engine
  (seven classes, per-class opt-in, quiet hours, user-set daily ceiling, durable ledger).
- **Export** — CSV/JSON with checksums and a manifest, templates, destinations, automation.
- **Logging** — medications and reminders, hydration, symptoms, journal, workouts, cycle, and the
  pregnancy module's P0 slice.
- **Monetization** — StoreKit 2, no accounts. 7-day app-managed trial from first launch, then
  monthly/yearly/lifetime. See D-32/D-33 and `docs/MONETIZATION.md`.

## Working mode

This repository is native-first.

- iOS UI and app integration should be implemented in Swift/SwiftUI.
- Android UI and app integration should be implemented in Kotlin/Jetpack Compose — **when that lane
  resumes.** Until then, do not write Android code speculatively "for parity".
- Shared logic should begin as shared contracts, schemas, and domain specs before introducing runtime sharing.
- Contracts (`packages/metric-ontology/registry.json`, `packages/contracts/algorithms/`) are the
  canonical copies; `apps/*/…/Resources` hold build-time mirrors. A new derived metric needs a
  registry entry AND an algorithm entry or its engine will silently produce nothing.

## Repo layout

```text
badan/
  apps/ios/          SwiftUI client
  apps/android/      Compose client
  backend/api/       AI-coach FastAPI proxy (A9 / ADR-0010) — the ONLY server surface
  backend/workers/   dormant; no scheduled server-side work exists yet
  infra/             badan-api.service, nginx/badan-api.conf
  docs/adr/          architecture decisions — read before changing posture
  docs/DECISIONS.md  product/priority decisions (D-nn)
```

## Backend posture — read before adding any network call

**The MVP shipped with zero backend (ADR-0002).** On-device SQLite is the sole source of
truth; ingestion, scores and export generation are all zero-network and stay that way.

That posture is **narrowly** amended, once, by ADR-0010 / D-22: the **AI coach (A9)** is
an explicitly opt-in, feature-gated exception. `backend/api` is a stateless FastAPI proxy
in front of a hosted LLM (OpenRouter). It holds **no accounts and no user health data** —
retrieval and conversation context stay on device, and the service only ever sees one
query plus whatever minimal context the client assembled for that request.

Deployed on the founder's VPS as an isolated service: its own systemd unit, its own
unprivileged user, its own nginx vhost (`badan.binjamshid.com`), touching no other
service on that host.

A **second** network-reaching surface is permitted by ADR-0011 / D-37: **opt-in methodology
telemetry**, default off, on the SAME service (`POST /v1/footprints`) rather than a new one.
It carries learning footprints only — which metric, which method, the direction of a user's
disagreement, a bucketed event count, and whether a calibration was in force. No reading, no
magnitude, no date or period key, no identifier, no region. The payload schema is closed
(`additionalProperties: false`) and CI-gated so "footprint" cannot quietly widen into "reading".

So there are exactly two files in `apps/ios/Sources/` allowed to open a socket for BADAN's own
services — `Platform/AICoach/AICoachClient.swift` and `Platform/Telemetry/FootprintClient.swift`
— plus the user-configured REST export destination, which is network by definition. CI enforces
this list.

**Do not** widen this into accounts, sync, server-side history, or a second backend
surface without a new ADR. "The AI coach has a backend" is not a licence for the rest of
the app to acquire one, and neither is "telemetry has a route."

BADAN is deliberately **not** on the platform-api identity/backup services the other apps
in this portfolio share — it has no accounts to attach them to.

## Product guardrails

- Raw data is not paywalled — **narrowed by D-33**: viewing, keeping, logging and deleting your own
  records stay free and uncapped forever; only *bulk export beyond the last 7 days* is subscriber-
  only. Nothing else about raw data may be gated without another decision.
- Preserve provenance and source lineage.
- Casual and power-user modes are presentation layers over one underlying model.
- Wellness-safe language only — never diagnostic or prescriptive.
- Arabic/RTL readiness is a first-order concern.

## Development priorities

The original seven (canonical contracts → ontology seed → source abstraction → Home/detail/export/
logging shells) are all shipped. What replaces them:

1. **Widen ingestion.** Nutrition is 0 of 7 metrics and body composition is partial. Several premium
   ideas in `docs/MONETIZATION.md` depend on data BADAN does not yet receive — selling
   interpretation of absent data is the one failure that document is written to prevent.
2. **Let the user choose what is tracked and shown** — **delivered** (D-35 branch, 2026-07-28).
   Per-metric hide/pin lives on `CustomizationProfile` with a Settings manage screen and a Home
   pinned card. Hiding is presentation only: a hidden metric is still ingested, still derived, still
   found by explicit name search, and still in the export scope picker. Do not let "hidden" come to
   mean "not collected" — HealthKit will not backfill what BADAN declined to read.
3. **Earn the derived numbers.** Every algorithm entry is still `provisional: true`. Constants are
   seeded defaults, not validated ones, and the provisional flag must not be cleared per-metric
   until that metric's constants actually are. Two mechanisms now feed this — user-chosen methods
   (D-35) and on-device feedback calibration (D-36) — but neither *earns* a constant by itself, and
   opt-in telemetry (D-37) is explicitly not sufficient grounds either.
4. **Close the honest-degradation gaps**, not paper over them: the stress density gate hides the
   surface for Apple-Watch-only users, the mood estimate needs two of three terms, and the wake
   summary lands at first unlock on a locked device. These are correct; they should be *explained*
   in-app, not softened.
5. **Android, when it resumes** — re-mirror the diverged registry, budget and metric set first.

## Never

- Add a network dependency to any surface other than the opt-in AI coach and the opt-in
  methodology telemetry without a new ADR.
- Send user health data off device — **narrowed by D-37 / ADR-0011, and the Never survives.** No
  health datum leaves under that decision; what leaves is a statement about a *method* (metric id,
  algorithm id, direction, bucketed count). A reading, an offset magnitude, a date or a period key
  reaching any payload is still a violation, and there is a test that fails loudly if one does.
- Paywall raw data — **except** the D-33 export cap above. Do not widen that exception: gating the
  metric browser, provenance, manual logging, deletion, or on-device viewing of any reading remains
  prohibited.
- Add accounts or a login. BADAN has none, and IAP does not require one (D-32 — Apple's SIWA rule
  applies only to apps offering third-party login).
- Use diagnostic or prescriptive framing in copy.
- Break the offline path for ingestion, scores, or exports.

## Decision log

Architecture changes go in `docs/adr/` as a numbered ADR; product and priority calls go in
`docs/DECISIONS.md` as a `D-nn`. Ask before changing an accepted decision.
