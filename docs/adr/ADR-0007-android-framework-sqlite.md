# ADR-0007 — Android uses framework SQLite (not Room), mirroring the iOS seam

- Status: Accepted
- Date: 2026-07-10
- Amends ADR-0005's note that "Android will use Room", by the same reasoning that chose raw
  SQLite over GRDB on iOS.

## Context

ADR-0005 chose raw SQLite over GRDB on iOS for offline, zero-dependency, deterministic builds,
with a thin `SQLiteConnection` wrapper as the single swap seam. The plan (AP-06) had assumed
Room for Android. Room brings an annotation processor (KSP), a version-compatibility matrix
(KSP ↔ Kotlin ↔ AGP), and a schema abstraction that would diverge from the raw-DDL /
two-DB-files / embedded-provenance design the iOS side already implements from the same DDL.

## Decision

Android uses the **framework SQLite** (`android.database.sqlite.SQLiteDatabase`) behind a thin
`SqliteConnection` wrapper — the exact parity of the iOS wrapper. This:

- runs the **same migration-001 DDL** verbatim (same table/column names, same indexes),
- keeps the two physical DB files (`badan.db` + `badan_sensitive.db`, D-9),
- has **no KSP / annotation processing** and no Room version matrix,
- keeps the single swap seam (`SqliteConnection`) that a future Room/SQLCipher move would target,
- makes cross-platform conformance trivial: both wrappers implement the same `execute/run/query/
  transaction/closeHandle/reopen` surface over identical SQL.

Timestamps are stored as `INTEGER` epoch-millis on both platforms; the Kotlin domain represents
instants as `Long` (epoch-millis) where iOS uses `Date` — the same UTC meaning, a representation
detail, not a semantic divergence.

## Consequences

- One logical schema, two thin native wrappers — the drift surface is the SQL, which is shared.
- We hand-write SQL + row mapping on Android too (full control, no hidden behaviour), consistent
  with iOS.
- Room remains a clean future option (swap the wrapper) if its migration/observation ergonomics
  become worth the KSP cost.
