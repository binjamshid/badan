# ADR-0001 — Native-first with contracts-level sharing

- Status: Accepted
- Date: 2026-07-10
- Supersedes the KMP-shared-core assumption in blueprint §33/§47/§52 until the M4 gate.

## Context

BADAN must ship a genuinely native experience on both iOS and Android, with heavy OS
integration (HealthKit / Health Connect, background, widgets/watch later), dense charts,
and strong RTL. `CLAUDE.md` mandates native-first. The blueprint (v2) assumes a Kotlin
Multiplatform shared core; repo reality and the architecture-decision doc favour native.

## Decision

Native UI and app integration per platform (Swift/SwiftUI, Kotlin/Compose). **Shared
material is specifications, not runtime:** canonical entities, the metric ontology, insight
templates, the symptom dictionary, and the export contract live as machine-readable data in
`packages/` and are the single source of truth for both apps. Each platform implements the
same logical schema and the same conformance behaviour.

The small set of duplicated logic (unit conversion, timezone/day-attribution, dedup-lite,
baseline median/MAD, export serialization) is budgeted and fixture-guarded.

## KMP re-evaluation gate (M4)

Adopt a KMP shared core only if: ≥3 fixture-divergence incidents from duplicated logic, or
duplicated domain code exceeds ~2k LOC/platform, or the team confirms toolchain comfort.
Otherwise stay native and re-check each milestone.

## Consequences

- Two client codebases; parity enforced by shared data + conformance fixtures, not a runtime.
- No cross-platform runtime dependency to manage in MVP.
- This session's runnable flagship is iOS (see ADR-0006); Android mirrors the architecture.
