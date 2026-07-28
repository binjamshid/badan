# CLAUDE.md

BADAN — health and body-metrics app. Native iOS and Android, local-first.

## Working mode

This repository is native-first.

- iOS UI and app integration should be implemented in Swift/SwiftUI.
- Android UI and app integration should be implemented in Kotlin/Jetpack Compose.
- Shared logic should begin as shared contracts, schemas, and domain specs before introducing runtime sharing.

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

**Do not** widen this into accounts, sync, server-side history, or a second backend
surface without a new ADR. "The AI coach has a backend" is not a licence for the rest of
the app to acquire one.

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

1. Canonical domain contracts.
2. Metric ontology seed.
3. Health source abstraction.
4. Home summary shell.
5. Metric detail shell.
6. Export shell.
7. Logging shell.

## Never

- Add a network dependency to any surface other than the opt-in AI coach without a new ADR.
- Send user health data off device.
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
