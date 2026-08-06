# ADR-0012 — Android parity port: resume the lane, supersede the flagship framing

- Status: Accepted
- Date: 2026-07-30
- Supersedes ADR-0006's "iOS is the deeply-built flagship this pass; Android mirrors via shared
  contracts" framing, and corrects ADR-0006's own text where it still assumed Room (see
  "What ADR-0006 got wrong" below). ADR-0007's no-Room, framework-SQLite posture is **not**
  touched by this ADR — it is reaffirmed as still governing.

## Context

ADR-0006 (2026-07-10) made iOS the compiled, simulator-verified flagship for one pass and kept
Android "a first-class, non-dead-end path" by holding shared truth in `packages/` and `docs/`
language-neutrally. `CLAUDE.md`'s current state section (2026-07-28) records what actually
happened next: the founder paused Android entirely on 2026-07-22 ("skip all android for now"),
and iOS kept shipping against those same shared contracts for seven months while Android did not
move. `packages/contracts/INVARIANTS.md`'s own header (`packages/contracts/INVARIANTS.md:7`)
already states "every entity under `apps/ios/Sources/Domain/` (and its future Android
equivalent, per ADR-0006) is expected to uphold all eight [invariants]" — the constitution never
stopped naming Android, only the build did.

The founder has now decided to resume the Android lane and take it to full feature parity with
iOS (see D-38, `docs/DECISIONS.md`). This ADR is the architectural record for that resumption: it
supersedes ADR-0006's flagship/trailing framing, and it pins the three structural questions a
parity port raises before any area work can start — module topology, migration-numbering
posture, and the predicate change that makes filling reserved migration-number holes safe.

## Decision

### Module topology: `:app` + `:wear` + `:contracts`

Android's app module stays `:app`. Two new modules are added:

- **`:wear`** — a separate Wear OS APK (`minSdk 30`, `<uses-feature
  android:name="android.hardware.type.watch">`), its own manifest and dependency set, mirroring
  the phone/watch split iOS already has between the main app target and its watchOS companion.
- **`:contracts`** — a pure `kotlin("jvm")` module holding only the ambient-snapshot DTO tree
  (the Kotlin analogue of iOS's `AmbientSnapshotDto`), its `@Serializable` annotations, a schema
  version, and the DataClient path/message-key constants `:wear` and `:app` both need to agree on
  the wire format. Being pure-JVM, `:contracts` cannot reach `Context`, SQLite, or Health Connect
  — CI asserts `:wear`'s resolved dependency graph contains only `:contracts` plus
  `androidx.wear.*`/Compose, so the watch module can never grow a path to a repository. A renderer
  of phone-computed truth stays enforceable at the build-graph level, not just by convention.

**Glance home-screen widgets and quick-settings tiles stay inside `:app`, not a separate
module or process.** This is a genuine platform difference from iOS, not a stylistic choice:
`apps/ios/Sources/Platform/Ambient/AmbientSnapshotStore.swift` exists at all because an iOS
widget is a separate App Extension process with no shared memory or direct call path back into
the host app — `AmbientSnapshotDto` is hand-duplicated on both sides of that boundary because,
per that file's own rationale, "the two copies can only ever be kept in sync by hand, never by
the compiler." A `GlanceAppWidgetReceiver` is an ordinary `BroadcastReceiver` running in the
**same process and the same APK** as the rest of `:app`. There is no extension boundary to
duplicate a DTO across. `apps/android/app/src/main/java/net/albayyan/badan/platform/shortcuts/
RunExportTileService.kt` already proves the pattern this ADR extends: a `TileService` living
inside `:app`, calling straight back into the app's own repositories and `MainActivity`, no IPC
DTO in sight. Glance widgets and QS tiles follow that same shape. iOS's forced DTO duplication is
therefore a constraint of its extension model, not a decision Android needs to re-derive — Android
does not share it, and code should not be written as if it does.

### Migration numbering stays aligned with iOS; reserved holes get filled, not appended past

`apps/android/app/src/main/java/net/albayyan/badan/storage/Schema.kt` already states the
intended posture in its own comments, not just in this plan: `Schema.kt:210`, `:413`, `:459`,
`:477`, and `:592` each read "Byte-equivalent mirror of iOS `Schema.mainMigrations` version 4 /
5 / 6 / 7 / 8" (respectively), and `Schema.kt:459`'s version-6 comment explains that an
`IF NOT EXISTS` clause exists solely so "the two platforms' version-6 statement strings [stay]
byte-identical rather than forking them." `Schema.kt:730` similarly documents Android's version 3
as a byte-equivalent mirror of iOS main v3. Android's migration version numbers are **deliberately
equal to iOS's own migration version numbers** for the same logical change — not a coincidence of
build order, a convention already load-bearing in the file as it stands today.

Android currently has two reserved-but-unfilled slots: main v3 and sensitive v2 (the numbers exist
in the sequence but their content was never ported before the 2026-07-22 pause). This ADR directs
that Android's forthcoming parity work **fills those holes with the matching iOS migration's
content**, rather than appending it at the next free number (main v9/v10/v11 would otherwise land
at 9/10/11 anyway by coincidence of being next, but main v3 must land at 3, not 9). Appending past
the holes instead of filling them would fork the numbering permanently between platforms and
require inventing and maintaining a mapping comment to recover what equal integers already give
for free. The one exception is a single Android-only catch-up number (main v12, five indexes iOS
shipped inside its own v2 that Android's v2 omitted) — documented as Android-only precisely because
it cannot be retrofitted into the already-shipped v2 without breaking devices that already applied
it.

### The migration predicate changes from `> MAX(version)` to `NOT IN (...)`

`Database.kt:127-129` currently reads:

```kotlin
conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
val current = conn.query("SELECT MAX(version) AS v FROM schema_migrations;").firstOrNull()?.getLong("v") ?: 0L
val pending = migrations.filter { it.version.toLong() > current }
```

Under a `> MAX(version)` filter, a migration numbered lower than one already applied can never
run — which is exactly the situation hole-filling creates (main v3 must still apply on a device
that has already applied v9, v10, v11 from before this ADR, once those are eventually ported).
This ADR directs the predicate to become `version NOT IN (SELECT version FROM
schema_migrations)`, checked per-migration rather than against a single high-water mark. This is
safe given the rest of `Database.kt`'s existing behavior: every applied version is already
recorded in the same transaction that runs it (`Database.kt:133-134`), `resetAll()` already drops
`schema_migrations` and re-migrates from zero, and `schema_migrations.version` is declared
`INTEGER PRIMARY KEY` — a SQLite rowid alias — so the classic `NOT IN`-with-NULL footgun cannot
fire against it.

This same change is also what makes hole-filling *safe for concurrent authorship*: once a task
aggregates migration providers from multiple areas built in parallel, registration order is no
longer guaranteed to match version order, and applying "everything higher than the current max"
would silently skip a lower-numbered migration registered after a higher one already ran on some
device. `NOT IN` has no such ordering dependency — each version is judged on its own — but the
*application* order still must be sorted ascending by version (not registration order) before
migrations run, since a later `ALTER TABLE` may depend on an earlier `CREATE TABLE`. That sort,
and a test that registers providers out of order and asserts they still apply in ascending
version order, is required alongside the predicate change.

### ADR-0007's no-Room posture is undisturbed

This ADR does not reopen ADR-0007. Android continues on `android.database.sqlite.SQLiteDatabase`
behind the thin `SqliteConnection` wrapper (`apps/android/app/src/main/java/net/albayyan/badan/
storage/sqlite/SqliteConnection.kt`), hand-written SQL and row mapping, no KSP, no Room version
matrix. The parity port adds volume (many more tables, many more migration providers) but no new
persistence technology; `ADR-0007-android-framework-sqlite.md`'s stated future option — swapping
the one wrapper file if Room's ergonomics ever become worth the KSP cost — remains exactly as
available, and exactly as unexercised, as it was before this ADR.

### What ADR-0006 got wrong

`ADR-0006-ios-first-runnable-flagship.md:23` names the Android mapping as "documenting the
Android mapping (Room ↔ the same DDL, Compose ↔ the same screens) in `docs/architecture.md`" —
i.e. ADR-0006 itself still assumed Room for Android, dated 2026-07-10. `ADR-0007-android-
framework-sqlite.md`, dated the same day, already corrected this ("Amends ADR-0005's note that
'Android will use Room'") — but ADR-0006's own text was never itself edited to match, so a reader
of ADR-0006 alone would still come away believing Android's persistence plan was Room. This ADR
states plainly, in one place a parity-port reader is certain to consult: ADR-0006's Room mention
is stale and superseded by ADR-0007, which governs and is unchanged (previous section).

## Consequences

- ADR-0006's "iOS flagship, Android trails" framing is retired. Android is no longer scoped as a
  trailing mirror of iOS's shared contracts; it is scoped to full feature parity, tracked through
  the release-gate checklist (G6, permitting feature-list parity **or** a declared, reasoned
  variance) rather than through ADR-0006's original "well-specified next milestone" language.
- `:contracts` becomes the first Android module with a hard compiler-enforced boundary
  (pure-JVM, no `Context`/SQLite/Health Connect reachability) — a stronger guarantee than iOS's
  extension-boundary DTO duplication achieves by convention alone, precisely because Android does
  not need to fight the same process boundary iOS does.
- Every migration-provider task in the parity port receives a **pre-allocated** version number
  from the fixed table this ADR's companion plan lays out (main 3, 9, 10, 11, 12; sensitive 2,
  5–9) rather than choosing its own — the predicate and sort changes above are what make that
  table safe to fill out of order across parallel work.
- Four narrower decisions this resumption also requires — the SQLCipher artifact substitution,
  the Play Billing product-id space, Play Integrity in place of App Attest, and the Android
  background substrate as ADR-0009 approval A2's counterpart — are recorded separately as D-39
  through D-42 in `docs/DECISIONS.md`, since each amends a specific prior ADR/decision on its own
  terms rather than being an architectural consequence of module topology or migration numbering.
- This ADR does not itself claim parity is achieved, verified, or scheduled to a date. Parity is
  established by the shared conformance fixtures and the G6 checklist once the work lands, not by
  this document.
