# ADR-0005 — Raw SQLite (system libsqlite3) over GRDB for the MVP

- Status: Accepted
- Date: 2026-07-10
- Amends EXECUTION_PLAN §5/AP-05 which named GRDB.

## Context

The plan named GRDB (a Swift package) for iOS persistence. GRDB is excellent, but it requires
SwiftPM package resolution (a network fetch) at build time. For a strictly local-first,
offline, reproducible build, betting the whole runnable-app deliverable on package resolution
adds an avoidable risk class. The plan's storage design is already expressed as **raw DDL**
with explicit provenance columns and named indexes — an ORM is not needed to honour it.

## Decision

Use the **system `SQLite3` C library** directly, behind a thin ~150-line Swift wrapper
(`SQLiteConnection`, `SQLValue`, `SQLiteRow`). Zero external dependencies, fully offline,
deterministic, and a faithful, low-magic implementation of the raw-DDL / two-DB-files /
embedded-provenance / EXPLAIN-QUERY-PLAN design.

The wrapper is deliberately the **single seam** any future swap targets: adopting GRDB (for
its migration/observation ergonomics) or SQLCipher (ADR-0004) means reimplementing that one
file's surface, not touching repositories.

## Consequences

- No package manager in the loop; `xcodegen generate && xcodebuild` is the whole toolchain.
- We hand-write SQL and row mapping (more code, full control, no hidden behaviour).
- Query-plan/index discipline is explicit and testable.
- Android will use Room (its native idiomatic choice) against the same logical schema.
