# Android port conventions

**Read this before touching any file in `apps/android`.** It is the document every task in the
Android parity port (`docs/adr/ADR-0012-android-parity-port.md`, plan on file as
`transient-hatching-hammock`) is told to read first. It exists because the plan runs many agents
concurrently against one codebase, and the failure modes that matter — two tasks editing the same
file, a task silently overwriting Android-only behaviour, a migration landing at the wrong
version, a string added in English only — are all things a single paragraph of instruction can
prevent, and none of them are things a compiler catches after the fact.

If something here conflicts with a specific task's own instructions, the task instructions win —
but that should be rare, and worth a stop-and-report if it happens.

---

## 1. One agent owns one area, start to finish

Concurrency in this plan comes from **areas running in parallel**, not from subdividing an area
across agents. A 5,000-LOC area split three ways does not produce three independent tasks — it
produces a three-stage pipeline, because stage 2 needs to compile against what stage 1 wrote. The
plan's own governing rule is:

> No unit of work may compile against an artifact produced by another unit running concurrently.

That is only true if the unit is the *area*. One agent takes an area — its `features/<x>/`,
`domain/<x>/`, its migration provider, its DI provider, its detail host, its registry entries, its
strings object, its tests — and carries it start to finish, sequentially. Do not hand off half an
area mid-task, and do not pick up a second area before the first is done and self-verified.

---

## 2. The frozen-file rule, and the inverse check that actually matters more

Batch 1 rewrites every **magnet file** — a shared file that many later tasks would otherwise all
need to edit — into a final shape that later tasks extend through a registry entry instead of a
direct edit. Once Batch 1 lands, those files are **frozen**: `scripts/check_frozen_files.sh` diffs
the current tree against the `android-port-scaffold` tag (cut right after Batch 1) for every path
listed in `scripts/frozen-files.txt`, and fails if any of them changed.

**But the frozen-file list is structurally blind to the failure mode that actually happens.** It
only catches an edit to a file *someone remembered to list*. The real failure is a task editing a
magnet nobody thought to freeze — a shared file that isn't on the list because the list is, by
construction, written before every future task's needs are known. A frozen-file check can never be
complete; it can only be a backstop.

So the **primary control is the inverse**: every task declares the paths it owns, and
`scripts/check_task_ownership.sh` fails the task if its diff — `git status --porcelain`, which
catches new/untracked files as well as edits, not just `git diff --name-only` — contains anything
outside that declared scope. This check doesn't need to know what a magnet is. It doesn't need a
maintained list. It catches *any* out-of-scope file, frozen or not, named in advance or not,
because it inverts the question from "is this file protected?" to "did this task touch only what
it said it would?" That is why it is the mechanism and the frozen-file list is the backstop, not
the other way around.

Run both, in this order, before every commit:

```bash
bash scripts/check_task_ownership.sh <owned-paths-file>   # or: TASK_OWNED_PATHS="..." bash scripts/check_task_ownership.sh
bash scripts/check_frozen_files.sh                         # defaults to the android-port-scaffold tag
```

If either fails: **stop and report.** Do not edit around it, do not widen your declared scope to
cover the file you weren't supposed to touch, and do not weaken either script to make the failure
go away. A task that genuinely must amend a magnet is not a normal task — it becomes a solo
**magnet-amendment task**, run alone at a batch barrier with no other task running concurrently,
and the `android-port-scaffold` tag is re-cut afterwards so the frozen baseline reflects the
amendment.

---

## 3. Where new code goes, so it never collides

The whole point of Batch 1's registries is that adding a *feature* never means editing a *shared*
file. Concretely:

- **Per-feature strings.** Each feature declares its own `object <Feature>Strings` holding its
  bilingual (`LocalizedString(en, ar)`) copy. At least 16 features already follow this pattern
  (verified directly — e.g. `features/journal/JournalModel.kt`, `features/home/HomeScreen.kt`,
  `features/healthmonitor/HealthMonitorModel.kt`, `features/reports/ReportsScreen.kt`); it is the
  established convention, not a new one. The one shared strings object, `Loc` in
  `core/Strings.kt`, is itself frozen — do not add a case to it. If a string is genuinely
  cross-feature, that is a conversation for a stop-and-report, not a `Loc` edit.
- **One migration provider per area.** Your area owns exactly one `MigrationProvider` (main and/or
  sensitive, per your pre-allocated version — see §4 below). You fill the provider stub; you never
  edit the aggregator that collects providers into `Schema`'s migration list.
- **One DI provider per area.** Same shape: `app/di/<Area>Providers.kt` is your file to fill in
  (forward-declared as a lazy stub by Batch 1). The composition root that wires providers together
  is not yours to edit.
- **One `*DetailHost.kt` per area.** Batch 1 stubs ~24 of these against `DetailRegistry` in
  `app/RouteHost.kt`. You fill your own host; you do not add a case to the registry's dispatch
  logic — you register an entry.
- **Registry entry objects, each in their own file.** Every registry Batch 1 introduces (home
  cards, LogHub tiles/`RecentKind`, Body tools/headline candidates, notification classes, export
  writer fragments) takes entries as separate objects/files, one per area, never as edits to the
  registry's own aggregation file. If you find yourself editing the registry file itself rather
  than adding a new file next to it, you are about to touch a frozen file — stop and report
  instead.

---

## 4. Migration numbering — mirror iOS, fill the holes, never append past them

`storage/Schema.kt` says, in its own migration comments, things like *"Byte-equivalent mirror of
iOS `Schema.mainMigrations` version 6"* for every migration it defines, and version 6's comment
goes further — it explains that `CREATE INDEX IF NOT EXISTS idx_baseline_lookup` is written as
`IF NOT EXISTS` specifically because Android already shipped that index in its own version 2 (iOS
never did), so the statement is a no-op on Android and a real create on iOS: *"keeping the two
platforms' version-6 statement strings byte-identical rather than forking them."* Android's
migration numbers are **deliberately aligned with iOS's**, not independently numbered.

That means: main version 3 and sensitive version 2 are gaps in the numbering today (Android has
1, 2, 4, 5, 6, 7, 8 on main and 1, 3, 4 on sensitive — verified directly against `Schema.kt`), and
they are **reserved slots for iOS's main v3 and sensitive v2 content**, not empty numbers to skip.
**Fill them. Do not append that content past the current top of the list** (e.g. as main v9 when
main already goes to v8) — that would fork the numbering permanently and require inventing a
mapping comment to recover what equal integers already give for free.

Your task will hand you a **pre-allocated version number**. Use exactly that number for exactly
that content. Never invent a new one, and never renumber an existing migration to make room.

Two structural fixes make hole-filling safe (both land in Batch 1, in `storage/Database.kt` and
the migration aggregator — do not re-derive or second-guess them in your own area's migration
work):

1. The pending-migration predicate is `version NOT IN (SELECT version FROM schema_migrations)`,
   not `version > MAX(version)` — the old predicate would silently skip a hole-filling migration
   registered after a higher-numbered one had already applied on a device.
2. Both the provider aggregator and `migrate()` **sort by version** before applying — provider
   *registration* order is no longer schema *application* order.

If your task's pre-allocated migration is a hole-fill, treat that as confirmation the plan
intends it, not a surprise to resolve on your own.

---

## 5. Contract entries are load-bearing — never hardcode around a missing one

`packages/metric-ontology/registry.json` and `packages/contracts/algorithms/algorithms.json` (and
their Android mirrors under `app/src/main/assets/`) are the canonical source for what a derived
engine computes. **A missing `algorithms.json` entry for a metric means the engine computes
nothing for it** — engines look their contract entry up and no-op when it's absent, by design (see
`ontology/MetricRegistry.kt`, `core/Units.kt`). This is not a bug to route around locally.

If your area needs a metric, unit, or algorithm that isn't in the registry or algorithms contract:
**do not** hardcode a constant, a conversion, or a fallback value to make your feature "work
anyway." That produces a number that looks real and isn't backed by anything — worse than an
obviously-missing feature. Report it instead: the contract entry belongs in
`packages/metric-ontology/registry.json` / `packages/contracts/algorithms/algorithms.json`
(neither of which you own), and adding one is a decision, not a code change you make silently
inside your area.

---

## 6. Do not regress Android-only surface

"Port from iOS" is an instruction to close gaps, never a license to delete or shrink working
Android behaviour. Android currently **leads** iOS in several areas — verified directly by LOC
comparison (iOS `apps/ios/Sources/<x>` vs Android
`apps/android/app/src/main/java/net/albayyan/badan/<x>`, `*.swift`/`*.kt` line counts):

| Area | iOS LOC | Android LOC |
|---|---:|---:|
| `features/body` | 1,918 | 2,107 |
| `features/workouts` | 1,138 | 1,617 |
| `features/journal` | 1,283 | 1,559 |
| `features/symptom` | 954 | 1,145 |
| `features/healthmonitor` | 846 | 1,045 |
| `features/reports` | 602 | 852 |
| `domain/reports` | 949 | 1,104 |

If your area touches one of these (or any other surface where the Kotlin already does more than
the Swift), **keep the extra Android behaviour** and note in your `docs/variance/<task-id>.md`
what you preserved and why. Do not "clean up" Android down to iOS's shape. If you're unsure
whether something is Android-only depth or genuine drift, keep it and say so in your variance
file — that's a cheap default that costs nothing to reverse later, unlike deleting working code.

---

## 7. Bilingual is structural, not a follow-up step

`LocalizedString(en, ar)` cannot be constructed with only one language — there is no default, no
"add Arabic later" state that compiles. Any `@string/` resource you add to
`apps/android/app/src/main/res/values/strings.xml` needs its Arabic counterpart in
`apps/android/app/src/main/res/values-ar/strings.xml` **in the same change**, not a follow-up.
Both files are frozen after Batch 1 pre-declares every string the port needs (Glance widget
labels, QS tile labels, `shortcuts.xml` capability labels, the live-workout notification channel,
Wear tile strings) in both locales — so in the common case you are *using* an already-declared
string, not adding one. If your task genuinely needs a resource string that isn't pre-declared,
that is a stop-and-report against a frozen file, same as any other magnet — not a quick add to
`values/` with `values-ar/` "to follow."

A monolingual string addition is a silent Arabic/RTL regression, and CLAUDE.md makes Arabic/RTL
readiness a first-order concern, not a nice-to-have.

---

## 8. A build hazard you cannot see from the diff: `ExportSchema.VERSION`

`.github/workflows/ci.yml` parses `ExportSchema.VERSION` (`apps/android/app/src/main/java/net/
albayyan/badan/export/CsvWriter.kt`) and its Swift counterpart (`apps/ios/Sources/Export/
CSVWriter.swift`) with a regular expression, not a compiler, to cross-check the export schema
version against `packages/export-schemas/csv_columns.json` and the fixture set. If an IDE
auto-formats that line — wraps it, changes the quoting style, reflows the surrounding block — the
regex stops matching and CI fails with an error about a schema-version *mismatch*, pointing you at
the wrong problem entirely; nothing about the failure message says "formatting."

**This is a Batch-1 task, not yet done**: add the line
`// CI-PARSED — do not reformat this line` directly above the `ExportSchema.VERSION` constant in
**both** `CsvWriter.kt` and `CSVWriter.swift`. Neither file is owned by this document (they belong
to the export area / an iOS task), so this section only documents the hazard and the fix that is
owed — if your task touches either file before that comment lands, add it as part of your change
rather than leaving the trap for the next agent who reformats it.

---

## 9. Self-verify — exactly this, in this order

Every task's self-verify is exactly the four commands below, run from `apps/android`, in order.
**Do not run `assembleDebug`, `lint`, `:app:build`, or the unfiltered test suite** — those are
slow, whole-module operations that belong to the barrier integrator, not to a single task running
concurrently with up to five siblings.

```bash
./gradlew :app:compileDebugKotlin --console=plain
./gradlew :app:compileDebugUnitTestKotlin --console=plain
./gradlew :app:testDebugUnitTest --tests "<your package>.*" \
                                 --tests "*MigrationOrderingTest" --console=plain
bash scripts/check_task_ownership.sh <your owned-paths file>   # or TASK_OWNED_PATHS=... 
bash scripts/check_frozen_files.sh
```

All four/five commands are runnable locally by any agent — no CI-only step exists in this list.

Notes on running this concurrently with sibling tasks:

- Every area agent works in its **own git worktree**, sharing one `GRADLE_USER_HOME`. Set
  `org.gradle.jvmargs=-Xmx2048m` and `org.gradle.workers.max=2` in that worktree's
  `gradle.properties` override (the repo default is `-Xmx3072m` / unset `workers.max`, sized for a
  single-worktree run — leave it alone in a worktree you don't control). Cap concurrent worktrees
  at **6**: 7 worktrees × 2 GB heap plus daemons saturates a typical dev machine before CPU does.
- `gradle.properties` sets `configuration-cache=true` — concurrent `./gradlew` invocations across
  worktrees can and will serialize on the configuration-cache and execution-history locks. **A
  `./gradlew` invocation blocking because a sibling task holds the config-cache lock is expected,
  not a hang.** Wait it out; do not kill a sibling's process, and do not "work around" the lock by
  running `--no-configuration-cache` or similar — that changes what you're actually testing.
- Compilation is the expensive part (a cold config-cache miss dominates); test *execution* is
  cheap (the full suite runs in around 6 seconds). Use `--tests` filters as shown above rather than
  running the unfiltered suite — filtering saves nothing on compilation but avoids re-running
  hundreds of unrelated tests every verify cycle.

---

## 10. Variance files

If your task substitutes a genuine Android platform difference for an iOS capability (a
capability-level gap, not a shortcut) — Play Integrity for App Attest, Glance widgets for
Lock-Screen widgets, an `IF NOT EXISTS` byte-identity quirk, a permission Android grants but iOS
can't, anything the plan or your task instructions call a decided substitution — write
`docs/variance/<task-id>.md` documenting it, even if the answer is "no variances." See
`docs/variance/README.md` for the convention (one file per task, never a shared ledger).

---

## Quick checklist before you start a task

1. Read this document and `docs/adr/ADR-0012-android-parity-port.md`.
2. Read every iOS source path your task lists, in full, before writing Kotlin.
3. Confirm your pre-allocated IDs (migration version, DI provider, route name, table name, strings
   object, registry entry key) — fill them, never invent new ones.
4. Write your owned-paths list before you start editing, and run
   `scripts/check_task_ownership.sh` against it as you go, not only at the end.
5. If a magnet needs to change, stop — that's a magnet-amendment task, not your task.
6. Before you delete or shrink anything, check whether it's Android-only depth (§6) — when in
   doubt, keep it and note it.
7. Every new `@string/` gets both locales, in the same change.
8. Run the self-verify command set in §9, in order, and only those commands.
9. Write `docs/variance/<task-id>.md`, even to say there's nothing in it.
