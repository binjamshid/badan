# BADAN — Decision Log

Format: **Context · Choice · Rationale · Migration impact (price of reversal) · Approval**, each
entry a stable numbered id (`D-<n>`), never renumbered — a superseded decision gets a new id and
says which one it replaces, rather than the old id being reused or deleted. `Approval` records who
decided and how firm the decision is (`accepted` = load-bearing today; `open` = still revisitable
without a formal reversal).

**How this file was created (2026-07-22):** every entry below is a **backfill** — a restatement of
a decision this repo already made and recorded elsewhere, not a new decision made while writing
this log. Each entry cites the exact source document it was transcribed from. Nothing here is
invented: where a source document is itself a draft with no decision pinned yet (see D-20), that
is stated as such rather than promoted into a decision it isn't.

Sources consulted: `docs/adr/ADR-0001` through `ADR-0009` (all nine ADRs in the repo at the time
of writing), `packages/contracts/INVARIANTS.md` (I1–I8), and `docs/MONETIZATION.md`.

---

## D-1 — Native-first UI with contracts-level sharing only (ADR-0001)
- **Context:** BADAN needs genuinely native iOS/Android experiences (HealthKit/Health Connect,
  background work, dense charts, RTL) but the original blueprint (§33/§47/§52) assumed a Kotlin
  Multiplatform shared core.
- **Choice:** Native UI/app integration per platform (Swift/SwiftUI, Kotlin/Compose). Shared
  material is **specifications, not runtime**: canonical entities, the metric ontology, insight
  templates, the symptom dictionary, and the export contract live as machine-readable data in
  `packages/`, consumed identically by both platforms.
- **Rationale:** `CLAUDE.md` mandates native-first; a KMP shared core is heavier than the repo's
  actual coupling needs at this stage.
- **Migration impact:** A small, budgeted set of duplicated logic (unit conversion,
  timezone/day-attribution, dedup-lite, baseline median/MAD, export serialization) exists on both
  platforms, fixture-guarded against drift. Reversal cost: adopting KMP later means consolidating
  this duplicated logic into a shared core — a re-architecture, not a config flip. ADR-0001 names
  its own re-evaluation gate (the "KMP re-evaluation gate" below), so this isn't open-ended.
- **Supersession:** none. Re-evaluation gate (ADR-0001, M4): adopt KMP only if ≥3
  fixture-divergence incidents occur, duplicated domain code exceeds ~2k LOC/platform, or the team
  confirms toolchain comfort.
- **Approval:** accepted (backfilled from ADR-0001, Accepted, 2026-07-10).

## D-2 — No backend in the MVP; local-first, zero network (ADR-0002)
- **Context:** Local-first is BADAN's strongest privacy proof and eliminates an entire risk class
  (auth, hosting, compliance, breach surface).
- **Choice:** MVP ships with **zero backend**. On-device SQLite is the sole source of truth. No
  accounts, no remote analytics, no network calls anywhere in the app. `backend/`/`infra/` stay
  dormant. Export is fully offline (OS share sheet only).
- **Rationale:** The product promise is a user-owned repository; a backend is not needed to
  deliver the MVP's value and would otherwise introduce a breach surface for a health app.
- **Migration impact:** The export module is lint-forbidden from importing any
  networking/entitlement API (D-8 in ADR-0002's own numbering — not the same id space as this
  file). Reversal cost is explicitly priced in `docs/MONETIZATION.md` §5 (see D-20 below):
  reversing this decision needs a **superseding ADR**, a privacy-policy rewrite, a Data
  Safety/privacy-nutrition update on both app stores, and reintroduces the breach surface this ADR
  exists to avoid.
- **Supersession:** none yet. ADR-0002 itself names the trigger: "the first backend work item is
  sync or the first vendor integration, and not before the M4 review."
- **Approval:** accepted (backfilled from ADR-0002, Accepted, 2026-07-10).

## D-3 — Sync-ready schema, not sync-dependent behavior (ADR-0003)
- **Context:** A future multi-device/E2E-sync world must not require a painful schema retrofit,
  but sync must not leak into the MVP as complexity or a network dependency.
- **Choice:** Every row table carries, from day one: a ULID primary key, `updated_at`,
  `origin_device_id`, and a `deleted_at` tombstone. A reserved, unused `sync_cursors` table exists.
  Provenance carries an `external_id` idempotency key; measurement tables have partial-unique
  identity indexes so re-ingest is a no-op. No sync service, oplog, or conflict resolution ships in
  the MVP; **no write path may require the network.**
- **Rationale:** Paying a few always-present columns now is cheap; retrofitting them onto a live
  schema later is expensive.
- **Migration impact:** Re-running ingestion is idempotent (proven by the identity indexes);
  deletes are tombstones, preserving a future merge story. Reversal cost of *not* having done this
  would have been a schema migration across every existing row at sync time — this decision's
  entire point is to make that cost already-paid.
- **Supersession:** none.
- **Approval:** accepted (backfilled from ADR-0003, Accepted, 2026-07-10).

## D-4 — Sensitive-plus namespace as a separate physical DB file; encryption posture stated honestly (ADR-0004)
- **Context:** Medications, symptoms, and conditions are more sensitive than sleep or steps.
  "Disable this module and remove its data" must be a hard guarantee, not a best-effort row delete.
- **Choice:** Sensitive-plus entities live in a **separate physical database file**
  (`badan_sensitive.db`), distinct from `badan.db`. Disabling those modules purges by **deleting
  the file** (`purgeSensitiveNamespace`); the main DB is untouched. Export includes this namespace
  only when `includeSensitive` is explicitly enabled. Encryption posture (stated honestly, not
  papered over): MVP relies on OS file-level encryption (iOS Data Protection; Android FBE);
  SQLCipher is **not** yet adopted.
- **Rationale:** A structural (file-boundary) guarantee is mechanically trustworthy in a way a
  filtered view over shared storage is not.
- **Migration impact:** Extra care is needed at the repository seam (two DB connections), handled
  by `LoggingRepository`. Reversal/upgrade cost: adopting SQLCipher is flagged as a deliberate
  future decision (tracked for M4), needed before sync or passphrase-protected export — the latter
  half of that trigger has since been superseded, see D-8.
- **Supersession:** partially superseded by **D-8** (ADR-0008), which is scoped explicitly to
  *exported files* only — ADR-0004's on-device encryption posture (no SQLCipher) remains
  unchanged and still governs `badan.db`/`badan_sensitive.db` at rest.
- **Approval:** accepted (backfilled from ADR-0004, Accepted, 2026-07-10).

## D-5 — Raw system SQLite (not GRDB) on iOS (ADR-0005)
- **Context:** The plan named GRDB for iOS persistence, but GRDB requires SwiftPM package
  resolution (a network fetch) at build time — an avoidable risk for a strictly local-first,
  offline, reproducible build.
- **Choice:** Use the system `SQLite3` C library directly, behind a thin (~150-line) Swift wrapper
  (`SQLiteConnection`, `SQLValue`, `SQLiteRow`) — zero external dependencies, deterministic,
  faithful to the plan's raw-DDL / two-DB-files / embedded-provenance design.
- **Rationale:** The storage design was already expressed as raw DDL with explicit provenance
  columns and named indexes; an ORM is not needed to honor it, and it removes a build-time network
  dependency.
- **Migration impact:** More hand-written SQL and row mapping, in exchange for full control and no
  hidden behavior. The wrapper is deliberately the single seam any future swap targets — reversal
  cost of adopting GRDB or SQLCipher later is "reimplement one file's surface," not "touch every
  repository."
- **Supersession:** amends `EXECUTION_PLAN` §5/AP-05, which named GRDB.
- **Approval:** accepted (backfilled from ADR-0005, Accepted, 2026-07-10).

## D-6 — iOS is the deeply-built flagship this pass; Android mirrors via shared contracts (ADR-0006)
- **Context:** The build environment has a full iOS toolchain, so an iOS app can be compiled, run,
  and demonstrated end-to-end; building and verifying two production-grade native apps in one pass
  is not realistic. This competes with `CLAUDE.md`'s parity mandate ("do not build iOS in a way
  that makes Android a second-class dead end").
- **Choice:** iOS is the deeply-built, compiled, simulator-verified flagship (real domain model,
  SQLite persistence, ingestion+dedup, derivation, export, ~15 screens, seeded data, tests).
  Android stays a first-class, non-dead-end path by holding all shared truth in `packages/`/`docs/`
  language-neutrally, documenting the Android mapping, and keeping the Kotlin scaffold coherent.
- **Rationale:** Parity is enforced as a property of shared contracts and conformance fixtures, not
  a requirement to build both apps simultaneously.
- **Migration impact:** Android trails iOS in this pass — stated plainly in the ADR itself, not
  hidden. As of this backfill (2026-07-22), Android has since caught up substantially (e.g. the
  export-encryption parity closed in D-8's addendum), so this ADR's "flagship" framing is now
  historical rather than current-state.
- **Supersession:** none formally, though its premise (Android as trailing) is materially less true
  today than on 2026-07-10.
- **Approval:** accepted (backfilled from ADR-0006, Accepted, 2026-07-10).

## D-7 — Android uses framework SQLite (not Room), mirroring the iOS seam (ADR-0007)
- **Context:** ADR-0005 chose raw SQLite over GRDB on iOS; the plan (AP-06) had assumed Room for
  Android, which brings an annotation processor (KSP), a version-compatibility matrix, and a schema
  abstraction that would diverge from the raw-DDL design iOS already implements.
- **Choice:** Android uses framework SQLite (`android.database.sqlite.SQLiteDatabase`) behind a
  thin `SqliteConnection` wrapper — exact parity with the iOS wrapper. Runs the same migration-001
  DDL verbatim, keeps the two physical DB files (`badan.db` + `badan_sensitive.db`), no KSP/Room
  version matrix. Timestamps: `INTEGER` epoch-millis on both platforms (Kotlin `Long`, iOS `Date`)
  — same UTC meaning, representation detail only.
- **Rationale:** One logical schema, two thin native wrappers, so the only drift surface is the
  shared SQL.
- **Migration impact:** Hand-written SQL + row mapping on Android too, consistent with iOS. Room
  remains a clean future option (swap the wrapper) if its migration/observation ergonomics become
  worth the KSP cost — reversal cost is bounded to that one wrapper file, by design.
- **Supersession:** amends ADR-0005's note that "Android will use Room."
- **Approval:** accepted (backfilled from ADR-0007, Accepted, 2026-07-10).

## D-8 — Passphrase-encrypted `includeSensitive` exports; BDNX container format (ADR-0008 + Android-parity addendum)
- **Context:** Review ledger #19 flagged that sensitive-scope exports (`raw.csv`, `derived.csv`,
  `events.csv`, `bundle.json`, `manifest.json`) left the device as plaintext (FEAT-185, deferred).
  `docs/runbooks/disaster-recovery.md` independently named the same gap: "there is no
  passphrase-protected export a user could safely store off-device today."
- **Choice:** An export with `scope.includeSensitive == true` is wrapped in one AES-256-GCM
  encrypted container (`export.badanenc`, the byte-exact "BDNX" format) before it ever reaches the
  share sheet, keyed by a user-typed passphrase (PBKDF2-HMAC-SHA256, 600,000 rounds, 16-byte random
  salt). `ExportCenterScreen`/`AdvancedExportScreen` (Android) both require and validate the
  passphrase (entry + confirm, minimum 10 characters — `ExportPassphrasePolicy`);
  `ExportRunner.run` independently refuses to produce a sensitive export without one on both
  platforms. Standard platform primitives only — CryptoKit + CommonCrypto on iOS,
  `javax.crypto` on Android — no new dependency on either side. The Android mirror (added
  2026-07-22, this repo state) is byte-exact with the iOS format, proven by two-way cross-platform
  fixtures under `packages/fixtures/encryption/` (`ios-written-v1.badanenc` decrypts on Android,
  `android-written-v1.badanenc` decrypts on iOS, plus iOS's original hardcoded format-stability
  golden decrypting on Android too).
- **Rationale:** Export is BADAN's only backup mechanism (no server, no sync — D-2/D-3); the only
  portable secret in this threat model is a user-chosen passphrase, since there is no server-side
  key and no account to recover one from (D-2).
- **Migration impact:** A sensitive export is now one `.badanenc` file instead of several plain
  files; "export again" for a past sensitive job requires a fresh passphrase (none is ever stored).
  Price of reversal / no-go trigger (from the ADR itself): revisit if a security review finds
  600,000-round PBKDF2 insufficient against realistic offline attacker hardware (would need a
  memory-hard KDF — its own ADR and dependency decision), or if wall-clock KDF time exceeds 1.5s on
  the oldest supported device. A forgotten passphrase makes that export **permanently
  unrecoverable** — a deliberate design consequence, not a defect.
- **Supersession:** narrows ADR-0004 (D-4)'s encryption posture for the **exported-file** case
  only; on-device encryption (no SQLCipher) is unchanged and still governed by D-4.
- **Approval:** accepted (backfilled from ADR-0008, Accepted, 2026-07-20, plus its
  2026-07-22 Android-parity addendum recorded in the same file).

## D-9 — Widen the frozen CSV export contract, 24 → 26 columns (ADR-0009, approval A1)
- **Context:** `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §28 asked the founder to approve three gated
  actions (A1–A3) before further WHOOP/HAE work could proceed; the 24-column CSV export contract
  had been declared frozen.
- **Choice:** `packages/export-schemas/csv_columns.json` gains `granularity` and
  `aggregation_method`; the export schema version bumps `0.1.0 → 1.0.0`.
- **Rationale:** The change is additive (no column removed/reordered/redefined) and versioned (the
  schema version bump is the contract's own escape hatch) — consumers pinned to the 24-column read
  still parse a 26-column file correctly by name.
- **Migration impact:** Every export golden fixture regenerated at v1.0.0; `docs/` gains a schema
  changelog. Reversal cost is low precisely because the change was additive by design.
- **Supersession:** none.
- **Approval:** accepted — Founder, per ADR-0009 (2026-07-20).

## D-10 — HealthKit background delivery entitlement + BGTaskScheduler (ADR-0009, approval A2)
- **Context:** Same founder-approval gate as D-9 (ADR-0009's A2).
- **Choice:** `apps/ios/App/BADAN.entitlements` gains
  `com.apple.developer.healthkit.background-delivery`; `Info.plist` gains
  `BGTaskSchedulerPermittedIdentifiers` for a BGAppRefreshTask and a BGProcessingTask.
- **Rationale:** Keeps the user's on-device repository fresh without a network dependency; privacy
  posture is unchanged in substance (still no network, still no collected data), but the
  App-Store-review justification story changes because the app now wakes in the background.
- **Migration impact:** Binding build rules from the ADR: the observer completion handler must
  return within seconds on every wake (HealthKit disables background delivery after 3 missed
  handlers — that budget is never spent); an observer wake means "something changed," never a
  payload, and must be followed by an anchored re-query; `enableBackgroundDelivery` is
  re-registered defensively on every app open; a locked store is logged as `skippedLocked`, never
  surfaced as a user-facing error; no UI copy ever promises a wall-clock time for a background
  wake.
- **Supersession:** none.
- **Approval:** accepted — Founder, per ADR-0009 (2026-07-20).

## D-11 — Score naming (Readiness/Effort/Sleep score) and public formula publication (ADR-0009, approval A3)
- **Context:** Same founder-approval gate as D-9/D-10 (ADR-0009's A3).
- **Choice:** Scores ship as **Readiness**, **Effort** (0–21 scale, WHOOP-comparable shape but
  BADAN's own published curve), and **Sleep score**. Formulas are published in-app (the existing
  anatomy-sheet pattern) and in `docs/algorithms/`; algorithm constants live as data in
  `packages/contracts/algorithms/algorithms.json` so both platforms evaluate identical curves.
- **Rationale:** 0–21 (rather than 0–100) keeps the number legible to users arriving from WHOOP
  without implying it *is* WHOOP's number.
- **Migration impact:** An algorithm change is necessarily an app update with a changelog and an
  `AlgorithmVersion` row — remote configuration of algorithm parameters is explicitly **not**
  introduced. Reversal (re-closing the formula) would contradict the explicit publication
  commitment and would need its own founder decision.
- **Supersession:** none.
- **Approval:** accepted — Founder, per ADR-0009 (2026-07-20).

## D-12 — I1: every health datum carries full, embedded provenance (INVARIANTS.md)
- **Context:** "Where did this number come from" must always be answerable directly from the data.
- **Choice:** No measurement, derived value, or logged entry exists without a record of source,
  device, ingestion path, external id, batch id, and timestamps — embedded on the row itself
  (denormalized, per D-3-equivalent architecture note "D-3" inside `docs/architecture.md`, not this
  file's D-3), not reconstructed from a separate audit trail.
- **Rationale:** A separate audit trail can fall out of sync with the data it describes; embedding
  provenance on the row cannot.
- **Migration impact:** Every domain entity under `apps/ios/Sources/Domain/` (and its Android
  equivalent) is expected to uphold this. Reversal would mean re-deriving provenance after the
  fact for historical rows with no embedded record — effectively unrecoverable for any data
  ingested before the reversal.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I1).

## D-13 — I2: derived values append, never overwrite (INVARIANTS.md)
- **Context:** A recomputed baseline/insight/derived value must not erase "what BADAN believed at
  the time."
- **Choice:** Recomputation appends a new row; it never mutates or deletes the prior result.
- **Rationale:** Preserves auditability and lets a stale/wrong derivation be distinguished from one
  simply superseded by better data.
- **Migration impact:** Derived-value tables grow monotonically rather than being overwritten in
  place; storage cost accrues over time by design. Reversal would require pruning history the
  invariant exists to keep.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I2).

## D-14 — I3: dedup suppresses, never deletes (INVARIANTS.md)
- **Context:** Ingestion reconciling a likely-duplicate reading (e.g. the same walk from a phone
  and a watch) must not silently destroy the loser.
- **Choice:** The losing row is marked suppressed, not removed; the row and its
  `ReconciliationDecision` both remain, so the decision is always reversible and inspectable.
- **Rationale:** A dedup decision is a judgment call, not ground truth, and judgment calls must stay
  correctable.
- **Migration impact:** Suppressed rows persist in storage indefinitely (until an explicit user
  purge). This is also the basis for D-8's export `includeSuppressed` option and the export
  manifest's dedup policy note.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I3).

## D-15 — I4: manual entry wins for weight/BP/labs; device wins elsewhere by source priority (INVARIANTS.md)
- **Context:** Conflicting readings for the same metric/time need a reconciliation rule, and "most
  recent write wins" is not correct universally.
- **Choice:** For weight, blood pressure, and lab values, a manual entry is authoritative over a
  device reading. For everything else, devices are reconciled against each other by a defined
  source-priority order.
- **Rationale:** People correct their scale by hand but rarely mis-key a number; the reverse is true
  for continuously-sampled device metrics like heart rate.
- **Migration impact:** This is a metric-specific rule, not a blanket policy — changing it means
  auditing every metric family individually, not flipping one flag.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I4).

## D-16 — I5: raw and derived data are always separable (INVARIANTS.md)
- **Context:** Every read path, export, and API must be able to distinguish "what a source actually
  recorded" from "what BADAN computed from it."
- **Choice:** Raw (provenance-carrying) data is never silently blended with derived values in a way
  that makes the two indistinguishable.
- **Rationale:** This is also what makes the "raw data is not paywalled" product guardrail
  (`CLAUDE.md`) meaningful in practice — see D-20's discussion of `docs/MONETIZATION.md`.
- **Migration impact:** Constrains every future feature (including any premium tier, D-20) to keep
  raw and derived presentation paths distinct.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I5).

## D-17 — I6: no domain entity references entitlement/paywall state (INVARIANTS.md)
- **Context:** Presentation-layer concerns (what a build/plan is allowed to show) must not leak
  into the domain layer.
- **Choice:** Domain entities (measurements, derived values, logs) carry no notion of subscription
  tier, paywall status, or feature-flag entitlement.
- **Rationale:** Keeps one canonical data model serving every presentation policy without forking
  or annotating the data itself — directly relevant if `docs/MONETIZATION.md` (D-20) is ever acted
  on.
- **Migration impact:** Any future monetization feature must be implemented as a presentation-layer
  gate over the existing model, never as a schema/domain change: this invariant is the concrete
  constraint that keeps a premium tier from being able to "hide" raw data (see D-20).
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I6).

## D-18 — I7: sensitive-plus is a separate, structurally purgeable namespace (INVARIANTS.md)
- **Context:** Restated/elaborated form of D-4 (ADR-0004)'s file-boundary decision, stated here as
  a standing domain invariant rather than a one-time architectural choice.
- **Choice:** Medications and symptoms live in a physically separate database file so "turn off
  sensitive records" is a literal file deletion (`Database.purgeSensitiveNamespace()`), never a
  best-effort row-by-row purge or a filtered view over shared storage.
- **Rationale:** A structural boundary cannot silently regress into a filtered view the way a
  logical/soft boundary could under future refactors.
- **Migration impact:** Same as D-4.
- **Supersession:** none; restates D-4 as a standing invariant.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I7).

## D-19 — I8: all entity ids are on-device ULIDs (INVARIANTS.md)
- **Context:** BADAN has no backend (D-2) and therefore no central authority to hand out
  sequential/server-assigned ids.
- **Choice:** Every entity id is a ULID generated on-device — lexicographically sortable by
  creation time, collision-resistant without coordination.
- **Rationale:** Matches D-2/D-3's local-first, sync-ready posture: an id scheme that doesn't
  assume a server exists.
- **Migration impact:** A future backend (D-2's reversal) would need to either keep client-generated
  ULIDs as canonical or introduce a mapping layer — reversal cost is bounded because ULIDs remain
  valid, globally-unique keys even after a backend exists.
- **Supersession:** none.
- **Approval:** accepted (backfilled from `packages/contracts/INVARIANTS.md`, I8).

## D-20 — Monetization: no premium feature is decided or built yet (`docs/MONETIZATION.md`)
- **Context:** `docs/MONETIZATION.md` is explicitly headed "Status: draft for owner decision.
  Nothing here is built" (written 2026-07-16). It is a proposal document, not a decision record.
- **Choice:** **No choice has been pinned.** This entry exists so the decision log doesn't have a
  silent gap where a reader might assume monetization was decided; the honest state, as of this
  backfill, is that it was not.
- **What the draft does establish as already-binding (restated, not newly decided here):** the
  `CLAUDE.md` guardrail "raw data is not paywalled" — the draft's own framing is "you never pay to
  see, keep, or leave with your own data; you pay for BADAN's interpretation of it" — and that
  reversing ADR-0002 (D-2, no backend) to add a backend-verified subscription is a "legitimate
  product decision" but would need its own superseding ADR, a privacy-policy rewrite, and a Data
  Safety/privacy-nutrition update on both stores (see D-2's migration-impact note).
- **Rationale:** N/A — no decision made.
- **Migration impact:** N/A.
- **Supersession:** none; this entry itself would be superseded the moment an owner decision is
  actually made on any item in `docs/MONETIZATION.md` §3/§5/§6.
- **Approval:** **open** — explicitly awaiting an owner/founder decision; nothing here is
  `accepted`.

---

## D-21 — Founder self-designates as retained clinical advisor (ADR-0010, approval A25)
- **Context:** A25 named a standing clinical-advisor requirement across the safety-language
  matrix, pregnancy content, vitals-BLE copy, and release-gate sign-offs — a recurring
  non-engineering critical path across EPIC-40/41/43.
- **Choice:** The founder (RN, nursing background) is the retained clinical advisor.
- **Rationale:** Satisfies A25 directly, and its clinical half also unblocks A18/A21's
  "clinical advisor" precondition.
- **Migration impact:** None to code. Does not substitute for GCC/Oman legal review (A17/A18).
- **Supersession:** none.
- **Approval:** accepted — Founder, per ADR-0010 (2026-07-23).

## D-22 — AI coach: hybrid hosting, OpenRouter GPT-4o, opt-in-only, first network call (ADR-0010, approval A9)
- **Context:** A9 was pre-approved in principle ("Phase-3 exit," now reached); this pins the
  concrete parameters.
- **Choice:** On-device retrieval + hosted stateless inference via OpenRouter (`gpt-4o`),
  served from an isolated service at `badan.binjamshid.com` on the founder's VPS (own
  systemd unit, nginx vhost, TLS cert, unprivileged user — not sharing process/config with
  the founder's other live services on that box). Default off; a dedicated consent screen is
  the only way to enable it.
- **Rationale:** Matches the plan's hybrid recommendation; opt-in keeps the local-first
  promise intact for every user who never enables it.
- **Migration impact:** BADAN's first-ever network call. Narrowly amends D-2/ADR-0002 —
  scoped to this one consented pathway, not a general reversal. Needs a privacy-policy
  section, an App/Play Data Safety label update, and consent copy through the same
  wellness-safe lint as every sensitive surface.
- **Supersession:** narrows D-2 (ADR-0002) for this one feature path only; D-2's zero-network
  posture is otherwise unchanged. Anticipates but does not fully resolve A4 (vendor OAuth
  backend remains separately gated).
- **Approval:** accepted — Founder, per ADR-0010 (2026-07-23).

## D-23 — Adopt SQLCipher for `badan_sensitive.db` only (ADR-0010, approval A16)
- **Context:** A16 had no firm recommendation pinned in the plan ("re-decide at Phase-1
  gate"); pregnancy/glucose/lab data landing now (D-24, D-26) raises the urgency the plan
  named.
- **Choice:** `badan_sensitive.db` moves to SQLCipher (SwiftPM on iOS, `android-database-sqlcipher`
  on Android), device-Keychain/Keystore-backed key. `badan.db` is unaffected — stays raw
  SQLite + OS-level file protection.
- **Rationale:** The sensitive namespace is about to carry meaningfully more sensitive data;
  upgrading its at-rest encryption ahead of that, rather than retrofitting later, is cheaper.
- **Migration impact:** Amends ADR-0005's zero-dependency posture for this one dependency,
  scoped to the sensitive-DB connection wrapper only (that wrapper's whole reason to exist,
  per D-5). `purgeSensitiveNamespace()` (D-4/D-18) is behaviorally unchanged — still a file
  delete. Does not touch ADR-0008's export-passphrase flow (D-8).
- **Supersession:** amends D-4/ADR-0004's "SQLCipher is not yet adopted" clause; D-4's
  file-boundary structure itself is unchanged.
- **Approval:** accepted — Founder, per ADR-0010 (2026-07-23).

## D-24 — Fertile-window estimation approved (ADR-0010, approval A17)
- **Context:** A17 gated CYCLE-12, the one item Phase 3F slice 2 left explicitly out of scope.
- **Choice:** Three-mode (calendar / signal-assisted / suppressed) fertile-window estimation,
  non-contraceptive framing, per the plan's recommendation.
- **Rationale:** Real user value for TTC users; suppressed-mode protects vulnerable cases.
- **Migration impact:** New CYCLE-12 build work inside the existing cycle module (EPIC-39).
- **Supersession:** none; lifts the CYCLE-12 exclusion named in Phase 3F.
- **Approval:** accepted — Founder+clinical (D-21); legal review is the founder's own
  separate action (see D-25), per ADR-0010 (2026-07-23).

## D-25 — Pregnancy module (EPIC-40) approved to build; legal review is founder-owned (ADR-0010, approval A18)
- **Context:** A18 required a clinical advisor (now D-21) and GCC/Oman legal review before
  build start; `docs/legal/reproductive-threat-model.md` scoped the review but explicitly did
  not authorize A18 itself.
- **Choice:** Engineering on EPIC-40 starts now. The founder has taken personal
  responsibility for preparing and submitting the GCC/Oman legal review in parallel — that
  review's completion is not a build-start gate, but it remains owed before this surface
  ships/is submitted to the App Store.
- **Rationale:** Separates what engineering can safely start (the module, behind the
  existing sensitive-namespace/consent/purge machinery) from what only the founder can do
  (retaining counsel, submitting the review).
- **Migration impact:** Highest-stakes domain in the plan; loss-handling and content review
  discipline from the threat-model doc still apply in full.
- **Supersession:** none; this is the memo the threat-model doc said A18 still needed.
- **Approval:** accepted (build) — Founder, per ADR-0010 (2026-07-23). Legal review:
  **open**, founder-owned, tracked separately — do not treat as closed.
- **Scope note (added post-audit, 2026-07-24):** the P0 slice that actually shipped covers
  PREG-01 through PREG-05 (modes, due dates, content shell, loss, storage/consent) only.
  PREG-06 (entity reuse — weight/symptom/appointment logging tagged into the pregnancy view
  and general history), though bundled into this same EPIC-40 batch by
  `BADAN_WHOOP_HAE_EXECUTION_PLAN.md`, was not built in this slice; a general-correctness
  audit of the P0 build flagged that this absence had no paper trail anywhere (not in code,
  not here, not in ADR-0010). Recorded here, and in `PregnancyModels.swift`'s own "out of
  scope" header, so the gap is disclosed rather than silently narrowed. PREG-06 remains a
  real, un-scheduled item for a future slice.

## D-26 — Glucose: platform-written ingestion approved now; vendor OAuth stays deferred (ADR-0010, approval A21)
- **Context:** A21 named glucose/CGM as the highest regulatory scrutiny in the corpus, but
  distinguished platform-written data from direct vendor integrations.
- **Choice:** HealthKit `bloodGlucose` / Health Connect `BloodGlucoseRecord` ingestion and
  export are buildable now, same as any other widened metric. Dexcom/Libre/Lingo direct
  OAuth integrations stay deferred, pending both the legal+clinical review (D-25) and each
  vendor's own developer-program approval (external lead time, same class as Garmin/A20).
- **Rationale:** The regulatory risk is concentrated in vendor-integration/treatment-adjacent
  framing, not in reading a value the OS already holds.
- **Migration impact:** "Never for treatment decisions" remains load-bearing copy on every
  glucose surface, per I13/the plan's clinical-boundary language.
- **Supersession:** none.
- **Approval:** accepted (platform-written path) — Founder, per ADR-0010 (2026-07-23). Vendor
  integrations: **open**, blocked on D-25 + vendor developer-program approval.
- **Scope gap (flagged by independent audit, 2026-07-24) — DB placement was never actually
  founder-approved:** `body.glucose` (registry `sensitiveClass: sensitivePlus`, per this decision
  and the blueprint's own CGM-platforms row) is stored in **`badan.db`** (main), via the same
  shared `measurements`/`IngestionPipeline` every other widened HealthKit metric uses — **not**
  `badan_sensitive.db`. A prior pass at this note called that "a deliberate reading of this
  decision's own 'buildable now, same as any other widened metric' line as covering storage
  architecture" — an audit found that framing does not hold up: **D-23/A16's own text** names
  glucose by name as one of the datasets whose imminent arrival justified adopting SQLCipher
  ("Pregnancy, glucose, and lab data are all landing on top of the sensitive namespace this same
  review unblocks" — ADR-0010, A16), which reads as the founder's actual expectation that glucose
  would land in the encrypted sensitive namespace, not `badan.db`. Landing it in main instead was
  an implementation shortcut this decision's own text does not establish, dressed up with a
  self-granted "Approval" line it never separately received — this entry's sole `Approval:` below
  covers the original 2026-07-23 ADR-0010 approval, which never mentions storage architecture.
  Concrete consequences this leaves open, named plainly rather than argued away: `body.glucose`
  is **not** SQLCipher-encrypted at rest (unlike every other `sensitivePlus` metric, post-D-23),
  and it is **not** covered by `purgeSensitiveNamespace()` — a user who turns off "Sensitive
  records" in Settings to erase their sensitive health data keeps their full glucose history on
  the device, silently.
  Kept for the record, since it's real engineering context for whoever makes the actual call: (a)
  export gating already holds identically for `body.glucose` regardless of physical DB, because
  `ExportRunner.metricAllowed` reads `sensitiveClass` directly (it already excludes `cycle.*`/
  `lab.*` from a default export the same way) — only the encryption-at-rest and purge-on-disable
  properties are actually at stake here, not export. (b) Building a second sensitive-DB-backed
  `MeasurementRepository`/`IngestionPipeline`/`HealthKitAdapter` stack — mirroring how
  cycle/pregnancy/lab reach `badan_sensitive.db` — is a materially larger change than "widen a
  metric the same way every other one was widened": those three domains are manually-entered/
  OCR'd and never touch `IngestionPipeline` at all, so there is no existing precedent for routing
  a *platform-written* sensitive-plus metric's generic, heterogeneous-batch ingestion path to a
  second connection, and doing it hastily risks the reconciliation-v2/export/timeline call sites
  that already read `body.glucose` out of `badan.db`. That is a real cost, but it is a cost to be
  weighed by the founder, not assumed away by the session that benefits from the cheaper path.
  **Resolved (Founder, 2026-07-24):** accept the gap for now, revisit later. No glucose-facing
  module or user toggle exists yet, so nothing today makes purge-on-disable urgent; the migration
  to a second sensitive-DB-backed path is deferred rather than rushed. `body.glucose` stays in
  `badan.db` (unencrypted, not covered by `purgeSensitiveNamespace()`) until this is revisited —
  explicitly a deferral, not a reclassification: the registry's `sensitiveClass: sensitivePlus`
  tag is unchanged, and export gating already treats it as sensitive regardless of physical DB.
  Revisit when glucose ships as a real user-facing feature, or opportunistically alongside a
  future sensitive-DB migration already in flight.
- **CLOSED (2026-07-27, delegated):** `body.glucose` now lives in `badan_sensitive.db`. Done under
  the founder's explicit standing delegation for this session ("build everything ... I delegate
  decisions"), and squarely within the deferral's own stated revisit condition above — this was the
  "opportunistically, alongside other work" case, not a reversal of it.
  **What shipped:** sensitive migration 9 mirrors `raw_samples`/`interval_records` into the
  sensitive file (byte-identical DDL, the same deliberate-duplication precedent the sensitive
  `baselines` table set for CYCLE-06); `MeasurementRouting` holds the placement rule in exactly one
  place and derives it from the registry's own `sensitiveClass`, so no metric id is hardcoded and a
  future sensitive-plus measured metric routes correctly with no code change;
  `MeasurementRepository` gained an optional second connection and routes every read and write
  through that rule, which is why no call site outside it changed; `SensitiveMeasurementRelocator`
  moves an existing install's already-ingested glucose out of `badan.db` at startup, idempotently.
  **Both consequences the gap left open are now closed and tested**: glucose is SQLCipher-encrypted
  at rest like every other sensitive-plus record, and "erase sensitive records" actually erases it
  (`SensitiveMeasurementRoutingTests.testPurgingSensitiveRecordsActuallyRemovesGlucose`, which
  reads the physical files rather than asking the routing layer where it put things).
  **Cost paid rather than assumed away:** the second-stack concern in (b) above turned out to be
  avoidable — routing inside the single existing repository, instead of building a parallel
  `IngestionPipeline`/`HealthKitAdapter`, left the reconciliation-v2, export, and timeline call
  sites untouched. What is genuinely new and worth knowing: `MeasurementRepository.transaction`
  now brackets both files, and two separate SQLite files cannot two-phase-commit, so a process kill
  between the two commits can leave the halves disagreeing. Every write there is an idempotent
  upsert keyed by provenance identity, so a re-ingest restores agreement; the limit is documented
  at the method rather than papered over.

## D-27 — Watch app accelerated to Phase 4 (ADR-0010, approval A22)
- **Context:** A22 asked whether the watch app stays Phase 5 or accelerates.
- **Choice:** Accelerate to Phase 4 (EPIC-42 extension), per the plan's recommendation. The
  founder holds a physical Apple Watch Series 10 for on-device verification — this build
  environment has no paired Watch, so physical testing is a founder-owned step, the same
  pattern as the TestFlight upload boundary.
- **Rationale:** Three consumers (workout fidelity, complications, live surfaces) justify
  moving it earlier than v1.0's plan assumed.
- **Migration impact:** New watchOS target; phone-first live workout (Phase 3C slice 2)
  stays the honest-degradation fallback for users without the watch app.
- **Supersession:** revises v1.0's Phase-5 watch placement, per the plan's own v1.1
  amendment.
- **Approval:** accepted — Founder, per ADR-0010 (2026-07-23).

## D-28 — Ambient copy governance package approved as specced (ADR-0010, approval A24)
- **Context:** A24 covered One True Sentence tone, band labels, privacy defaults, and
  hydration/reminder wording as one package; Phase 3D's build flagged this copy pending
  founder sign-off.
- **Choice:** "Lightly interpretive within the wellness-safe register," all band
  thresholds/labels and privacy defaults, approved as one package — the plan's own
  recommendation, unchanged.
- **Rationale:** One decision covers the whole ambient + reminder copy surface rather than
  piecemeal review per widget.
- **Migration impact:** Unblocks the copy flagged since Phase 3D (EPIC-33/44) and any
  remaining ambient surfaces built after it.
- **Supersession:** none.
- **Approval:** accepted — Founder, per ADR-0010 (2026-07-23).

## D-29 — Daily notification budget becomes a user preference (1–4, default 3)
- **Context:** EPIC-32 shipped the non-med budget as a fixed `dailyNonMedLimit = 2`, described in
  three places in the code as "a hard invariant, not a preference". Adding producers for the
  wake summary, adaptive bedtime and goals meant more than two classes competing for it.
- **Choice:** `NotificationPreference.dailyNonMedLimit`, clamped 1…4, default 3.
- **Rationale:** A fixed 2 stopped being an anti-fatigue measure once there were more than two
  classes to spend it on. With the morning and evening anchors both on, every other class the
  user explicitly opted into was starved permanently and silently — a 2 ceiling made BADAN a
  two-class product regardless of what the user turned on. The anti-fatigue guarantee is now
  carried by the clamp plus `NotificationClass.priority` (so the ceiling is never merely
  first-come) rather than by the number being immovable.
- **Migration impact:** None to storage — the field decodes to 3 on any profile that predates it,
  and is clamped on decode as well as on assignment. Android still holds
  `DAILY_NON_MED_LIMIT = 2`; re-mirroring is the Android lane's work when it resumes.
- **Supersession:** **reverses** EPIC-32's "budget is a hard invariant, not a preference". The
  doc-comments asserting that were corrected in the same change rather than left contradicting
  the code.
- **Approval:** accepted — Founder, 2026-07-28.

## D-30 — Readings on the lock screen are an explicit opt-in, default off
- **Context:** Every notification body was deliberately value-free, so a notification carried no
  information on its own. Users asked for the numbers; the numbers are legible to anyone holding
  a locked phone.
- **Choice:** `NotificationPreference.showValuesInNotifications`, offered once during onboarding
  and changeable in Settings. Off unless explicitly turned on; skipping the onboarding step
  leaves it off.
- **Rationale:** Silence on a privacy question is read as "no", never as consent. The value-free
  copy remains byte-identical for everyone who has not opted in — structurally, via a separate
  `valueFreeContent`, not by keeping two wordings in step by hand.
- **Migration impact:** None; decodes to `false` on any older profile. Note the constraint this
  exposes: pre-scheduled notifications are composed hours before they fire, so they stay
  value-free even for an opted-in user. Values appear only on paths that compose at delivery.
- **Supersession:** none — narrows nothing, adds an opt-in.
- **Approval:** accepted — Founder, 2026-07-28.

## D-31 — `goalReached` ships; `goalAtRisk` deliberately does not
- **Context:** The goals notification work proposed both a reached notice and an at-risk one that
  would fire late in the day while a goal was still attainable.
- **Choice:** `goalReached` only. No at-risk class, no streaks, no badges, no congratulation.
- **Rationale:** `GoalEvaluation`'s own doc states the rule — "There is no scoring, no streak and
  no judgement here by design: BADAN describes, it doesn't grade" — and `CLAUDE.md` forbids
  prescriptive framing. Reaching a goal is a fact that occurred and can be stated flatly. Telling
  someone they are behind with hours left is a verdict on their day and a prompt to act on it,
  which is the shape of thing that guardrail exists to keep out however gently it is worded.
- **Migration impact:** `notification_deliveries.notification_class` is bare `TEXT` with no CHECK
  (migration v8), so the new code is additive and needs no migration.
- **Supersession:** none. A test pins the absence, so "we decided not to" survives a future change
  that looks obviously useful.
- **Approval:** accepted — Founder, 2026-07-28.

---

## Doc map cross-link

`CLAUDE.md` now carries both a **Repo layout** section naming `docs/adr/` and `docs/DECISIONS.md`,
and a **Decision log** section stating the rule this file exists to serve: architecture changes go
to `docs/adr/` as a numbered ADR, product and priority calls come here as a `D-nn`, and an accepted
decision is not changed without asking first.

(This paragraph previously said `CLAUDE.md` had no doc map and covered "only Working mode / Product
guardrails / Development priorities". That stopped being true when those sections were added.)

Still worth cross-linking from `CLAUDE.md` if its layout block ever expands:
`packages/contracts/INVARIANTS.md` and `docs/MONETIZATION.md`, neither of which it names today.
