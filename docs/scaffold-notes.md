# Scaffold Notes

This scaffold is intentionally expandable.

## App folders (correction)

- `apps/ios` — the native SwiftUI flagship (runnable; see `apps/ios/README.md`).
- `apps/android` — the native Kotlin/Compose parallel path.
- **The Flutter path is closed** — `apps/flutter` was never created (EXECUTION_PLAN §12; ADR-0001).
- Shared truth lives in `packages/` (contracts-level sharing, not a runtime).

## Status (superseded)

The "next implementation docs" list is **done** — see `docs/EXECUTION_PLAN.md §6/§11` for the
authoritative sequence and `docs/execution-checklist.md` for live status. The canonical domain
model, metric ontology, ingestion contracts, export schema, and both the casual-home and
power-user-detail IAs are implemented in `apps/ios/`.
