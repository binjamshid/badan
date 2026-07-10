# BADAN Execution Planning Package

**Status:** v1.0 — execution pass over the existing repo (docs + scaffold as of 2026-07-10)
**Inputs read:** `BADAN_MASTER_BLUEPRINT.md` (v1, product truth), `BADAN_MASTER_BLUEPRINT_V2.md` (deep reference library), `docs/PRD.md` (v0.1, current scope), `CLAUDE.md` (implementation guardrails), `docs/project_description.md`, `README.md`, `docs/architecture-decision.md`, `docs/native-implementation-plan.md`, `docs/scaffold-notes.md`, `scripts/next_steps.md`, `infra/README.md`, all files under `apps/`, `packages/`, `backend/`.
**Posture:** additive precision. Nothing below regenerates existing documents; it builds the missing execution layer on top of them and lists the few targeted amendments the source docs need.

---

## 1. Current-state audit

### 1.1 Strengths worth preserving

1. **The strategic docs are coherent and consistent on product truth.** PRD, project_description, CLAUDE.md, and blueprint all agree on the five load-bearing commitments: repository-first (raw data never paywalled), provenance always, one model / two renderings, export as a differentiator, wellness-safe wording, Arabic/RTL and Android parity as structural. No re-litigation needed.
2. **The native-first decision is defensible and already made.** `docs/architecture-decision.md` + `CLAUDE.md` + `README.md` converge on Swift/SwiftUI + Kotlin/Compose with sharing held at the contracts level. This contradicts blueprint v2 §33/§47 (KMP shared core) — see §1.3 and §2.1 for the resolution.
3. **Feature-folder layout in both app shells is correct.** `apps/ios/Sources/Features/<Feature>/` and `apps/android/.../features/<feature>/` match the blueprint's per-feature ownership model and will partition cleanly across agents.
4. **`packages/` as the shared spec layer is the right seam.** contracts / metric-ontology / export-schemas is a good decomposition; only their *content grade* is insufficient (below).
5. **`scripts/next_steps.md` is directionally right** — its 7 items are a subset of what this package turns into concrete packets.

### 1.2 Missing pieces (the "well-scaffolded → ready for execution" gap)

**Hard blockers (nothing compiles today):**
- **No build systems.** `apps/ios` has no `.xcodeproj`/`project.yml`/`Package.swift`; `apps/android` has no `settings.gradle.kts`, `build.gradle.kts`, wrapper, or `AndroidManifest.xml`. The `.kt`/`.swift` files are orphaned sources.
- **Not a git repository.** No `.git`, no `.gitignore`, no LICENSE, no CI. Multi-agent execution without version control is a non-starter.
- **Empty `backend/api`, `backend/workers`** — fine (see §2.3), but they need a README declaring dormancy so agents don't "helpfully" fill them.

**Contract-grade gaps (per the required checklist):**

| Concern | Current coverage | Verdict |
|---|---|---|
| Provenance | Flat fields in `health_contracts.md` (`sourceId`, `sourceName`, `deviceName`, `ingestionMethod`) | **Partial.** No Provenance struct, no measured-vs-recorded timestamps, no timezone-at-measurement, no dedup lineage (`suppressedBy`), no `ImportBatch` linkage. §4 supplies the struct. |
| Raw vs derived separation | Layer names exist (RawSample / NormalizedMeasurement / DerivedMetric) | **Thin.** No `AlgorithmVersion`, no `InputManifest`, no append-only rule for derived values. Naming also drifts from blueprint (§1.3 item 4). |
| Sync boundaries | **Absent** in PRD/scaffold; blueprint covers strategy | **Gap.** Decision needed now because it shapes primary keys, timestamps, tombstones. Resolved in §2.4: MVP is sync-*ready*, not sync-*dependent* — `SyncCursor`, ULIDs, `updatedAt`+`originDeviceId`, soft-delete tombstones enter the schema from day 1; no sync service ships in MVP. |
| Export architecture | Formats + dimensions listed in `export_bundle.md` | **Thin.** No manifest spec, no schema versioning, no data dictionary, no raw/derived separation rules in output, no round-trip test plan. §4 (ExportJob) + VS-2 + AP-13 close this. |
| Structured logging (user logs) | PRD lists it; placeholder screens exist | **Gap.** No entities for meds/symptoms/food/workouts/conditions. §4 defines all five; VS-3 proves two. |
| Platform integration abstraction | Listed as future work in `next_steps.md` | **Gap.** No `HealthStorePort` contract. §4 + AP-07/08. |
| Local-first / offline | Implied by privacy posture only | **Gap → decision in §2.4.** All MVP behavior is local; every write path must work offline by construction. |
| Privacy boundaries | Guardrails present in CLAUDE.md (good) | **Partial.** No data-class table (standard vs sensitive-plus), no "no health values in logs/analytics" enforcement mechanism. §9.6 + AP-01 add the lint. |
| Casual vs power rendering | Principle stated everywhere | **Partial.** No `PresentationPolicy` contract. §4 defines it inside `CustomizationProfile`; VS-1 must render one card under both policies to prove the mechanism. |

**Content-grade gaps in `packages/`:** all three seeds are prose markdown. Prose contracts cannot be codegen'd, linted, or conformance-tested — and with two native codebases, un-generated contracts guarantee drift. This is the single highest-leverage fix in the repo (§2.2, AP-02).

### 1.3 Contradictions and ambiguities (flagged, not silently resolved)

1. **KMP vs native-first.** Blueprint v2 §33/§47 selects a KMP shared core; CLAUDE.md/README/native-implementation-plan defer shared runtime. Per the stated precedence (CLAUDE.md governs implementation guardrails; scaffold is repo reality), **native-first wins now**. The blueprint's underlying concern — logic drift between platforms — is real and must be answered by machine-readable contracts + codegen + shared conformance fixtures (§2.2), plus an explicit KMP re-evaluation gate at M4 (§8) with pre-agreed criteria. Neither doc needs rewriting; `architecture-decision.md` needs a short decision-record appendix (§12.3).
2. **`apps/flutter` referenced but absent.** `docs/scaffold-notes.md` says the flutter folder exists to keep the evaluation path open; the tree has no `apps/flutter`. Repo reality has already closed the Flutter path. Amend scaffold-notes (§12.4) and record the closure formally rather than leaving a phantom option.
3. **Tab IA drift.** Scaffold shells use 4 tabs (Home / Metrics / Log / Settings); blueprint v1 §14 specifies 5 destinations (Today / Journey / Body / Log / Coach) with Settings as a modal. For MVP slices the 4-tab shell is acceptable (PRD scope has no Journey/Coach yet), but this is a deliberate deferral, not an accident: record it, and rename `Metrics` → `Body` now while renames are free (§12.6). Settings-as-tab gets revisited at M4.
4. **Entity naming drift.** `health_contracts.md` uses NormalizedMeasurement / DerivedMetric / UserLogEntry / ExportBundle; blueprint uses IntervalRecord / DerivedValue / EventRecord / ExportJob. §4 fixes canonical names (aligned to the blueprint, which the rest of the 10k-line reference library uses) and gives the rename map. The seed file gets a pointer, not a rewrite (§12.5).
5. **Two blueprints at root.** v1 is cited as authoritative product truth; v2 (execution reference) also lives at root and disagrees with repo reality on KMP and monorepo layout (`core/`, `contracts/`, `adapters/` vs actual `packages/`, `apps/`). Treat v2 as a **reference library**: its per-subsystem specs (metric ontology details, screen specs, dedup rules, export columns) remain valid; its repo layout and shared-runtime sections are superseded by this package where they conflict. One paragraph in v2's front matter should say so (§12.7).
6. **`scripts/tree.txt`** is a stale snapshot; delete or regenerate in CI (trivial, §12.8).

### 1.4 Overengineering risk assessment

The danger in this repo is not under-planning — it's importing the v2 blueprint's full apparatus (14 core modules, 473 packets, sync engine, insight engine) into an MVP that PRD v0.1 correctly scopes to: ingestion foundation, canonical model, provenance, home summary, metric detail, logging foundations, CSV/JSON export, dashboard-customization basics. **Rule for this phase: nothing gets built that VS-1…VS-5 (§6) doesn't exercise.** Specifically deferred: sync service, insight/AI engine, broker integrations, watch/widgets, Coach surface, biology/labs, cycle engine, notifications engine. Schema-level *reservations* for sync and derived-value versioning are the only forward payments allowed (they're cheap now, brutal later).

---

## 2. Architecture validation

### 2.1 Confirmed: native-first, contracts-shared — with two hardening conditions

The Swift+Kotlin decision is right for BADAN's shape (HealthKit/Health Connect intimacy, background execution nuance, RTL fidelity, future watch/widget surfaces — all per `architecture-decision.md`, which this package ratifies). It stands **only if** two conditions are met, otherwise drift will quietly rebuild the problem KMP was meant to solve:

1. **Contracts become machine-readable and generated.** Every shared definition (entities, metric registry, export schema, analytics events, fixtures) lives as JSON Schema/YAML in `packages/`, and a codegen step (`scripts/gen_types.py`) emits Swift (`Codable` structs) and Kotlin (`@Serializable` data classes) into checked-in `Generated/` folders. Hand-editing generated files is CI-rejected. Prose markdown in `packages/*/src/` becomes commentary around schemas, not the contract itself.
2. **Both platforms pass the same conformance fixtures.** `packages/fixtures/` holds golden files (ingestion payloads → expected canonical rows → expected export output). Each app has a thin test target that runs identical fixture suites. A behavior exists only when both platforms pass its fixture — this replaces KMP's "one implementation" guarantee with "one specification, two verified implementations."

**Duplicated-logic budget:** while native-first holds, the duplicated domain surface must stay small. MVP duplicates only: unit conversion, timezone/day-attribution rules, dedup-lite (§6 VS-1 scope), baseline-lite (14-day rolling median/MAD), and export serialization. Heavier engines (full dedup rule set, scoring, insights) are **frozen until the M4 KMP gate** — if the gate decides "stay native," they get built twice against an expanded fixture corpus; if "adopt KMP for core," they get built once. This sequencing means the KMP decision is made with evidence and *before* the expensive engines exist.

**M4 KMP gate criteria (pre-agreed now):** adopt KMP for `core` if by end of M4 any of: (a) ≥3 fixture-divergence incidents traced to duplicated logic, (b) duplicated domain code exceeds ~2k LOC/platform, (c) the team confirms Kotlin/Swift toolchain comfort. Otherwise stay native and re-check at each milestone.

### 2.2 What is shared vs native

| Layer | Home | Form | Rationale |
|---|---|---|---|
| Entity schemas, invariants | `packages/contracts/` | JSON Schema + generated Swift/Kotlin | One definition, two verified consumers |
| Metric registry (ids, units, families, display rules) | `packages/metric-ontology/` | YAML + registry JSON Schema → generated enums/lookups | Registry-driven UI needs typed access |
| Export schema + manifest + data dictionary | `packages/export-schemas/` | JSON Schema + column-map YAML | Export must be byte-comparable across platforms |
| Conformance fixtures | `packages/fixtures/` (new) | JSON/CSV golden files | The drift firewall |
| Analytics event taxonomy | `packages/contracts/analytics/` | YAML (allowlisted property types) | Privacy enforcement point |
| Logical DB schema | `docs/data-model.md` + per-platform DDL | Spec shared; DDL native (GRDB / Room) | SQLite both sides; identical logical schema, idiomatic implementations |
| Health store access | `apps/*/…/platform/health/` | Native adapters implementing the shared `HealthStorePort` contract shape | Platform APIs are the point of nativeness |
| UI, navigation, design system | `apps/*` | SwiftUI / Compose | Native by decision |
| Background execution | `apps/*` | BGTaskScheduler / WorkManager | Non-portable by nature |

### 2.3 Backend day-1 minimum: zero

**Decision: the MVP ships with no backend.** Local-first + account-optional means slices VS-1…VS-5 run entirely on-device: platform-store ingestion, local SQLite, local export via share sheet. `backend/api` and `backend/workers` stay as dormant placeholders with a README stating: "No service exists or is called in MVP. First backend work item is the sync service or the first vendor integration, whichever is scheduled first — see EXECUTION_PLAN §8." This eliminates an entire class of MVP risk (auth, hosting, compliance surface, cost) and is the strongest possible proof of the privacy posture. The only "backend-shaped" MVP artifact is the analytics decision: MVP uses **no remote analytics** (local debug logging only); a privacy-preserving telemetry vendor decision is an M4 agenda item.

### 2.4 Local-first implications (now concrete)

1. Device SQLite is the source of truth; there is no "server copy" to reconcile against in MVP.
2. Every table carries sync-readiness fields from day 1: ULID primary keys (offline-generatable, sortable), `updatedAt`, `originDeviceId`, `deletedAt` (tombstone) — plus a reserved `sync_cursors` table (see §4, SyncCursor). Cost now: trivial. Cost of retrofitting: a migration across every table plus identity backfill.
3. All writes are synchronous-local with optimistic UI; no write path may require network.
4. Export runs fully locally (Law 1 made physical: the export code path has no networking import — enforceable by lint).
5. Backup story for MVP: OS-level device backup + user-initiated export. Document this honestly in-app when accounts/sync are asked about.

### 2.5 Why this shape is right for BADAN

The product's three differentiators — provenance-grade trust, export, dual-altitude rendering — are all *data-layer* properties. This architecture puts the entire data layer under specification-grade control (schemas + fixtures) while spending native effort exactly where users feel it (health integration fidelity, RTL, platform polish). The deferred decisions (KMP, sync, backend) are each held open at the cheapest possible holding cost: fixtures, schema reservations, and dormant folders respectively.

---

## 3. Repo responsibility map

| Area | Owns | May depend on | Forbidden | Owner (workstream §7) |
|---|---|---|---|---|
| `packages/contracts/` | entity JSON Schemas, invariants doc, analytics taxonomy, `HealthStorePort` contract shape | nothing | depending on apps/backend; prose-only contracts | WS-A |
| `packages/metric-ontology/` | registry schema + family YAMLs (ids, units, kinds, display) | contracts (schema refs) | UI concerns beyond display metadata | WS-A |
| `packages/export-schemas/` | export column maps, manifest schema, data dictionary source | contracts, metric-ontology | entitlement/monetization references (Law 1) | WS-A |
| `packages/fixtures/` (new) | golden ingestion→canonical→export fixtures; RTL string fixtures | all other packages (read-only) | platform-specific encodings | WS-A + WS-I |
| `scripts/` | codegen (`gen_types.py`), fixture tooling, tree/docs generators | packages (read) | writing into `apps/*` outside `Generated/` | WS-A |
| `apps/ios/` | SwiftUI app, GRDB storage, HealthKit adapter, generated types (checked in) | packages via codegen only | importing Android code; hand-edits in `Generated/`; network calls in MVP | WS-B/D |
| `apps/android/` | Compose app, Room storage, Health Connect adapter, generated types | packages via codegen only | same as iOS, mirrored | WS-C/E |
| `backend/` | dormant; README only | — | any MVP code | (locked) |
| `infra/` | dormant; README only | — | any MVP code | (locked) |
| `docs/` | PRD, ADRs, data-model spec, this package | — | duplicating contract content (link, don't copy) | WS-J |

**Cross-cutting dependency rules (CI-enforced from AP-01):**
- Apps never parse `packages/` YAML at runtime — only generated types. (Runtime registry loading is a post-MVP option; MVP compiles the registry in.)
- UI layers (`Features/`) depend on repositories/state models, never directly on health adapters or DB — the seam that keeps dual-altitude rendering a presentation concern.
- The export module must not import entitlement, networking, or analytics modules.
- No module may log or emit analytics containing health *values* — allowlist lint on analytics property names and log call sites.

---

## 4. Initial domain contracts

Canonical names below supersede the seed names in `packages/contracts/src/health_contracts.md` (rename map: `NormalizedMeasurement→IntervalRecord`, `DerivedMetric→DerivedValue`, `UserLogEntry→EventRecord` subtypes, `ExportBundle→ExportJob` + bundle format). All entities get JSON Schemas in `packages/contracts/entities/` (one file each, `snake_case.schema.json`) and generated types on both platforms. Shared field conventions: `id: ULID`, `createdAt/updatedAt: ISO-8601 UTC`, `originDeviceId: string`, `deletedAt: timestamp?` (tombstone; hard delete only via user deletion flows), timestamps that describe *measurement* carry `timezone` (IANA id) alongside UTC instant.

**Cross-entity invariants (the constitution — goes in `packages/contracts/INVARIANTS.md`):**
I1 Every stored health datum carries a full `Provenance`. I2 Derived values never overwrite — recompute appends with new `AlgorithmVersion`. I3 Dedup suppresses, never deletes (`suppressedBy` pointer). I4 Manual entries win over device data for weight/BP/labs; device wins elsewhere by source priority. I5 Raw and derived are separable in every query and every export. I6 No entity references entitlement state. I7 Sensitive-class entities (cycle later; meds/symptoms now) live in a separate storage namespace with independent purge. I8 All ids are ULIDs minted on-device.

### 4.1 Reference & identity entities

- **MetricDefinition** — registry row, compiled from `packages/metric-ontology/`. Fields: `metricId` ("sleep.time_asleep" — dot-namespaced, lowercase snake), `family` (enum of the 15 seed families), `kind` (`rawSample|intervalAggregate|session|event|derived`), `canonicalUnit`, `displayUnits[]` (per-locale), `displayNames` (en/ar minimum), `casualLabel`/`preciseLabel` (dual-altitude vocabulary), `chartHint` (`bandLine|bars|ledger|eventStrip|pointRange`), `baselineEligible: bool`, `sensitiveClass` (`standard|sensitivePlus`). Invariant: apps never hardcode a metric id string outside generated constants.
- **Source** — a connected data origin. `sourceId`, `type` (`healthkit|healthConnect|manual|import|vendor(reserved)`), `displayName`, `platformBundleId?`, `status` (`active|revoked|hidden`), `priorityRank` (per-metric overrides live in a small `source_priority` table). Hidden ≠ deleted (Bevel-parity hide-source behavior).
- **Device** — physical origin when known. `deviceId`, `name`, `model`, `firstSeen/lastSeen`, `sourceId` FK.
- **PermissionState** — per platform data type: `platformType` (e.g., `HKCategoryTypeIdentifierSleepAnalysis` / `SleepSessionRecord`), `status` (`notRequested|granted|denied|partial|revoked`), `lastCheckedAt`, `lastReadAt?`. Drives denied-state UI and the consent screen's honesty ("last read: …").

### 4.2 Provenance (struct embedded in every health datum)

**Provenance** — `sourceId`, `deviceId?`, `ingestionPath` (`platformStore|manual|import|derived`), `platformRecordId?` (idempotency key for re-sync), `importBatchId?`, `measuredAt` + `measuredTimezone`, `recordedAt` (when the origin recorded it), `ingestedAt` (when BADAN stored it), `algorithmVersionId?` (derived only), `qualityFlags[]` (`gapFilled|artifactSuspected|userCorrected|provisionalBaseline|estimate`), `suppressedBy?` (ULID of the winning record when deduped). Invariants: I1, I3; `platformRecordId+sourceId` unique when present (idempotent re-ingest).

### 4.3 Measurement entities

- **RawSample** — instant/short-interval platform readings kept for lineage and power-user explorer. `metricId`, `value: decimal`, `unit` (as received), `canonicalValue` (converted), `startAt/endAt`, `provenance`. Table: `raw_samples`, indexed `(metricId, startAt)`. Retention/decimation policy is a post-MVP knob; MVP keeps all.
- **IntervalRecord** — normalized aggregates BADAN treats as canonical facts (daily steps, nightly time-asleep, session-level HR stats). Fields as RawSample plus `aggregation` (`sum|mean|min|max|duration|latest`), `coverage` (0–1, how complete the underlying data was), `sourceRollup[]` (contributing source ids). This is the layer charts read by default.
- **EventRecord** — typed discrete events; closed union via `eventType` + typed `payload` (each payload has its own schema file): `mealEntry` (→ NutritionEntry), `symptomEntry`, `adherenceEvent`, `workoutEntry` (summary event; session detail below), `statusInterval` (reserved), `note`, `measurementEntry` (manual weight/BP). Common: `occurredAt/timezone`, `endAt?`, `provenance`, `tags[]`.

### 4.4 Derivation entities

- **AlgorithmVersion** — `algorithmId` ("baseline.rolling_median"), `semver`, `description`, `introducedIn` (app version), `params` (frozen JSON). Registry file in contracts; rows referenced by every DerivedValue.
- **DerivedValue** — `metricId` (derived metrics are registry members too), `value`, `windowStart/End`, `algorithmVersionId`, `inputManifest` (compact list of input record ids or window descriptors — enough to re-derive and to render "why"), `provenance` (ingestionPath=`derived`), `supersededBy?` (append-only chain, I2). Table `derived_values`, indexed `(metricId, windowEnd, supersededBy)`.
- **Baseline** — materialized personal-normal band: `metricId`, `windowDays` (14 MVP), `method` (`medianMAD`), `center`, `lowerBand/upperBand`, `sampleCount`, `computedAt`, `algorithmVersionId`, `provisional: bool` (until `sampleCount ≥ 7`), `covariateContext` (MVP: always `"default"`; reserved key so cycle/status conditioning later is additive, not a migration).

### 4.5 Interpretation entity (MVP-minimal)

- **Insight** — deferred as an *engine*, but the entity ships now because VS-4's "why" sheet is a proto-insight: `insightType` (`statusExplanation` only in MVP), `metricIds[]`, `evidence` (input manifest + baseline refs), `renderedText` (en+ar), `generatedAt`, `algorithmVersionId`, `feedback?` (`helpful|notHelpful|inaccurate`). Template-rendered, no LLM in MVP (AI stays downstream of plumbing).

### 4.6 Ownership & portability entities

- **ExportJob** — `scope` (metricIds[]/families, dateRange, sources[], `includeRaw/includeDerived/includeSuppressed`, unitProfile, language), `format` (`csv|json`), `status` (`pending|running|completed|failed`), `manifest` (schemaVersion, appVersion, row counts per metric, dedup-policy note, checksums), `outputUri?` (local file), timestamps. Invariant: runnable offline; no entitlement reference (I6).
- **ImportBatch** — reserved for archive importers (post-MVP) but created now because Provenance references it: `sourceDescription`, `fileHash`, `recordCounts`, `status`, `undoableUntil`. One-tap batch undo = tombstone everything with this `importBatchId`.
- **SyncCursor** — reserved, unused in MVP: `scopeKey` (table or entity class), `deviceId`, `lamport: int`, `lastSyncedAt?`. Its existence forces every repository write to bump `updatedAt` correctly, which is the actual sync-readiness discipline.
- **ReconciliationDecision** — the dedup journal: `winnerId`, `loserId`, `ruleId` (e.g., `sleep.session_overlap.v1`), `decidedAt`, `reversible: bool`, `reversedAt?`. Renders in the power-user lineage sheet; makes dedup auditable and undoable.

### 4.7 Logging-domain entities

- **MedicationRegimen** — `name` (free text MVP; localized ingredient list post-MVP), `strength?`, `form?`, `schedule` (structured: `asNeeded | daily(times[]) | weekly(days[], times[])`), `startedAt`, `endedAt?`, `notes?`, `sensitiveClass=sensitivePlus`. No dosing advice anywhere near this entity (rendering rule, and no interaction data stored).
- **AdherenceEvent** — `regimenId`, `kind` (`taken|skipped|late`), `scheduledFor?`, `occurredAt`, `skipReason?` (enum + free text), provenance (manual). Non-punitive by design: skip-with-reason is a first-class equal of taken.
- **SymptomEntry** — `symptomId` (canonical dictionary seed ~50 entries in ontology package, localized) or `customLabel`, `severity` (1–10 int, UI may render 3-level), `occurredAt`, `duration?`, `bodyLocation?` (coded list), `triggers[]` (tags), `note?`, `sensitiveClass=sensitivePlus`.
- **WorkoutEntry** — MVP = imported session summaries + manual quick-add: `activityType` (mapped enum), `startAt/endAt`, `duration`, `energyKcal?`, `distanceM?`, `avgHr?/maxHr?`, `perceivedEffort?` (RPE 1–10, manual), provenance. Strength set/rep detail is a post-MVP payload extension, already namespaced (`workout.strength.*` reserved in ontology).
- **NutritionEntry** — MVP = manual quick-log: `description`, `mealType` (`breakfast|lunch|dinner|snack`), `energyKcal?`, `macros?` {proteinG, carbsG, fatG}, `occurredAt`, provenance. Database/barcode/AI pathways are post-MVP; the entity is forward-compatible via optional `foodItemRefs[]`.
- **Condition** — user-declared: `label` (custom or coded seed list), `status` (`active|resolved|episodic`), `onsetAt?`, linked `medicationRegimenIds[]`, `symptomIds[]`, `metricIds[]`, `notes`. BADAN never infers conditions (invariant, rendering + review rule).

### 4.8 Presentation entity

- **CustomizationProfile** — one row per user (MVP: singleton): `depthPolicy` (`casual|balanced|power`), `perSurfaceOverrides` (map surfaceId→policy), `homeModules[]` (ordered module ids + visibility), `unitOverrides` (map metricId→unit), `language` (`en|ar`), `theme` (`system|dark|light`). This *is* the dual-altitude mechanism: state models read policy from here; renderers branch on it; underlying queries are identical (fixture-tested identical values under both policies).

### 4.9 The port contract

- **HealthStorePort** (contract shape in `packages/contracts/ports/health_store_port.md` + schema for its DTOs; implemented natively): `capabilities() → [PlatformTypeCapability]`, `requestAuthorization(bundle) → PermissionState[]`, `readSamples(platformType, range, anchor?) → ([RawSampleDto], anchor)`, `observeChanges(platformType)` (iOS observer / HC changes-token semantics documented per platform), `writeRecord(dto)` (post-MVP, reserved). DTO→canonical mapping tables live beside the contract and are fixture-tested per platform.

---

## 5. File creation order

Real files, in dependency order. Rationale is stated only where the order isn't obvious. (Repo bootstrap first — nothing else is verifiable without it.)

**Wave 0 — repo becomes a repo (AP-01)**
1. `.gitignore` (Xcode + Gradle + Python + DS_Store) → `git init` + initial commit of current state *before any changes* (preserves provenance of the scaffold itself)
2. `LICENSE` (proprietary placeholder — decide OSS posture later per blueprint §43)
3. `docs/adr/ADR-0001-native-first-contracts-shared.md` (records §2.1 incl. KMP gate criteria)
4. `docs/adr/ADR-0002-no-backend-mvp.md`, `docs/adr/ADR-0003-sync-ready-not-sync-dependent.md`
5. `.github/workflows/ci.yml` (starts as: schema validation + codegen-drift check; grows per milestone)

**Wave 1 — contracts before code (AP-02, AP-03)**
6. `packages/contracts/entities/_conventions.md` (ULID/timestamps/tombstone/sensitiveClass rules from §4)
7. `packages/contracts/entities/provenance.schema.json` — first, because everything embeds it
8. `packages/contracts/entities/{metric_definition,source,device,permission_state}.schema.json`
9. `packages/contracts/entities/{raw_sample,interval_record,event_record}.schema.json` (+ `payloads/{nutrition_entry,symptom_entry,adherence_event,workout_entry,measurement_entry,note}.schema.json`)
10. `packages/contracts/entities/{algorithm_version,derived_value,baseline,insight}.schema.json`
11. `packages/contracts/entities/{export_job,import_batch,sync_cursor,reconciliation_decision,medication_regimen,condition,customization_profile}.schema.json`
12. `packages/contracts/INVARIANTS.md` (I1–I8)
13. `packages/metric-ontology/registry.schema.json` + `packages/metric-ontology/families/{sleep,heart,activity,body,nutrition,symptoms,medications,subjective}.yaml` (MVP-needed families first; ~40 metric ids seeded, en+ar names)
14. `packages/contracts/ports/health_store_port.md` + `packages/contracts/ports/dto/{raw_sample_dto,capability}.schema.json`
15. `packages/contracts/analytics/events.yaml` (MVP: ~12 events, property allowlist)
16. `scripts/gen_types.py` + `scripts/gen_types_test.py` (YAML/JSON-Schema → Swift/Kotlin; deterministic output)
17. `packages/export-schemas/csv_columns.yaml`, `manifest.schema.json`, `packages/export-schemas/DATA_DICTIONARY.md` (generated skeleton)

**Wave 2 — apps become buildable (AP-05, AP-06, parallel)**
18. iOS: `apps/ios/project.yml` (XcodeGen) + `apps/ios/Package.swift` deps (GRDB) → generated `.xcodeproj` checked in or generated in CI
19. iOS: `apps/ios/Sources/Generated/` (codegen output target) + `apps/ios/Sources/Domain/` (thin extensions over generated types)
20. iOS: `apps/ios/Sources/Storage/Database.swift` (GRDB setup, migrations v1 DDL for §4 tables), `Storage/Repositories/{SampleRepository,EventRepository,BaselineRepository,ExportJobRepository}.swift`
21. Android: `settings.gradle.kts`, root+app `build.gradle.kts`, `gradle/libs.versions.toml`, wrapper, `AndroidManifest.xml`, theme stubs
22. Android: `app/src/main/java/com/badan/app/generated/` + `domain/`, `storage/BadanDatabase.kt` (Room, same logical DDL), `storage/repositories/*.kt`
23. Both: `…/platform/health/HealthStoreAdapter.{swift,kt}` implementing the port for sleep + HR read paths only
24. Both: fixture test targets: `apps/ios/Tests/ConformanceTests/`, `apps/android/app/src/test/…/conformance/` wired to `packages/fixtures/`

**Wave 3 — fixtures then features (AP-04 then AP-09…AP-14)**
25. `packages/fixtures/ingestion/{sleep_two_sources.json,hr_day.json,steps_phone_watch_overlap.json}` + `expected/` canonical rows + `expected_export/` CSV/JSON goldens
26. Feature state models and screens in slice order (§6): Home summary → Metric detail → Export → Logging (meds/symptoms) → each as `Features/<X>/{<X>State,<X>ViewModel,<X>View|Screen}` per platform
27. `docs/data-model.md` (generated ERD + prose; from schemas, not hand-drawn)
28. `docs/rtl-checklist.md` + pseudo-locale test harness entries (AP-15)

---

## 6. Vertical slices

Each slice is end-to-end (ingestion→storage→rendering or logging→storage→export), ships on both platforms, and proves a named architectural property. A slice is done when its fixture suite passes on both platforms and the demo script runs on physical devices.

**VS-1 · "Last night, truthfully" — sleep + resting HR from platform store to Home card to detail.**
Read sleep sessions + HR via adapters → normalize to RawSample/IntervalRecord with full Provenance → dedup-lite (two-source sleep overlap: keep priority source, journal a ReconciliationDecision, suppress not delete) → Home summary card (time asleep + one plain sentence template) → Metric detail (30-day bar chart, per-day values, source lineage row per record). Dual-altitude proof: casual renders card+chart; power reveals lineage + suppressed records — same queries, `CustomizationProfile.depthPolicy` switch only. *Proves: ingestion, provenance, dedup journal, storage, dual rendering.* Fixtures: `sleep_two_sources`, `hr_day`.

**VS-2 · "Take it with you" — export sleep+HR as CSV and JSON.**
Export screen (scope: date range + the two metric families) → ExportJob runs locally → CSV per `csv_columns.yaml` (incl. provenance columns + `suppressed_by`) + JSON bundle + manifest (schemaVersion, counts, checksums) → share sheet. Round-trip test: exported CSV re-parsed and diffed against DB. *Proves: export architecture, raw/derived separation in output, schema versioning, offline completeness.*

**VS-3 · "Log what matters" — medications + symptoms, fully offline.**
Create MedicationRegimen (name/strength/schedule) → today's due list → taken/skip-with-reason AdherenceEvents → SymptomEntry quick-log (dictionary chips + severity slider) → both appear in a simple day timeline → both included in VS-2 export (sensitive-class export toggle honored). Airplane-mode demo mandatory. *Proves: EventRecord union, sensitive-class namespace, non-punitive logging UX, offline writes, RTL forms (this slice is the RTL stress case — Arabic symptom names, RTL sliders).*

**VS-4 · "Why is it saying that?" — baseline-lite + status + anatomy sheet.**
14-day median/MAD Baseline for `sleep.time_asleep` and `heart.rhr` → status chip vs personal band on detail screens ("below your typical range") → tap opens anatomy sheet: band values, sample count, provisional flag, contributing records (InputManifest), AlgorithmVersion string. First DerivedValue rows, append-only. *Proves: derivation pipeline, explainability, provisional honesty, I2/I5 invariants.* No LLM anywhere — template text, en+ar.

**VS-5 · "Arabic is not a locale file" — full AR/RTL pass over VS-1…VS-4.**
Complete Arabic strings for all shipped surfaces, RTL layout audit (mirrored navigation, correct chart chrome per blueprint §25.9: time axes LTR, chrome mirrored), Arabic-digit preference toggle, snapshot tests in `ar` + pseudo-locale in CI. *Proves: i18n is structural; catches the 20% of layouts that always break.*

---

## 7. Workstreams

| WS | Mission | Owns (paths) | Blocked by | Parallel with |
|---|---|---|---|---|
| WS-A Contracts & codegen | schemas, ontology, export schema, fixtures, `gen_types` | `packages/*`, `scripts/gen_types*` | AP-01 | everything after freeze |
| WS-B iOS platform | project bootstrap, GRDB, HK adapter, repositories | `apps/ios/{project.yml,Sources/{Storage,Platform,Generated}}` | WS-A freeze | WS-C |
| WS-C Android platform | gradle bootstrap, Room, HC adapter, repositories | `apps/android/{*.gradle.kts,…/{storage,platform,generated}}` | WS-A freeze | WS-B |
| WS-D iOS features | Home/Detail/Export/Logging screens + state models | `apps/ios/Sources/Features/**` | WS-B repos | WS-E |
| WS-E Android features | same, mirrored | `apps/android/…/features/**` | WS-C repos | WS-D |
| WS-F Export | export engine both platforms + schema tests | `Features/Export` + export core per platform, `packages/export-schemas` | WS-A, storage | WS-D/E others |
| WS-G Logging domain | meds/symptoms entities' UX + dictionaries | `Features/{Medications,Symptoms}` both | WS-A, storage | WS-F |
| WS-H Design & RTL | tokens, shared components (Card, Chart, StatusChip, StatefulContainer), RTL harness | `DesignSystem/` both platforms | AP-05/06 shells | all feature work |
| WS-I QA & CI | CI growth, conformance runners, device matrix, privacy lints | `.github/`, test targets, `packages/fixtures` (with WS-A) | AP-01 | continuous |
| WS-J Docs & ADR | ADRs, data-model doc, amendments of §12 | `docs/` | none | continuous |

Freeze discipline: WS-A publishes contracts v0.1 at M1; after that, contract changes require an ADR + regen + fixture update in the same PR. Feature workstreams never edit `packages/` directly.

---

## 8. Milestones

| M | Name | Contents | Exit criteria |
|---|---|---|---|
| M0 (wk 1) | Repo is real | AP-01: git, CI skeleton, ADR-0001..03, dormancy READMEs | `git log` exists; CI green on schema-lint job; both dormant areas labeled |
| M1 (wk 2–3) | Contracts v0.1 frozen | AP-02/03/04: all §4 schemas, ontology seed (~40 metrics), codegen emitting Swift+Kotlin, first fixtures | codegen deterministic (CI drift check); both type sets compile in isolation; fixtures validate against schemas; INVARIANTS.md reviewed |
| M2 (wk 4–6) | VS-1 on devices | AP-05..AP-10: buildable apps, adapters (sleep+HR), storage, Home card + detail | VS-1 demo on physical iPhone + Android; conformance fixtures pass identically on both; provenance visible in power mode |
| M3 (wk 7–9) | VS-2 + VS-3 | AP-13/14: export + meds/symptoms logging | round-trip export test green; airplane-mode logging demo; sensitive-class toggle honored in export |
| M4 (wk 10–12) | VS-4 + VS-5 + gates | baseline-lite, anatomy sheet, full AR pass; **KMP gate review; PRD v0.2; telemetry decision** | status chips truthful vs fixtures; AR snapshot suite green; ADR-0004 (KMP outcome) merged; PRD updated per §12.2 |

Cut-line policy: within a milestone, RTL and fixture coverage never slip; scope (e.g., second metric family) slips first.

---

## 9. Testing strategy

1. **Contract tests (WS-A):** every schema has valid/invalid example instances in `packages/contracts/examples/`; CI validates. Codegen output snapshot-tested.
2. **Conformance fixtures (the drift firewall):** identical suites both platforms — ingestion payload → expected canonical rows (Provenance included) → expected export bytes. Any divergence is a release blocker and a data point for the KMP gate.
3. **Domain unit tests:** unit conversion, day-attribution/timezone rules (DST fixtures: 23/25-hour days), dedup-lite rule, baseline math (golden numeric files, injected clock — no wall-clock in domain code).
4. **Adapter tests:** iOS HK adapter against HealthKit test store where feasible + recorded DTO fixtures; Android HC adapter with Robolectric + HC test client; permission-state matrix (granted/denied/partial/revoked) per adapter.
5. **Storage/migration:** DDL v1 soak test (create → insert fixtures → query plans asserted on indexes); migration framework tested from v1 forward starting at first schema change.
6. **Privacy validation:** lints — no health-value literals in log/analytics calls (allowlist on `events.yaml` property names); export module import-graph check (no network/entitlement imports); sensitive-class tables in separate namespace verified by test.
7. **UI:** snapshot tests dark+light × en+ar × 2 type sizes for every shipped screen; one UI-flow test per slice (log symptom; run export; open anatomy sheet).
8. **Export round-trip:** CSV re-parse diff (VS-2 acceptance) runs in CI against fixtures forever after.
9. **Manual device matrix (pre-release):** iPhone (current−1 OS), Pixel, Samsung (HC via Samsung Health path) — background-read behavior and permission flows.

---

## 10. Risk register

| # | Risk | Likelihood/Impact | Mitigation (owner) |
|---|---|---|---|
| R1 | Dual-native logic drift | M/H | Machine-readable contracts + conformance fixtures (WS-A/I); duplicated-logic budget; M4 KMP gate with pre-agreed criteria (§2.1) |
| R2 | Scaffold stays unbuildable while docs grow | H/H | M0/M2 exit criteria are *device demos*, not documents; AP-05/06 are the first coding packets after contracts |
| R3 | Contracts freeze too late → agents collide | M/H | M1 freeze is a hard gate; feature packets carry "blocked by M1" prerequisite |
| R4 | Health Connect background/permission surprises (OEM variance) | M/M | AP-08 includes a spike task on Samsung/Pixel; foreground-refresh fallback designed in from VS-1 (stale banner, not silent) |
| R5 | Scope gravity from the 10k-line blueprint | H/M | §1.4 rule: nothing outside VS-1..5; blueprint v2 explicitly demoted to reference library (§12.7) |
| R6 | RTL retrofitted instead of structural | M/H | VS-5 is a milestone-gated slice; AR snapshots in CI from M2 onward (not M4) for every new screen |
| R7 | Sync retrofit pain later | M/H | §2.4 schema reservations (ULID/updatedAt/tombstones/SyncCursor) enforced by schema review at M1 |
| R8 | Export becomes a settings-page afterthought | L/H | VS-2 is the second slice; round-trip test permanent in CI; Law 1 lint |
| R9 | Store health-data review friction | M/M | Wellness wording lint on user-facing strings; privacy declarations checklist drafted at M3 (docs/store-compliance.md) |
| R10 | Agent merge collisions in shared files (project.yml, gradle catalogs, string catalogs, DI wiring) | H/M | Registration patterns (per-feature files), packet ownership boundaries (§11 "owns" is exclusive), generated-file discipline |

---

## 11. Agent packets

Format: **AP-nn · name — prereqs · owns (exclusive write) · tasks · acceptance · avoid.** Read-only access to everything else. Packets marked ∥ can run in parallel once prereqs are met.

**AP-01 · Repo bootstrap** — prereqs: none · owns: repo root dotfiles, `.github/`, `docs/adr/ADR-0001..03`, dormancy READMEs (`backend/README.md`, `infra/README.md`) · tasks: git init + initial commit of untouched scaffold; `.gitignore`; LICENSE placeholder; CI with schema-validation + codegen-drift + lint job stubs; ADRs per §5; delete `scripts/tree.txt` or regenerate in CI · acceptance: CI green on empty jobs; ADRs merged; second commit shows only additive files · avoid: touching `apps/`, `packages/` content.

**AP-02 · Entity schemas + codegen** — prereqs: AP-01 · owns: `packages/contracts/entities/**`, `INVARIANTS.md`, `scripts/gen_types*` · tasks: author all §4 schemas (order §5 wave 1); build `gen_types.py` (JSON Schema → Swift Codable + Kotlin @Serializable, deterministic, with header "GENERATED — do not edit"); emit into both apps' `Generated/` dirs; CI drift check · acceptance: all schemas validate; example instances pass; generated Swift compiles via `swiftc -parse`, Kotlin via `kotlinc` (no app project needed yet) · avoid: inventing entities beyond §4; runtime YAML loading.

**AP-03 · Metric ontology seed ∥(AP-02 after provenance/metric_definition schemas)** — owns: `packages/metric-ontology/**` · tasks: registry schema; ~40 MVP metric ids across 8 families with units, kinds, en+ar names, casual/precise labels, chartHints; validation script · acceptance: registry validates; every VS-1..4 metric present (`sleep.time_asleep`, `sleep.time_in_bed`, `heart.rhr`, `heart.hr`, `activity.steps`, meds/symptom event metrics, baseline-derived ids); AR names reviewed by a human reviewer gate · avoid: seeding all 350 blueprint metrics now.

**AP-04 · Conformance fixtures ∥** — prereqs: AP-02/03 · owns: `packages/fixtures/**` · tasks: author `sleep_two_sources` (overlap dedup case), `hr_day`, `steps_phone_watch_overlap`, DST day, expected canonical rows + expected CSV/JSON export bytes; fixture README with authoring rules · acceptance: fixtures validate against schemas; expected exports conform to `export-schemas` · avoid: platform-specific encodings (dates as ISO-8601 UTC strings only).

**AP-05 · iOS project bootstrap ∥(AP-02)** — owns: `apps/ios/{project.yml,Package.swift,Sources/{Generated,Domain,Storage},Tests/}` · tasks: XcodeGen project (app + unit test + conformance test targets); GRDB dependency; DDL v1 migrations for §4 tables (incl. sync-ready fields); repositories (Sample/Event/Baseline/ExportJob); wire existing placeholder views into buildable app · acceptance: `xcodebuild test` green in CI (macOS runner); DB round-trip unit test; existing RootView renders · avoid: rewriting the existing Feature views' content; adding networking.

**AP-06 · Android project bootstrap ∥** — mirror of AP-05 · owns: `apps/android/**` build files, `storage/`, `generated/`, test targets · acceptance: `./gradlew test` + `assembleDebug` green in CI; Room schema exported to `schemas/` for migration testing · avoid: same as AP-05; no Hilt-vs-manual bikeshed — manual DI (small object graph, matches iOS environment approach; revisit at M4).

**AP-07 · iOS HealthKit adapter ∥(AP-05)** — owns: `apps/ios/Sources/Platform/Health/**` · tasks: implement port for sleepAnalysis + heartRate + restingHeartRate + stepCount: authorization bundle, anchored reads, DTO mapping per contract tables, PermissionState persistence · acceptance: adapter conformance kit (fake store + recorded fixtures) passes; permission matrix states render correct PermissionState · avoid: background delivery (M4+ spike), write paths.

**AP-08 · Android Health Connect adapter ∥(AP-06)** — mirror, incl. HC availability states (not installed / needs update) and a short Samsung/Pixel spike note in `docs/spikes/hc-behavior.md` · acceptance: Robolectric suite green; availability states surfaced as typed results · avoid: background reads in MVP; Samsung-direct SDK.

**AP-09 · iOS ingestion pipeline + dedup-lite ∥(AP-07, AP-04)** — owns: `apps/ios/Sources/Domain/Ingestion/**` · tasks: DTO→canonical normalization (units, timezone/day attribution), sleep-overlap dedup rule + ReconciliationDecision journal, idempotent re-ingest via `platformRecordId` · acceptance: conformance fixtures pass byte-identically vs `expected/`; re-running ingestion is a no-op · avoid: generalizing the dedup rule engine beyond the one rule.

**AP-10 · Android ingestion pipeline + dedup-lite ∥(AP-08, AP-04)** — mirror of AP-09 · acceptance: same fixtures, identical canonical output to iOS (CI compares both platforms' serialized results — this is the drift firewall's first live wire).

**AP-11 · Home summary + metric detail, iOS ∥(AP-09)** — owns: `apps/ios/Sources/Features/{Home,Metrics}/**` · tasks: replace placeholders with `HomeState`/`MetricDetailState` reading repositories; sleep card + one-sentence template (en+ar strings); 30-day chart; lineage row under power policy; `CustomizationProfile` depth toggle in Settings · acceptance: VS-1 demo script passes; snapshot tests (dark/light × en/ar); both policies render same values (fixture-asserted) · avoid: chart library exploration beyond Swift Charts; more than 2 metrics.

**AP-12 · Home summary + metric detail, Android ∥(AP-10)** — mirror (Compose, Vico or Canvas — pick in-packet with a 1-page note) · acceptance: mirror of AP-11.

**AP-13 · Export engine, both platforms ∥(AP-09/10)** — owns: `Features/Export/**` both apps + `packages/export-schemas` refinements (with WS-A review) · tasks: ExportJob runner, CSV writer per `csv_columns.yaml`, JSON bundle writer, manifest+checksums, share-sheet delivery, round-trip test · acceptance: VS-2 criteria; exported files byte-identical across platforms for fixture data; no network/entitlement imports (lint) · avoid: PDF, scheduling, encryption options.

**AP-14 · Meds + symptoms logging, both platforms ∥(AP-05/06)** — owns: `Features/{Medications,Symptoms}/**` both apps + symptom dictionary seed in ontology (with WS-A review) · tasks: regimen CRUD, due list, taken/skip-with-reason, symptom quick-log with severity + recents chips, day timeline rows, sensitive-namespace storage, export inclusion toggle · acceptance: VS-3 criteria incl. airplane-mode demo + AR forms; non-punitive review (no red/guilt states) · avoid: reminders/notifications (post-MVP), dosing-adjacent copy of any kind.

**AP-15 · RTL/l10n harness ∥(AP-11/12)** — owns: `docs/rtl-checklist.md`, string catalogs structure, snapshot-test harness config both platforms · tasks: AR string catalogs for shipped surfaces; pseudo-locale + AR snapshot lanes in CI; RTL audit fixes list filed as issues · acceptance: VS-5 criteria; CI fails on missing AR strings for shipped screens · avoid: translating unshipped surfaces.

**Parallelism summary:** after M1 freeze, up to 8 packets run concurrently (AP-05∥06, then 07∥08, then 09∥10∥13-prep∥14, then 11∥12∥15). Collision-prone shared files (project.yml, gradle catalogs, string catalogs) are owned by exactly one packet at a time per §11 ownership; features register rather than edit shared wiring.

---

## 12. Targeted file amendments

Only these; everything else stands. (Listed as edits for the owner to apply — or say the word and I'll apply them.)

1. **`CLAUDE.md`** — append 4 lines under "Working mode": contracts are machine-readable (JSON Schema/YAML) and consumed only via `scripts/gen_types.py` output; never hand-edit `Generated/`; both platforms must pass `packages/fixtures/` conformance suites for any shared behavior; canonical entity names per `packages/contracts/INVARIANTS.md` (blueprint rename map applies).
2. **`docs/PRD.md`** — add a "Scope decisions (v0.1 → v0.2)" block: MVP is local-first with **no backend and no remote analytics**; sync is out of scope but schema is sync-ready (ULID/updatedAt/tombstones); MVP metric scope = sleep, heart, activity + meds/symptoms logging; entity naming aligned to blueprint (IntervalRecord/DerivedValue/EventRecord/ExportJob).
3. **`docs/architecture-decision.md`** — append "Decision record (2026-07-10)": Swift+Kotlin committed; Flutter path closed (folder never created); KMP re-evaluation gate at M4 with §2.1 criteria; link ADR-0001.
4. **`docs/scaffold-notes.md`** — correct the `apps/flutter` claim (does not exist; path formally closed); replace "immediate next implementation docs" list with a pointer to this package's §5.
5. **`packages/contracts/src/health_contracts.md`** — prepend: "Superseded as contract by `packages/contracts/entities/*.schema.json` (see EXECUTION_PLAN §4). Kept as historical seed. Rename map: NormalizedMeasurement→IntervalRecord, DerivedMetric→DerivedValue, UserLogEntry→EventRecord payloads, ExportBundle→ExportJob."
6. **App shells** — rename the `Metrics` tab/feature to `Body` on both platforms while the rename is one commit (aligns with blueprint IA; avoids a later churny rename across tests/analytics).
7. **`BADAN_MASTER_BLUEPRINT_V2.md`** — one front-matter paragraph: "Repo reality (2026-07): native-first with contracts-level sharing per ADR-0001 supersedes §33/§47's KMP-shared-core layout until the M4 gate; §47 monorepo paths map to the actual `packages/`+`apps/` layout — subsystem specs remain authoritative as reference."
8. **`scripts/next_steps.md`** — replace body with: "Superseded by `docs/EXECUTION_PLAN.md` §5/§11." (keeps the file as a signpost).
9. **`backend/README.md` + `infra/README.md`** — add the dormancy sentence from §2.3.
10. **`README.md`** — update "First build target" to name VS-1/VS-2 and link this package.

— End of package —
