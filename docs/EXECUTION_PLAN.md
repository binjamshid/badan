# BADAN Execution Plan

**Status:** v1.1 — 2026-07-10. Supersedes v1.0 (archived at `docs/archive/EXECUTION_PLAN_v1.0.md`; changelog in Appendix B).
**Inputs:** `BADAN_MASTER_BLUEPRINT.md` (v2.0, execution-grade reference at repo root), `docs/BADAN_MASTER_BLUEPRINT_OLD_DONT_USE.md` (v1, historical), `docs/PRD.md` v0.1, `CLAUDE.md`, `docs/architecture-decision.md`, `docs/native-implementation-plan.md`, `docs/project_description.md`, all `packages/` seeds, both app scaffolds.
**Audience:** engineers and coding agents. This document says what to build first, in what order, with what interfaces. It does not restate product strategy.

**Reconciliation notes (ambiguities resolved, not hidden):**

1. **Blueprint file naming.** The root `BADAN_MASTER_BLUEPRINT.md` *is* v2.0 (the execution reference). The old v1 product blueprint is `docs/BADAN_MASTER_BLUEPRINT_OLD_DONT_USE.md`. Blueprint §-references below are to the root v2 file.
2. **KMP vs native-first.** Blueprint v2 §33/§47/§52 assume a KMP shared core (SQLDelight, `core-db`, commonMain paths). `CLAUDE.md` + `docs/architecture-decision.md` + repo reality say native-first with contracts-level sharing. **Native-first governs.** Blueprint v2's subsystem *specs* (DDL shapes, dedup rules, port interfaces, pipeline stages) remain authoritative as specifications; its KMP module paths are translated here to `packages/` (specs) + per-platform native implementations (raw SQLite on iOS, framework SQLite on Android — ADR-0005/ADR-0007). A KMP re-evaluation gate runs at M4 (§2, D-4).
3. **Entity naming.** Canonical names follow the blueprint (`RawSample`, `IntervalRecord`, `Session`, `EventRecord`, `DerivedValue`, `Baseline`, `ExportJob`); the seed names in `packages/contracts/src/health_contracts.md` (`NormalizedMeasurement`, `DerivedMetric`, `UserLogEntry`, `ExportBundle`) are superseded (rename map in §3).
4. **`apps/flutter`** is referenced in `docs/scaffold-notes.md` but does not exist. The Flutter path is closed (§12 amends the note).
5. **Tab IA.** Both apps now ship the full 5-tab IA (Today, Body, Log, Insights, Settings) — the blueprint's 5 destinations — superseding the earlier 4-tab MVP-deferral plan; the `Metrics` → `Body` rename (§12) has also landed.

**Scope rule for everything below:** nothing gets built that vertical slices VS-1…VS-5 (§7) do not exercise. Schema-level reservations for sync, imports, and derived-value versioning are the only forward payments allowed. Explicitly deferred: sync service, AI/insight engine, vendor/broker integrations, watch/widgets, notifications, Coach surface, labs/biology, cycle engine.

---

## 1. Build strategy

| Question | Decision | Rationale |
|---|---|---|
| Domain-first vs UI-first | **Domain-first, with buildable shells immediately.** Contracts + storage + ingestion precede feature UI; but neither app compiles today, so project bootstrap (build systems) runs in parallel with contract authoring, not after it. | Every BADAN differentiator (provenance, export, dual-altitude) is a data-layer property. UI built before the canonical model would be rebuilt. |
| Local persistence before cloud | **Yes — MVP ships with zero backend.** Device SQLite is the source of truth. No accounts, no remote analytics, no network calls anywhere in MVP. `backend/` and `infra/` stay dormant with READMEs saying so. | Local-first is the strongest proof of the privacy posture and deletes an entire risk class (auth, hosting, compliance). |
| Export in phase 1 | **Yes.** Export is the *second* vertical slice (VS-2), not a settings-page afterthought. CSV + JSON + manifest, fully offline. | "Raw data is not paywalled" and "exports are a core promise" are product law; an export path designed late always leaks internal schema. |
| Analytics timing | **Derived analytics:** baseline-lite (14-day rolling median/MAD) lands in M4 (VS-4) — the *minimum* derivation that proves the append-only DerivedValue pipeline and explainability UI. Full scoring/insight engines wait for the M4 KMP gate. **Product telemetry:** none in MVP; local debug logging only; vendor decision is an M4 agenda item. | Derivation infrastructure must exist before any engine; engines are the most expensive thing to build twice, so they wait for the sharing decision. |
| AI timing | **No LLM, no AI, in MVP.** The `Insight` entity ships (VS-4's "why" sheet is a template-rendered proto-insight, en+ar) so the schema is proven, but generation is deterministic templates. AI enters only after repository, storage, ingestion, and baselines are credible — post-M4. | AI on top of an unproven repository amplifies wrong data. Templates prove the explainability contract at zero model risk. |
| Platform sequencing | **iOS and Android in lockstep from M2, neither leads.** Mirrored work packets (§11); shared conformance fixtures are the synchronization mechanism — a behavior exists only when both platforms pass its fixture. | Android parity is structural, not optional (CLAUDE.md). A "port later" plan always produces a second-class Android app. |
| "Done enough to learn" | A slice is done when: (a) its conformance fixtures pass **identically on both platforms**, (b) the demo script runs on **physical devices** (iPhone + Pixel), (c) AR/RTL snapshots pass for its screens, (d) power mode reveals provenance for every datum it shows. Not: pixel-perfect visuals, full metric coverage, performance tuning. | The MVP question is "does the architecture hold end-to-end," answered per slice, on devices, in both languages. |

---

## 2. Architecture decisions to lock now

Frozen as of M1 (each gets an ADR in `docs/adr/`; changes after freeze require an ADR + codegen + fixture update in one PR):

- **D-1 · Canonical entity shape.** Blueprint-named entities (§3), ULID ids minted on-device, ISO-8601 UTC instants plus IANA `tzId` on every measurement-describing timestamp, closed `EventRecord` union with versioned typed payloads.
- **D-2 · Raw vs derived separation.** Raw/normalized records are facts; `DerivedValue` rows are append-only interpretations carrying `algorithmId+version` and an `InputManifest`. Recompute appends and supersedes; it never overwrites. Raw and derived are separable in every query and every export.
- **D-3 · Provenance is embedded, denormalized structure.** Every health datum carries provenance as columns on its own row (source, device, ingestion path, external id, batch id, measured/recorded/ingested timestamps, quality flags, `suppressed_by`) — never a join, never optional (blueprint §52.2 pattern).
- **D-4 · Shared core = specifications, not runtime.** All shared definitions live as JSON Schema/YAML in `packages/`; `scripts/gen_types.py` emits Swift `Codable` + Kotlin `@Serializable` into checked-in `Generated/` dirs; hand-editing generated files is CI-rejected. Both platforms pass identical fixtures in `packages/fixtures/`. Duplicated-logic budget: unit conversion, timezone/day-attribution, dedup-lite, baseline-lite, export serialization — nothing heavier until the **M4 KMP gate** (adopt KMP for core if: ≥3 fixture-divergence incidents from duplicated logic, or duplicated domain code >~2k LOC/platform, or team confirms toolchain comfort; else stay native, re-check each milestone).
- **D-5 · Native UI boundaries.** `Features/` depend on state models/repositories only — never on health adapters or the DB directly. Dual-altitude is a presentation switch (`CustomizationProfile.depthPolicy`) over identical queries; fixtures assert both policies render the same values.
- **D-6 · Backend minimum footprint = zero** (see §1). First backend work item is sync or first vendor integration, whichever is scheduled first, and not before M4 review.
- **D-7 · Sync-ready, not sync-dependent.** Every table carries ULID PK, `updated_at`, `origin_device_id`, `deleted_at` tombstone from day 1; a reserved `sync_cursors` table exists unused. No sync service, no oplog, no conflict resolution in MVP. All writes are synchronous-local; no write path may require network.
- **D-8 · Export contract philosophy.** Versioned published schema (`packages/export-schemas/`), manifest with schemaVersion/counts/checksums/dedup-policy note, generated data dictionary, raw vs derived vs suppressed all explicitly separable in output. Export code path has no networking or entitlement imports — lint-enforced. Internal refactors never break the published dictionary (decoupled column-mapping layer).
- **D-9 · Sensitive-plus namespace.** Meds, symptoms, conditions (cycle later) live in a **second SQLite file** (`badan_sensitive.db`) so module-disable purge = file deletion. MVP relies on OS file-level encryption (iOS Data Protection complete-until-first-unlock class; Android FBE); SQLCipher adoption is an explicit M4 decision item (needed before sync/export-passphrase work), not silently assumed — this is a deliberate simplification of blueprint §52.4, flagged honestly.
- **D-10 · Privacy enforcement is mechanical.** Analytics event taxonomy is an allowlist (`packages/contracts/analytics/events.yaml`); lints reject health-value literals in log/analytics call sites; export module import-graph checked in CI.
- **D-11 · Wellness-safe language + AR/RTL are merge gates.** User-facing string lint (no diagnosis/treatment phrasing); every shipped screen has en+ar strings and AR snapshot tests from M2 onward, not retrofitted at M4.

---

## 3. Domain model starting set

Rename map from seed contracts: `NormalizedMeasurement→IntervalRecord`, `DerivedMetric→DerivedValue`, `UserLogEntry→EventRecord` payloads, `ExportBundle→ExportJob`. One JSON Schema per entity in `packages/contracts/entities/<snake_case>.schema.json`; shared conventions (ULID, timestamps, tombstones, `sensitiveClass`) in `entities/_conventions.md`.

**Invariants (`packages/contracts/INVARIANTS.md` — the constitution):**
I1 every stored health datum carries full Provenance · I2 derived values append, never overwrite · I3 dedup suppresses, never deletes (`suppressedBy` pointer) · I4 manual wins over device for weight/BP/labs, device wins elsewhere by source priority · I5 raw and derived separable in every query/export · I6 no entity references entitlement state · I7 sensitive-plus entities live in the separate namespace with independent purge · I8 all ids are ULIDs minted on-device.

### 3.1 Reference & identity
- **MetricDefinition** — compiled from `packages/metric-ontology/`: `metricId` (dot-namespaced, e.g. `sleep.time_asleep`), `family`, `kind` (`rawSample|intervalAggregate|session|event|derived`), `canonicalUnit`, `displayUnits[]`, `displayNames` (en+ar), `casualLabel`/`preciseLabel`, `chartHint`, `baselineEligible`, `sensitiveClass`. Apps never hardcode metric-id strings outside generated constants.
- **Source** — `sourceId`, `type` (`healthkit|healthConnect|manual|import|vendor(reserved)`), `displayName`, `platformBundleId?`, `status` (`active|revoked|hidden`), plus per-metric `source_priority` overrides. Hidden ≠ deleted.
- **Device** — `deviceId`, `name`, `model`, `firstSeen/lastSeen`, `sourceId`.
- **PermissionState** — per platform data type: `platformType`, `status` (`notRequested|granted|denied|partial|revoked`), `lastCheckedAt`, `lastReadAt?`. Drives denied-state UI and consent-screen honesty.

### 3.2 Provenance (embedded struct)
`sourceId`, `deviceId?`, `ingestionPath` (`platformStore|manual|import|derived`), `platformRecordId?` (idempotency key), `importBatchId?`, `measuredAt`+`measuredTimezone`, `recordedAt`, `ingestedAt`, `algorithmVersionId?`, `qualityFlags[]` (`gapFilled|artifactSuspected|userCorrected|provisionalBaseline|estimate|tzAssumed`), `suppressedBy?`. `(platformRecordId, sourceId)` unique when present → idempotent re-ingest.

### 3.3 Measurements
- **RawSample** — instant/short-interval readings kept for lineage and the power explorer: `metricId`, `value` + `unit` as received, `canonicalValue` (SI), `startAt/endAt`, provenance. MVP keeps all raw; decimation tiers (blueprint §52.6) are a post-MVP knob.
- **IntervalRecord** — normalized aggregates treated as canonical facts (daily steps, nightly time-asleep): RawSample fields + `aggregation` (`sum|mean|min|max|duration|latest`), `coverage` (0–1), `sourceRollup[]`. Default read layer for charts.
- **Session** *(new in v1.1 — required by VS-1)* — sleep/workout episodes: `kind` (`sleepPrimary|sleepNap|workout`), `subtype?`, `startAt/endAt/tzId`, `localNight` (`YYYY-MM-DD` sleep attribution — the "last night" query key), `detail` (typed JSON: merged-from refs, stage summary), provenance. **SessionStage** — `(sessionId, seq)`, `stage`, `startAt/endAt`.
- **EventRecord** — closed union via `eventType` + versioned typed `payload` (each payload its own schema): `mealEntry`, `symptomEntry`, `adherenceEvent`, `workoutEntry` (manual quick-add summary), `measurementEntry` (manual weight/BP), `note`; `statusInterval` reserved. Common: `occurredAt/tzId`, `endAt?`, provenance, `tags[]`, `editedAt?/editAudit?`.

### 3.4 Derivation
- **AlgorithmVersion** — `algorithmId` (`baseline.rolling_median`), `semver`, `params` (frozen JSON), `introducedIn`. Registry file in contracts.
- **DerivedValue** — `metricId`, `value`, `periodKey` (`day:2026-07-10` | `session:<ulid>` | `week:2026-W28`), `algorithmVersionId`, `inputManifestId`, provenance (`ingestionPath=derived`), append-only with latest-read semantics. **InputManifest** — `[{recordId, metricId, weight?, window?}]` — renders the anatomy sheet.
- **Baseline** — materialized personal-normal band: `metricId`, `covariateContext` (MVP always `"default"`; reserved key so cycle/status conditioning is additive later), `windowDays` (14), `method` (`medianMAD`), `center/spread`, `bandLow/bandHigh`, `nPoints`, `provisional` (until `nPoints ≥ 7`), `algorithmVersionId`, `validFrom/computedAt`.

### 3.5 Interpretation (MVP-minimal)
- **Insight** — `insightType` (`statusExplanation` only), `metricIds[]`, `evidenceRefs` (derived-value + record ids), `renderedText` (en+ar), `depthVariant` (`casual|power`), `generatedAt`, `algorithmVersionId`, `feedback?`. Template-rendered; the entity exists so the schema is proven before any engine.

### 3.6 Ownership & portability
- **ExportJob** — `scope` (metricIds/families, dateRange, sources, `includeRaw/includeDerived/includeSuppressed`, `includeSensitive`, unitProfile, language), `format` (`csv|json`), `status`, `manifest` (schemaVersion, appVersion, per-metric counts, dedup-policy note, checksums), `outputUri?`. Runs offline; never references entitlement (I6).
- **ImportBatch** — reserved (Provenance references it): `sourceDescription`, `fileHash`, `recordCounts`, `status`, `chunkCursor`, `undoableUntil`. Batch undo = tombstone by `importBatchId`.
- **SyncCursor** — reserved, unused: `scopeKey`, `deviceId`, `lamport`, `lastSyncedAt?`.
- **ReconciliationDecision** — the dedup journal: `winnerId`, `loserId?`, `ruleId` (`sleep.session_overlap.v1`), `ruleVersion`, `score?`, `decidedAt`, `reversible`, `reversedAt?`, `detail` (JSON: thresholds, overlap %). Powers the power-mode lineage sheet; reversal clears `suppressed_by` and journals a compensating row.

### 3.7 Logging domain (all `sensitiveClass=sensitivePlus` except workout/nutrition)
- **MedicationRegimen** — `name` (free text MVP), `strength?`, `form?`, `schedule` (structured: `asNeeded | daily(times[]) | weekly(days[], times[])`), `startedAt/endedAt?`, `notes?`. No dosing advice anywhere near this entity.
- **AdherenceEvent** — `regimenId`, `kind` (`taken|skipped|late`), `scheduledFor?`, `occurredAt`, `skipReason?` (enum + free text). Skip-with-reason is a first-class equal of taken — non-punitive by design.
- **SymptomEntry** — `symptomId` (canonical ~50-entry localized dictionary in ontology) or `customLabel`, `severity` (1–10), `occurredAt`, `duration?`, `bodyLocation?`, `triggers[]`, `note?`.
- **WorkoutEntry** — imported session summaries + manual quick-add: `activityType`, `startAt/endAt`, `duration`, `energyKcal?`, `distanceM?`, `avgHr?/maxHr?`, `perceivedEffort?`. Strength set/rep detail post-MVP (`workout.strength.*` namespace reserved).
- **NutritionEntry** — manual quick-log: `description`, `mealType`, `energyKcal?`, `macros?`, `occurredAt`; forward-compatible `foodItemRefs[]` for database/barcode/AI later.
- **Condition** — user-declared only (BADAN never infers): `label`, `status` (`active|resolved|episodic`), `onsetAt?`, linked regimen/symptom/metric ids, `notes`.

### 3.8 Presentation
- **CustomizationProfile** — singleton in MVP: `depthPolicy` (`casual|balanced|power`), `perSurfaceOverrides`, `homeModules[]` (ordered + visibility), `unitOverrides`, `language` (`en|ar`), `theme`. This *is* the dual-altitude mechanism.

---

## 4. Storage and schema starting set

One **logical schema**, specified in `docs/data-model.md` + per-platform DDL: raw SQLite (iOS) and framework SQLite (Android) — ADR-0005/ADR-0007 — same table/column names, snake_case. Adapted from blueprint §52.2 to MVP scope (no FTS, no aggregates tier, no oplog yet). Column types: `TEXT` ULIDs, `INTEGER` epoch-millis UTC, `TEXT` IANA tz ids, `TEXT` JSON for closed payloads. Sync-ready columns on **every** row table: `updated_at`, `origin_device_id`, `deleted_at` (tombstone).

### 4.1 Main DB `badan.db` — tables v1

| Table | Key columns beyond conventions | Indexes |
|---|---|---|
| `sources` | kind, display_name, platform_bundle_id, status, connected_at, last_delivery_at, hidden | — |
| `source_devices` | source_id FK, name, model, first_seen, last_seen | — |
| `source_priorities` | (metric_id, source_id) PK, rank | PK |
| `permission_states` | (store, platform_type) PK, status, last_checked_at, last_read_at | PK |
| `raw_samples` | metric_id, value, original_value, original_unit, measured_at, recorded_at, tz_id, + provenance cols (source_id, device_id, ingestion_path, external_id, batch_id, quality_flags, suppressed_by) | `(metric_id, measured_at)` workhorse; partial unique `(metric_id, external_id, source_id) WHERE external_id IS NOT NULL` → idempotent re-sync; `(batch_id)` → batch undo |
| `interval_records` | metric_id, start_at, end_at, tz_id, value, aggregation, coverage, + provenance cols | `(metric_id, start_at, end_at)` |
| `sessions` | kind, subtype, start_at, end_at, tz_id, local_night, detail JSON, + provenance cols | `(kind, start_at)`; partial `(local_night) WHERE kind LIKE 'sleep%'` → "last night" |
| `session_stages` | (session_id, seq) PK, stage, start_at, end_at | PK |
| `event_records` | event_type, payload_schema_version, payload JSON, occurred_at, recorded_at, tz_id, edited_at, edit_audit JSON, + provenance cols | `(event_type, occurred_at)`; `(occurred_at)` → timeline |
| `derived_values` | metric_id, period_key, value, confidence, provisional, algorithm_id, algorithm_version, computed_at, input_manifest_id | `(metric_id, period_key, computed_at DESC)` → latest-read |
| `input_manifests` | inputs JSON | — |
| `baselines` | metric_id, covariate_context, window_days, center, spread, band_low, band_high, n_points, provisional, algorithm_version, valid_from, computed_at | unique `(metric_id, covariate_context, window_days, valid_from)` |
| `insights` | insight_type, template_version, period_key, depth_variant, rendered_text, locale, evidence_refs JSON, generated_at, feedback | `(insight_type, generated_at)` |
| `dedup_decisions` | batch_id, rule, rule_version, kept_record_id, suppressed_record_id, score, reversible, reversed_at, decided_at, detail JSON | `(suppressed_record_id)` → lineage sheet |
| `export_jobs` | scope JSON, format, status, manifest JSON, output_uri, started_at, finished_at | — |
| `import_batches` *(reserved)* | source_kind, file_name, state, chunk_cursor, counts JSON | — |
| `sync_cursors` *(reserved)* | scope_key, device_id, lamport, last_synced_at | — |
| `customization_profile` | singleton row: depth_policy, per_surface_overrides JSON, home_modules JSON, unit_overrides JSON, language, theme | — |
| `read_anchors` | (store, platform_type) PK, anchor BLOB, updated_at — HK anchors / HC changes tokens | PK |

### 4.2 Sensitive DB `badan_sensitive.db` — tables v1

`medication_regimens`, `adherence_events` (`(regimen_id, acted_at)` index), `symptom_entries` (`(occurred_at)` index), `conditions`, `condition_links`. Same conventions and provenance columns. Purge-on-disable = close, delete file, recreate empty. Export includes this namespace only when `includeSensitive` is explicitly on.

### 4.3 Policies

- **IDs:** ULID everywhere, minted on-device (offline-generatable, time-sortable — index-friendly and sync-safe later). One shared ULID implementation per platform, fixture-tested for canonical encoding.
- **Migrations:** forward-only, numbered (`001_init.sql` …); no down-migrations ever. From the first schema change onward: frozen fixture DB per released version, K→N migration matrix in CI. Long data migrations run as resumable post-migration jobs, never inside DDL. Both platforms run the same numbered migration SQL verbatim through their thin `SqliteConnection`/`SQLiteConnection` wrappers; migrations are snapshot-tested against a frozen fixture DB per released version.
- **Query discipline:** every repository query names its index; `EXPLAIN QUERY PLAN` snapshot tests fail CI on full-table scans over `raw_samples`, `event_records`, `sessions`.
- **Dedup hooks:** the partial unique identity index (upsert-on-re-sync), `suppressed_by` on every record table (suppress, never delete), `dedup_decisions` journal with reversal semantics.
- **Audit/history:** derived values append-only (I2); `event_records.edit_audit` JSON trail for user edits; tombstones instead of hard deletes except user-initiated purge flows.
- **Aggregates/decimation/FTS:** deliberately absent from v1; MVP data volumes (2 metric families + logs) don't need them. `agg_daily` is the first post-MVP storage addition when charts exceed budget.

---

## 5. Integration layer starting set

All ports are specified in `packages/contracts/ports/` (interface shape + DTO JSON Schemas + mapping tables) and implemented natively in `apps/*/…/Platform/`. Every port method returns a typed result (`Ok | Denied(kind) | StoreUnavailable(state) | TransientFailure(retryAfter) | PermanentFailure(code)`) — error policy is type-driven, not exception-driven (blueprint §51.1).

- **HealthStorePort** (MVP subset of blueprint §51.1): `availability()` (Available | UpdateRequired | NotInstalled | Unsupported — HC needs this, HK returns Available/Unsupported), `capabilities()`, `permissionState(types)`, `requestPermissions(bundle)`, `readSamples(type, range, anchor?) → (page, anchor)`, `readSessions(kind, range, anchor?)`, `observeChanges(types)` (foreground only in MVP), `historicalWindow(type)` (HK: full history; HC: 30-day default → drives backfill honesty in UI). **Deferred:** `enableBackgroundDelivery`, `writeRecords`, `deleteOwnRecords`.
  - **iOS `HealthKitAdapter`** — `apps/ios/Sources/Platform/Health/`: HKAnchoredObjectQuery reads, anchors persisted to `read_anchors`; MVP types: sleepAnalysis, heartRate, restingHeartRate, stepCount.
  - **Android `HealthConnectAdapter`** — `apps/android/…/platform/health/`: HC client with availability states surfaced as typed results, changes-token persistence; mirrored types (SleepSessionRecord, HeartRateRecord, RestingHeartRateRecord, StepsRecord).
  - Both ship with a **FakeHealthStore** driven by recorded DTO fixtures — the conformance-kit substrate and the simulator/demo data source.
- **DTO→canonical mapping tables** live beside the port contract (`HkTypeMap`, `HcTypeMap` as YAML) and are fixture-tested per platform. Unmapped types are counted and retained in an ingest log, never errors.
- **PermissionsController** (per platform, thin): staged permission bundles (ask for what the current screen needs, not everything), persists `permission_states`, renders the granted/denied/partial matrix honestly. Permission denial is a first-class UI state, not an error.
- **ArchiveImporter** — **interface reserved, no implementation in MVP**: `probe(file) → ImportPlan`, `parse(file, plan) → chunk stream`, `resume(batchId)`. Contract file only, because `ImportBatch` and `Provenance.importBatchId` already reference the concept. First implementations (Apple Health ZIP, generic CSV) are post-MVP.
- **VendorApiAdapter / brokers** — not stubbed at all. Reserved: `Source.type=vendor` enum value and the `ingestion_path=vendor` string. Anything more is dead code until a backend exists.
- **FileExportPort** — `ExportRunner` (builds ExportJob output: CSV writer per `csv_columns.yaml`, JSON bundle writer, manifest with checksums) + platform delivery (`UIActivityViewController` / `ACTION_SEND` share sheet). Writes to app sandbox, hands off to OS. No networking imports — lint-enforced.
- **Notifications** — nothing in MVP, not even a stub (med reminders are the first post-MVP consumer; premature stubs invite scope creep against the non-punitive-logging rule).
- **Widgets/watch** — no stubs. One design constraint honored now: repositories expose snapshot-friendly read APIs (plain value types, no live DB handles) so widget/watch processes can consume pre-rendered snapshots later without repository surgery.

---

## 6. First file/module creation sequence

Ordered to minimize rework and prove architecture earliest. (Wave 0 first — nothing is verifiable without version control and CI.)

**Wave 0 — repo becomes a repo (AP-01)**
1. `.gitignore` (Xcode + Gradle + Python + .DS_Store) → `git init` → **initial commit of the untouched scaffold** (preserves scaffold provenance) → second commit adds the rest of this wave
2. `LICENSE` (proprietary placeholder; OSS posture decided later per blueprint §43)
3. `docs/adr/ADR-0001-native-first-contracts-shared.md` (D-4 incl. KMP gate), `ADR-0002-no-backend-mvp.md` (D-6), `ADR-0003-sync-ready-not-sync-dependent.md` (D-7), `ADR-0004-sensitive-namespace-and-encryption.md` (D-9)
4. `.github/workflows/ci.yml` — starts with schema-validation + codegen-drift jobs; grows per milestone
5. `backend/README.md`, `infra/README.md` dormancy notes; delete `scripts/tree.txt`

**Wave 1 — contracts before code (AP-02, AP-03, AP-04)**
6. `packages/contracts/entities/_conventions.md`
7. `packages/contracts/entities/provenance.schema.json` — first; everything embeds it
8. `packages/contracts/entities/{metric_definition,source,device,permission_state}.schema.json`
9. `packages/contracts/entities/{raw_sample,interval_record,session,session_stage,event_record}.schema.json` + `payloads/{meal_entry,symptom_entry,adherence_event,workout_entry,measurement_entry,note}.schema.json`
10. `packages/contracts/entities/{algorithm_version,derived_value,input_manifest,baseline,insight}.schema.json`
11. `packages/contracts/entities/{export_job,import_batch,sync_cursor,reconciliation_decision,medication_regimen,condition,customization_profile}.schema.json`
12. `packages/contracts/INVARIANTS.md` (I1–I8 + rename map)
13. `packages/metric-ontology/registry.schema.json` + `families/{sleep,heart,activity,body,nutrition,symptoms,medications,subjective}.yaml` (~40 MVP metric ids, en+ar names, casual/precise labels, chart hints)
14. `packages/contracts/ports/health_store_port.md` + `ports/dto/{raw_sample_dto,session_dto,capability,permission}.schema.json` + `ports/typemaps/{hk_typemap,hc_typemap}.yaml`
15. `packages/contracts/analytics/events.yaml` (~12 events, property allowlist — enforcement point for D-10)
16. `scripts/gen_types.py` + `scripts/gen_types_test.py` (JSON Schema/YAML → deterministic Swift + Kotlin, "GENERATED — do not edit" headers)
17. `packages/export-schemas/csv_columns.yaml` + `manifest.schema.json` + generated `DATA_DICTIONARY.md` skeleton
18. `packages/fixtures/ingestion/{sleep_two_sources.json,hr_day.json,steps_phone_watch_overlap.json,dst_night.json}` + `expected/` canonical rows + `expected_export/` CSV/JSON goldens + authoring README

**Wave 2 — apps become buildable (AP-05 ∥ AP-06)**
19. iOS: `apps/ios/project.yml` (XcodeGen; app + unit-test + conformance-test targets); no external DB dependency (raw SQLite, ADR-0005)
20. iOS: `Sources/Generated/` (codegen output), `Sources/Domain/` (thin extensions over generated types)
21. iOS: `Sources/Storage/Database.swift` (raw SQLite via `SQLiteConnection`, migration 001 = §4 DDL, both DB files), `Storage/Repositories/{SampleRepository,SessionRepository,EventRepository,BaselineRepository,ExportJobRepository,ProfileRepository}.swift`
22. Android: `settings.gradle.kts`, `build.gradle.kts` (root+app), `gradle/libs.versions.toml`, wrapper, `AndroidManifest.xml`
23. Android: `…/generated/`, `…/domain/`, `storage/{BadanDatabase.kt,SensitiveDatabase.kt}` (framework SQLite via `SqliteConnection`, ADR-0007, same logical DDL as iOS), `storage/repositories/*.kt`
24. Both: `Platform/Health/` adapters (sleep + HR + steps read paths) + `FakeHealthStore` + fixtures wiring
25. Both: conformance test targets (`apps/ios/Tests/ConformanceTests/`, `apps/android/app/src/test/…/conformance/`) reading `packages/fixtures/`

**Wave 3 — pipeline, then features in slice order (AP-09…AP-15)**
26. Both: `Domain/Ingestion/` — normalization (units, tz/day attribution), sleep-overlap dedup-lite + `dedup_decisions` journal, idempotent re-ingest
27. Features per slice order Home → Detail → Export → Logging, each as `Features/<X>/{<X>State,<X>ViewModel,<X>View|Screen}` replacing placeholders
28. `docs/data-model.md` (generated from schemas), `docs/rtl-checklist.md` + AR snapshot harness config

---

## 7. First vertical slices

Each slice is end-to-end, ships on **both** platforms, and proves a named architectural property. Done = fixtures pass identically on both platforms + physical-device demo + AR snapshots green (§1, last row).

**VS-1 · "Last night, truthfully" — proves ingestion, provenance, dedup, storage, dual rendering.**
*Story:* As a user with a watch and phone both recording sleep, I open BADAN and see last night's sleep and resting HR, correct and deduplicated, and can inspect where every number came from.
*Modules:* health adapters, ingestion pipeline, sessions/samples storage, Home + Metric detail features, CustomizationProfile.
*Files:* `Platform/Health/*`, `Domain/Ingestion/*`, `Storage/*`, `Features/Home/*`, `Features/Body/*` (post-rename), fixtures `sleep_two_sources`, `hr_day`, `dst_night`.
*Acceptance:* two-source sleep overlap → priority source wins, loser suppressed with a journaled `ReconciliationDecision` (visible, reversible in power mode); Home card shows time-asleep + one template sentence (en+ar); detail shows 30-day chart + per-day values + per-record lineage row; casual vs power is a `depthPolicy` switch over identical queries (fixture-asserted equal values); re-running ingestion is a no-op.

**VS-2 · "Take it with you" — proves export architecture, raw/derived separation, offline completeness.**
*Story:* As a user, I export my sleep and heart data for a date range as CSV and JSON and share the files, with no network involved.
*Modules:* Export feature, ExportRunner, export-schemas package.
*Files:* `Features/Export/*`, export writers, `packages/export-schemas/*`.
*Acceptance:* CSV per `csv_columns.yaml` incl. provenance columns + `suppressed_by`; JSON bundle + manifest (schemaVersion, per-metric counts, checksums, dedup-policy note); round-trip test re-parses the CSV and diffs against the DB; exported bytes identical across platforms for fixture data; export module has no networking/entitlement imports (lint); works in airplane mode.

**VS-3 · "Log what matters" — proves EventRecord union, sensitive namespace, offline writes, RTL forms.**
*Story:* As a user on a plane, I mark today's medication taken (or skipped, with a reason, without guilt) and log a symptom with severity — in Arabic.
*Modules:* Logging features, sensitive DB, event repositories, VS-2 export extension.
*Files:* `Features/Medications/*`, `Features/Symptoms/*`, `SensitiveDatabase`, symptom dictionary in ontology.
*Acceptance:* regimen CRUD → today's due list → taken/skip-with-reason AdherenceEvents; symptom quick-log (dictionary chips, severity slider); both render in a day timeline; both appear in export only when the sensitive toggle is on; airplane-mode demo mandatory; AR forms + RTL sliders pass snapshots (this slice is the RTL stress case); zero red/guilt states.

**VS-4 · "Why is it saying that?" — proves derivation pipeline, explainability, append-only invariant.**
*Story:* As a user, I see that last night's sleep was below my typical range, and one tap shows me exactly which records and which algorithm produced that judgment.
*Modules:* baseline computation, DerivedValue/InputManifest storage, anatomy sheet UI, Insight templates.
*Files:* `Domain/Derivation/*`, `Features/Body/AnatomySheet*`, baselines/derived repositories.
*Acceptance:* 14-day median/MAD baselines for `sleep.time_asleep` + `heart.rhr`; status chip vs personal band ("below your typical range" — wellness-safe wording, en+ar templates, no LLM); anatomy sheet shows band values, sample count, provisional flag, contributing records (InputManifest), algorithm version string; recompute appends new DerivedValue rows and supersedes (I2 fixture-asserted); provisional flag honest below 7 points.

**VS-5 · "Arabic is not a locale file" — proves i18n is structural.**
*Story:* As an Arabic-speaking user, every shipped screen is fully Arabic, correctly mirrored, with correct chart chrome.
*Modules:* all shipped surfaces; string catalogs; snapshot harness.
*Acceptance:* complete AR strings for VS-1…VS-4 surfaces; RTL audit (mirrored navigation, time axes LTR with mirrored chrome per blueprint chart rules); Arabic-digit preference toggle; `ar` + pseudo-locale snapshot lanes in CI; CI fails on missing AR strings for shipped screens.

---

## 8. Parallel workstreams

| WS | Mission | Owns (exclusive write) | Blocked by | Parallel with |
|---|---|---|---|---|
| WS-A Contracts & codegen | schemas, ontology, export schema, fixtures, `gen_types` | `packages/*`, `scripts/gen_types*` | AP-01 | everything after M1 freeze |
| WS-B iOS platform | project bootstrap, raw SQLite (ADR-0005), HK adapter, repositories | `apps/ios/{project.yml,Sources/{Storage,Platform,Generated}}` | WS-A freeze | WS-C |
| WS-C Android platform | gradle bootstrap, framework SQLite (ADR-0007), HC adapter, repositories | `apps/android/{*.gradle.kts,…/{storage,platform,generated}}` | WS-A freeze | WS-B |
| WS-D iOS features | Home/Detail/Export/Logging screens + state models | `apps/ios/Sources/Features/**` | WS-B repos | WS-E |
| WS-E Android features | same, mirrored | `apps/android/…/features/**` | WS-C repos | WS-D |
| WS-F Export | export engine both platforms + schema tests | `Features/Export/**` both + `packages/export-schemas` (with WS-A review) | WS-A, storage | WS-D/E others |
| WS-G Logging domain | meds/symptoms UX + dictionaries | `Features/{Medications,Symptoms}/**` both | WS-A, storage | WS-F |
| WS-H Design & RTL | tokens, shared components (Card, Chart, StatusChip, StatefulContainer), RTL harness | `DesignSystem/` both platforms | AP-05/06 shells | all feature work |
| WS-I QA & CI | CI growth, conformance runners, device matrix, privacy lints | `.github/`, test targets, `packages/fixtures` (with WS-A) | AP-01 | continuous |
| WS-J Docs & ADR | ADRs, data-model doc, §12 amendments | `docs/` | none | continuous |

**Freeze discipline:** WS-A publishes contracts v0.1 at M1; afterwards contract changes require ADR + regen + fixture update in the same PR. Feature workstreams never edit `packages/` directly. **Collision control:** shared wiring files (`project.yml`, gradle catalogs, string catalogs, DI composition roots) are owned by exactly one packet at a time; features *register* into per-feature files rather than editing shared wiring.

---

## 9. Milestone roadmap

| M | Name | Scope | Depends on | Exit criteria | Explicitly not yet |
|---|---|---|---|---|---|
| M0 (wk 1) | Repo is real | AP-01: git, CI skeleton, ADR-0001…04, dormancy READMEs, §12 doc amendments | — | `git log` exists; CI green on schema-lint job; dormant areas labeled | any app code changes |
| M1 (wk 2–3) | Contracts v0.1 frozen | AP-02/03/04: all §3 schemas, ontology seed, codegen, fixtures | M0 | codegen deterministic (CI drift check); generated Swift passes `swiftc -parse`, Kotlin passes `kotlinc`; fixtures validate; INVARIANTS reviewed; AR metric names human-reviewed | UI work; adapter work beyond DTO shapes |
| M2 (wk 4–6) | VS-1 on devices | AP-05…AP-12: buildable apps, adapters (sleep/HR/steps), storage, ingestion+dedup-lite, Home + detail | M1 | VS-1 demo on physical iPhone + Android; conformance fixtures pass identically both platforms; provenance visible in power mode; AR snapshots for shipped screens | export, logging, baselines, background delivery |
| M3 (wk 7–9) | VS-2 + VS-3 | AP-13/14: export engine, meds/symptoms logging, sensitive DB | M2 | round-trip export test green; cross-platform byte-identical export on fixtures; airplane-mode logging demo; sensitive-class export toggle honored | notifications/reminders; nutrition beyond quick-log |
| M4 (wk 10–12) | VS-4 + VS-5 + gates | baseline-lite, anatomy sheet, full AR pass; **KMP gate review; SQLCipher decision; telemetry decision; IA/tab review; PRD v0.2** | M3 | status chips truthful vs fixtures; AR snapshot suite green; ADR-0005 (KMP outcome) merged; PRD updated | insight engine, sync, vendors, watch/widgets |

Cut-line policy: within a milestone, RTL and fixture coverage never slip; feature scope (e.g., a second metric family) slips first.

---

## 10. Test matrix

| Layer | Tests | Fixtures / mechanism |
|---|---|---|
| Contract/schema | every schema has valid+invalid example instances, CI-validated; codegen output snapshot-tested; deterministic-output drift check | `packages/contracts/examples/` |
| Conformance (the drift firewall) | identical suites both platforms: ingestion payload → expected canonical rows (provenance included) → expected export bytes; divergence = release blocker + KMP-gate data point | `packages/fixtures/{ingestion,expected,expected_export}/` |
| Mapping | HK/HC DTO → canonical mapping tables; unit fidelity round-trip within registry precision; unmapped-type counting | `ports/typemaps/*` + recorded DTO fixtures |
| Domain unit | unit conversion; timezone/day-attribution incl. DST 23/25-hour days and `local_night`; dedup-lite rule incl. reversal; baseline median/MAD golden numerics; injected clock everywhere (no wall-clock in domain code) | `dst_night`, golden numeric files |
| Adapter | conformance-kit subset (blueprint §51.9 items 1,2,4,5,7,8,10): idempotent re-read, anchor continuity across restart, permission downgrade → typed Denied, capability honesty, unit fidelity, timezone battery, dedup handshake; iOS against HK test store where feasible, Android via Robolectric + HC test client; permission matrix granted/denied/partial/revoked | `FakeHealthStore` + recorded fixture packs |
| Storage/migration | DDL v1 soak (create → insert fixtures → assert query plans on indexes; fail on full-table scans); from first schema change: frozen fixture DBs + K→N matrix; sensitive-DB purge test (file gone, main DB intact) | `EXPLAIN QUERY PLAN` snapshots |
| Sync idempotency (readiness) | every repository write bumps `updated_at`; re-ingest is a no-op (partial unique index proven); tombstone semantics on delete flows | conformance + storage suites |
| Provenance preservation | property-style assertion: no code path stores a health record with null provenance; suppressed records retrievable with `suppressed_by` lineage; export carries provenance columns | fixture suite + schema NOT NULLs |
| Export snapshot | CSV re-parse diff vs DB (permanent in CI after VS-2); manifest checksum verification; cross-platform byte-equality on fixtures; no-network/no-entitlement import-graph lint | `expected_export/` goldens |
| Analytics correctness | baseline math golden files; append-only recompute (I2) asserted; provisional-flag thresholds; status-chip classification vs fixture bands | golden numerics |
| Privacy | allowlist lint on analytics/log call sites (no health-value literals); sensitive-namespace isolation test; wellness-language lint on user-facing strings | `events.yaml` allowlist |
| UI smoke | snapshot tests dark+light × en+ar × 2 type sizes per shipped screen; one flow test per slice (see sleep card → open lineage; run export; log symptom; open anatomy sheet); pseudo-locale lane | per-platform snapshot harness |
| Manual device matrix (pre-release) | iPhone (current−1 OS), Pixel, Samsung (HC-via-Samsung-Health path): permission flows, foreground refresh, share-sheet delivery | checklist in `docs/` |

**Fixture strategy:** fixtures are authored once in `packages/fixtures/` as platform-neutral JSON/CSV (ISO-8601 UTC strings, no platform encodings), versioned with the contracts, and consumed by both platforms' conformance targets. Every bug fix that touches domain logic adds a fixture reproducing it. Fixture authoring rules live in the fixtures README.

---

## 11. Coding-agent task packets

Format: **AP-nn · name — prereqs · owns (exclusive write) · tasks · acceptance · avoid.** Read-only access to everything else. ∥ = parallel-safe once prereqs met.

**AP-01 · Repo bootstrap** — prereqs: none · owns: root dotfiles, `.github/`, `docs/adr/`, `backend/README.md`, `infra/README.md` · tasks: git init + initial commit of untouched scaffold; `.gitignore`; LICENSE placeholder; CI with schema-validation/codegen-drift/lint job stubs; ADR-0001…04; delete `scripts/tree.txt`; apply §12 doc amendments · acceptance: CI green; ADRs merged; first commit is the pristine scaffold · avoid: touching `apps/` or `packages/` content beyond §12 amendments.

**AP-02 · Entity schemas + codegen** — prereqs: AP-01 · owns: `packages/contracts/entities/**`, `INVARIANTS.md`, `scripts/gen_types*` · tasks: author §3 schemas in Wave-1 order; build `gen_types.py` (deterministic Swift Codable + Kotlin @Serializable, generated headers); emit into both `Generated/` dirs; CI drift check · acceptance: schemas + examples validate; generated Swift passes `swiftc -parse`, Kotlin passes `kotlinc` (no app project needed) · avoid: entities beyond §3; runtime YAML loading.

**AP-03 · Metric ontology seed** ∥ (after provenance/metric_definition schemas) — owns: `packages/metric-ontology/**` · tasks: registry schema; ~40 MVP metric ids across 8 families with units, kinds, en+ar names, casual/precise labels, chart hints; validation script · acceptance: registry validates; every VS-1…4 metric present (`sleep.time_asleep`, `sleep.time_in_bed`, `heart.hr`, `heart.rhr`, `activity.steps`, med/symptom event metrics, baseline-derived ids); AR names human-reviewed · avoid: seeding all ~350 blueprint metrics.

**AP-04 · Conformance fixtures** ∥ — prereqs: AP-02/03 · owns: `packages/fixtures/**` · tasks: `sleep_two_sources` (overlap dedup), `hr_day`, `steps_phone_watch_overlap`, `dst_night`; expected canonical rows; expected CSV/JSON export bytes; authoring README · acceptance: fixtures validate against schemas; expected exports conform to export-schemas · avoid: platform-specific encodings.

**AP-05 · iOS project bootstrap** ∥ (AP-02) — owns: `apps/ios/{project.yml,Package.swift,Sources/{Generated,Domain,Storage},Tests/}` · tasks: XcodeGen project (app + unit + conformance targets); raw SQLite via `SQLiteConnection` (ADR-0005); migration 001 = §4 DDL incl. both DB files and sync-ready columns; repositories (Sample/Session/Event/Baseline/ExportJob/Profile); wire existing placeholder views into a buildable app · acceptance: `xcodebuild test` green in CI; DB round-trip unit test; existing RootView renders · avoid: rewriting Feature view content; networking; hand-edits in `Generated/`.

**AP-06 · Android project bootstrap** ∥ — mirror of AP-05 · owns: `apps/android/**` build files, `storage/`, `generated/`, test targets · tasks: gradle bootstrap; framework SQLite (ADR-0007) main + sensitive DBs via `SqliteConnection`; repositories; manifest/theme; manual DI (no Hilt bikeshed — small graph, mirrors iOS environment approach, revisit M4) · acceptance: `./gradlew test assembleDebug` green in CI; migrations verified · avoid: same as AP-05.

**AP-07 · iOS HealthKit adapter** ∥ (AP-05) — owns: `apps/ios/Sources/Platform/Health/**` · tasks: implement port for sleepAnalysis/heartRate/restingHeartRate/stepCount: authorization bundles, anchored reads with `read_anchors` persistence, DTO mapping per typemap, PermissionState persistence; FakeHealthStore · acceptance: adapter conformance-kit subset passes on fake + recorded fixtures; permission matrix renders correct states · avoid: background delivery; write paths.

**AP-08 · Android Health Connect adapter** ∥ (AP-06) — mirror, plus HC availability states (not installed / needs update) surfaced as typed results and a short Samsung/Pixel behavior spike note in `docs/spikes/hc-behavior.md` · acceptance: Robolectric suite green; availability states typed · avoid: background reads; Samsung-direct SDK.

**AP-09 · iOS ingestion pipeline + dedup-lite** ∥ (AP-07, AP-04) — owns: `apps/ios/Sources/Domain/Ingestion/**` · tasks: DTO→canonical normalization (units, tz/day attribution, `local_night`), sleep-overlap dedup rule (session boundary overlap ≥70% + same kind → priority-source election, journal decision, suppress loser), idempotent re-ingest via identity index · acceptance: conformance fixtures byte-identical vs `expected/`; re-ingest is a no-op; reversal restores pre-decision state · avoid: generalizing a rule engine beyond this one rule.

**AP-10 · Android ingestion pipeline + dedup-lite** ∥ (AP-08, AP-04) — mirror of AP-09 · acceptance: same fixtures, identical canonical output to iOS — CI compares both platforms' serialized results (the drift firewall's first live wire).

**AP-11 · Home + metric detail, iOS** ∥ (AP-09) — owns: `apps/ios/Sources/Features/{Home,Body}/**` · tasks: `HomeState`/`MetricDetailState` over repositories; sleep card + template sentence (en+ar); 30-day chart (Swift Charts); lineage row under power policy; depth toggle in Settings via ProfileRepository · acceptance: VS-1 demo script; snapshots dark/light × en/ar; both policies render same values (fixture-asserted) · avoid: chart-library exploration; >2 metric families.

**AP-12 · Home + metric detail, Android** ∥ (AP-10) — mirror (Compose; Vico or Canvas — decide in-packet with a 1-page note) · acceptance: mirror of AP-11.

**AP-13 · Export engine, both platforms** ∥ (AP-09/10) — owns: `Features/Export/**` both + `packages/export-schemas` refinements (WS-A review) · tasks: ExportJob runner; CSV writer per `csv_columns.yaml`; JSON bundle + manifest + checksums; share-sheet delivery; round-trip test · acceptance: VS-2 criteria; byte-identical cross-platform on fixtures; no network/entitlement imports (lint) · avoid: PDF, scheduling, encryption options.

**AP-14 · Meds + symptoms logging, both platforms** ∥ (AP-05/06) — owns: `Features/{Medications,Symptoms}/**` both + symptom dictionary seed (WS-A review) + sensitive DB wiring · tasks: regimen CRUD; due list; taken/skip-with-reason; symptom quick-log (chips + severity); day timeline rows; sensitive-namespace storage + purge; export toggle · acceptance: VS-3 criteria incl. airplane-mode demo + AR forms; no red/guilt states · avoid: reminders/notifications; any dosing-adjacent copy.

**AP-15 · RTL/l10n harness** ∥ (AP-11/12) — owns: `docs/rtl-checklist.md`, string-catalog structure, snapshot harness config both platforms · tasks: AR catalogs for shipped surfaces; pseudo-locale + AR snapshot CI lanes; RTL audit findings filed as issues · acceptance: VS-5 criteria; CI fails on missing AR strings for shipped screens · avoid: translating unshipped surfaces.

**AP-16 · Baseline-lite + anatomy sheet, both platforms** — prereqs: AP-11/12 · owns: `Domain/Derivation/**` both, `Features/Body/AnatomySheet*` both · tasks: 14-day median/MAD job (injected clock); DerivedValue/InputManifest/Baseline persistence, append-only; status chip; anatomy sheet; en+ar templates · acceptance: VS-4 criteria; I2 fixture-asserted; golden numerics match both platforms · avoid: any second algorithm; any LLM; covariate contexts beyond `default`.

**Parallelism:** after M1 freeze, up to 8 packets run concurrently: AP-05∥06 → AP-07∥08 → AP-09∥10∥13-prep∥14 → AP-11∥12∥15 → AP-16.

---

## 12. Immediate repo changes to make next

In order, starting today (items 1–2 are AP-01's first commits; 3–10 are one-line-to-one-paragraph doc amendments AP-01 applies):

1. **`git init` + commit the untouched scaffold**, then add `.gitignore`, LICENSE, CI skeleton, ADR-0001…04. Nothing else proceeds without version control.
2. **Create `docs/adr/`** with the four ADRs recording D-4, D-6, D-7, D-9.
3. **`CLAUDE.md`** — append under "Working mode": contracts are machine-readable (JSON Schema/YAML) consumed only via `scripts/gen_types.py` output; never hand-edit `Generated/`; shared behavior exists only when both platforms pass `packages/fixtures/`; canonical entity names per `packages/contracts/INVARIANTS.md`.
4. **`docs/PRD.md`** — add "Scope decisions (v0.1 → v0.2)": local-first, no backend, no remote analytics in MVP; sync out of scope but schema sync-ready; MVP metric scope = sleep, heart, activity + meds/symptoms logging; blueprint entity naming adopted.
5. **`docs/architecture-decision.md`** — append decision record: Swift+Kotlin committed 2026-07-10; Flutter path closed (folder never created); KMP gate at M4 with D-4 criteria; link ADR-0001.
6. **`docs/scaffold-notes.md`** — correct the `apps/flutter` claim; point "next implementation docs" at this plan's §6.
7. **`packages/contracts/src/health_contracts.md`** — prepend supersession note + rename map (kept as historical seed).
8. **App shells** — rename `Metrics` tab/feature → `Body` on both platforms now, while the rename is one commit.
9. **`BADAN_MASTER_BLUEPRINT.md`** — one front-matter paragraph: native-first with contracts-level sharing per ADR-0001 supersedes §33/§47/§52's KMP layout until the M4 gate; §47 monorepo paths map to actual `packages/`+`apps/`; subsystem specs remain authoritative as reference. Also note that v1 lives at `docs/BADAN_MASTER_BLUEPRINT_OLD_DONT_USE.md`.
10. **`scripts/next_steps.md`** → "Superseded by `docs/EXECUTION_PLAN.md` §6/§11."; **`backend/README.md` + `infra/README.md`** → dormancy sentences; **`README.md`** → point "First build target" at VS-1/VS-2 and this plan; delete `scripts/tree.txt`.

Then: AP-02/03/04 (contracts, ontology, fixtures) immediately after, targeting the M1 freeze.

---

## Appendix A. Risk register

| # | Risk | L/I | Mitigation |
|---|---|---|---|
| R1 | Dual-native logic drift | M/H | machine-readable contracts + conformance fixtures; duplicated-logic budget; M4 KMP gate with pre-agreed criteria |
| R2 | Scaffold stays unbuildable while docs grow | H/H | M2 exit criteria are device demos, not documents; AP-05/06 are the first coding packets after contracts |
| R3 | Contracts freeze too late → agent collisions | M/H | M1 freeze is a hard gate; feature packets carry "blocked by M1" |
| R4 | Health Connect background/permission surprises (OEM variance) | M/M | AP-08 Samsung/Pixel spike; foreground-refresh fallback with stale banner designed in from VS-1 |
| R5 | Scope gravity from the 10k-line blueprint | H/M | scope rule (preamble): nothing outside VS-1…5; blueprint demoted to reference where it conflicts with repo reality |
| R6 | RTL retrofitted instead of structural | M/H | AR snapshots in CI from M2 for every new screen; VS-5 milestone-gated |
| R7 | Sync retrofit pain | M/H | D-7 schema reservations enforced by schema review at M1 |
| R8 | Export becomes an afterthought | L/H | VS-2 is the second slice; round-trip test permanent in CI; no-network lint |
| R9 | Store review friction for health data | M/M | wellness-language lint; privacy-declaration checklist drafted at M3 (`docs/store-compliance.md`) |
| R10 | Merge collisions in shared wiring files | H/M | exclusive packet ownership (§11); per-feature registration files; generated-file discipline |
| R11 | Sensitive-DB encryption posture underspecified | M/M | D-9 states MVP posture explicitly (OS file encryption + separate purgeable file); SQLCipher is a tracked M4 decision, ADR-0004 |

## Appendix B. v1.0 → v1.1 changelog

1. Restructured into the 12 execution sections (build strategy and integration layer consolidated into their own sections; storage got a concrete table-level starting set adapted from blueprint §52 to MVP scope and native GRDB/Room).
2. **Added `Session` + `SessionStage`** to the domain and schema starting set (with `local_night` attribution) — v1.0 routed sleep through IntervalRecord only, which cannot support VS-1's overlap dedup or the "last night" query cleanly.
3. **Added `read_anchors`** table (HK anchors / HC changes tokens) — required by adapter idempotency, missing from v1.0's entity list.
4. **Made the sensitive namespace physical** (second DB file, purge = file delete) and stated the MVP encryption posture honestly as a decision (D-9/ADR-0004) instead of leaving it implicit.
5. Corrected stale blueprint file references (root file is v2.0; v1 is `docs/BADAN_MASTER_BLUEPRINT_OLD_DONT_USE.md`).
6. Added AP-16 (baseline-lite packet — VS-4 had no owning packet in v1.0) and folded v1.0's §12 amendments into AP-01's tasks so they actually get executed.
7. Carried forward unchanged in substance: invariants I1–I8, entity field sets, vertical slices VS-1…5, workstreams, milestones, test strategy, packets AP-01…15, risk register.
