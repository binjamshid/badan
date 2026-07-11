# ADR-0006 — iOS is the runnable flagship this pass; Android mirrors via shared contracts

- Status: Accepted
- Date: 2026-07-10

## Context

The build environment has a full iOS toolchain (Xcode 26.6, xcodegen, iOS 26 simulators) so
an iOS app can be compiled and run and demonstrated end-to-end here. Building AND verifying
two production-grade native apps in a single execution pass is not realistic; the plan itself
uses shared conformance fixtures precisely so parity is a property, not a simultaneous build.

The competing value is CLAUDE.md's parity mandate: "do not build iOS in a way that makes
Android a second-class dead end."

## Decision

Make **iOS the deeply-built, compiled, simulator-verified flagship** in this pass — real
domain model, SQLite persistence, ingestion+dedup, derivation, export, ~15 screens (both
altitudes), seeded data, tests. Keep Android a **first-class, non-dead-end** path by: (1)
holding all shared truth (entities, ontology, insight templates, symptom dictionary, export
columns, the logical schema, invariants) in `packages/` and `docs/`, language-neutral; (2)
documenting the Android mapping (Room ↔ the same DDL, Compose ↔ the same screens) in
`docs/architecture.md`; (3) keeping the existing Kotlin scaffold coherent.

## Consequences

- The repo contains a genuinely working BADAN app now (iOS), not just plans.
- Android is a well-specified next milestone, not a rewrite — it consumes the same `packages/`.
- Honesty: this ADR states plainly that Android trails iOS in this pass.
