# ADR-0002 — No backend in MVP (local-first)

- Status: Accepted
- Date: 2026-07-10

## Context

Local-first is the strongest proof of BADAN's privacy posture and deletes an entire risk
class (auth, hosting, compliance, breach surface). The product promise is a user-owned
repository.

## Decision

The MVP ships with **zero backend**. The on-device SQLite store is the sole source of truth.
No accounts, no remote analytics, no network calls anywhere in the app. `backend/` and
`infra/` stay dormant with READMEs saying so. Export is fully offline (files handed to the OS
share sheet). The first backend work item is sync or the first vendor integration, and not
before the M4 review.

## Consequences

- The export module is lint-forbidden from importing any networking/entitlement API (D-8).
- Everything works in airplane mode.
- Sync is designed for but not built (ADR-0003).
