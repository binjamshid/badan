# CLAUDE.md

BADAN — health and body-metrics app. Native, local-first. A repository that keeps your readings on
your device, shows where each number came from, and says plainly when it doesn't know.

## Current state (2026-07-28, v1.1 build 4 on TestFlight)

**iOS is the live surface. Android has resumed, targeting full parity** (D-38 / ADR-0012) —
`apps/android` holds a real Kotlin mirror of the domain/ontology layer.
Before resumption its notification registry, budget constant and metric set had diverged from
iOS; re-mirroring that drift is the first-order work of the resumed lane (see
`docs/android-parity-status.md` for the current gap list). Until that re-mirror lands, do not
assume either platform's present behavior matches the other's.

Shipping today:

- **Ingestion** — ~15 HealthKit types (sleep sessions + stages, HR, RHR, HRV, steps, energy,
  distance, floors, weight, body fat, lean mass, VO₂ max, SpO₂, respiratory rate, glucose).
  Nutrition is still 0 of 7. Lab reports enter the notebook by document camera, photos or a PDF
  file, all read by on-device Vision OCR — **HealthKit Clinical Records was removed after App
  Review refused it under Guideline 2.5.1 (D-43 / ADR-0013); do not add it back.**
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
- **Monetization** — StoreKit 2. 7-day app-managed trial from first launch, then
  monthly/yearly/lifetime. See D-33 and `docs/MONETIZATION.md`.
- **Accounts** — an **optional** Sign in with Apple account (D-44 / ADR-0014, replacing D-32's
  no-accounts posture). Carries entitlement between platforms and runs referrals; holds no health
  data; signed out is a complete state. **iOS only so far** — the service speaks Android's half of
  the wire but no Android client exists (`docs/android-parity-status.md`), so do not describe this
  to users as working across platforms yet.

## Working mode

This repository is native-first.

- iOS UI and app integration should be implemented in Swift/SwiftUI.
- Android UI and app integration should be implemented in Kotlin/Jetpack Compose — **the lane has
  resumed, targeting full parity with iOS** (D-38 / ADR-0012). Android code is no longer
  speculative: build and re-mirror it deliberately against the shared contracts and the current
  iOS implementation, not against a remembered or assumed state.
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

A **third** is permitted by ADR-0014 / D-44: **optional accounts**, created with Sign in with
Apple, on the SAME service. They carry two things and no more — which store product a user owns on
which platform, and referrals. `POST /v1/account/apple`, `GET/DELETE /v1/account`,
`PUT /v1/account/entitlement`, `POST /v1/account/referral/claim`. The server stores an account id,
an HMAC of Apple's subject claim (never the claim), a referral code, and one product id per
platform. No name, no email, no device list, **no health datum**.

So there are exactly three files in `apps/ios/Sources/` allowed to open a socket for BADAN's own
services — `Platform/AICoach/AICoachClient.swift`, `Platform/Telemetry/FootprintClient.swift` and
`Platform/Account/AccountClient.swift` — plus the user-configured REST export destination, which is
network by definition. CI enforces this list.

**Do not** widen this into health-data sync, server-side history, backup, or a second backend
surface without a new ADR. "The AI coach has a backend" is not a licence for the rest of
the app to acquire one; neither is "telemetry has a route"; and neither is "there are accounts now."
Accounts authorise *entitlement* state and nothing else.

BADAN is still **not** on the platform-api identity/backup services the other apps in this
portfolio share. D-44 gave it an account of its own, scoped to entitlement; it did not join a shared
identity system, and it has no health data server-side to back up.

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
5. **Android — resumed to full parity** (D-38 / ADR-0012). Re-mirror the diverged registry,
   budget constant and metric set first, then close the remaining gaps tracked in
   `docs/android-parity-status.md`.

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
- Re-add the HealthKit Clinical Records API, the `health-records` entitlement value, or
  `NSHealthClinicalHealthRecordsShareUsageDescription` — App Review has already refused them once
  (D-43 / ADR-0013), and doing it again re-opens a rejection rather than a question.
- ~~Add accounts or a login.~~ **Reversed by D-44 / ADR-0014 (2026-08-07).** BADAN now has an
  **optional** Sign in with Apple account, and its scope is fixed: carrying a subscription between
  platforms, and referrals. D-32's reasoning was not repudiated — SIWA is still not *required* by
  Guideline 4.8, and StoreKit still binds a purchase to the Apple ID by itself. The account exists
  because entitlement is the one piece of state that has to outlive a single vendor's ecosystem.
  What survives as a hard rule: **signed out is a complete, permanent state** (nothing in the app
  may ever require an account), the account holds **no health data**, and the remote may **grant**
  access but never **revoke** it. Widening the account past entitlement and referrals needs a new
  decision.
- Use diagnostic or prescriptive framing in copy.
- Break the offline path for ingestion, scores, or exports.

## Decision log

Architecture changes go in `docs/adr/` as a numbered ADR; product and priority calls go in
`docs/DECISIONS.md` as a `D-nn`. Ask before changing an accepted decision.
