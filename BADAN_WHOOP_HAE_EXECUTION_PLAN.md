# BADAN WHOOP + Health Auto Export Execution Plan

**Status:** v1.1 — 2026-07-20. Planning document of record for BADAN's full capability expansion: WHOOP-equivalent intelligence, Health Auto Export–class export/automation, and (v1.1) the seven domain research programs — hydration, cycle tracking, pregnancy, lab results, live exercise, third-party accessories, and ambient surfaces. Together these define the target: **the definitive user-owned health repository — broader than any single competitor, honest where they overclaim, exportable where they lock in.**
**Inputs:** `docs/whoop.md`, `docs/HAE.md`, and (v1.1, read in full) `docs/BADAN_HYDRATION_WATER_RESEARCH.md`, `docs/BADAN_PERIOD_TRACKER_RESEARCH.md`, `docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md`, `docs/BADAN_LAB_RESULTS_NOTEBOOK_RESEARCH.md`, `docs/BADAN_LIVE_EXERCISE_MONITOR_RESEARCH.md`, `docs/BADAN_THIRD_PARTY_ACCESSORIES_RESEARCH.md`, `docs/BADAN Widgets, Complications, and Ambient Health R.md`; plus `BADAN_MASTER_BLUEPRINT.md` v2.0, `docs/EXECUTION_PLAN.md` v1.1, `docs/PRD.md` v0.1, `docs/architecture.md`, `docs/data-model.md`, `docs/MONETIZATION.md`, `CLAUDE.md`, `packages/contracts/INVARIANTS.md`, ADR-0001…ADR-0008, and direct inspection of `apps/ios`, `apps/android`, `packages/`, `backend/`, `infra/`.
**v1.1 change summary:** seven new epics (EPIC-38…44), seven domain capability inventories (§7A), ~20 new canonical entities (§9.14–9.19), a BLE/GATT accessory framework, a workout operating system that revises two v1.0 verdicts (live workout surfaces, watch timing), and nine new approval decisions (A17–A25). All v1.0 content stands except where an explicit **[v1.1 supersession]** note appears.
**Audience:** founder, engineers, and coding agents. This document converts the two research inputs into BADAN-specific, repository-grounded execution work. Where it conflicts with the research documents, BADAN's invariants (I1–I8) and ADRs govern.

---

## 1. Executive decision summary

### 1.1 Recommended high-level strategy

Build in this order: **(1) ingestion + provenance foundation, (2) Health Auto Export–class export and automation, (3) WHOOP-equivalent intelligence, (4) vendor ecosystem + AI.** Not the reverse.

The reasoning is mechanical, not philosophical:

- **Every WHOOP-equivalent score is starved today.** The ontology defines 44 metrics; `HealthKitAdapter.swift` reads exactly 4 HealthKit types (sleep, heart rate, resting HR, steps). There is no HRV, no respiratory rate, no SpO2, no temperature, no workouts, no VO2 max, no body mass in the iOS ingest path. A Recovery-equivalent score weighted ~70% on HRV (`whoop.md` §5) cannot be computed from data BADAN does not receive. `docs/MONETIZATION.md` §2 already identified this (PERF-181) as "the whole foundation" — this plan makes it Phase 0.
- **Export is BADAN's cheapest strategic win.** The export subsystem is already the most mature differentiator in the repo: frozen 24-column CSV contract, separated JSON bundle, manifests with checksums, sensitive-export encryption (iOS), formula-injection hardening, offline-only lint posture. Reaching HAE-class capability is mostly *additive* (templates, scheduling honesty, destinations, GPX, delta export) on top of working code — whereas WHOOP-class scoring requires months of new data accumulation before it is honest to ship.
- **Scores need history before they need code.** Baselines require weeks of real ingested data per user. Shipping ingestion widening + background sync *first* means that by the time the Readiness v2 / Effort engines land (Phase 2), early users already have the 14–60 day histories those engines need for non-provisional output.
- **WHOOP's moat is not raw data — it is opaque scoring** (`whoop.md` §13). BADAN's counter-position is transparent, published, versioned formulas over multi-device data with first-class export. Both research documents independently converge on the same strategy: match the daily loop, exceed on explainability/portability/AI, skip the regulated tier.

### 1.2 Major implementation bets

| Bet | What it is | Why it is safe to bet on |
|---|---|---|
| B1 | **Reuse the existing derivation architecture for all WHOOP-like scores.** No new "snapshot" tables — Recovery/Strain/Sleep-debt outputs are `DerivedValue` rows (append-only, I2) with `AlgorithmVersion` + `InputManifest`, personal bands are `Baseline` rows. | The pipeline exists, is tested, and already computes a readiness composite and sleep efficiency. Extending it preserves I1–I5 for free. |
| B2 | **The export domain grows from `ExportJob`, not around it.** `ExportTemplate`, `ExportDestination`, `ExportRun` extend the existing `export_jobs` machinery and the `ExportRunner` orchestrator. | `ExportRunner` already handles scope, manifests, checksums, encryption, cleanup. Templates/destinations are configuration layers over it. |
| B3 | **Three-tier scheduling honesty, labeled in the UI** (opportunistic background / Shortcuts time-of-day / manual), per `HAE.md` §6 — never the word "cron," never a promised wall-clock time on-device. | It is the only architecture Apple's platform permits; HAE's community complaints show what happens when apps imply more. |
| B4 | **Local-first survives this plan.** Phases 0–3 require zero backend (ADR-0002 intact). The backend activates only for vendor OAuth (Garmin/Oura) and optional server-side true scheduling, both Phase 4, both behind an explicit ADR supersession decision. | Every HAE capability except cloud-drive OAuth relay and every Phase 0–2 WHOOP capability is computable on-device from HealthKit/Health Connect. |
| B5 | **Android stays in lockstep at the contracts level, not the calendar level.** iOS leads runnable delivery per ADR-0006; Android parity is enforced by shared fixtures per phase gate, with two named parity debts (export encryption, background sync) paid inside Phase 0–1. | Matches the repo's existing working mode; avoids the "port later = second-class" trap by gating releases on fixture parity, not simultaneous feature builds. |

### 1.3 Biggest opportunities

1. **Out-export everyone.** No competitor (WHOOP, Oura, Bevel, HAE itself) ships versioned schemas, per-record provenance, raw/derived separation, *and* encrypted sensitive bundles. BADAN is already 60% there.
2. **The transparent score.** A Readiness/Effort score whose formula, inputs, and confidence are one tap away (the existing anatomy-sheet pattern) converts WHOOP's black-box prestige into BADAN's trust asset.
3. **Sleep intelligence is nearly free.** Sleep is BADAN's best-covered family (sessions + stages already ingested and deduped). Sleep need/debt/consistency is high-value analytics over data already in `sessions`/`session_stages`.
4. **Strength PR tracking ships before WHOOP's.** `whoop.md` §5 documents WHOOP's own acknowledged gap; BADAN has `workout_entries` and a logging UI to extend.
5. **AI coach as a Phase-4 leapfrog** on BADAN's own normalized longitudinal store, multilingual (Arabic-first advantage), with editable memory — WHOOP cannot match the language surface and will not match the transparency.

### 1.4 Biggest constraints

1. **iOS background execution is opportunistic, never guaranteed** — HealthKit background delivery is throttled/coalesced, silently disabled after 3 missed completion handlers, and the store is unreadable while locked (`HAE.md` §4, §6). All automation UX must be designed around this.
2. **Data-history cold start.** Score credibility requires weeks of per-user history; every score ships with the existing `provisional` flag semantics until thresholds are met.
3. **Vendor APIs need a backend.** Garmin (OAuth2 PKCE + developer-program approval) and Oura cannot be integrated client-only without embedding secrets; this forces the ADR-0002 supersession decision before Phase 4.
4. **Fitbit API migration risk** — legacy Web API decommissioned Sept 2026 (`whoop.md` §7); any Fitbit work targets the new Google Health API only.
5. **Wellness-safe ceiling.** No BP estimation, no diagnosis framing, no "biological age" number sold as fact (`docs/MONETIZATION.md` §4). This excludes ~15% of WHOOP's surface permanently, by design.
6. **Single-developer throughput.** The phasing assumes serialized platform work with fixture-enforced parity, not parallel teams.

### 1.5 Top decisions requiring founder/technical approval

Full log in §25. The five that gate the most work:

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| A1 | Widen the frozen CSV export contract (24 → 26 columns: `granularity`, `aggregation_method`) as schema v1.0 | Approve — additive, versioned bump | EPIC-08 and everything downstream of export |
| A2 | Add `com.apple.developer.healthkit.background-delivery` entitlement + BGTaskScheduler (changes App Store privacy story) | Approve | EPIC-04, all automation tiers |
| A3 | Score naming + publication policy (publish formulas in-app and in `docs/`) | Approve "Readiness / Effort / Sleep score", formulas published | EPIC-25, 26; App Review posture |
| A4 | Backend activation for vendor OAuth (supersedes ADR-0002) | Defer decision to end of Phase 2; plan assumes **yes, minimal broker** in Phase 4 | EPIC-37 |
| A5 | Healthspan-equivalent ("Vitality Trend") — build at all? | Defer to Phase 5; only under MONETIZATION §4 conditions | EPIC-36 |

### 1.6 Recommended order of execution

**Phase 0** ingestion widening + background sync + Android parity debts → **Phase 1** export domain (templates, quick export, GPX, destinations v1, scheduling honesty, Shortcuts, export health dashboard) → **Phase 2** sleep suite + Readiness v2 + Effort + Health Monitor → **Phase 3** REST destination, delta export, journal correlations, reports, widgets, notifications → **Phase 4** vendor integrations + AI coach + cloud drives → **Phase 5** Vitality Trend, MQTT/HA evaluation, watch surfaces beyond widgets. Full roadmap in §19; first 10 actions in §28.

### 1.7 v1.1 addendum — folding in the seven domain programs

The seven new research documents extend BADAN from "scores + export" into a **whole-life health repository**: fluids, cycles, pregnancies, lab records, live workouts, every connectable device, and every ambient surface. The v1.0 sequencing logic survives intact — foundation → export → intelligence — but three strategic updates follow from the new material:

1. **The repository thesis gets four new pillars.** The lab notebook ("a notebook, not a chart"), the cycle module (phase-conditioned baselines closing the documented WHOOP luteal false-alarm gap), the workout OS (strength as a flagship system-of-record neither HealthKit nor Health Connect natively models), and the device ecosystem (the most honest provenance/reconciliation layer in the category) are each **differentiators no competitor combines**. They slot into Phases 1–4 without displacing v1.0's P0 work because they *consume* the same foundation (canonical store, provenance, background substrate, export contracts).
2. **Two v1.0 verdicts are revised.** *(a)* Live intra-workout surfaces were deferred pending a watch app (§5.2/§5.6); the live-exercise research shows a phone-first live path (GPS + BLE HR + manual strength) is viable now with honest degradation, and makes the **watch app a Phase-4 deliverable instead of Phase 5** (EPIC-42, decision A22). *(b)* EPIC-30's "cycle overlay" is superseded by a full cycle module (EPIC-39) whose defining feature — phase-conditioned baselines inside `BaselineEngine` — lands with the Phase-2 baseline work, not after it.
3. **Sensitivity governance becomes a program of its own.** Pregnancy, cycle, labs, and glucose each carry clinical/legal sign-off gates that engineering cannot satisfy alone (A18, A21, A25). The plan treats these as scheduled review dependencies with named owners, not copy polish. A standing **clinical advisor + GCC/Oman legal review** relationship is now on the critical path for Phases 2–4.

The v1.1 opportunity statement, plainly: WHOOP owns recovery, HAE owns export, Flo owns cycles, Strong owns strength, Apple owns the platform — **nobody owns the honest, bilingual, exportable union of all of them.** That union is exactly what BADAN's existing invariants (I1–I8) were designed to carry.

---

## 2. Inputs reviewed and planning assumptions

### 2.1 Research inputs read in full

- **`docs/whoop.md`** — "Reproducing WHOOP Features Without WHOOP Hardware" (198 lines, 27 references). Feature inventory across recovery, strain, sleep, stress, health monitor, healthspan, workouts, journal, AI, MG-tier clinical features; per-feature feasibility verdicts (Exact / Close Approximation / Partial / Not realistic); platform capability map; recommended 4-phase roadmap.
- **`docs/HAE.md`** — "Implementing Health Auto Export–Class Export and Automation" (280 lines, 22 references). HAE feature/tier inventory; iOS framework constraint map (observer queries, background delivery failure modes, locked-store behavior); export format architecture (tagged-union schema finding); three-tier automation model; destination matrix; match/improve/skip verdicts.

### 2.2 BADAN planning documents reviewed

- `BADAN_MASTER_BLUEPRINT.md` v2.0 — structure surveyed in full; deep-read of §20 (export product contract incl. SQLite-bundle and manifest specs), §24 (widgets/watch/ambient snapshot pattern incl. target file layout `ios/BadanWidgets/`), plus the §41 roadmap, §52 schema, §56 export-engine, §59 notification sections as referenced by `docs/EXECUTION_PLAN.md`.
- `docs/EXECUTION_PLAN.md` v1.1 — read in full (governing decisions D-1…D-11, vertical slices VS-1…5, packets AP-01…16, milestone history M0–M4).
- `docs/PRD.md`, `docs/architecture.md`, `docs/data-model.md`, `docs/project_description.md`, `docs/MONETIZATION.md`, `CLAUDE.md` — read in full.
- ADR-0001…ADR-0008 — titles and load-bearing content (native-first; no backend; sync-ready; sensitive namespace; raw SQLite; iOS-first flagship; Android framework SQLite; export encryption).

### 2.3 Repository areas inspected

- `apps/ios/Sources/**` — every folder: App, Core, Domain (incl. Ingestion, Derivation), Ontology, Platform/Health, Platform/Notifications, Storage (incl. Migrations DDL and all repositories), Export (all four files), DesignSystem, Features (all screens), Resources. `apps/ios/App/` config: entitlements, Info.plist, PrivacyInfo.xcprivacy, project.yml.
- `apps/ios/Tests/**` — all 23 test files.
- `apps/android/app/src/main/java/net/albayyan/badan/**` — all packages; AndroidManifest; gradle config; the 3 test files.
- `packages/` — metric-ontology registry (44 metrics), contracts (INVARIANTS, insight templates, symptom dictionary), export-schemas (csv_columns.json).
- `backend/`, `infra/` — confirmed dormant (READMEs + empty dirs, per ADR-0002).

### 2.4 Planning assumptions and known uncertainties

1. **No `packages/fixtures/`, no codegen pipeline exists yet** despite `docs/EXECUTION_PLAN.md` Wave-1 describing them; contracts are JSON + markdown, consumed by hand-written parallel Swift/Kotlin. This plan therefore specifies *fixture additions* as new work, not extensions.
2. **`event_records` table does not exist** — the execution plan's EventRecord union was implemented instead as concrete tables (`workout_entries`, `nutrition_entries`, `note_entries`, sensitive tables). This plan follows repo reality (concrete tables) and does not resurrect the union.
3. **A readiness composite already exists** in the derivation layer (per `docs/architecture.md` §5: "sleep efficiency, a readiness score"). This plan treats Readiness v2 as an upgrade with a published formula and wider inputs, not a greenfield score.
4. **No CI details assumed** beyond `.github/workflows/ci.yml` existing; test-gate specifics in §23 are written as target state.
5. **Apple/Google platform behavior** (background-delivery throttling, Health Connect 30-day default read window, Shortcuts unlock requirement) is taken from the two research docs' cited platform documentation; each is re-verified during the owning epic's spike task before dependent UX copy is finalized.
6. **Team size** is assumed to be one founder-engineer plus coding agents; estimates are expressed in relative complexity (S/M/L/XL), not weeks.

### 2.5 v1.1 research inputs read in full

- **`docs/BADAN_HYDRATION_WATER_RESEARCH.md`** (238 lines) — local-first fluid-intake ledger; 17-row feature catalog; 9 goal models; 10 reminder types with a `ReminderPolicyEngine`; 14-entity data model; HYD-001…016 backlog.
- **`docs/BADAN_PERIOD_TRACKER_RESEARCH.md`** (467 lines) — cycle logging/prediction/anomaly system; 11-input catalog; 5-tier prediction stack; 7-class anomaly matrix; phase-as-covariate architecture; 11-entity model; CYCLE-01…14 backlog.
- **`docs/BADAN_PREGNANCY_CALENDAR_RESEARCH.md`** (303 lines) — seven-mode journey model (TTC→postpartum incl. loss); four-source due-date provenance; trauma-aware loss design; 12-entity model; PREG-01…12 backlog.
- **`docs/BADAN_LAB_RESULTS_NOTEBOOK_RESEARCH.md`** (1,605 lines, 41 sections) — provenance-first lab record system; 20-category analyte ontology; 6 ingestion routes incl. OCR review queues and FHIR; 25-entity model; LAB-01…18 backlog.
- **`docs/BADAN_LIVE_EXERCISE_MONITOR_RESEARCH.md`** (1,526 lines) — workout operating system; 28-modality taxonomy; full lifecycle state machine; ~30-metric live ontology; Apple/Android runtime capability matrices; strength SOR; 11 epic groups.
- **`docs/BADAN_THIRD_PARTY_ACCESSORIES_RESEARCH.md`** (545 lines) — 11-route integration-depth framework; full device taxonomy (watches, rings, straps, scales, cuffs, oximeters, thermometers, CGMs, machines, mats); GATT service reference; 31-entity device/provenance model; ACC-001…015 backlog.
- **`docs/BADAN Widgets, Complications, and Ambient Health R.md`** (1,186 lines) — ~55 ambient surfaces across WidgetKit/lock screen/complications/Smart Stack/Live Activities/Glance/Wear tiles; widget catalog; App Intents families; privacy-mode system; W-01…12 backlog. *(Does not reference blueprint §24's WGT-I-01…16 — reconciliation is EPIC-44's first task.)*

**Uncertainty added in v1.1:** several vendor/platform claims are explicitly verify-at-build (Huawei/Xiaomi integration paths, Ultrahuman/RingConn/Galaxy Ring maturity, Libre/Lingo API terms, Zwift/TrainingPeaks terms, exact Garmin Health Connect exclusions, Health Connect Medical Records API maturity). Each owning epic carries a verification spike task.

---

## 3. Current repository assessment

| Area | Current implementation | Relevant files | Readiness | Gap | Recommended action |
|---|---|---|---|---|---|
| Health data ingestion (iOS) | HealthKit via `HKAnchoredObjectQuery` (HR, RHR, sleep) + `HKStatisticsCollectionQuery` (steps). 90-day backfill. Anchors committed only after write-txn success (DATA-08). | `apps/ios/Sources/Platform/Health/HealthKitAdapter.swift`, `HealthStorePort.swift`, `Domain/Ingestion/IngestionPipeline.swift` | **Solid pattern, tiny surface** | Only 4 of 44 ontology metrics ingested; no HRV/RR/SpO2/temp/VO2/energy/distance/body/workouts/routes | EPIC-01 (widen types), EPIC-03 (workouts+routes) |
| Health data ingestion (Android) | Health Connect paged `readRecords` for 9 record types incl. HRV-RMSSD, RR, SpO2 | `apps/android/.../platform/health/HealthConnectAdapter.kt` | Ahead of iOS in breadth | No workouts/routes; no changes-token incremental path equivalent hardening; 30-day HC history honesty not surfaced | EPIC-02, EPIC-03 |
| Data model | Canonical entities + embedded provenance (I1), append-only derivation (I2), reversible dedup (I3), sensitive namespace (I7) | `apps/ios/Sources/Domain/*.swift`, `docs/data-model.md` | **Strong** | No export template/destination/run entities; no journal/context-tag entity; no cycle context; no route storage | §9 extensions; EPIC-09, 12, 29, 30 |
| Sync (device↔store) | Foreground-only: launch `.task` + `scenePhase == .active`, debounced (`SyncDebounce`) | `apps/ios/Sources/App/AppEnvironment.swift` | Works but stale-prone | No background delivery, no `HKObserverQuery`, no `BGTaskScheduler`; Android has no WorkManager | EPIC-04 (iOS), EPIC-05 (Android) |
| Local persistence | Two raw-SQLite files (`badan.db`, `badan_sensitive.db`), forward-only migrations v3/v2, sync-ready columns everywhere | `apps/ios/Sources/Storage/{Database,Migrations}.swift`, Android `storage/Schema.kt` | **Strong** | New tables needed for templates/destinations/runs/routes/journal; migration v4 | §9; EPIC-09 |
| Device integrations | HealthKit + Health Connect only; `Source.type=vendor` reserved, unused | `Domain/Sources.swift` | Foundation only | No Garmin/Oura/Polar/Fitbit; no backend to hold OAuth | EPIC-37 (Phase 4, gated on A4) |
| Exports | CSV (24-col frozen contract) + JSON bundle + manifest/checksums; offline-only; sensitive-export AES-GCM encryption (iOS); share-sheet delivery; job history in `export_jobs` | `apps/ios/Sources/Export/{CSVWriter,JSONBundleWriter,ExportRunner,ExportEncryption}.swift`, `packages/export-schemas/` | **Best-in-repo** | No templates/presets, no scheduling, no destinations beyond share sheet, no GPX, no delta export, no aggregation control, Android lacks encryption | EPIC-06, 08–18 |
| Background work | None on iOS beyond opportunistic WAL maintenance on `scenePhase == .background`; none on Android | `Storage/Database.swift` (`performBackgroundMaintenance`) | Absent | Entire automation substrate missing | EPIC-04, 05, 15 |
| Dashboards | Home (casual/power variants, readiness hero, module cards), Body browser, Timeline, Insights | `Features/Home/HomeScreen.swift`, `Features/Body/*` | Good shell | No WHOOP-style daily loop (score trio + trend), no reports | EPIC-25–27, 31 |
| Charts | Custom `MetricChart`/`MetricSparkline` + AX descriptors | `DesignSystem/Components/MetricChart.swift` | Adequate | Stage hypnogram, zone-time bars, route map previews needed | inside owning epics |
| Logging | Meds (regimens/adherence/reminders), symptoms, workouts, nutrition, notes, water/weight quick-log | `Features/{Medication,Symptom,WorkoutNutrition,LogHub}/*`, `Storage/Repositories/LoggingRepository.swift` | **Strong** | No behavior journal (caffeine/alcohol/etc. tags), no strength sets/reps, no PR detection | EPIC-28, 29 |
| AI / insights | Deterministic template engine, 13 wellness-safe en+ar templates, evidence refs | `Domain/Derivation/InsightEngine.swift`, `packages/contracts/insights/templates.json` | Good foundation | No correlation engine, no LLM layer, no reports | EPIC-29, 31, 35 |
| Settings | 7-category settings incl. goals, notifications, privacy, backup/restore, diagnostics | `Features/Settings/*` (13 files) | Good | No export/automation settings surface, no per-score customization | inside owning epics |
| Permissions | `PermissionState` persisted; staged request; read-only posture (`NSHealthShareUsageDescription` only) | `Domain/Sources.swift`, `App/Info.plist` | Good | Usage string names only 4 types; no per-family consent explainers for new sensitive types (routes, cycle) | EPIC-01/03 tasks; §17 |
| Widgets / watch | None (no widget target, no App Intents, no watchOS) | — (confirmed absent) | Absent | Blueprint §24 specifies full target layout, unbuilt | EPIC-19 (Intents), EPIC-33 (widgets); watch Phase 5 |
| Testing | 23 iOS XCTest files (pipeline, dedup, migration, export, encryption, honesty, notifications, a11y-adjacent); 3 Android tests; no shared fixture suite | `apps/ios/Tests/*`, `apps/android/app/src/test/*` | Good iOS depth | No conformance fixtures pack, thin Android coverage, no export-contract goldens | §23; per-epic test tasks |
| Observability | `PerformanceLog` OSLog signposts; Diagnostics screen (health-data-free report) | `App/PerformanceLog.swift`, `Features/Settings/DiagnosticsScreen.swift` | Minimal, privacy-correct | No export/sync/background success metrics, no automation run log | EPIC-16; §24 |
| Compliance / privacy | Privacy manifest (empty collected-data — honest), sensitive-DB purge, wellness language discipline, sample-data honesty tests | `App/PrivacyInfo.xcprivacy`, `docs/PRIVACY_POLICY.md`, tests | **Strong** | New permission families (routes, background) change the story; Android Data Safety not yet exercised for new types | §17 tasks in each ingestion epic |

**Summary judgment:** BADAN's foundation quality is high and unusually honest; the gaps are *breadth* (ingestion surface) and *ambient capability* (background, widgets, automation), not architecture. Nothing in either research document requires reworking the core; nearly everything lands as additive modules governed by existing invariants.

---

## 4. Strategic principles and decision rules

These translate `CLAUDE.md`, the invariants, and the research findings into rules an engineer or agent can apply without asking:

1. **Raw data is never paywalled.** Every capability in this plan is classified free/premium against `docs/MONETIZATION.md` §1: answers to "what did my body do?" are free (all raw views, all export formats, all destinations that move the user's own data); answers to "what should I make of it?" may be premium (trend decomposition, correlation narratives, deepened score anatomy). Export scheduling *convenience* is a legitimate premium candidate; export itself never is.
2. **Provenance is mandatory (I1).** Every new ingestion path (new HK/HC types, workouts, routes, future vendors) stamps the full embedded provenance struct. A route point without a `sourceId` is a bug, not a shortcut. Vendor-originated rows use `ingestionPath=vendor` (already reserved).
3. **One data model, two altitudes.** No WHOOP-style surface gets its own query path. Casual home shows the score + one sentence; power mode shows the same score's anatomy (inputs, weights, versions, confidence) via the existing `InputManifest`/anatomy-sheet pattern. Fixtures assert both altitudes render identical values (D-5).
4. **Automatic value before manual logging.** Phase ordering inside every epic: ingested/derived value first, manual augmentation second. The journal (EPIC-29) is deliberately Phase 3 — correlations against *already-flowing* scores, not a data-entry chore shipped early.
5. **Export is a flagship capability.** Export work is never rescheduled below score work in a phase conflict; the Export Center is a primary surface (Body → Tools today; §16 elevates it), and every new entity added by this plan must define its export representation *in the same PR* that creates it (§9 includes one per entity).
6. **Cross-platform parity is architectural.** A capability "exists" when both platforms pass its shared fixture. iOS may ship first per ADR-0006, but a phase does not *exit* (§19 gates) with a parity debt unlisted. The two standing debts (Android export encryption, Android background sync) are scheduled work (EPIC-05, 06), not footnotes.
7. **Normalize without erasing source truth.** Cross-device values are reconciled by the existing source-priority + dedup-journal machinery — never averaged across vendors. VO2 max and HRV are displayed as per-source trends with methodology labels; blending across algorithms is prohibited (`whoop.md` §5 VO2 finding).
8. **Scores must be explainable and wellness-safe.** Every derived score ships with: published formula (in-app anatomy sheet + `docs/algorithms/`), `AlgorithmVersion` row, input manifest, confidence/provisional flag, and wellness-safe copy ("your body may welcome a gentler day" — never "do not train," never diagnosis). The wellness-language lint (D-11) applies to all new strings.
9. **No false precision.** Directional bands and trends over decimal-precision absolutes wherever the underlying sensor/algorithm varies by device: temperature deviation (not absolute skin temp), VO2 trend (not a blended number), sleep-need range (not a fake-exact minutes target). Sensor-quality labeling (high/medium/low per source) is a required feature of the Health Monitor (EPIC-27), not a nice-to-have.
10. **Scheduling honesty is a product feature.** Every automation surface labels its reliability tier: "Best-effort background," "Runs via Shortcuts (device must be unlocked)," "Manual." The words "cron," "guaranteed," "every day at" never appear un-caveated on-device. Server-side true scheduling is the only place wall-clock promises are allowed, and only after A4.
11. **Sensitive classes gate independently.** Routes (location), cycle, ECG-class clinical pass-throughs, mood/state — each gets its own consent toggle and its own export opt-in, extending the existing `sensitiveClass` + `includeSensitive` machinery rather than a blanket switch (`HAE.md` §12).
12. **Backend minimalism.** Any capability that *can* be on-device *is* on-device. The backend, when activated (A4), holds only: vendor OAuth broker, optional push-assisted scheduling, optional cross-device entitlement. It never becomes the computation home for scores (they stay on-device), and it never stores raw health data in Phase 4 without a further explicit decision.

---

## 5. Capability inventory from WHOOP research

Parity targets: **Match** (equivalent capability), **Improve** (BADAN does it better), **Approximate** (concept reproduced, formula BADAN's own), **Defer** (later phase), **Reject** (deliberately not built). "Current BADAN status" reflects the inspected repo, not aspiration.

### 5.1 Recovery / readiness

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Recovery Score (HRV+RHR+RR+sleep composite) | Readiness composite exists in derivation layer; inputs limited to HR/RHR/sleep (no HRV/RR ingested) | Readiness v2: published weighted composite over overnight HRV, RHR, respiratory rate, sleep score; personal-baseline z-positions, not population norms (EPIC-25) | **Approximate + Improve** (transparency) | HK/HC HRV (SDNN/RMSSD), RHR, RR, sleep sessions | L | P0 (Phase 2) |
| Recovery color banding (green/yellow/red) | Amber-only calm palette convention exists | Position-vs-personal-band chips (existing pattern); no red/green moralizing — DesignSystem rule retained | Improve | derived | S | P0 |
| Baseline calibration period w/ progress UI | `Baseline.provisional` until n≥7 exists | Calibration surface: "day 9 of 14" progress, confidence copy (EPIC-23) | Match | local | M | P1 |
| Morning readiness delivery | None (no notifications for scores) | Morning summary notification once score computed, opt-in (EPIC-32) | Match | local | M | P1 |

### 5.2 Strain / training load

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Strain score (0–21 log scale, day-level) | Nothing | "Effort" score: BADAN-designed log-curve over time-in-HR-zone vs user max HR; formula published (EPIC-26) | **Approximate** | continuous HR (HK/HC), user HR max | L | P0 (Phase 2) |
| Strain Coach (target strain from recovery) | Nothing | Effort guidance range derived from Readiness ("a gentler range today: …"), wellness-safe (EPIC-26) | Approximate | derived | M | P1 |
| Cardio vs muscular load split | Nothing | Cardio load Phase 2; muscular load approximated from strength logging volume Phase 3 (EPIC-28) | Approximate | HR + strength logs | L | P2 |
| Live intra-workout strain ticker | Nothing; no watch app | Defer to watch surface phase; iPhone-only live view has little value | Defer | live HR | XL | P3 |
| HR zones + zone-time views | Nothing | Zone-time bars on workout detail + day view; zones from user max HR (editable) (EPIC-26) | Match | HR samples | M | P0 |

### 5.3 Sleep

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Sleep stages | Ingested (`session_stages`), shown in detail | Add hypnogram chart component | Match | HK/HC | M | P0 |
| Sleep Performance % (actual vs need) | `sleep.score` in ontology; efficiency derived | Sleep need model (baseline + debt + prior-day effort + nap credit), performance = actual/need (EPIC-24) | **Approximate + Improve** (need-range honesty) | sessions + derived | L | P0 (Phase 2) |
| Sleep debt | Nothing | Rolling debt state machine with decay, published constants (EPIC-24) | Approximate | sessions | M | P0 |
| Sleep consistency % | Nothing | Bed/wake-time variance score (EPIC-24) | Match | sessions | S | P0 |
| Naps reduce need | Nap sessions ingested (`sleepNap` kind exists) | Nap credit in need model (EPIC-24) | Match | sessions | S | P0 |
| Disturbance tracking | Stages ingested | Micro-awakening count from stage data (EPIC-24) | Match | stages | S | P1 |
| Sleep Planner (bedtime recommendation) | Nothing | Suggested wind-down window from need model; local notification opt-in (EPIC-24/32) | Approximate | derived | M | P2 |
| Haptic/silent alarms | Nothing; no watch | Reject on iPhone (no hardware surface); revisit with watch app | Reject (now) | — | — | — |

### 5.4 Stress

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Real-time Stress Monitor | Nothing | Daytime autonomic-load index **only where daytime HRV density suffices** (Garmin/Oura/Samsung via Phase 4 vendors); on Apple-Watch-only data show low-confidence daily trend or hide (EPIC-34) | **Approximate (partial, device-gated)** | dense daytime HRV | L | P2 |
| Stress spike notifications | Nothing | Only atop a confident stress index; threshold alerts opt-in | Defer | same | M | P3 |
| Breathing/recovery exercises | Nothing | Reject — content product, not repository strength; link out instead | Reject | — | — | — |

### 5.5 Health monitor

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Vitals dashboard (RR, SpO2, skin temp, RHR, HRV) | Metrics in ontology; RR/SpO2 ingested on Android only; temp nowhere | Health Monitor surface: baseline-deviation tiles per vital with per-source sensor-quality labels (EPIC-27) | **Match + Improve** (quality labels) | HK/HC | M | P0 (Phase 2) |
| Temperature deviation (not absolute) | Nothing | Wrist-temp deviation from personal baseline, Oura-style documented method (EPIC-27) | Match | HK `appleSleepingWristTemperature`, HC SkinTemperature | M | P1 |
| Deviation alerts ("outside typical range") | Baseline band machinery exists | Calm out-of-band notice, wellness-safe copy, never alarmist | Improve | derived | S | P1 |
| ECG / Afib pass-through | Nothing | Pass through Apple Watch irregular-rhythm notifications as read-only clinical events, clearly labeled "recorded by your device" — never computed by BADAN | Match (pass-through only) | HK clinical types | M | P3 |
| Blood-pressure estimation | BP metrics exist in ontology (manual/cuff entry) | **Reject** cuffless estimation entirely (`whoop.md` §11); manual/cuff-device BP entry remains | Reject | — | — | — |

### 5.6 Workouts and strength

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Auto-detected workout ingestion | Manual `workout_entries` only | Ingest HK `HKWorkout`/HC `ExerciseSessionRecord` with summary metrics + HR series (EPIC-03) | Match | HK/HC | L | P0 (Phase 0) |
| GPS routes | Nothing | Ingest `HKWorkoutRoute`/HC route; store as route resource; separate consent (EPIC-03) | Match | HK/HC + location consent | L | P0 |
| Strength logging (sets/reps) | `WorkoutEntry` has no set detail (`workout.strength.*` namespace reserved) | Set/rep/weight logging, 1RM estimation (Epley/Brzycki), volume tracking (EPIC-28) | Match | manual | M | P1 (Phase 3) |
| PR detection + trends | Nothing | PR events + trend views — ships ahead of WHOOP (EPIC-28) | **Improve** | local | M | P1 |
| Post-workout analytics | Nothing | Workout detail: zones, HR curve, effort contribution, route map (EPIC-26/03) | Match | ingested | M | P0 |
| HR broadcast to gym equipment | Nothing | Reject — requires live BLE peripheral role; niche; revisit with watch | Reject (now) | — | — | — |

### 5.7 Journal / context behavior tracking

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Behavior journal (caffeine, alcohol, …) | Notes/nutrition exist; no structured behavior tags | `JournalEntry` (structured boolean/quantity tags from curated bilingual dictionary) with one-screen daily flow (EPIC-29) | Match | manual | M | P1 (Phase 3) |
| Behavior↔score correlations | Nothing | On-device paired-comparison engine with sample size + confidence shown; "association, not cause" copy (EPIC-29) | **Improve** (statistical transparency) | local | L | P1 |
| Voice logging | Nothing | Defer to AI phase (EPIC-35) | Defer | — | L | P3 |
| Context status (travel, illness, fasting) | `Condition` entity exists (user-declared) | `ContextStatus` interval entity; overlays on charts; feeds score confidence (EPIC-29) | Match | manual | M | P2 |

### 5.8 Cycle / women's health context

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Cycle-phase overlay on recovery | Nothing (cycle deferred in EXECUTION_PLAN scope rule) | `CycleContext` from HK/HC menstrual data (read) + manual; phase overlay on Readiness/sleep charts; `covariateContext` hook already reserved in `baselines` | Match | HK/HC cycle types, manual | L | P2 (Phase 3) |
| Hormonal insight narratives | Nothing | Wellness-safe phase-aware copy only after overlay proves value; extra sensitivity gating (I7 namespace) | Approximate | derived | M | P3 |

### 5.9 Coaching / AI

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| WHOOP Coach (conversational) | Deterministic InsightEngine only | AI coach over local longitudinal store (RAG), bilingual, cited-from-your-data answers (EPIC-35) | **Improve** | local + model | XL | P2 (Phase 4) |
| My Memory (editable AI context) | Nothing | Editable memory store, user-visible and deletable (EPIC-35) | Improve | local | M | P2 |
| Proactive check-ins | Nothing | Context-triggered nudges through notification budget engine; strictly opt-in (EPIC-32/35) | Approximate | local | M | P3 |
| Weekly/monthly performance assessments | Nothing | Deterministic report generator first (EPIC-31); AI narrative later | Match | derived | M | P1 (Phase 3) |

### 5.10 Healthspan / longevity

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| WHOOP Age / Pace of Aging | Nothing; MONETIZATION §4 flags the risk | "Vitality Trend" — directional, fully cited, never an age number; only under §4 conditions; Phase 5, approval-gated (EPIC-36) | **Approximate (heavily reframed)** | 8 of 9 inputs feasible (lean mass needs scale/manual) | XL | P3 (Phase 5) |
| Unlock gating (21-of-31 recoveries) | — | Adopt honest variant: refuse to compute below data threshold rather than degrade silently | Improve | local | S | with EPIC-36 |

### 5.11 Teams / community

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Teams, leaderboards, social feed | Nothing; no accounts | **Reject for this planning horizon** — requires accounts/backend/moderation; contradicts local-first posture; revisit only post-sync | Reject | — | — | — |

### 5.12 Widgets / watch surfaces

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Home/lock-screen widgets | None | WidgetKit + Glance per blueprint §24 snapshot pattern (subset: ring, sentence, meds-due, sleep card) (EPIC-33) | Match | snapshot store | L | P1 (Phase 3) |
| Watch app + complications | None | Phase 5; snapshot-friendly read APIs already the convention | Defer | — | XL | P3 |
| Live Activities | None | Defer with watch/workout live surfaces | Defer | — | L | P3 |

### 5.13 Notifications and alarms

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Daily summary notifications | Med reminders only (`NotificationScheduler`, 64-cap aware) | Morning readiness + evening wind-down classes through a budgeted decision layer; ≤2/day default (EPIC-32) | Match | local | M | P1 |
| Adaptive/behavioral nudges | None | Defer until correlation engine provides substance | Defer | — | M | P3 |
| Smart alarms | None | Reject (no wearable haptic surface) | Reject | — | — | — |

### 5.14 Settings / customization

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Dashboard customization | `CustomizationProfile.homeModules` exists | Extend module set with new score cards; keep | Match | local | S | P0 |
| HR max / zones editing | Nothing | Profile fields + zone editor; drives Effort backfill recompute (EPIC-26) | Match | manual | M | P0 |
| Score input weighting visibility | Anatomy sheet exists | Per-score anatomy incl. weights + versions; premium: personalized weighting later | Improve | local | M | P0 |

### 5.15 Reports and assessments

| Feature | Current BADAN status | Recommended BADAN action | Parity target | Data sources | Complexity | Priority |
|---|---|---|---|---|---|---|
| Weekly/monthly reports | Nothing | Deterministic report generator (JSON model → shareable render); export-integrated (EPIC-31) | Match | derived | L | P1 (Phase 3) |
| PDF export of reports | Nothing | Human-readable report as shareable PDF/HTML alongside (never instead of) raw exports | Improve | local | M | P1 |

---

## 6. Capability inventory from Health Auto Export research

Columns: verdict; execution locus (on-device / backend / hybrid); iOS and Android feasibility (**Exact / Approximate / Partial / Unavailable**); value; privacy; provenance behavior.

| # | HAE capability | Verdict | Locus | iOS feasibility | Android feasibility | User value | Privacy/security implications | Required data/provenance behavior |
|---|---|---|---|---|---|---|---|---|
| 6.1 | CSV export | **Match (exists)** + Improve (tidy-long default already; add wide mode, aggregation columns) | On-device | Exact (shipped) | Exact (shipped) | High | Formula-injection hardening already in place (keep) | 24-col contract already carries provenance; add `granularity`/`aggregation_method` (A1) |
| 6.2 | JSON export | **Match (exists)** + Improve (schema v1.0, ISO-8601 everywhere, tagged-union payloads per `HAE.md` §5) | On-device | Exact (shipped) | Exact (shipped) | High | — | Versioned envelope; per-record provenance object (exists) |
| 6.3 | GPX route export | **Match (new)** | On-device | Exact (after EPIC-03 ingestion) | Exact (HC ExerciseRoute) | High for athletes | GPS reveals home/work — **independent consent toggle**, excluded from default bundles | Route provenance = parent workout provenance + per-point timestamps |
| 6.4 | Workout export (summary + HR series + recovery) | Match (new) | On-device | Exact | Exact | High | Normal class | Workout as parent object w/ `hr_series_ref`, `route_ref` (never flattened) |
| 6.5 | Sample-level (raw) export | **Match (exists)** — raw_samples already exported at full resolution | On-device | Exact | Exact | High (QS users) | Sensitive classes gated (exists) | Existing |
| 6.6 | Aggregate export (bucket granularity second→year) | **Match (new)** | On-device | Exact (`HKStatisticsCollectionQuery` / SQL GROUP BY over canonical store) | Exact (SQL over canonical store) | High | — | Emit `granularity` + `aggregation_method` on every bucketed record (improves on HAE gap) |
| 6.7 | Quick export (one-tap presets) | **Match (new)** | On-device | Exact | Exact | High (casual) | — | Presets are `ExportTemplate` rows |
| 6.8 | Saved export templates | Match (new) | On-device | Exact | Exact | High (power) | Templates may name sensitive scopes — stored locally, included in backup only with consent | New `ExportTemplate` entity (§9) |
| 6.9 | Date + metric filters | **Match (exists)** — `ExportScope` already has metricIds/families/range/sources | On-device | Exact | Exact | High | — | Existing |
| 6.10 | iCloud Drive / Files destination | Match (new) | On-device | Exact (document picker + security-scoped bookmark; iCloud via Files) | Exact (SAF `ACTION_OPEN_DOCUMENT_TREE`) | High | Files leave sandbox — destination shown per run in history | `ExportDestination(kind: fileFolder)` |
| 6.11 | Dropbox / Google Drive | Match (defer to Phase 4) | On-device w/ OAuth SDKs | Exact | Exact | Medium | Third-party OAuth tokens in Keychain/Keystore; scope-minimal | `ExportDestination(kind: cloudDrive)`; no BADAN backend needed (vendor SDK direct) |
| 6.12 | REST API destination | **Match (new, Phase 3)** | Hybrid (user's own endpoint) | Exact | Exact | High (devs/QS) | HTTPS-only default; token in Keychain; explicit "you are sending health data to your own server" consent; never a BADAN-suggested endpoint | Idempotency keys + delta cursors (§22) |
| 6.13 | MQTT broker | Evaluate, likely Defer (Phase 5) | Hybrid | Approximate (foreground + opportunistic bg publish) | Approximate | Low for BADAN's audience | Unencrypted broker risk; TLS-only if built | Same payload contract as REST |
| 6.14 | Home Assistant entities | Evaluate, likely Defer (Phase 5) | Hybrid | Approximate | Approximate | Low–medium | Same as MQTT | Via REST/webhook contract, not a bespoke integration |
| 6.15 | Calendar event logging | Defer indefinitely | On-device (EventKit) | Exact | Exact | Low | Calendar leaks health events to any calendar-sharing party — poor default for a privacy product | Would need per-event redaction rules; not worth it now |
| 6.16 | Shortcuts / automation actions | **Match (new, Phase 1)** | On-device | Exact (App Intents: `RunExportTemplateIntent`) | Partial (no Shortcuts equivalent; app-shortcut + quick-settings tile approximation) | High — it is the only iOS "scheduled time" path | Intent runs require unlock for HK-fresh data; document honestly | Intent executes an `ExportTemplate` by id, records an `ExportRun` |
| 6.17 | Scheduled exports (in-app automations) | **Match (new)** with reliability-tier labels | On-device | **Approximate** (opportunistic: HK background delivery + BGTaskScheduler; no wall-clock guarantee) | **Approximate-to-Exact** (WorkManager periodic is materially more reliable, still OEM-throttled) | High | Background runs touch health data while user absent — explicit enrollment | `AutomationSchedule` entity + `ExportRun` log; checkpoint anchors |
| 6.18 | Background execution substrate | Match (new, Phase 0) | On-device | Approximate (see §13 constraints) | Approximate (WorkManager) | Foundation | Battery/permission honesty | Run log with outcome enum incl. `skippedLocked`, `throttled` |
| 6.19 | Incremental/delta exports | **Improve (new)** — HAE has anchors; BADAN adds manifest-chained, idempotent deltas | On-device | Exact | Exact | High (API/automation users) | — | Per-(template,destination) `ExportCursor`; manifest carries `previous_manifest_sha` |
| 6.20 | Full backups | Match (new) — "everything bundle" incl. settings/templates; encrypted option for whole bundle | On-device | Exact | Exact | High | Backup contains sensitive namespaces → passphrase path (exists on iOS; EPIC-06 for Android) | Bundle = data + `customization` + templates + schema docs |
| 6.21 | Export history / activity log | **Match + elevate** — "Export & Automation Health" dashboard (HAE.md §8 finding: the #1 trust surface) | On-device | Exact | Exact | High | Log stores metadata only, never values | `ExportRun` entity; failure taxonomy |
| 6.22 | Schema documentation | **Improve (exists partially)** — `csv_columns.json` + `export_bundle.md`; add generated DATA_DICTIONARY + changelog + versioning policy | On-device artifact + docs | Exact | Exact | High (trust) | — | `export_schema_version` in every manifest (exists as schemaVersion 0.1.0 → v1.0) |
| 6.23 | Local-network TCP/MCP server | Defer (Phase 5 feasibility study) — improve on HAE only if built: TLS + token, never unencrypted | On-device | Partial (foreground-only realistically) | Partial | Medium (AI-agent audience) | High risk surface; HAE ships it unencrypted — BADAN must not | Read-only query API over canonical store; audit log |
| 6.24 | Desktop/Mac auto-sync | Reject as bespoke protocol; desktop = consumer of BADAN's own export files/API (`HAE.md` §13) | — | — | — | Low now | — | — |
| 6.25 | Widgets (free tier) | Match (EPIC-33; §5.12) | On-device | Exact | Exact | High | Snapshot redaction when locked | Blueprint §24 snapshot pattern |
| 6.26 | Automation-config backup (iCloud) | Match (new) — templates/destinations included in BackupRestore surface | On-device | Exact | Exact | Medium | Destination credentials excluded from plaintext backup (Keychain-only) | Config export as versioned JSON |

---

## 7. Unified BADAN capability map

Master matrix. Priority: P0 = required for this initiative's first release wave; P1 = feature-parity wave; P2 = high-value next; P3 = advanced/power; P4 = future/speculative. Approval column references §25 decisions.

| Capability | Source | User value | Casual value | Power value | Architecture dependency | iOS | Android | Backend | Priority | Approval |
|---|---|---|---|---|---|---|---|---|---|---|
| Ingestion widening (HRV, RR, SpO2, energy, distance, body, temp, VO2) | Both + PERF-181 | Foundation | High (auto value) | High | HealthStorePort typemap growth | EPIC-01 | EPIC-02 | No | **P0** | No |
| Workout + route ingestion | Both | High | Med | High | New route storage | EPIC-03 | EPIC-03 | No | **P0** | Routes consent copy |
| Background sync substrate | HAE | Foundation | High (freshness) | High | Entitlement + BGTask / WorkManager | EPIC-04 | EPIC-05 | No | **P0** | A2 |
| Android export encryption parity | Existing gap | Trust | Med | High | Kotlin AES-GCM+PBKDF2 port | — | EPIC-06 | No | **P0** | No |
| Ontology expansion v0.2 (~20 metrics + derived ids) | Both | Foundation | — | — | registry.json + regen mirrors | EPIC-07 | EPIC-07 | No | **P0** | No |
| Export schema v1.0 (versioning, granularity fields, ISO-8601) | HAE | High | Low | High | csv_columns/json contracts | EPIC-08 | EPIC-08 | No | **P0** | A1 |
| Export templates + quick export | HAE | High | High | High | ExportTemplate entity | EPIC-09/10 | EPIC-09/10 | No | **P0** | No |
| Advanced export builder | HAE | High | Low | High | ExportScope UI | EPIC-11 | EPIC-11 | No | P1 | No |
| GPX export | HAE | High (athletes) | Low | High | Route storage | EPIC-12 | EPIC-12 | No | P1 | Route consent |
| Aggregated exporter | HAE | Med | Med | High | SQL aggregation layer | EPIC-13 | EPIC-13 | No | P1 | No |
| Destinations v1 (Files/iCloud folder) | HAE | High | High | High | ExportDestination entity | EPIC-14 | EPIC-14 | No | **P0** | No |
| Scheduling/automation engine (3-tier) | HAE | High | Med | High | EPIC-04/05 + templates | EPIC-15 | EPIC-15 | Optional later | P1 | A2 |
| Export & Automation Health dashboard | HAE | Trust anchor | Med | High | ExportRun log | EPIC-16 | EPIC-16 | No | P1 | No |
| Incremental/delta export | HAE | High (automation) | Low | High | ExportCursor | EPIC-17 | EPIC-17 | No | P1 | No |
| Full backup + config backup | HAE | High | High | High | Bundle spec | EPIC-18 | EPIC-18 | No | P1 | No |
| App Intents / Shortcuts | HAE | High | Med | High | Templates | EPIC-19 | partial analog | No | P1 | No |
| REST API destination | HAE | High (devs) | Low | Very high | Destinations + delta | EPIC-20 | EPIC-20 | No (user's server) | P2 | Consent copy |
| Cloud drives (Dropbox/GDrive) | HAE | Med | Med | Med | OAuth SDKs | EPIC-21 | EPIC-21 | No | P2 | Token policy |
| Data dictionary + schema docs generation | HAE | Trust | Low | High | export-schemas | EPIC-22 | shared | No | P1 | No |
| Baseline engine v2 (multi-window, confidence, backfill) | WHOOP | Foundation | — | — | BaselineEngine | EPIC-23 | EPIC-23 | No | **P0** | No |
| Sleep suite (need/debt/consistency/naps/disturbances) | WHOOP | Very high | High | High | Sessions (exist) + EPIC-23 | EPIC-24 | EPIC-24 | No | **P0** | Copy review |
| Readiness v2 (recovery-equivalent, published formula) | WHOOP | Very high | High | High | EPIC-01, 23 | EPIC-25 | EPIC-25 | No | **P0** | A3 |
| Effort score (strain-equivalent) | WHOOP | High | High | High | EPIC-01, 03, HR-max profile | EPIC-26 | EPIC-26 | No | **P0** | A3 |
| Health Monitor surface | WHOOP | High | High | Med | EPIC-01 vitals | EPIC-27 | EPIC-27 | No | **P0** | No |
| Strength logging + PR | WHOOP | High | Med | High | workout_entries ext | EPIC-28 | EPIC-28 | No | P1 | No |
| Journal + correlations | WHOOP | High | Med | High | JournalEntry + engine | EPIC-29 | EPIC-29 | No | P1 | Stats copy |
| Cycle context overlay | WHOOP | High (subset) | Med | Med | CycleContext + covariate hook | EPIC-30 | EPIC-30 | No | P2 | Sensitivity review |
| Weekly/monthly reports | WHOOP | High | High | Med | Derived store | EPIC-31 | EPIC-31 | No | P1 | No |
| Notifications/daily summaries | WHOOP | High | High | Med | Budgeted decision layer | EPIC-32 | EPIC-32 | No | P1 | No |
| Widgets | Both | High | High | Med | Snapshot store (blueprint §24) | EPIC-33 | EPIC-33 | No | P1 | No |
| Stress monitor (device-gated) | WHOOP | Med | Med | Med | Dense daytime HRV | EPIC-34 | EPIC-34 | Vendors help | P2 | Confidence copy |
| AI coach + memory | WHOOP | Very high | High | High | Local store + model host | EPIC-35 | EPIC-35 | A-decision | P2 | AI hosting (A9) |
| Vitality Trend (healthspan-equiv) | WHOOP | Med | Med | Med | Long history + EPIC-36 inputs | EPIC-36 | EPIC-36 | No | P3 | **A5** |
| Vendor integrations (Garmin/Oura → Polar/Samsung) | WHOOP | High | High | High | Backend broker | EPIC-37 | EPIC-37 | **Yes** | P2 | **A4** |
| MQTT / Home Assistant | HAE | Low–med | Low | Med | REST contract reuse | Phase 5 | Phase 5 | No | P4 | No |
| Local MCP/TCP server | HAE | Med (AI users) | Low | High | Read API + TLS | Phase 5 study | Phase 5 | No | P4 | Security review |
| Watch app / Live Activities / Wear tiles | WHOOP | Med | Med | Med | Snapshot APIs | Phase 5 | Phase 5 | No | P4 | No |
| Teams/leaderboards; BP estimation; clinician/EHR; smart alarms; calendar destination; desktop peer-sync | Both | — | — | — | — | — | — | — | **Rejected** (§26) | — |

---

## 7A. Capability inventories from the seven domain research documents (v1.1)

Same verdict vocabulary as §5/§6. Phase numbers refer to §19's roadmap (with v1.1 amendments). Every feature named in the source documents appears below or in its owning epic's task list (§20); source backlog IDs (HYD/CYCLE/PREG/LAB/ACC/W-nn) are imported wholesale into §20 so nothing is dropped.

**v1.1 verdict supersessions of v1.0 rows:** ① §5.2 "Live intra-workout strain ticker: Defer" and §5.6 "post-workout only" → superseded by EPIC-42's phased live monitor (phone-first now, watch-first Phase 4). ② §5.8 cycle rows and EPIC-30 → superseded by EPIC-39 (full module; overlay remains its Phase-3 first slice). ③ §6.15 "Calendar destination: Defer indefinitely" → stands for *automation destinations*, with one narrow exception: pregnancy `AppointmentLog` per-event, user-confirmed EventKit export (EPIC-40), never automated. ④ §7 "Watch app: Phase 5/P4" → watch app moves to Phase 4 (A22). ⑤ §10 CGM row "defer glucose UI to Phase 4" → confirmed and hardened: Dexcom-class API integration is Phase 4+ behind legal gate A21; platform-written glucose ingestion/export earlier is fine. ⑥ HR broadcast, smart alarms, teams, BP estimation, clinician/EHR — rejections unchanged.

### 7A.1 Hydration (→ EPIC-38)

| Feature | Verdict | Phase | Notes (constraints preserved from source) |
|---|---|---|---|
| One-tap quick add; container presets/favorites; custom drinks (type + default volume) | Build | 1 | ≤2s / ≤2 actions to log; confirmation "Added 500 mL from My Bottle" + Undo |
| Edit/undo/backdate/multi-day history | Build | 1 | Append-first ledger; revisions preserve original id + audit chain |
| Manual goal / **no-goal as equal-status default** / simple starter goal | Build | 1 | Goal snapshot stored on every daily summary; "your tracking goal" wording only |
| Body-weight / activity / climate-adjusted goal models | Build (opt-in, off by default) | 3 | Each requires explicit approval + "optional estimate, not medical guidance" copy; never silent |
| Day-type goal schedules | Build | 2 | User-authored only |
| Fasting profile + editable Ramadan template | Build | 2 | Generic user-entered windows; total reminder suppression during fast; never infer faith; optional prayer quiet blocks |
| Pregnancy/cycle hydration context | Build (display-only) | 3 | Never target calculators; manual/clinician goal path mandatory |
| Reminder engine: fixed schedule, interval, morning-start, incomplete-goal, meal-linked, post-workout, travel-timezone, adaptive (experiment), medication-adjacent | Build phased (fixed P0 of module; adaptive P3 experiment; medication-adjacent P3, never dose advice) | 1–3 | All off by default; initial cap 1/day; "Not now" = 2–4h cooldown; 3–5 ignored prompts → offer adjustment not escalation; plans 7–14 days ahead; never Time-Sensitive/Critical; folds into EPIC-32 budget |
| Notification actions: Log 250 mL / Open presets / Not now / Pause today | Build | 1 | — |
| HealthKit `dietaryWater` + HC `HydrationRecord` write-back and import | Build | 1–2 | Only modify BADAN-owned records; loop prevention via external ids/fingerprints; plain-water only maps; rich fields stay local |
| Beverage metadata (caffeine/alcohol/electrolytes) | Build | 3 | **Never silently compute "net hydration" multipliers**; never mix food-water estimates into logged totals |
| Widgets/watch presets (2–4) + offline queue; App Intents `LogHydration`, `GetHydrationProgress`, `PauseHydrationReminders`, `SetHydrationGoal` | Build | 2–3 | Joins EPIC-19/33/44 surfaces; App Group cache |
| Weekly reports + deterministic insights (consistency 7d, time-of-day 14 entries/7d, adherence goal+7d, workout-adjacent 5 workouts, caffeine/alcohol 14 matched days, symptom 20 matched days) | Build | 3 | Min-n thresholds enforced; observational wording ("logged drinks on 5 of 7 days"); AI may summarize, never invent causality |
| JSON/CSV export (entries, summaries, goals, rules, sources) | Build | 1 | Default export **excludes** notes, medication names, cycle/pregnancy/fasting contexts, reminder history, location |
| Smart bottles; weather/location context; food-water estimates/barcode | Defer | 4+ | Adapter order: platform → CSV/JSON import → OAuth vendor → BLE last; privacy review gates |
| Streak-guilt mechanics, dehydration claims, urgent tones, account-first onboarding | **Reject** | — | "Missing logs do not mean the user did not drink" |

### 7A.2 Period tracking & cycle intelligence (→ EPIC-39, supersedes EPIC-30)

| Feature | Verdict | Phase | Notes |
|---|---|---|---|
| Period start/end logging (ongoing flag, backdating, ≤3 interactions repeat case) | Build | 2/3 boundary | Sensitive DB only (arch test blocks main-DB placement); user-asserted always beats inferred |
| Flow logging (custom scales; original label + normalized score) | Build | 3 | Casual labels spotting/light/medium/heavy; numeric mappings power mode |
| Cycle history + next-period **window** prediction with confidence bands | Build | 3 | 5-tier stack (0 / 1–2 / 3–5 / 6+ cycles / rich-signal); weighted median of last 3–6 cycles; width from personal spread, never generic 28-day; "prediction paused" for irregular contexts, never forced precision |
| Phase estimate (menstrual/follicular/ovulatory/luteal/unknown) with confidence + evidence basis | Build | 3 | Recomputed daily; below-threshold confidence → unconditioned baselines, never a guessed label |
| **Phase-conditioned baselines in `BaselineEngine`** (HRV/RHR/sleep/temp/readiness) | Build | 2 (engine hook) / 3 (live) | The core differentiator — closes the WHOOP/Bevel luteal false-alarm gap; parallel baselines per phase via reserved `covariateContext`; luteal fixture must stop tripping generic under-recovery alarms |
| Anomaly engine: cycle length dev., period duration dev., flow dev., missed expected period, repeated irregularity (v1); symptom-cluster shift (only if symptom infra solid — it is) | Build | 3 | Min history 3 cycles (single) / 4–6 (pattern); escalate on 2 consecutive or 3-of-4; three surfacing levels (suppressed/gentle/detailed), default gentle = passive cards not push; banned/approved phrasing library imported verbatim into copy lint |
| Contraceptive/reproductive context log (pill/IUD/patch/ring/injection/implant/EC/HT) | Build | 3 | Neutral record-keeping; suppressive context pauses/broadens predictions; fertile estimates auto-hidden |
| BBT logging/import; ovulation test logging | Build (opt-in) | 3 | BBT refines confidence, never required; LH = near-term signal, BBT = retrospective confirmation |
| Cervical mucus logging | Defer | 4 | Hidden until opt-in |
| Fertile-window estimate (calendar-only broad / signal-assisted narrow / suppressed modes) | Build behind **A17** | 3–4 | Non-contraceptive framing everywhere; suppressed for postpartum/suppressive-contraception/perimenopause/preference |
| Sexual activity logging | Defer, elevated gating | 4+ | Sensitive-plus-highest tier (new); off by default, own sub-consent, excluded from casual surfaces + cloud AI |
| Historical CSV import with mapping review | Build | 3 | Reuses `import_batches`; user confirms before history joins predictions |
| Wearable temp/HRV correlates | Build | 3 | "Signals that sometimes move with cycle phase" — context, never authoritative events |
| Goals/modes: general awareness, TTC, avoiding-pregnancy awareness (non-contraceptive), symptom-pattern, perimenopause, postpartum | Build | 3 | Modes tune presentation only — never fork the database |
| Correlation Lab (within-subject, phase coverage + n + CI) | Build | 3–4 | Joins EPIC-29 engine |
| Hide / pause-predictions / purge (3 separate controls); consent stack (platform → module → sync → cloud-AI → sexual-activity) | Build | 3 | Purge deletes rows + invalidates derived values; sensitive export default-off **every time**, never sticky |
| Partner/caregiver sharing | Defer | 5 | Only with per-field scoping, revocation, audit (A4-dependent) |
| Notification styles none/gentle/detailed | Build | 3 | Gentle default; one bundled "pattern changed" card |

### 7A.3 Pregnancy calendar (→ EPIC-40)

| Feature | Verdict | Phase | Notes |
|---|---|---|---|
| Seven explicit user-declared modes: TTC, pregnancy-confirmed, week-by-week, late-pregnancy, birth/delivery log, postpartum handoff, loss | Build | 3–4 | **BADAN never infers pregnancy, loss, or fertility intent** — every transition user-initiated; exits reachable in 1–2 taps; re-entry never resets history |
| Due-date model: provider > ultrasound-adjusted > conception-based > LMP, with visible source + change history | Build | 3 | Exact week conventions clinically validated before ship (A18); ranges where method supports; calm recalculation message, milestones preserve completed items |
| Week-by-week content shell + versioned content schema + trimester-aware tone | Build shell; content gated on **A18/A25** | 3–4 | Mandatory identical disclaimer footer on 100% of content screens (canonical string chosen once); content independently authored/licensed + clinically reviewed; multiples flag branches gated on clinical review |
| Logging: weight/symptoms/appointments/tests/meds — **all reuse existing BADAN entities + pregnancy-context tag** | Build | 3 | No parallel schemas; entries appear in both pregnancy view and general history |
| Kick counter + contraction timer | Build after safety-copy review | 4 | Baseline-relative language only ("if movement feels different than usual for you"); contraction timer labeled stopwatch utility, never labor-stage claims; persistent emergency footer, never a triggered popup |
| Mood check-ins + resource surfacing | Build | 4 | One-tap professional-support link visible on every check-in |
| Hospital-bag/birth-plan checklist; belly-photo/memory journal | Build | 4–5 | Organizer framing; photos private-by-default |
| **Loss declaration**: 1–2 taps from anywhere, minimal fields, immediate (same-session, zero-delay) suppression of ALL pregnancy notifications overriding standing prefs, keep/archive/delete choice (revisitable), grief-appropriate copy, resources in-flow, lighter-touch pacing option on re-entry, fertility-treatment context flag | Build **as first-class alongside core flow, never retrofitted** | 3 (foundational) | The documented category failure; local-notification cancellation must be synchronous (local-first makes this satisfiable) |
| Lab-notebook handoff (`ScreeningTestReference` links, never duplicates) | Build | 4 | Depends on EPIC-41 |
| HealthKit `Pregnancy` category one-way write (+`PregnancyTestResult`, `Lactation`, bleeding types read) | Build (opt-in) | 4 | Never read back to infer status; HC has **no** pregnancy-status type — BADAN-internal on Android, asymmetry documented |
| Calendar export of appointments | Build (per-event confirm only) | 4 | Surfaces OS-cloud-sync caveat to user |
| Partner sharing (`SharingConsentRecord`) | Defer | 5 | Legal + leadership gate; immediate logged revocation |
| Elevated export friction + separate loss-record export confirm; rapid full-module deletion; zero third-party SDK signal | Build | 3 | Friction ≠ paywall — never fails closed, never subscription-tied |
| Passive inference, numeric clinical thresholds, un-disableable celebration content, forced start-over, urgency triage, bundled consent, cloud-first storage | **Reject (hard constraints)** | — | Verbatim from source §18 |

### 7A.4 Lab results notebook (→ EPIC-41)

| Feature | Verdict | Phase | Notes |
|---|---|---|---|
| Report/panel/result canonical model (LabReport, LabPanel, LabResult + 22 supporting entities) | Build | 3 | Report-level + observation-level + component-level (FHIR `DiagnosticReport`/`Observation` shaped); versioned corrections, never destructive |
| Source-document vault (PDF/image, SHA-256, encrypted separately) | Build | 3 | Original artifact always preserved; "notebook, not a chart" |
| Manual entry (quick single-marker + full report) | Build | 3 | First-class, not fallback; provisional→verified replacement keeps history |
| PDF upload + share-sheet import; photo/scan OCR with staged pipeline + review queue | Build | 3 | OCR defaults `review_required`; locale-aware decimals, Arabic+English OCR, comparator symbols (`<`,`≥`…); document stores even when extraction fails |
| HealthKit Clinical Records import (`HKClinicalRecord`, FHIR R4) | Build | 3–4 | iOS-strongest structured path; raw FHIR blob preserved; provider-coverage honesty |
| Health Connect Medical Records import | Build | 4 | Experimental API — verify at build; Android ranks PDF/manual first |
| Direct FHIR bundle import; provider connectors; CSV/JSON import; email import; personal API | Phase-gated | 4–5 | Connectors are networked → A4-dependent |
| Analyte ontology: 20 categories (CBC, iron, metabolic, liver, kidney, lipids, glucose, glycemic, thyroid, reproductive, vitamins, inflammation, urinalysis, micro/culture, allergy, drug monitoring, genetic-meta, custom, user-defined, derived) with LOINC/UCUM strategy, conversion-safety classes (safe/conditional/unsafe/none), bilingual names | Build | 3 | **Unknown markers first-class** — import never blocks; eGFR never recalculated retroactively; absolute-vs-percent differentials preserved |
| Reference-range engine: **four separated concepts** — source interval / source flag / personal baseline / user-defined threshold | Build | 3 | Hard schema requirement; missing range → never invented; "Outside this laboratory's stated reference interval" wording |
| Unit normalization (originals always preserved; ranges normalized together or shown in source units) | Build | 3 | HbA1c %↔mmol/mol dual-view; unsafe classes never auto-converted |
| Trends, personal baselines, panel-snapshots-over-time, per-lab overlays, confidence model | Build | 4 | Quality states: verified_structured / parsed_high_conf / needs_review / user_entered / corrected / conflict_flagged; source quality ranks structured > OCR-reviewed > OCR-unreviewed > manual |
| Duplicate/conflict resolver (weighted score; merge/link/flag, never auto-delete) | Build | 4 | Amended reports supersede-with-history |
| Notes, clinician questions, visit-prep packet builder | Build | 3 (notes/questions) / 4 (packet) | "Strongest differentiator vs generic dashboards" |
| Collections: source panels, virtual, smart (rule-based) | Build | 4 | — |
| Exports: original docs, marker CSV, report/notebook JSON, FHIR-shaped, human-readable PDF, appointment packet, de-identified research export | Build | 3 basics / 4 full | Raw/normalized/derived/annotations/provenance separated in every export; export audit log |
| AI summaries (JSON output schema: overview/changes/uncertainties/questions/citations; every sentence cites visible records) | Build | 4 | On-device deterministic first; cloud LLM opt-in only (A19); non-diagnostic contract |
| Sensitivity tiers: standard / high (reproductive, STI, cultures, drug screens) / very-high (genomic, pathology, HIV, fertility-treatment — separate consent + local-only option) | Build | 3 | **Entire lab domain excluded from widgets/ambient by default**; per-category local-only override even when sync exists |
| Traffic-light health scores, "Normal/Healthy/Danger/Optimal" language, closed analyte dictionary, auto-merge, portal scraping | **Reject** | — | Verbatim anti-patterns |

### 7A.5 Live exercise monitor / workout OS (→ EPIC-42; extends EPIC-03/26/28)

| Feature | Verdict | Phase | Notes |
|---|---|---|---|
| Canonical workout lifecycle state machine (IDLE→…→PERSISTED, incl. auto-pause, sensor-degraded, route-degraded, low-battery, interruption, crash-recovery draft) | Build | 3 | Platform-neutral machine + adapters; **blocks nearly everything downstream**; frequent checkpoints, draft always recoverable |
| Quick start: Walk / Run / Strength / Open workout | Build | 3 | Casual path 3 screens; countdown default 3s (Apple `prepare()` warm-up) |
| 28-modality taxonomy + per-modality metric bundles, cue defaults, chart density, custom activity builder, templates (versioned, local-first) | Build | 3 taxonomy+top modalities / 4 full | No runner-first hardwiring; adaptive/wheelchair modalities inclusive-by-design |
| Live metric ontology (~30 metrics with source hierarchy, cadence, caveats — full registry imported into EPIC-42 tasks) | Build | 3 | Casual cap 2–4 primary metrics; estimates labeled; **HR tile omitted, never zeros**, on phone-only Apple sessions; HRV live = off by default (unreliable) |
| Apple runtime: `HKWorkoutSession`+`HKLiveWorkoutBuilder`+`HKLiveWorkoutDataSource`, correct end sequence (stopActivity→stopped→endCollection→finishWorkout→end), crash recovery w/ data-source rebuild, locked-device workout data prompt | Build | 3 (phone) / 4 (watch-first) | Watch-first is Apple's recommended path → A22 pulls watch app to Phase 4; phone-only = graceful degraded mode |
| Android runtime: BADAN-owned capture engine (foreground services, batching ≤1000 records/write, stable `clientRecordId` idempotency) separate from HC persistence; HC availability fallback to local-only | Build | 3 | OEM kill-risk messaging; WorkManager for deferred sync only, never sub-minute live |
| Strength SOR: `ExerciseDefinition` (bilingual, muscle groups, equipment), `WorkoutTemplate`, `StrengthSet` with set semantics (warm-up/working/drop/failure/back-off/assisted/timed), crash-safe `StrengthSessionRunner` persisting after every set, superset flow, plate math, exercise-swap preserving completed sets | Build | 3 | Merges with EPIC-28; warm-ups excluded from PR logic by default; auto-rep detection = optional annotation only, **never core** |
| Interval/HIIT engine: structured targets (time/distance/pace/HR-zone/power), adherence eval, haptic-first cues, calm wording ("You are below your target pace range", never "Push harder") | Build | 4 | Cue throttling; degrade clearly when target sensor absent ("heart rate unavailable; target guidance paused") |
| Route capture: low-accuracy point filtering, pause-aware, partial-route marking, elevation confidence, **privacy clipping near home for share/export** | Build | 3 | Extends EPIC-03/12 |
| Live surfaces: default + compact screens (3); Live Activities lock-screen (4); Siri workout intents (4); watch screens/complications (4); Wear OS companion (4–5) | Build phased | 3–5 | Lock surfaces minimal metrics only; joins EPIC-44 |
| Post-workout notebook: overview, timeline, splits, zones, strength log, route detail, provenance sheet, quality notes ("HR unavailable first 2 min; zone minutes partial"), comparisons, reflection prompts | Build | 3–4 | PR caveat engine disallows false PRs on partial data |
| Provenance/quality: session/metric/derived levels; quality dims (completeness, freshness, continuity, accuracy, consistency, derivation transparency); per-metric-family primary source during live session; merge journal | Build | 3 | Casual badges ("Watch HR", "Estimated calories"); e1RM formula ID stamped |
| Training load: acute 7d EWMA / chronic 28d EWMA, focus distribution, strength muscle-load channels | Build | 4 | Feeds/aligns EPIC-26; blueprint constants adopted |
| Guidance system (pace/zone/interval/milestone/rest/lap cues; sensory channels visual/haptic/audio/mixed) | Build | 4 | Optional, calm, globally disable-able |
| Offline + battery: offline start-to-save, checkpointing survives process death, batched writes, battery-saver mode, long-session warnings | Build | 3 | "Users forgive missing polish before they forgive lost workouts" |
| Exports: session summary CSV, child CSVs (laps/intervals/sets), full JSON w/ provenance, GPX/GeoJSON, notebook PDF; **pending-sync state indicated in exports** | Build | 3–4 | Extends EPIC-08/12 contracts; sessions.csv/workout_sets.csv per blueprint |
| AI workout summaries ("explain this chart", compare workouts, weekly narrative) | Build | 4 | Grounded/citation contract; joins EPIC-35 |
| FIT/TCX/GPX file import | Build | 4 | De-risks Garmin/Polar/Suunto/COROS category with zero vendor dependency |
| Autonomous training coach, medical/emergency detection, emergency-access affordance (without legal review), cloud-dependent live execution | **Reject / gate** | — | Verbatim from source §45/§31 |

### 7A.6 Third-party accessories & device ecosystem (→ EPIC-43; extends §10 and EPIC-37)

Integration-depth doctrine (imported as decision rule): **11 routes** — HealthKit-mediated / HC-mediated / vendor OAuth / vendor SDK / broker / direct BLE / FTMS / file import / document import / manual / transparent non-support. Default to platform mediation; escalate to vendor APIs only where platform data is materially incomplete; BLE for standards-based sensors; file/document/manual as dignified fallback; **say "not supported yet" honestly rather than pretending.**

| Device class / capability | Verdict | Phase | Notes |
|---|---|---|---|
| GATT abstraction layer: Heart Rate, Cycling Power, Cycling Speed & Cadence, Running Speed & Cadence, Weight Scale, Body Composition, Blood Pressure, Health Thermometer, Pulse Oximeter, FTMS (+glucose profiles where lawful) | **Build (flagship)** | 3 | One adapter per GATT service → any conforming device works without device-specific code; AccessorySetupKit (iOS 18) picker pairing; user-initiated scanning only; **foreground/session-based only — no background-BLE promises**; no reverse engineering, ever |
| BLE HR straps + cycling power/cadence | Build | 3 | Best engineering-cost-to-coverage ratio; strap-beats-optical-wrist quality signal surfaced; "sensor may be connected to another app" handling |
| BLE smart scales / body composition | Build | 3 | Bioimpedance caveat persistent; **household "who is this reading for?" prompt — never weight-range auto-attribution** |
| BLE BP cuffs, thermometers (site metadata), pulse oximeters (non-clinical-grade disclosure incl. motion/skin-tone variance) | Build w/ safety copy | 4 | §44 safety-language matrix imported to copy lint; clinical+legal sign-off (A25) |
| FTMS gym machines | Build | 4 | Calories labeled "machine-estimated"; many optional sub-features → scoped |
| Reconciliation engine v2 + Device Hub | **Build (flagship)** | 3 | Extends existing dedup: `DataConflict` + `SourcePriorityRule` (user-overridable, default visible) + immutable `ReconciliationDecision`; defaults: chest strap > wrist HR in workouts; richest source wins duplicate workouts; **Oura-vs-Watch sleep shown side-by-side until user picks**; most-recent weight wins day; CGM stream = trend line + manual as points; "why am I seeing this value?" one-tap; never silently merge or average |
| Device Hub UI (cards: healthy/needs-attention/disconnected; Device Detail: sync history, raw browser; Source Priority Editor; troubleshooting flow; opt-in SupportDiagnosticBundle excluding health values) | Build | 3 | Casual users "never think about devices"; power users get the full lens |
| Device lifecycle: new-device-never-overwrites, replacement grouping optional, multiple simultaneous devices, retire ≠ delete, disconnect-vs-disconnect-and-delete choice | Build | 3 | Clock drift: deviceTimestamp vs ingestionTimestamp both kept, gap flagged |
| Garmin Connect Health API (epoch-level depth beyond partial one-way HC feed) | Build | 4 | **Commercial license fee = explicit business decision (A20)**; ping/pull-or-push needs broker (A4) |
| Strava OAuth import | Build | 4 | Aggregator — original device provenance preserved underneath |
| Samsung Health extended metrics; Polar API | Evaluate | 4 | Partner-terms dependent |
| Ultrahuman, RingConn, Galaxy Ring; Huawei, Xiaomi; Suunto, COROS; Zwift, TrainingPeaks; sleep mats | Research-spike first | 4–5 | Verify-at-build list (§2.5); Huawei/Xiaomi regionally relevant to Oman/GCC |
| Dexcom CGM API (tiered access, sandbox→full) ; Libre/Lingo | Build behind **A21 legal gate** | 4+ | "Never for treatment decisions" framing throughout; own consent flow; highest scrutiny in the corpus |
| HealthKit Clinical Records / HC Medical Records (FHIR) | Build | 4 | Feeds EPIC-41; provider-sourced records visually/structurally distinct from consumer data |
| File import FIT/GPX/TCX/CSV + document import (PDF) | Build | 3 | MVP-class universal fallback; document import feeds lab notebook |
| Environmental sensors; hydration hardware | Defer | 5 | Contextual overlay only |
| SDK data-access boundary: no analytics/ad/egress-capable SDK may touch device-ecosystem tables | **Build (architectural)** | 3 | Enforced as a compile-time/module boundary + CI lint, not policy prose |
| Wear OS as BLE accessory; legacy Google Fit API; portal scraping/credential automation; proprietary-protocol reverse engineering | **Reject** | — | Verbatim |

### 7A.7 Widgets, complications & ambient surfaces (→ EPIC-44; extends EPIC-33)

Reconciliation mandate: the research doc's W-01…12 and ~55 surfaces do **not** reference blueprint §24's WGT-I-01…16 or its snapshot pattern. **EPIC-44 task 1 produces the crosswalk**; the blueprint's snapshot-store architecture (app-group bounded DTO, locked-redaction variant, no DB access from extensions) **wins** over the doc's shared-SQLite-from-extension suggestion — extension memory limits and the sensitive-namespace boundary decide it. The doc's surface catalog, privacy-mode system, and preset system are adopted on top.

| Surface / capability | Verdict | Phase | Notes |
|---|---|---|---|
| One True Sentence pipeline (rule-bound daily sentence) + inline lock widget + small/medium home + Android + Wear tile headline | Build | 3 | Refresh once/morning + meaningful shifts only, never jitter; interpretive latitude = founder decision A24 |
| Readiness / sleep / activity / hydration / health-monitor widgets (small+medium, iOS+Android) | Build | 3 | Maps onto WGT-I-01/05/06/07 + hydration; "last updated" freshness tiers (<2h / same-day / >1d); omit-over-stale rule |
| Lock-screen circular/rectangular/inline (conservative defaults: status words "Steady"/"Check-in suggested", not scores; masked mode) | Build | 3 | Lock screens = semi-public; highest privacy default |
| Watch complications: Ready-Today corner, Sleep rectangular, Activity circular, Health-monitor corner, Hydration modular (full per-complication spec: color, privacy, stale, tap, fallback) | Build | 4 (with watch app, A22) | Stale sleep >2 days → "No recent sleep data", never reuse; shapes-beyond-color |
| Watch Smart Stack cards; watch glance screen | Build | 4 | System controls Smart Stack presence — no guarantees promised |
| Wear OS tiles (summary/readiness/hydration/start-workout; dynamic expressions ≤ platform limit) + complications | Build | 4–5 | Tiles can't scroll; render from local state |
| Live Activities: workout, medication window (no drug names on lock screen), export-job progress, acute symptom session (opt-in) | Build | 4 | Compact/expanded/minimal states specified; "Data paused; check BADAN" on stale — never wrong values; joins EPIC-42 |
| App Intents families (8 logging / 5 query / 2 export / 3 automation — verbatim ids adopted) + Android App Actions/shortcuts | Build | 3 (extends EPIC-19) | `LogPeriodEventIntent`/`LogPregnancySymptomIntent` restricted from lock surfaces |
| Large/extra-large dashboards, multi-metric power widgets, export-status + automation-health widgets, baseline-deviation widget, correlation-insight widget, anomalies-inbox widget | Build | 4–5 | Power widgets consume EPIC-16/23/29 outputs; "patterns to review", never pseudo-diagnosis |
| Preset system: casual / athlete / recovery / hydration / cycle-pregnancy (private-only) / quantified-self + guardrails against customization chaos | Build | 4 | Hierarchical settings; density warnings |
| Privacy modes: global high/normal/verbose × per-surface × per-metric sensitivity; locked-screen redaction (blur/generic/hide) | Build | 3 | **Amendment to doc:** for sensitive-plus families, lock-screen redaction is **non-overridable** — verbose mode never exposes weight/reproductive/lab/mental-health on lock surfaces (I7 wins over user-tunability) |
| Widget/complication refresh honesty (WidgetKit ~5-min floor + delayed `.atEnd`; Android 30-min floor + Doze; steps hourly cap) | Build (copy + AC) | 3 | All freshness claims best-effort; no deterministic promises in copy or acceptance criteria |
| Notification-adjacent surfaces (hydration reminders, medication windows, anomaly notices) | Build via EPIC-32 budget | 3–4 | Doc has no budget concept — **the ≤2/day budget engine governs**; all classes opt-in |

---

## 8. Architecture implications

### 8.1 Governing reconciliation

Both research documents assume architectures BADAN must *not* copy: `whoop.md` assumes a scoring backend; `HAE.md` documents an iOS-only single-purpose app. BADAN's target architecture keeps computation on-device, extends the existing layer map (`docs/architecture.md` §1), and adds four new module groups. **Key structural decision: WHOOP-like "snapshots" are not new tables.** A recovery snapshot is a set of `DerivedValue` rows sharing a `periodKey` and `AlgorithmVersion`; a training-load snapshot likewise. This preserves I2 (append-only), I5 (raw/derived separation), and the anatomy-sheet explainability path without a parallel storage system.

### 8.2 Component map

| Component | Purpose | Ownership module (iOS path; Android mirrors under `net.albayyan.badan`) | Inputs | Outputs | Storage | Privacy boundary | Existing file to change | New module |
|---|---|---|---|---|---|---|---|---|
| Canonical health entities | Facts + provenance (exists) | `Sources/Domain/` | adapters, manual | repos | `badan.db` | I7 split | `Measurements.swift` (workout session detail) | — |
| Route storage | GPS route sub-resource for workouts | `Sources/Domain/Measurements.swift` + `Storage/` | HK/HC route queries | GPX writer, map preview | new `workout_routes`, `route_points` tables | **Location-sensitive: own consent, default-excluded from export** | `Migrations.swift` (v4) | `Storage/Repositories/RouteRepository.swift` |
| Ingestion adapters | Platform → DTO (exists, widen) | `Sources/Platform/Health/` | HK/HC | DTOs | anchors in `read_anchors` | permission-gated | `HealthKitAdapter.swift`, `HealthConnectAdapter.kt` | `Platform/Health/WorkoutRouteReader.swift` |
| Background execution engine | Wake, sync, run automations, respect failure budget | new `Sources/Platform/Background/` | OS wakeups (HK bg delivery, BGTask / WorkManager) | ingest runs, automation runs, run log | `background_runs` table | no UI; logs metadata only | `AppEnvironment.swift` (registration), `project.yml` (entitlements) | `BackgroundCoordinator.swift`, `HealthKitObserverRegistrar.swift`, `BackgroundTaskRegistrar.swift` |
| Derivation engines | Scores/baselines (exists, extend) | `Sources/Domain/Derivation/` | canonical rows | DerivedValue/Baseline rows + InputManifests | `derived_values`, `baselines` | wellness-safe outputs only | `BaselineEngine.swift`, `InsightEngine.swift` | `SleepIntelligenceEngine.swift`, `ReadinessEngine.swift`, `EffortEngine.swift`, `DeviationEngine.swift`, `CorrelationEngine.swift` |
| Algorithm registry | Versioned published formulas | `packages/contracts/algorithms/` (new) + `Sources/Ontology/` | — | `AlgorithmVersion` metadata + methodology docs | bundled JSON | public by design | `InsightTemplateStore.swift` pattern reuse | `algorithms.json`, `AlgorithmRegistry.swift` |
| Export domain | Jobs (exists) + templates, destinations, runs, cursors | `Sources/Domain/Export.swift` + `Sources/Export/` | scopes, templates | files, run records | new tables (§9) | export module keeps zero-network lint **except** the isolated destination layer (see 8.3) | `Export.swift`, `ExportRunner.swift` | `Export/Templates/`, `Export/Destinations/`, `Export/GPXWriter.swift`, `Export/AggregateExporter.swift`, `Export/ReportRenderer.swift` |
| Destination credential vault | Tokens/secrets for REST/cloud destinations | `Sources/Platform/Secrets/` (new) | user config | Keychain/Keystore handles | **never in SQLite**; Keychain (iOS) / EncryptedSharedPreferences+Keystore (Android) | credentials never exported, never logged | — | `DestinationSecretsStore.swift` |
| Automation scheduler | Template × cadence × destination orchestration with tier labels | `Sources/Domain/Automation/` (new) | schedules, background wakeups, App Intents | ExportRuns | `automation_schedules` | reliability-tier honesty in UI | — | `AutomationEngine.swift`, `ReliabilityTier.swift` |
| App Intents surface | Shortcuts actions | `Sources/Platform/Intents/` (new) | template ids | intent results | — | intents expose template names only | `project.yml` | `RunExportTemplateIntent.swift`, `LogWaterIntent.swift` (blueprint WGT-I-04 dependency) |
| Snapshot store (ambient) | Widget/watch read model (blueprint §24) | `Sources/Platform/Ambient/` (new) + widget extension target | domain events post-derivation | bounded JSON snapshot in app group | app-group file, redacted-when-locked variant | per-family widget consent keys | `project.yml` (new target `BadanWidgets`) | `AmbientSnapshotWriter.swift`, `ios/BadanWidgets/*` |
| Notification decision layer | Budgeted delivery (extends med reminders) | `Sources/Platform/Notifications/` | derived events, prefs | scheduled locals | prefs in profile | ≤2/day default; opt-in classes | `NotificationScheduler.swift` | `NotificationDecisionEngine.swift` |
| Journal/context domain | Behavior tags, context statuses, cycle context | `Sources/Domain/Logging.swift` + sensitive DB | manual + HK/HC cycle reads | entries; correlation inputs | `badan_sensitive.db` new tables | **sensitive-plus (I7)** | `LoggingRepository.swift` | `JournalEntry`, `ContextStatus`, `CycleContext` types |
| Reports generator | Weekly/monthly deterministic reports | `Sources/Domain/Reports/` (new) | derived store | report model → renderer | `reports` table (metadata) + file artifact | wellness-safe; report is an export artifact | — | `ReportBuilder.swift`, `Export/ReportRenderer.swift` |
| Vendor broker (Phase 4) | OAuth + pull for Garmin/Oura | `backend/api`, `backend/workers` (activate) + `Sources/Platform/Vendors/` | vendor APIs | normalized DTO batches | backend: tokens + cursors only (no raw health storage without further decision) | supersedes ADR-0002 (A4) | `backend/README.md` | see EPIC-37 |
| AI layer (Phase 4) | Coach, memory, narratives | `Sources/Domain/AI/` (new) | local store + model | answers with evidence refs | `ai_memory` table (user-editable) | on-device-first; hosting per A9 | — | see EPIC-35 |

### 8.3 The export zero-network lint, amended

D-8's "export module has no networking imports" is load-bearing and stays true for **generation**. Destinations introduce network by definition. Resolution: `Sources/Export/` (writers, runner) keeps the lint; a sibling `Sources/Export/Destinations/` module is the *only* code allowed to move a finished, checksummed artifact, is lint-checked to never import writers' internals (it consumes file URLs + manifests only), and is compiled out of any build lacking the feature flag. File generation remains provably offline; delivery is a separate, auditable act. This preserves the privacy-policy claim "export generation involves no network" with one precise amendment to the policy text (§17).

### 8.4 Event flow (target state)

```
HK/HC change ──► BackgroundCoordinator ──► IngestionPipeline ──► canonical rows
      │                                            │
      │                                            ▼
      │                                DerivationScheduler (debounced)
      │                                            │
      │              ┌─────────────┬───────────────┼──────────────┬─────────────┐
      │              ▼             ▼               ▼              ▼             ▼
      │       SleepIntelligence  Readiness      Effort       Deviation     Baselines
      │              └─────────────┴───────┬───────┴──────────────┘
      │                                    ▼  (DerivedValue + InputManifest rows)
      │                     ┌──────────────┼────────────────┬────────────────┐
      │                     ▼              ▼                ▼                ▼
      │              AmbientSnapshot  NotificationDecision  InsightEngine  AutomationEngine
      │                  (widgets)        (≤2/day)          (templates)   (due exports?)
      │                                                                       │
      └──────────────────────────────────────────────────────────────────► ExportRunner ──► Destinations
```

Every arrow is an in-process call or persisted queue row — no server in the loop through Phase 3.

---

## 9. Canonical health-data model extensions

Conventions carried from `docs/data-model.md`: ULID ids, epoch-millis UTC + IANA tz, sync-ready columns (`updated_at`, `origin_device_id`, `deleted_at`), embedded provenance on measurement-bearing rows, forward-only migration (**v4** on `badan.db`, **v3** on `badan_sensitive.db`). For each entity: purpose · key fields · relationships · indexes · raw/derived class · privacy · export representation.

**Existing entities that already satisfy the requirement (change noted only):**

- **HealthSample → `RawSample`/`IntervalRecord` (exist).** No shape change; new metric ids only.
- **MetricDefinition (exists).** Registry v0.2 adds ~20 metrics (§ EPIC-07 list) and new derived ids. Export: registry slice already embedded in JSON bundle dictionaries.
- **DataSource → `Source` (exists).** Add `sensorQuality` map (metricFamily → high/medium/low) for the Health Monitor labels; vendor sources activate the reserved `type=vendor`.
- **Device (exists).** No change.
- **ProvenanceRecord → embedded `Provenance` (exists).** No change; new ingestion paths reuse enum values.
- **SleepSession/SleepStage → `Session`/`SessionStage` (exist).** No change.
- **JournalEntry-adjacent logs (MedicationLog→`MedicationRegimen`+`AdherenceEvent`, SymptomLog→`SymptomEntry`) exist.** No change.
- **RecoverySnapshot / TrainingLoadSnapshot / StressSnapshot / HealthMonitorSnapshot / DerivedMetric → `DerivedValue` (+`Baseline`) rows, by design (§8.1).** A "snapshot" is the set of derived rows for a `periodKey`; read models assemble them. No new tables. Export: rows appear in `derived.csv` / `derived_values[]` exactly like today.
- **Insight (exists).** Correlation findings render through it with new template types.
- **AlgorithmVersion (exists as domain type).** Gains a bundled registry file (`packages/contracts/algorithms/algorithms.json`) so versions/params/methodology-URLs are data, not code.
- **SyncCheckpoint → `read_anchors` (exists) + new `ExportCursor` below.**

**New entities (migration v4 unless noted):**

### 9.1 `Workout` (ingested session; extends `Session` usage)
- **Purpose:** first-class ingested workout episodes (auto-detected by watch/phone), distinct from manual `workout_entries`.
- **Decision:** reuse `sessions` with `kind=workout` (already an enum case) + typed `detail` JSON (activity type, totals: energy, distance, avgHR/maxHR, elevation, HR-recovery-60s when computable). Manual `workout_entries` remain the quick-add path; a read model unifies both, dedup rule `workout.session_overlap.v1` suppresses the manual duplicate when an ingested twin exists (I3 journal).
- **Fields (in detail JSON, versioned):** `activityType`, `totals{}`, `hrSeriesRef?`, `routeRef?`, `sourceWorkoutUUID`.
- **Indexes:** existing `(kind, start_at)` suffices; add partial `(external_id, source_id) WHERE kind='workout'` (already generalized by v3 index).
- **Raw/derived:** raw fact. **Privacy:** normal class; route separately gated. **Export:** `workouts[]` top-level array in JSON v1.0 (parent object with refs, per `HAE.md` §9); `events.csv` row + per-workout files on detailed export.

### 9.2 `WorkoutRoute` + `RoutePoint`
- **Purpose:** GPS trace sub-resource.
- **Tables:** `workout_routes` (id, session_id FK, point_count, start_at, end_at, + provenance, + consent_snapshot: the route-consent state at ingest time); `route_points` (route_id, seq, lat, lon, altitude_m, hacc_m, timestamp) — bulk-inserted, no per-point provenance (inherits route's).
- **Indexes:** `route_points(route_id, seq)` PK; `workout_routes(session_id)`.
- **Raw/derived:** raw. **Privacy:** location-sensitive: ingestion requires the route toggle ON; export requires the *separate* route export toggle; excluded from Quick Export presets; never in snapshots/widgets.
- **Export:** GPX 1.1 file per route (`route_<ulid>.gpx`), referenced from workout objects; optionally embedded polyline omitted from CSV entirely.

### 9.3 `ExportTemplate`
- **Purpose:** saved, named export configuration (HAE presets, but explicit and inspectable).
- **Fields:** id, name, `scope` (existing `ExportScope` JSON: metricIds/families/sources/range-rule), `rangeRule` (`fixed|lastNDays|sinceLastRun|allTime`), `format` (csv/json/gpx-bundle), `aggregation` (`raw|hour|day|week|month` + method), `layout` (`tidy|wide`), `includeSchemaDocs` bool, `destinationId?`, `createdAt/updatedAt`.
- **Relationships:** → `ExportDestination` (optional), ← `AutomationSchedule`, ← `ExportRun`.
- **Index:** pk; unique(name).
- **Privacy:** template naming a sensitive scope requires the sensitive toggle re-confirmation at *run* time (defense in depth — mirrors `ExportRunner`'s existing passphrase check).
- **Export:** included in full-backup bundle under `config.export_templates[]`.

### 9.4 `ExportDestination`
- **Purpose:** where artifacts go.
- **Fields:** id, kind (`shareSheet|fileFolder|restApi|cloudDrive(dropbox|gdrive)|mqtt(reserved)`), displayName, config JSON (folder bookmark data ref / URL + method + header template ids / provider account ref), `credentialRef` (**Keychain key, never the secret**), tlsPolicy (`httpsOnly` default), createdAt, lastVerifiedAt, status (`ok|authExpired|unreachable|disabled`).
- **Index:** pk.
- **Privacy:** secrets in Keychain/Keystore only; config JSON holds references. Destination rows excluded from plaintext backups; included (sans secrets) in encrypted backups.
- **Export:** listed by name+kind only in run manifests.

### 9.5 `ExportRun`
- **Purpose:** the trust ledger — one row per attempted export (manual, intent, scheduled).
- **Fields:** id, templateId?, jobId (FK to existing `export_jobs`), trigger (`manual|shortcut|scheduledOpportunistic|scheduledWork|retry`), startedAt/finishedAt, outcome (`success|partial|failedGeneration|failedDelivery|skippedLocked|skippedNoData|throttled|cancelled`), errorCode?, errorDetail (sanitized, value-free), bytesWritten, rowCounts JSON, destinationId?, deliveredAt?, cursorBefore/cursorAfter (delta runs), manifestSha256.
- **Indexes:** `(started_at DESC)`, `(template_id, started_at DESC)`.
- **Raw/derived:** operational metadata. **Privacy:** must never contain health values (tested, like DiagnosticsTests).
- **Export:** visible in Export Health dashboard; included in full backup.

### 9.6 `ExportCursor`
- **Purpose:** incremental-export checkpoint per (template, destination).
- **Fields:** (template_id, destination_id) PK, `highWatermark` (max `ingested_at` exported — chosen over `measured_at` so late-arriving/backfilled rows are still exported next run), lastManifestSha, lastRunId, updatedAt.
- **Privacy:** metadata only. **Export:** in full backup (enables restore-and-resume).

### 9.7 `AutomationSchedule`
- **Purpose:** user's declared automation intent, with honest tier.
- **Fields:** id, templateId FK, tier (`opportunisticBackground|shortcutDriven|manualOnly`), desiredCadence (`onNewData|hourlyBestEffort|dailyBestEffort|weeklyBestEffort`), quietHours?, enabled, consecutiveFailures, lastSuccessAt, nextExpectedWindow (display-only estimate), createdAt.
- **Index:** pk; `(enabled, tier)`.
- **Privacy:** none beyond template's. **Export:** in config backup.

### 9.8 `BackgroundRun`
- **Purpose:** substrate-level log (distinct from ExportRun: covers ingest wakeups too).
- **Fields:** id, kind (`hkObserverWake|bgAppRefresh|bgProcessing|workManagerPeriodic|foregroundSync`), startedAt, durationMs, outcome (`completed|expired|storeLocked|throttled|error`), workDone JSON (counts only), completionHandlerCalledInMs (iOS — guards the 3-strikes budget).
- **Index:** `(started_at DESC)` with a 90-day pruning job.
- **Privacy:** value-free. **Export:** Diagnostics + Export Health surfaces.

### 9.9 `JournalEntry` (sensitive DB, migration v3)
- **Purpose:** structured behavior tags (caffeine, alcohol, late meal, screen-in-bed, supplements…, from a curated bilingual dictionary in `packages/contracts/dictionaries/behaviors.json`).
- **Fields:** id, behaviorId (dictionary) | customLabel, valueKind (`boolean|count|quantity`), value?, unit?, occurredAt, tzId, note?, + provenance (manual).
- **Index:** `(occurred_at)`; `(behavior_id, occurred_at)`.
- **Raw/derived:** raw user assertion. **Privacy:** sensitive-plus (I7) — behavior patterns are lifestyle-revealing. **Export:** `logs.journal[]` in JSON; `events.csv` rows; only with `includeSensitive`.

### 9.10 `ContextStatus` (sensitive DB)
- **Purpose:** user-declared intervals that condition interpretation (travel, illness, fasting, altitude, injury).
- **Fields:** id, statusId (taxonomy) | customLabel, startAt, endAt?, tzId, note, + provenance.
- **Index:** `(start_at)`.
- **Privacy:** sensitive-plus. **Behavior:** engines read active statuses to annotate confidence ("computed during travel — your baseline may not apply"), never to silently alter values. **Export:** with sensitive toggle.

### 9.11 `CycleContext` (sensitive DB)
- **Purpose:** cycle-phase context from HK/HC menstrual data and/or manual entry.
- **Fields:** id, cycleStartAt, phase (`menstrual|follicular|ovulatory|luteal|unknown`), sourceKind (platform|manual), confidence, + provenance.
- **Index:** `(cycle_start_at)`.
- **Privacy:** sensitive-plus, own consent toggle distinct from general sensitive toggle (double-gate). Feeds the reserved `Baseline.covariateContext` — additive, exactly as the schema anticipated. **Export:** only with cycle-specific opt-in.

### 9.12 `Report`
- **Purpose:** generated weekly/monthly report metadata (artifact lives as a file, regenerable).
- **Fields:** id, periodKey (`week:2026-W29`), generatedAt, algorithmVersionId, sectionsIncluded JSON, artifactPath?, sha256.
- **Index:** unique(period_key, algorithm_version_id).
- **Raw/derived:** derived. **Export:** the artifact itself is an export product; regenerable from the store so never a source of truth.

### 9.13 `AIMemory` (Phase 4, sensitive DB)
- **Purpose:** user-editable AI context (WHOOP "My Memory" equivalent, transparent version).
- **Fields:** id, text, createdBy (`user|assistant`), createdAt, editedAt, archived.
- **Privacy:** sensitive-plus; fully user-visible/editable/deletable; audit column for assistant-written entries. **Export:** with sensitive toggle.

### 9.14 Hydration entities (v1.1, migration v5; main DB except noted)
From the hydration research's 14-entity model, mapped onto BADAN conventions: **`HydrationEntry`** (append-first drink ledger: volumeMl canonical, fluidType, beverageId?, containerId?, revision chain, platform external id — a specialization of the raw-sample pattern with its own table for beverage semantics), **`BeverageDefinition`**, **`ContainerPreset`**, **`HydrationGoal`** (+ per-day goal snapshot on summaries), **`HydrationTargetRule`** (approved contextual rules, versioned, off-by-default), **`FastingProfile`** (user-entered windows; drives reminder suppression), **`ReminderSchedule`**/**`ReminderEvent`** (generalized — shared with EPIC-32's decision engine). Caffeine/alcohol/electrolyte annotations live on `BeverageDefinition`. **Privacy:** entries normal-class; fasting/medication-adjacent/pregnancy contexts sensitive-plus. **Export:** tidy CSV set + JSON under `logs.hydration[]`; default redactions per §7A.1.

### 9.15 Cycle entities (v1.1, sensitive DB migration v3; supersedes §9.11's minimal `CycleContext`)
**`CycleRecord`** (anchor period span: start/end/ongoing, goal context), **`FlowLog`** (original label + normalized intensity + scale version), **`BasalTemperatureLog`**, **`OvulationSignalLog`** (LH/mucus/other, typed), **`ContraceptiveContextLog`** (method intervals), **`CyclePrediction`** (append-only derived: low/center/high window, method, suppression reason, input manifest), **`CyclePhaseEstimate`** (dated interval + confidence + evidence basis — feeds `Baseline.covariateContext`), **`CycleAnomalyEvent`** (type, basis window, template id, state; severity = surfacing priority only). Symptom entries gain optional `cycle_id` linkage (no parallel symptom model). Module visibility/consent rows live in main-DB settings (hide/pause/purge tri-state). **New sensitivity tier:** `sensitivePlusHighest` (sexual-activity class, Phase 4+) added to the `SensitiveClass` enum. **Export:** cycle family default-off, per-family toggles, derived cycle analytics separately toggleable.

### 9.16 Pregnancy entities (v1.1, sensitive DB)
**`PregnancyRecord`** (mode/stage, due-date source enum + value + change history, multiples flag/count, fertility-treatment context flag), **`GestationalMilestone`** (content-version stamped), **`AppointmentLog`**, **`KickCountSession`**, **`ContractionEvent`**, **`LossDeclarationRecord`** (minimal fields, highest tier, independently deletable, separately export-confirmed), **`PostpartumHandoffRecord`**. Weight/symptom/medication pregnancy entries = existing entities + pregnancy-context tag + gestational-week annotation (PREG-06 acceptance). **`ScreeningTestReference`** links to lab-notebook entries, never duplicates. Content cards are bundled versioned data (like insight templates), not entities.

### 9.17 Lab notebook entities (v1.1, sensitive DB + document vault)
Adopted from the 25-entity source model: **`LabReport`**, **`LabPanel`**, **`LabResult`** (raw value text + normalized value + comparator + result type + review state), **`AnalyteDefinition`** (bilingual, LOINC/UCUM, conversion policy, category), **`ReferenceRange`** (source-scoped; four-concept separation is schema law), **`SourceDocument`** (blob vault, SHA-256, OCR status, separately encrypted), **`OCRExtraction`** (engine/version/confidence/ambiguity flags/bounding boxes), **`UserCorrection`** (overlay, never destructive), **`LabAnnotation`**/**`UserQuestion`** (visit prep), **`DerivedTrend`**, plus reuse of existing `ImportJob`-pattern (`import_batches`), `Specimen`/`CollectionEvent`/`ObservationTime` folded as structured columns/JSON on report/result where full tables are premature. Three-tier `sensitivity_tier` on report+result; very-high tier supports local-only override. **Export:** every export separates raw/normalized/derived/annotations/provenance.

### 9.18 Workout-OS entities (v1.1; extends §9.1–9.2)
**`WorkoutSession`** stays `sessions(kind=workout)` with the richer versioned detail payload (state history, source profile, quality summary, refs). New tables: **`workout_checkpoints`** (crash-safe hot state for the active session — cleared on finalize), **`strength_sets`** (+`ExerciseDefinition` dictionary + `WorkoutTemplate` — was EPIC-28, now shared with EPIC-42; set semantics enum incl. warmUp/working/drop/failure/backOff/assisted/timed, superset group), **`workout_intervals`** (work/rest/lap/segment with targets + results), **`workout_quality`** (completeness/continuity/accuracy metrics per metric family). Live samples reuse `raw_samples`; laps/intervals/sets are child rows referenced from the session (never flattened — export contract §22 gains `laps[]`, `intervals[]`, `strength_sets[]`).

### 9.19 Device-ecosystem entities (v1.1; extends §9 provenance machinery)
Mapped onto existing structures where they exist: `Source`/`Device` gain **`connectionType`** (healthkit/health_connect/vendor_oauth/vendor_sdk/broker/ble_direct/fitness_machine/file_import/manual — the primary provenance signal), hashed serial (dup-detection only), capability set, pairing state, retirement. New: **`DataConflict`** (measurement ids, metric type, resolution status) and **`SourcePriorityRule`** (per-metric priority order, `isUserOverride` distinguishing defaults from choices) — the existing `dedup_decisions` table serves as the immutable `ReconciliationDecision` ledger (rule refs extended). **`DeviceSyncSession`** (per-source sync accounting) and **`ConnectionDiagnostic`** (value-free troubleshooting events) extend the §9.8 `BackgroundRun` pattern per-source. **`ConsentGrant`** — BADAN's own append-only consent ledger (revocations are new records), distinct from OS permissions; legal-audit-critical, exportable. **`DataQualityFlag`** rides the existing `quality_flags` provenance column with an expanded enum (implausible-value, gap-filled, low-confidence-estimate, clock-drift). Device/deviceTimestamp-vs-ingestionTimestamp distinction: already satisfied by `measured_at` vs `ingested_at` (existing provenance columns) — flagged gap becomes a quality flag.

---

## 10. Device and platform integration plan

| Source | Data it can provide | Integration approach | Mediation | Sync cadence | Provenance behavior | Dedup concerns | Limitations | Priority |
|---|---|---|---|---|---|---|---|---|
| **Apple Health / HealthKit** | Sleep+stages, HR, RHR, HRV(SDNN), RR (sleep-only), SpO2, wrist temp (sleep-only, Series 8+), steps, active/basal energy, distance, flights, VO2 max, walking metrics, weight/body-fat/lean mass, workouts+routes, mindful minutes, cycle data, ECG/irregular-rhythm (pass-through) | Extend `HealthKitAdapter`: anchored queries per type; statistics queries for cumulative types; `HKWorkoutRouteQuery` for routes; background delivery + observer registration (EPIC-04) | Platform-mediated | Foreground on open (exists) + opportunistic background (new); `.hourly` bg-delivery target for HR-family, `.daily` for the rest | `source=healthkit`, device from `HKDevice`/source revision (already implemented incl. Watch/iPhone recognition) | Watch-vs-iPhone overlap already handled for steps/sleep; extend priority table to energy/distance | RR+temp are sleep-only; daytime HRV sparse (stress gating); store locked = unreadable in background | **P0** |
| **Apple Watch** | (via HealthKit above) | No direct SDK work until a watch app (Phase 5) | Platform | — | Device rows already distinguish Watch | — | No independent access path | P0 (as HK) |
| **Health Connect** | 9 types already + ExerciseSession(+route), TotalCaloriesBurned, Vo2Max, Weight, BodyFat, LeanBodyMass, SkinTemperature, MenstruationFlow/Period, FloorsClimbed, Speed/Power (cycling) | Extend `HealthConnectAdapter` record set; changes-token incremental reads; WorkManager-driven periodic sync (EPIC-05) | Platform-mediated | WorkManager periodic (15-min floor, expect ~hourly real-world) + on-open | `source=healthConnect` + originating package captured as platformBundleId | Multiple writer apps (Samsung Health + Google Fit + vendor apps) → source-priority table per family is *more* critical than iOS | 30-day default history window — backfill honesty banner required; OEM job throttling | **P0** |
| **Wear OS** | via Health Connect (writer apps) | None direct until Wear tile phase | Platform | — | — | — | — | P4 |
| **Garmin** | Continuous HR/HRV, sleep, RR, stress score, Body Battery, Training Readiness/Load, VO2 (FirstBeat), workouts | Connect Developer Program + OAuth2 PKCE; backend broker holds tokens, polls/receives push, normalizes to DTO batches; device pulls batches | **Broker (backend)** — client-only impossible without leaking secrets | Backend pull/push per Garmin cadence; device fetch on open/bg | `source.type=vendor`, `ingestionPath=vendor`, vendor record ids as external_id | Garmin daily summaries vs HK duplicates when user runs both — priority per family + never blend VO2 across vendors | Program approval lead time (apply early — Phase 3 admin task); rate limits | P2 (Phase 4, A4) |
| **Oura** | Best-in-class sleep architecture, nightly HRV/temp deviation, readiness contributors, SpO2 | OAuth2 via broker; REST v2 pull | Broker | Nightly pull post-sync | as Garmin | Oura sleep vs Watch sleep overlap → existing sleep dedup rule extends with vendor priority | Ring-only daytime gaps | P2 (Phase 4) |
| **Fitbit / Google Health API** | HR, sleep, SpO2, RR, activity | **New Google Health API only** (legacy Web API dies Sept 2026) | Broker | per API | as Garmin | overlaps with HC on Android — prefer HC path when both present | API in transition; deprioritize until stable | P3 |
| **Polar** | HR, sleep, Training Load Pro | AccessLink API via broker | Broker | per API | as Garmin | — | smaller ecosystem | P3 |
| **Samsung Health** | HR, sleep, SpO2, stress | **Via Health Connect only** — no direct SDK | Platform | as HC | HC provenance shows Samsung package | covered by HC priority table | Samsung direct SDK explicitly avoided (AP-08 note) | P0 (as HC) |
| **Smart scales** | Weight, body fat, lean mass | Via HK/HC (vendor apps write) + manual entry fallback | Platform | as HK/HC | writer package visible | manual-wins rule (I4) already covers weight | No direct BLE pairing in scope | P0 (as HK/HC types) |
| **Chest straps** | High-fidelity workout HR | Via HK/HC workout writes from vendor apps | Platform | as HK/HC | device row shows strap | strap HR vs watch HR during same workout → workout-scoped HR source priority | No live BLE ingestion in scope (reject with HR-broadcast) | P1 |
| **CGM platforms** | Glucose + meal-time metadata | Via HK (Dexcom/Libre write) / HC on Android where available | Platform | as HK/HC | writer package | — | 3-hour Dexcom HK delay typical; glucose is sensitive-plus; **defer glucose UI to Phase 4**, ingest+export earlier is fine | P2 |
| **BP devices** | Cuff BP readings | Via HK/HC (cuff apps write) + manual (exists in ontology) | Platform | as HK/HC | writer package | manual-wins (I4) applies | Estimation rejected; cuff pass-through only | P1 |
| **Manual logs** | Everything loggable | Exists (LogHub + feature screens) | — | — | `ingestionPath=manual` | I4 | — | Shipped |
| **File imports** | Apple Health ZIP, generic CSV, GPX (inbound) | `ArchiveImporter` interface reserved in EXECUTION_PLAN — implement Apple Health ZIP first (Phase 3), `import_batches` table exists | On-device | manual trigger | `ingestionPath=import` + batchId (undo = tombstone batch) | imported rows collide with live HK history → identity index + dedup handles | Large-archive streaming parse; memory budget | P2 |

### 10.1 v1.1 integration-map additions (per the accessories research; §7A.6 doctrine governs)

| Source | Data | Approach | Mediation | Cadence | Provenance/dedup | Limitations | Priority |
|---|---|---|---|---|---|---|---|
| **BLE HR straps** (Polar H10-class, generic) | HR + RR-intervals | GATT Heart Rate Service via GATT abstraction; AccessorySetupKit pairing (iOS) | Direct BLE, foreground-session only | Sub-second–1s live | `connectionType=ble_direct`; strap wins over wrist optical in workouts (default rule) | No background BLE; contested-connection handling required | P1 (Phase 3) |
| **BLE cycling power/cadence/speed; foot pods** | Watts, RPM, speed, stride | GATT Cycling Power / CSC / RSC services | Direct BLE | Per-second | Sensor-location field kept | Calibration drift (power), wheel-circumference config (speed) — user-owned, disclosed | P1–P2 |
| **BLE scales / body composition** | Weight, body fat, muscle mass | GATT Weight Scale + Body Composition services OR platform | Direct BLE / platform | On-use | Household "who is this for?" prompt; manual-wins (I4) unchanged | Bioimpedance caveat persistent | P1 |
| **BLE BP cuffs / thermometers / pulse oximeters** | BP, temp (+site), SpO2 | GATT services OR platform (platform preferred for friction) | Direct BLE / platform | On-use | Site metadata captured; safety-copy matrix applies | Non-clinical-grade disclosures mandatory; A25 sign-off | P2 (Phase 4) |
| **FTMS gym machines** | Speed, incline, power, distance, machine-est. calories | GATT Fitness Machine Service | Direct BLE, session | Per-second | "Machine-estimated" labels | Many optional sub-features | P2 |
| **Strava** | Activities, routes, segments | OAuth API (aggregator) | Broker (A4) | On-upload poll | Underlying device provenance preserved — Strava is a hop, not a source | — | P2 (Phase 4) |
| **Dexcom CGM** | Glucose + trends | Tiered developer API (sandbox→full) | Broker (A4) + **A21 legal gate** | Near-real-time–delayed | `sensitivePlus`+; own consent flow | "Never for treatment decisions"; approval process | P3 (Phase 4+) |
| **Libre/Lingo; Ultrahuman; RingConn; Galaxy Ring; Huawei; Xiaomi; Suunto; COROS; Zwift; TrainingPeaks; sleep mats** | Various | Verify-at-build research spikes | Various | — | — | Documented-terms uncertainty; Huawei/Xiaomi matter for Oman/GCC | P3 spikes |
| **HealthKit Clinical Records / HC Medical Records** | Labs, meds, immunizations, conditions (FHIR) | Platform clinical APIs | Platform | Provider-sync | Provider-sourced records visually + structurally distinct | Provider participation uneven; HC API experimental | P2 (Phase 4, feeds EPIC-41) |
| **File imports (FIT/TCX/GPX/CSV) + documents (PDF)** | Workouts; lab reports | `ArchiveImporter` implementations | On-device | Manual | `ingestionPath=import` + batch undo | — | **P0-of-Phase-3** (universal fallback) |
| **Fitbit** *(v1.1 note)* | — | Deprioritized further: HC-mediated on Android covers most; new Google Health API only if direct ever needed | — | — | — | — | P3 |

---

## 11. WHOOP-equivalent execution plan

Epic numbering is global (shared with §12); task-level breakdown, acceptance criteria, and DoD live in §20. Each card here defines the product/pipeline shape. Common properties stated once: **all engines run on-device; no backend components exist in any epic below except where explicitly noted; all outputs are `DerivedValue`/`Baseline` rows with `AlgorithmVersion` + `InputManifest`; all copy passes the wellness-language lint; all UI ships en+ar with RTL snapshots.**

### EPIC-23 — Baseline & calibration engine v2
- **Outcome:** every score-bearing metric has a personal baseline with visible calibration progress and confidence, over configurable windows.
- **Scope:** extend `BaselineEngine` from single 14-day window to per-metric window sets (14d for vitals, 60d trailing for HRV per `whoop.md` §5, 28d for sleep need inputs); outlier rejection (MAD-based); backfill computation over imported history; confidence tiers (`provisional <7 pts`, `establishing <windowDays`, `established`).
- **Inputs:** canonical rows for baseline-eligible metrics (registry flag exists). **Pipeline:** nightly + post-ingest debounced recompute; append-only.
- **UI:** calibration progress on score cards ("day 9 of 14"); anatomy sheet shows window, n, method.
- **Settings:** none user-facing (windows are algorithm params, published).
- **Testing:** golden numerics; DST windows; backfill idempotency. **Risks:** window choices contested — mitigated by publishing rationale in `docs/algorithms/baselines.md`.
- **Phase 2 · Prereqs:** EPIC-01/02 (data). **Approval:** No.

### EPIC-24 — Sleep intelligence suite
- **Outcome:** sleep need, performance %, debt, consistency, nap credit, disturbances — the highest-ROI WHOOP cluster (`whoop.md` §12 Phase-1 pick), on data BADAN already ingests.
- **Scope & logic:** `SleepIntelligenceEngine` computing per `localNight`: **need** = personal baseline duration + debt·decay(k) + priorDayEffort·factor − napCredit (constants published, versioned); **performance** = actual/need bounded, shown as a range when confidence is low; **debt** = rolling accumulator with exponential decay; **consistency** = 0–100 from bed/wake variance over 14d; **disturbances** = wake-stage episode count ≥ threshold. New derived ids: `sleep.need`, `sleep.performance`, `sleep.debt`, `sleep.consistency`, `sleep.disturbances` (EPIC-07).
- **Inputs:** `sessions` (sleepPrimary/sleepNap) + `session_stages` + Effort output (soft dependency; need model runs without it at reduced-input version).
- **UI:** Sleep module card upgrade (Home), sleep detail with hypnogram + need-vs-actual bar, debt trend; anatomy sheet per value.
- **Notifications:** optional wind-down suggestion (via EPIC-32).
- **Testing:** state-machine fixtures (nap days, missed nights, DST, travel); need-range honesty (no fake precision minutes). **Risks:** need model overclaims → ship as range + "estimated" label until validated.
- **Phase 2 · Prereqs:** EPIC-23. **Approval:** copy review only.

### EPIC-25 — Readiness engine v2 (recovery-equivalent)
- **Outcome:** a 0–100 morning Readiness score from overnight HRV, RHR, respiratory rate, and sleep performance — formula published, per-input contribution visible.
- **Scoring:** per-input personal z-position (vs EPIC-23 baselines) → weighted composite (launch weights: HRV 0.5, RHR 0.2, RR 0.1, sleep 0.2 — BADAN's own, deliberately *not* WHOOP's claimed weights; documented with rationale and citations in `docs/algorithms/readiness.md`); input-completeness rules (missing HRV → reduced-input variant with capped confidence, never silent imputation); source-priority conflict resolution when two devices report HRV (existing dedup + priority machinery).
- **Inputs:** overnight HRV aggregates, RHR, RR, `sleep.performance`. **Pipeline:** computed once per morning when overnight data lands; recomputed (appended) if late data arrives.
- **UI:** Readiness hero card (exists — rewire), anatomy sheet with contribution bars + formula + version; calibration state.
- **Settings:** none at launch; personalized weighting is a premium Phase-4 candidate (MONETIZATION A5).
- **Testing:** golden composites; missing-input matrix; two-source HRV conflict fixture. **Risks:** Apple-Watch HRV sparsity → confidence labeling; users compare numbers to WHOOP → publish "why ours differs" education page.
- **Phase 2 · Prereqs:** EPIC-01/02/23. **Approval:** **A3** (naming + publication).

### EPIC-26 — Effort engine (strain-equivalent)
- **Outcome:** a continuous daily cardiovascular-load score (0–21 log scale for familiarity, or 0–100 — decide in A3) from time-in-zone, plus per-workout effort, zone views, and a readiness-linked daily guidance range.
- **Scoring:** zones from user HR max (profile field; default 208 − 0.7·age, editable); zone weights on a published log curve (BADAN-designed constants); day score = f(Σ weighted zone-minutes), monotonic, diminishing; workout effort = same curve over session window; HR-max edit triggers historical backfill recompute (append-only supersession, I2).
- **Inputs:** continuous HR raw samples, workouts (EPIC-03), profile. **Pipeline:** incremental intraday recompute on ingest; final at day close.
- **UI:** Effort card with day progress; workout detail zone bars + effort; guidance range copy from Readiness ("a gentler range may suit today: under 12") — wellness-safe, never prescriptive.
- **Testing:** curve monotonicity properties; backfill supersession; zone-boundary fixtures. **Risks:** iPhone-only users (no continuous HR) get near-zero Effort → detect and show steps/energy-based "activity load (reduced-input)" variant with distinct label instead of a misleading zero.
- **Phase 2 · Prereqs:** EPIC-01/03/07. **Approval:** **A3**.

### EPIC-27 — Health Monitor surface
- **Outcome:** a vitals dashboard (RHR, HRV, RR, SpO2, wrist-temp deviation) with personal-band deviation chips and per-source sensor-quality labels — `whoop.md` §5's trust-differentiator recommendation.
- **Logic:** `DeviationEngine` = existing baseline bands + calm out-of-band annotation; temp shown only as deviation-from-baseline; per-source quality map (`Source.sensorQuality`) seeded from a published table in `packages/contracts/sensor_quality.json` (e.g., wrist temp: medium; finger temp: high).
- **UI:** Health Monitor screen (new, under Body), tiles with sparkline + band; tile → metric detail. Casual: tiles only; power: bands, n, source labels.
- **Notifications:** optional "outside your typical range" calm notice (EPIC-32 budget).
- **Testing:** band classification fixtures; quality-label rendering; no-data/stale states. **Risks:** deviation alarms read as diagnosis → copy lint + "not a medical evaluation" persistent footer.
- **Phase 2 · Prereqs:** EPIC-01/02/23. **Approval:** No.

### EPIC-28 — Workout & strength logging + PR tracking
- **Outcome:** set/rep/weight strength logging feeding muscular-load approximation; PR detection and trend views (ships ahead of WHOOP).
- **Scope:** `workout.strength.*` reserved namespace activates; `strength_sets` table (session-linked); Epley/Brzycki e1RM (both shown, labeled as estimates); PR events (per movement × rep-range) as derived rows; volume/week trends.
- **UI:** strength logging flow inside WorkoutLogView (fast entry, previous-set memory), movement dictionary (bilingual), PR badges (calm, not gamified), trends screen.
- **Testing:** e1RM goldens; PR detection edge cases (tie, unit switch). **Risks:** logging friction → template workouts + repeat-last.
- **Phase 3 · Prereqs:** EPIC-03. **Approval:** No.

### EPIC-29 — Journal & behavior correlation engine
- **Outcome:** structured behavior journal + on-device correlation analysis against Readiness/sleep with honest statistics — sample size, effect direction, confidence, "association ≠ cause."
- **Logic:** `CorrelationEngine` batch job: for each behavior with ≥ N=14 logged days and ≥5 in each arm, paired comparison of next-day score distributions (Cliff's delta effect size + bootstrap CI — avoids parametric assumptions); findings stored as `DerivedValue` rows (metric id `journal.correlation.<behaviorId>.<scoreId>`) and rendered via new Insight templates showing n and CI.
- **Also:** `ContextStatus` intervals (travel/illness/fasting) annotating engine confidence.
- **UI:** one-screen daily journal (chips, yesterday-recall), correlations list (power mode shows the numbers; casual shows the sentence), context status manager.
- **Testing:** correlation goldens incl. null cases (must report "no clear association"); minimum-n enforcement. **Risks:** false-causal reading → template language locked by lint; small-n suppression mandatory.
- **Phase 3 · Prereqs:** EPIC-25 (needs scores to correlate). **Approval:** stats-copy review.

### EPIC-30 — Cycle context
- **Outcome:** cycle-phase overlay on Readiness/sleep charts; phase-conditioned baselines via the reserved `covariateContext`.
- **Scope:** read HK/HC menstrual types + manual entry; `CycleContext` entity (§9.11); overlay rendering; double-gated consent (I7 + cycle-specific toggle); phase-aware baseline contexts only after ≥2 recorded cycles.
- **Testing:** phase inference fixtures; consent gating; export exclusion default. **Risks:** high sensitivity — Phase 2 of privacy review (§17) before any store submission containing it.
- **Phase 3 · Prereqs:** EPIC-23. **Approval:** sensitivity review.

### EPIC-31 — Weekly/monthly reports
- **Outcome:** deterministic periodic reports (sleep, effort, readiness, adherence, notable changes) as an in-app surface and a shareable artifact — WHOOP's Performance Assessment, transparent edition.
- **Scope:** `ReportBuilder` (pure function over derived store → typed report model), `ReportRenderer` (HTML→PDF via `UIMarkupTextPrintFormatter`/WebView print on iOS; `PdfDocument` on Android), `reports` table (§9.12); report links every claim to its evidence (record ids), en+ar.
- **Testing:** snapshot of report model (not pixels) + rendering smoke; empty-week handling. **Risks:** report copy drifting from wellness-safe register → same lint pipeline.
- **Phase 3 · Prereqs:** EPIC-24/25/26. **Approval:** No.

### EPIC-32 — Notifications, daily summaries, adaptive prompts
- **Outcome:** a budgeted `NotificationDecisionEngine` (blueprint §24.6 pattern) extending the existing med-reminder scheduler: morning readiness summary, evening wind-down, calm deviation notices, export-failure alerts (from EPIC-16). Default ≤2/day, every class individually opt-in, all local.
- **Scope:** decision layer with per-class budget + quiet hours; deep links to evidence screens; respects the 64-pending cap alongside med reminders (existing cap logic extends).
- **Testing:** budget enforcement; class opt-in matrix; cap interplay with med reminders. **Risks:** notification fatigue → budget is a hard invariant, not a preference.
- **Phase 3 · Prereqs:** EPIC-24/25 (content), EPIC-04 (timely computation). **Approval:** No.

### EPIC-33 — Widgets & shortcuts surfaces
- **Outcome:** first widget wave per blueprint §24: `ring_single` (Readiness), `one_true_sentence`, `meds_due`, `sleep_last_night` (iOS WidgetKit + lock-screen variants; Android Glance equivalents), driven by the `AmbientSnapshotWriter` app-group snapshot with locked-state redaction.
- **Scope:** new `BadanWidgets` extension target (project.yml), snapshot store + reload triggers on derivation events; per-family widget consent keys; deep links.
- **Testing:** snapshot schema tolerance (N-1), deep-link resolution, RTL/theme renders. **Risks:** extension memory limits → bounded snapshot DTO only (never DB access from extension — blueprint decision honored).
- **Phase 3 · Prereqs:** EPIC-25 (score to show), EPIC-19 (intents for interactive widgets later). **Approval:** No.

### EPIC-34 — Stress monitor (device-gated)
- **Outcome:** daytime autonomic-load trend **only** where data density supports it; honest absence elsewhere.
- **Scope:** density detector (samples/hour threshold over trailing week) decides surface state: full intraday index (dense vendor data, Phase 4), daily low-confidence trend (moderate), or hidden with explanation ("your device doesn't record daytime HRV often enough for this"). Sliding-window HRV index with published method.
- **Testing:** density gating fixtures; no-surface state. **Risks:** the biggest false-precision trap in the plan — the gate is the feature.
- **Phase 3 (gate + trend) / Phase 4 (vendor-dense) · Prereqs:** EPIC-01; vendors for full version. **Approval:** confidence-copy review.

### EPIC-35 — AI coach & memory (Phase 4)
- **Outcome:** conversational coach answering only from the user's own normalized data with citations (record/derived-value refs), bilingual (Arabic first-class); editable, deletable memory; proactive check-ins through the EPIC-32 budget.
- **Scope:** retrieval layer over SQLite (structured retrieval — SQL feature extraction into prompt context — before any vector store; add embeddings only if needed); hosting per decision A9 (on-device model vs private inference endpoint); hard guardrails: no diagnosis, no medication advice, refusal templates, every claim cites local evidence; `AIMemory` entity (§9.13).
- **Backend:** only if A9 chooses hosted inference (stateless proxy, no retention).
- **Testing:** guardrail red-team suite; citation-integrity checks (every claim resolves to a real row); Arabic quality eval. **Risks:** the wellness-safe register is harder to guarantee from a generative model → template-constrained response formats for sensitive intents.
- **Phase 4 · Prereqs:** EPIC-24/25/26/29 (things to talk about). **Approval:** **A9** (hosting), copy governance.

### EPIC-36 — Vitality Trend (healthspan-equivalent, Phase 5, approval-gated)
- **Outcome (if approved):** a directional long-horizon wellness index over sleep consistency/duration, activity, zone-time, strength time, VO2 trend, RHR — explicitly **not** an age, per-weight citations published, refuses to compute below data thresholds (adapting WHOOP's unlock gate as an honesty device).
- **Constraints:** every MONETIZATION §4 condition is a hard requirement; never the paywall headline.
- **Phase 5 · Prereqs:** ≥6 months real user history, EPIC-23/24/26. **Approval:** **A5**.

### EPIC-37 — Vendor integration platform (Garmin, Oura first)
- **Outcome:** BADAN ingests Garmin/Oura data via a minimal backend broker; device remains the source of truth; vendor rows carry full provenance.
- **Scope:** backend (`backend/api` activation): OAuth PKCE flows, token vault, per-vendor pull workers, normalized DTO batch endpoint; device: `VendorSourceAdapter` conforming to `HealthStorePort`-adjacent contract, batch fetch + ingest through the existing pipeline; per-family source-priority defaults (Oura > Watch for sleep; Garmin > Watch for training load inputs — user-overridable); vendor VO2/HRV never blended with platform values (§4 rule 7).
- **Backend storage policy:** tokens + sync cursors + transient batches only; no durable raw health storage without a further ADR.
- **Admin:** Garmin developer-program application filed at Phase 3 start (lead time).
- **Testing:** broker contract tests; token-revocation flows; dedup fixtures for vendor-platform overlap. **Risks:** ADR-0002 supersession changes the privacy story materially → policy rewrite + store-listing updates are epic tasks, not afterthoughts.
- **Phase 4 · Prereqs:** **A4 approval**, EPIC-25/26 (so vendor data improves visible scores). **Approval:** **A4**.

### v1.1 domain epics (EPIC-38…44)

Cards follow the same conventions; full task lists (importing the source backlogs HYD/CYCLE/PREG/LAB/ACC/W verbatim) are in §20.

#### EPIC-38 — Hydration module
- **Outcome:** a local-first fluid-intake ledger with 2-second logging, equal-status no-goal mode, suppressible calm reminders, platform sync, and full export — hydration as *evidence first, inference second*.
- **Pipeline:** `HydrationEntry` ledger → daily summaries (manual/imported/estimated totals separated) → `ReminderPolicyEngine` (7–14-day local-notification plans, recomputed on logs/actions/tz/workout/fasting changes, fixed reminders pre-scheduled, contextual best-effort) → deterministic insights (min-n gated).
- **UI:** Today card in LogHub (favorites + calm progress + recents), custom sheet (amount/beverage/time/tag/note), goal settings, fasting/Ramadan profile, weekly card. Watch/widget surfaces via EPIC-44.
- **Safety rails:** no dehydration claims, no net-hydration multipliers, no streaks/shame, fasting-window total silence, purpose-bound consent per context, mL canonical with Arabic numeral parsing (exists in `DecimalParsing`).
- **Phase 1 (ledger+quick log+goals+export) / 2 (reminders+platform sync+fasting) / 3 (metadata+insights+contexts) · Prereqs:** EPIC-07 (ontology ids), EPIC-32 (budget). **Approval:** wording/caps/redaction set (bundled into A24 copy governance) + Ramadan copy cultural review.

#### EPIC-39 — Cycle intelligence (supersedes EPIC-30)
- **Outcome:** sensitive, local-first cycle logging + windowed prediction + calm anomaly cards + **phase-conditioned baselines in the core engine** — the corrective (not cosmetic) answer to WHOOP-class luteal false alarms, serving the blueprint's Mariam archetype.
- **Pipeline:** `CycleRecord`/`FlowLog`/signals → tiered predictor (weighted median of last 3–6 cycles, personal-variance interval, context-aware suppression) → `CyclePhaseEstimate` daily (confidence + evidence basis) → `covariateContext` baselines → anomaly rules (7-class matrix, min-history gates, escalation on persistence) → insight templates from the imported phrasing library.
- **Consent stack:** platform → module → sync → cloud-AI → (later) sexual-activity — five separate gates; hide/pause/purge tri-state; export default-off every time.
- **Phase 2 (baseline hook) / 3 (module v1 = CYCLE-01…08) / 3.5–4 (BBT, ovulation tests, import, fertile window per A17) / 4+ (mucus, sexual activity, sharing) · Prereqs:** EPIC-23. **Approval:** consent + anomaly copy (founder/legal), **A17** for fertile window.

#### EPIC-40 — Pregnancy calendar
- **Outcome:** the highest-stakes module, built as personal wellness organizer: seven user-declared modes, provenance-first due dates, week-by-week education shell, and **loss handling as a foundational feature** (1–2-tap declaration, same-session notification suppression, keep/archive/delete choice, grief-appropriate copy).
- **Sequencing law (from source):** mode model + due-date provenance + privacy/consent architecture first; safety copy drafted early and routed through clinical/legal review *in parallel with* engineering; loss handling built alongside — never after — the confirmed-pregnancy flow.
- **Integrations:** period tracker (TTC overlays, cycle predictions pause not delete, postpartum reactivation), lab notebook (`ScreeningTestReference`), meds/weight/symptoms via context tags, HealthKit `Pregnancy` one-way write, per-event calendar export.
- **Phase 3 (PREG-01…06: modes, due dates, content shell, loss, storage/consent, entity reuse) / 4 (kick/contraction after copy review, lab handoff, HK category, calendar) / 4–5 (mood+resources, postpartum, checklist, multiples content) / 5 (journal, sharing) · Prereqs:** EPIC-39 (period tracker), EPIC-41 for handoff. **Approval:** **A18** (module go + clinical advisor + GCC/Oman legal review); loss-flow copy needs clinical+legal+product leadership sign-off.

#### EPIC-41 — Lab results notebook
- **Outcome:** a durable, provenance-first personal laboratory record system — original artifacts preserved, analyte-level structure where safe, source wording where not, four-concept reference-range separation, OCR with human review, bilingual/RTL throughout. "A notebook, not a chart."
- **IA (10 surfaces):** Notebook Home, results timeline, reports, panels, markers (+detail with trend/interval/baseline overlays), collections, imports & review queue, notes & questions, exports, settings/privacy — each with casual (one calm sentence → chart → details) and power (raw rows, codes, lineage) altitudes.
- **Ingestion order:** PDF/photo+OCR-review + manual (universal, first) → HealthKit Clinical Records (iOS MVP+) → HC Medical Records (Phase 4, experimental) → CSV/JSON → FHIR bundles/connectors (Phase 5, A4).
- **Phase 3 (LAB-01…11: schema, vault, manual, browsers, report viewer, basic OCR+review, units, ranges, export v1, HK clinical) / 4 (LAB-12…16: baselines/trends, HC medical, AI summaries, collections, dedupe) / 5 (LAB-17/18: FHIR import, sharing) · Prereqs:** EPIC-08 (export contracts), migration capacity. **Approval:** ontology + OCR pipeline + range engine + export scope (product); **A19** (cloud OCR/LLM posture); AI summaries under A9/A25.

#### EPIC-42 — Live exercise monitor / workout OS (revises v1.0 live-workout deferral)
- **Outcome:** a trustworthy workout operating system: crash-safe lifecycle state machine, modality-aware live screens, strength as flagship SOR, provenance-visible metrics, offline-first capture — phone-first now, watch-first at Phase 4.
- **Structural law (from source):** the canonical session model + checkpointed local write path **block everything else**; live surfaces never ship ahead of them. Apple: correct end sequence + crash recovery + `prepare()` countdown; Android: BADAN-owned foreground-service runtime separate from HC persistence, batched idempotent writes.
- **Merges:** absorbs EPIC-28 (strength/PR) as its strength workstream; extends EPIC-03 (sessions/routes), EPIC-26 (zones/effort feed), EPIC-12 (GPX + privacy clipping).
- **Phase 3 (MVP: quick starts, state machine + checkpoints, run/walk/cycle basics, strength runner, post-workout notebook v1, provenance badges, export bundle, offline) / 4 (intervals+cues, Live Activities, Siri intents, watch app + complications, training-load views, AI summaries, FIT/TCX import, duplicate-merge UI) / 5 (Wear OS companion, vendor reconciliation depth, route replay) · Prereqs:** EPIC-03/04/05/23. **Approval:** **A22** (watch-app acceleration + phone-only live scope); guidance-copy review; emergency-affordance explicitly out until legal review.

#### EPIC-43 — Device ecosystem & BLE accessory framework
- **Outcome:** the most honest provenance/reconciliation layer in the category: an 11-route integration doctrine, a GATT abstraction covering ten service families, a Device Hub with sync history and a Source Priority Editor, and a reconciliation engine that **never silently merges disagreement**.
- **Architecture:** GATT service adapters (one per family, zero per-device code) + AccessorySetupKit/defensive Android BLE; `DataConflict`→`SourcePriorityRule`→journaled decision reusing `dedup_decisions`; `ConsentGrant` append-only ledger; SDK data-access boundary enforced structurally; per-category ship checklist (§27 gate G8).
- **Phase 3 (ACC-001…008, 015: platform flows hardened, GATT layer for HR/power/cadence/scales, reconciliation v2, file+document import, Device Hub, raw export, RTL pass) / 4 (FTMS, vitals BLE w/ safety copy, Strava, Garmin API after A20, clinical records) / 4+ (Dexcom after A21; research-spike vendors) · Prereqs:** EPIC-01/02 (canonical model breadth). **Approval:** **A20** (Garmin license budget), **A21** (Dexcom/glucose legal gate), **A25** (clinical advisor for vitals copy).

#### EPIC-44 — Ambient surface system v2 (extends EPIC-33)
- **Outcome:** the full calm-radar/data-cockpit ambient layer: widget catalog across every platform surface, complication system, Live Activities, presets, and a privacy-mode architecture where lock screens never leak.
- **Task 1:** W-01…12 ↔ blueprint WGT-I-01…16 crosswalk; blueprint snapshot pattern wins (bounded app-group DTO, locked-redaction variant, no extension DB access).
- **Phase 3 (wave 1 = EPIC-33 scope + One True Sentence pipeline + hydration/activity widgets + privacy modes + freshness tiers + App Intents families) / 4 (complications + Smart Stack + glance screen with watch app; Live Activities; power widgets; presets) / 5 (iPad dashboards, Wear tiles/complications, correlation widgets) · Prereqs:** EPIC-24/25/27 (content), EPIC-32 (budget), EPIC-19 (intents), A22 (watch). **Approval:** **A24** (One True Sentence tone + privacy defaults + band-label semantics).

---

## 12. Export and automation execution plan

Common properties: **generation is offline and lint-enforced (§8.3); every run writes an `ExportRun`; every artifact gets a manifest with `export_schema_version` and checksums; file naming follows `BADAN_<template-or-bundle>_<YYYYMMDD>-<YYYYMMDD>[_partN].<ext>` in folder scheme `BADAN/Exports/<year>/<month>/`; retries are idempotent via cursors + manifest chaining; failure UX routes through the Export Health dashboard (EPIC-16).**

### EPIC-08 — Export schema v1.0
- **Story:** as a downstream consumer (script, notebook, AI agent), I can rely on a versioned, documented, timezone-correct schema that never breaks silently.
- **Contract:** bump 0.1.0 → 1.0.0: keep all 24 CSV columns; append `granularity` (`raw|second|minute|hour|day|week|month|year`) and `aggregation_method` (`none|sum|mean|min|max|min_avg_max|duration|latest`) (A1); JSON bundle gains `export_schema_version`, ISO-8601-with-offset timestamps everywhere (replacing epoch-ms in the bundle's public face; internal storage unchanged), `workouts[]` parent objects with `hr_series_ref`/`route_ref`, tagged-union payload documentation per type; changelog file begun.
- **Modules:** `packages/export-schemas/` (csv_columns.json v2, json_bundle.schema.json new, CHANGELOG.md new), `CSVWriter.swift`/`CsvWriter.kt`, `JSONBundleWriter.swift`/`JsonBundleWriter.kt`, `ExportRunner` manifest fields.
- **Platform limits:** none. **Approval:** **A1**.

### EPIC-09 — Export template system
- **Story:** as any user, I can save an export configuration once and rerun it in one tap (and later, on a schedule).
- **Scope:** `ExportTemplate` entity + repository + migration v4; template CRUD UI in Export Center; run-through to existing `ExportRunner`; sensitive scopes re-confirm at run (passphrase path unchanged); config included in backup.
- **Input rules:** template stores scope + rangeRule; `sinceLastRun` requires a cursor (EPIC-17) else falls back to lastNDays with a notice.
- **Failure UX:** template run failures appear in Export Health with one-tap retry.
- **Approval:** No.

### EPIC-10 — Quick Export flow
- **Story:** casual user: "give me my data" in ≤3 taps.
- **Scope:** Quick Export card at top of Export Center: presets (Last 7 / Last 30 / All time) × format toggle (CSV/JSON) → share sheet. Presets are seeded read-only templates. **Excludes** sensitive namespaces and routes always (explicit builder path required for those — privacy default).
- **Output:** single bundle file (JSON) or zip of CSVs; streaming/chunked generation for all-time ranges (writers already stream; add chunked memory test at 1M rows).
- **Approval:** No.

### EPIC-11 — Advanced export builder
- **Story:** power user: arbitrary scope — metrics, families, sources, date range, granularity, layout, raw/derived/suppressed toggles, sensitive/route opt-ins — then save as template.
- **Scope:** builder UI (searchable metric multi-select reusing `BodyAllMetricsBrowser` search, category groups, range picker, granularity + method selector, tidy/wide layout choice); wide layout emitted by a new `WideCSVProjector` over tidy rows (single source of truth).
- **Approval:** No.

### EPIC-12 — GPX / workout route export
- **Story:** athlete exports workouts with routes to Strava-compatible GPX.
- **Contract:** GPX 1.1, `<trk><trkseg><trkpt lat lon><ele><time>` from `route_points`; one file per route; workout summary stays in CSV/JSON with `route_ref` filename linkage; zip bundling when >1 route.
- **Privacy:** requires route-export toggle (distinct from route-ingestion consent); per-run confirmation lists route count + date span; never in Quick Export.
- **Modules:** `Export/GPXWriter.swift` (+ Kotlin mirror), `RouteRepository`.
- **Approval:** consent copy.

### EPIC-13 — Aggregated metric exporter
- **Story:** user exports hourly/daily/weekly buckets instead of raw samples.
- **Scope:** SQL `GROUP BY` aggregation layer over canonical tables (not HK statistics queries — export must reflect BADAN's deduped canonical store, not the platform's), min/avg/max + sum per registry aggregation hint; every record stamped with `granularity`+`aggregation_method` (closing the HAE ambiguity gap); day boundaries computed in the row's `tz_id` (DST-correct, fixture-tested).
- **Approval:** No (contract via A1).

### EPIC-14 — Destinations v1: Files/iCloud folder
- **Story:** exports land in a user-chosen folder (iCloud Drive, local, third-party file provider) without the share-sheet dance.
- **Scope:** `ExportDestination(kind: fileFolder)` with security-scoped bookmark (iOS) / SAF tree URI (Android); write-through with `.complete` protection; destination verification ping (write+delete probe file); folder scheme applied.
- **Failure model:** bookmark/URI invalidation → destination status `unreachable` + Export Health alert + re-pick flow.
- **Approval:** No.

### EPIC-15 — Scheduling & automation engine
- **Story:** "keep my iCloud folder up to date daily" — with the app honest about what "daily" means on each platform.
- **Scope:** `AutomationSchedule` entity; `AutomationEngine` invoked by EPIC-04/05 substrate wakeups: evaluates due schedules (cadence satisfied? quiet hours? data new since cursor?), runs template → destination, records `ExportRun`; **tier labels in UI** (iOS: "Best-effort background — typically runs when your phone is active and charging"; "Runs via Shortcuts at a time you set — phone must be unlocked"; Android: "Scheduled — usually within an hour of the target"); failure budget: 3 consecutive failures → notification + schedule paused visibly (never silent death — the anti-HAE-complaint design).
- **Idempotency:** runs are cursor-bounded; a retried run reuses the same cursor window and manifest chain.
- **Platform limits:** stated per §13/§14; wall-clock promises only via Shortcuts tier (user-created) or future server tier.
- **Approval:** rides on A2.

### EPIC-16 — Export & Automation Health center
- **Story:** the user can always answer "did my automation actually run?" in one glance.
- **Scope:** dashboard: per-template last success, next expected window (estimate language), run history with outcome chips, sanitized error detail, one-tap "run now"; `BackgroundRun` substrate stats in a power-mode diagnostics section; export-failure notification class (via EPIC-32, available early as a simple local notification).
- **Approval:** No.

### EPIC-17 — Incremental/delta export
- **Story:** automation exports only what's new, verifiably.
- **Contract:** `ExportCursor` high-watermark on `ingested_at`; each delta manifest carries `previous_manifest_sha`, `cursor_before/after`, `is_delta: true`; consumers can verify chain integrity; tombstoned rows since cursor exported in a `deletions[]` section (id + deleted_at) so downstream stores can reconcile.
- **Edge rules:** cursor reset UI ("re-export everything"); suppression changes (dedup flips) emit correction records.
- **Approval:** No.

### EPIC-18 — Full backup & restore export
- **Story:** one artifact containing everything: all namespaces (with consent), config (templates, schedules, customization), schema docs — restorable.
- **Scope:** extends BackupRestoreSettingsScreen; bundle = JSON v1.0 full-scope + `config.*` + `DATA_DICTIONARY.md` + manifest; encrypted variant via existing `ExportEncryptor` (whole-bundle passphrase, not only sensitive); **restore** = staged import through `import_batches` with preview + batch undo; destination credentials never in plaintext bundles.
- **Approval:** No.

### EPIC-19 — Shortcuts / App Intents
- **Story:** "run my morning export at 7:30" via a Shortcuts personal automation — the only honest fixed-time path on iOS.
- **Scope:** `RunExportTemplateIntent` (template parameter, returns file/result), `GetLatestScoreIntent` (Readiness/sleep values for user automations), `LogWaterIntent` (quick log + future interactive widget); in-app setup guide that walks the user through creating the time-of-day automation, states the unlock requirement, and links Shortcuts directly.
- **Android analog:** app shortcuts + "run template" quick-settings tile; no full Shortcuts equivalent — labeled Approximate parity.
- **Approval:** No.

### EPIC-20 — REST API destination
- **Story:** developer/QS user posts every export (or delta) to their own endpoint.
- **Contract (§22.7):** POST with JSON bundle or NDJSON stream; headers: `X-Badan-Schema-Version`, `X-Badan-Manifest-Sha`, `Idempotency-Key` (= manifest sha); auth: bearer token from Keychain; response contract: 2xx success, 409 duplicate treated as success, 5xx/timeout → capped exponential backoff (3 tries) then Export Health failure; HTTPS enforced (HTTP only behind an explicit "I understand" developer toggle for LAN use).
- **Consent:** first-save confirmation: "BADAN will send the selected health data to a server you control. BADAN never chooses this destination for you."
- **Approval:** consent copy.

### EPIC-21 — Cloud-drive connectors (Dropbox / Google Drive)
- **Story:** exports land in Dropbox/GDrive without a BADAN backend (vendor SDKs, on-device OAuth).
- **Scope:** provider adapters behind a `CloudDriveDestination` protocol; minimal scopes (app-folder where offered); tokens in Keychain/Keystore; deferred to Phase 4 (Files/iCloud covers most value earlier).
- **Approval:** token-handling policy sign-off.

### EPIC-22 — Schema documentation & data dictionary
- **Story:** every export can carry its own docs; the repo publishes the contract.
- **Scope:** `scripts/gen_data_dictionary.py` generating `DATA_DICTIONARY.md` from `packages/export-schemas/` + registry (columns, types, units, enums, per-metric payload notes); optional inclusion in bundles; `docs/export-schema-changelog.md`; versioning policy (additive = minor; breaking = major with migration notes).
- **Approval:** No.

### EPIC-04 / EPIC-05 — Background substrate (iOS / Android)
Defined here because automation depends on them; ingestion epics share them.
- **iOS (EPIC-04):** add `com.apple.developer.healthkit.background-delivery` entitlement; `HealthKitObserverRegistrar` (observer query per read type, `enableBackgroundDelivery` .hourly for HR-family / .daily others); **completion-handler discipline** — handler called within seconds on every wake regardless of work outcome (3-strikes rule), work continues under a `BGProcessingTask` if long; proactive re-enable on app open; `BGTaskScheduler` registration (`net.albayyan.badan.refresh` app-refresh + `net.albayyan.badan.processing` for exports/backfills, submitted with earliestBeginDate hints, charging-preferred for processing); locked-store detection (`skippedLocked` outcome, retry on next wake); `BackgroundRun` logging throughout.
- **Android (EPIC-05):** `WorkManager` periodic sync worker (1h, constraints: battery-not-low), expedited one-off for user-triggered runs; changes-token incremental HC reads; Doze/OEM-throttle outcomes logged; automation evaluation piggybacks the sync worker.
- **Honest parity labels:** iOS scheduled exports = **Approximate**; Android = **Approximate-to-Exact**; both surfaced in UI copy (EPIC-15).
- **Approval:** **A2**.

### EPIC-06 — Android export encryption parity
- **Story:** sensitive exports on Android get the identical `BDNX` container: PBKDF2-HMAC-SHA256 (600k rounds) + AES-256-GCM, same magic/header/versioning, cross-platform decryptable.
- **Scope:** Kotlin `ExportEncryptor` mirroring `ExportEncryption.swift` byte-for-byte; shared fixture: iOS-encrypted container decrypts on Android and vice versa; passphrase policy shared (min 10 chars).
- **Approval:** No.

---

## 13. iOS implementation plan

### 13.1 HealthKit permission strategy
- **Staged bundles, extended:** the existing staged-permission pattern grows to family bundles requested contextually: core vitals (HRV, RR, SpO2, temp) when the user opens Health Monitor or during onboarding's "connect" step; workouts+energy+distance when opening workout surfaces; routes **only** from an explicit route-consent screen; body metrics from Body; cycle types only from the cycle opt-in flow. Never one blanket prompt (`HAE.md` §10).
- **Copy:** `NSHealthShareUsageDescription` rewritten to cover the widened read set in plain language (en+ar `InfoPlist.strings` exist); per-family in-app explainers precede every system prompt (the system dialog is never the first explanation).
- **Read-only posture retained** (no `NSHealthUpdateUsageDescription`) until a write need exists (none in this plan — BADAN does not write to HealthKit in Phases 0–4).
- **`PermissionState` honesty:** HealthKit cannot report read-denial distinctly; the existing partial/denied inference stays, and empty-result-with-granted-anchor heuristics feed the permission-recovery screen (§16).

### 13.2 Querying strategies
- **`HKAnchoredObjectQuery`** (existing pattern) for all discrete/sample types: HRV(SDNN), RR, SpO2, wrist temperature, weight/body-fat/lean mass, VO2 max, workouts, cycle categories. Anchors persisted via the existing `ReadAnchorRepository` two-phase commit (`pendingAnchors` → `commitPendingAnchors` after txn — DATA-08 discipline extends to every new type).
- **`HKStatisticsCollectionQuery`** (existing pattern for steps) extends to active energy, basal energy, distance, flights — cumulative types where cross-source overlap must resolve by recompute, not anchor.
- **`HKWorkoutRouteQuery`** streamed per workout; route points batched (500/insert) into `route_points`.
- **Workout HR series:** predicate-scoped HR sample query per workout window (reuses raw HR already ingested where possible; `hr_series_ref` resolves from canonical store, not duplicate storage).
- **ECG/irregular-rhythm (Phase 3+):** `HKElectrocardiogram`/category pass-through, stored as sessions with clinical flag, export-only surfaces first.

### 13.3 Background delivery — honest architecture
Per `HAE.md` §4/§6, restated as build rules:
- Observer wake = "something changed," never payload: always follow with anchored re-query (existing sync path is exactly this — it just gains a background entry point).
- Completion handler called immediately after scheduling local work — never awaited on ingest completion (3-strikes protection); re-`enableBackgroundDelivery` on every app open (defensive re-registration).
- Locked store: background reads return empty while device locked since last unlock in some states → detect via `protectedDataAvailable`, log `skippedLocked`, rely on next wake. Never report these as failures to the user; they are the platform working as designed.
- **Reliability truth table shipped in UI copy:** background sync = *best effort*; typical freshness target = "within a few hours"; guaranteed freshness = only when app opens.

### 13.4 BGTaskScheduler strategy
- `BGAppRefreshTask` (`net.albayyan.badan.refresh`): light — evaluate due automations, top-up sync if anchors stale >6h. Submitted on every backgrounding.
- `BGProcessingTask` (`net.albayyan.badan.processing`, requiresExternalPower-preferred, not required): heavy — large exports, historical backfills (HR-max recompute, import jobs). Checkpointed: every job writes progress (cursor/step) so expiration → resume, mirroring `SeedController.needsBackfillResume()`'s existing pattern.
- Expiration handlers always checkpoint-and-exit cleanly; `BackgroundRun` rows record `expired`.

### 13.5 App Intents / Shortcuts, widgets, watchOS
- Intents per EPIC-19 (`Sources/Platform/Intents/`); parameters resolve from template names; intents donate for Siri suggestions.
- Widgets per EPIC-33: new `BadanWidgets` extension target in `project.yml` + app group (`group.net.binjamshid.badan`) — **first app-group usage in the repo; entitlement change bundled with A2's review**. Snapshot pattern per blueprint §24.1 with `today.locked.json` redacted variant.
- watchOS: deferred to Phase 5; the snapshot store + plain-value repository read APIs are the forward payment (already the convention).

### 13.6 Files/iCloud, local network, privacy manifests
- File destinations via `UIDocumentPickerViewController` folder pick + security-scoped bookmarks (persisted in destination config; staleness handled per EPIC-14).
- Local-network server (Phase 5 study only): would require Local Network permission + Bonjour declarations; **not** in current entitlements; TLS + token mandatory if ever built.
- `PrivacyInfo.xcprivacy`: remains honest — still no tracking, no collected data (all processing on-device; destinations are user-directed). File-timestamp and UserDefaults reasons already declared; add any new required-reason APIs as they appear in implementation review (checked per release).
- App Store metadata: background modes justification text prepared (HealthKit background delivery is entitlement-gated, not a UIBackgroundModes key; BGTask identifiers go in `Info.plist` `BGTaskSchedulerPermittedIdentifiers`).

### 13.7 Scheduling reality summary (what we may promise)

| Behavior | Reliability class | UI language |
|---|---|---|
| Export on app open | Guaranteed | "Runs when you open BADAN" |
| Manual run | Guaranteed | — |
| Shortcuts time-of-day | Reliable **if unlocked at trigger** | "Runs at your chosen time via Shortcuts; iPhone must be unlocked" |
| HK background delivery wake | Best-effort, coalesced (hours) | "Best-effort background" |
| BGAppRefresh | Opportunistic, system-decided | (internal top-up; not promised) |
| BGProcessing | Opportunistic, favors charging+idle | "Large jobs usually run while charging" |
| Fixed wall-clock without user unlock | **Unavailable on iOS** | Never promised; server tier (Phase 4+, A4) is the only path |

### 13.8 v1.1 iOS additions
- **BLE/accessories:** AccessorySetupKit (iOS 18) is the preferred pairing path — specific-accessory picker, no broad Bluetooth permission; Core Bluetooth fallback for older OS. BLE is **foreground/session-only** in all copy and code; never promise background BLE.
- **Workout runtime:** `HKWorkoutSession` + `HKLiveWorkoutBuilder` + `HKLiveWorkoutDataSource` with the mandated end sequence (`stopActivity`→`.stopped`→`endCollection`→`finishWorkout`→`end`), `prepare()`+3s countdown, crash-recovery with data-source rebuild, and the locked-device workout-data prompt enabling lock-screen Live Activity metrics. Watch-first once the watch app lands (A22); phone-only sessions omit HR tiles rather than showing zeros.
- **Clinical records:** `HKClinicalRecord` read path (FHIR R4 preserved as raw blob + normalized rows) for the lab notebook; provider-coverage honesty in UI.
- **Reproductive types:** menstrual flow/BBT/ovulation/cervical-mucus/sexual-activity category reads behind the EPIC-39 consent stack; `Pregnancy` category one-way write (EPIC-40, opt-in, never read back for inference).
- **Notifications:** loss-triggered suppression cancels scheduled locals synchronously (all-local architecture makes the "immediately, not within 24h" guarantee satisfiable); hydration/cycle/pregnancy classes register with the EPIC-32 budget engine.
- **New entitlement/plist surface (bundled into A2's review):** Bluetooth usage strings, AccessorySetupKit declarations, clinical-records HealthKit capability, Live Activities support key, workout-processing background mode when the watch app ships.

---

## 14. Android implementation plan

- **Health Connect widening (EPIC-02/03):** add record types: ExerciseSessionRecord (+ExerciseRoute), TotalCaloriesBurned, Vo2MaxRecord, WeightRecord, BodyFatRecord, LeanBodyMassRecord, SkinTemperatureRecord, FloorsClimbedRecord, MenstruationFlow/PeriodRecord (Phase 3), matching manifest `READ_*` permissions + rationale strings; changes-token incremental reads persisted in `read_anchors` (same table, `platform_type` keyed) with token-expiry fallback to windowed re-read; 30-day default history honesty — backfill banner states the achievable window per type.
- **Background (EPIC-05):** WorkManager periodic sync (1h, `setRequiresBatteryNotLow`), expedited one-off for "run now"; automation evaluation inside the worker; `BackgroundRun` logging; OEM-throttling note surfaced in Export Health ("some phones delay background work — Samsung/Xiaomi battery settings link").
- **Export/files:** SAF tree URI destinations (EPIC-14); `FileProvider` share path exists; zip via `java.util.zip`; encryption parity (EPIC-06) with `javax.crypto` (PBKDF2WithHmacSHA256 + AES/GCM/NoPadding), cross-platform container fixtures.
- **Notifications (EPIC-32):** POST_NOTIFICATIONS runtime permission flow; channels per class (readiness, wind-down, deviation, export-health, meds — meds channel work also closes the missing Android med-reminder parity noted in the audit); budget engine shared logic via fixtures.
- **Widgets:** Glance app widgets mirroring the iOS wave (EPIC-33); `GlanceStateDefinition` fed by the snapshot file.
- **Wear OS:** Phase 5 with watch.
- **Shortcuts parity:** no Shortcuts equivalent → app shortcuts (`shortcuts.xml`) + quick-settings tile ("Run export template…"); WorkManager makes *in-app* scheduling genuinely stronger than iOS — Android UI may show "Scheduled (usually within the hour)" where iOS says "best-effort"; parity labeled honestly in both directions.
- **Feature gaps vs iOS + mitigation:** no Live Activities (skip), no App Intents ecosystem (tile+shortcut approximation), sensitive-DB protection relies on FBE (SQLCipher decision remains the tracked M4 item — unchanged by this plan but re-flagged for the Phase-1 gate since automation increases unattended data handling).

### 14.1 v1.1 Android additions
- **Workout runtime:** BADAN-owned capture engine (foreground services for GPS/sensor sampling with visible notification; batched HC writes ≤1000 records/request; stable `clientRecordId` idempotency; local durable session first, HC second); HC absent/outdated → full local-only mode with guidance. OEM kill-risk (Samsung/Xiaomi) surfaced honestly; WorkManager never used for sub-minute live needs.
- **BLE:** defensive stack (fragmented OEM behavior; assume background reconnection unreliable; always a foreground reconnect affordance); narrowest permission tier (scan vs connect), never location-as-BLE-side-effect beyond OS minimums; Wear OS never paired as a BLE accessory (route via HC).
- **Cycle types:** `MenstruationPeriodRecord`, `MenstruationFlowRecord`, `BasalBodyTemperatureRecord`, `OvulationTestRecord`, `CervicalMucusRecord`, `SexualActivityRecord`, intermenstrual bleeding — background/history reads need additional permissions; no pregnancy-status type exists (BADAN-internal, asymmetry documented).
- **Medical Records (FHIR):** experimental API, Android 16 SDK, no changelog sync — Phase-4 with verification spike; PDF/manual rank first on Android for labs.
- **Legacy rule:** never build against the deprecated Google Fit REST API.

---

## 15. Shared core and backend implementation plan

| Concern | Placement | Mechanism |
|---|---|---|
| Normalization, day attribution, dedup | Native per platform (exists) | Shared conformance fixtures (`packages/fixtures/` — to be created, §23) keep them identical |
| Provenance | Native per platform (exists) | Schema + fixtures |
| Score computation (all engines) | **Strictly on-device**, native per platform | Algorithm constants/params live in `packages/contracts/algorithms/algorithms.json` — single source; both platforms load data-driven params so "duplicated logic" is curve evaluation only; golden-numeric fixtures enforce identical outputs; this stays within D-4's duplicated-logic budget (re-check at each phase gate — persistent divergence is a KMP-gate data point) |
| Export schemas, templates shape, manifest | `packages/export-schemas/` (shared spec) + native writers | Byte-identical cross-platform export fixtures (existing CI ambition, made real in Phase 1) |
| Sync checkpoints | Native, same tables | `read_anchors` (exists) + `ExportCursor` (new, same DDL both platforms) |
| User preferences / customization | Native, same singleton row | existing |
| Device/source registry + sensor-quality map | `packages/contracts/sensor_quality.json` (new shared) | loaded like registry.json |
| Reports | Native builders over shared report-model schema | report-model JSON schema in contracts; renderers native |
| AI summaries (Phase 4) | On-device retrieval; inference per A9 | guardrail prompt/templates shared in contracts |
| Observability | Native, value-free local logs | § 24; no remote telemetry through Phase 3 (unchanged posture) |
| Remote configuration | **Not introduced.** Algorithm params ship in-app, versioned | avoids a silent-behavior-change channel — algorithm changes are app updates with changelogs, which is the transparency brand |
| Backend (Phase 4 only) | `backend/api` (FastAPI or equivalent — decided at activation), `backend/workers` (vendor pollers) | Holds: OAuth tokens (encrypted), vendor cursors, transient normalized batches, (optional, A4b) push-scheduling triggers. Never: durable raw health data, score computation. `infra/` gains IaC when activated |

---

## 16. UX and information architecture plan

IA changes: **Export Center is elevated** from Body→Tools to a first-class destination (kept reachable from Body; added to Settings and as a Home tool card); new screens marked ●. For each surface: purpose · target user · primary/secondary action · density · casual/power behavior · trust copy · friction points · accessibility.

| Surface | Purpose / target | Primary action · Secondary | Density | Casual mode | Power mode | Key trust copy | Friction risks | A11y requirements |
|---|---|---|---|---|---|---|---|---|
| Quick Export card ● | 3-tap export / casual | Preset+format → Share · open builder | Low | Whole surface | Same + last-run info | "Everything here stays on your device until you share it" | preset ambiguity → show row counts before share | VO labels incl. row counts; Dynamic Type XXL |
| Advanced export builder ● | Arbitrary scope / power | Run · Save as template | High | Hidden behind "Advanced" | Full | Sensitive & routes are separate switches with their own copy | over-choice → collapsed sections, sane defaults | keyboard nav; RTL pickers |
| Template manager ● | Saved configs / power | Run · Edit/Delete/Schedule | Med | Presets read-only | CRUD | Templates never auto-include newly-sensitive data types | name collisions → inline validation | list semantics; swipe alternatives |
| Export & Automation Health ● | Trust ledger / both | Run now · View run detail | Med | Status chips + last success | + run log, BackgroundRun stats, error details | "If something didn't run, you'll see it here — nothing fails silently" | outcome-taxonomy jargon → plain-language mapping | status not color-only (chip + text) |
| Automation setup wizard ● | Create schedule honestly / both | Enable · Learn about reliability | Med | Guided 3 steps | + tier/cadence detail | Tier label mandatory step; Shortcuts path explains unlock rule before enabling | users expect cron → the wizard *is* the expectation-setting | focus order; plain-language tiers |
| Destination manager ● | Where data goes / power | Add destination · Verify | Med | Files/iCloud only visible | + REST/cloud | "BADAN never chooses a destination for you"; credential storage explained | OAuth/token confusion → per-kind guides | secure text fields; error text not color-only |
| Data-source & provenance explorer (upgrade) | Which device wins / power | Set priority · Inspect lineage | High | Simple source list (exists) | + per-family priority editor, sensor-quality labels | "Changing priority re-evaluates duplicates; nothing is deleted" (I3) | priority mental model → preview of effect | table semantics |
| Daily view (Home upgrade) | WHOOP-style loop, BADAN-calm / both | Open score detail · journal | Low | Readiness + sleep + one sentence | + Effort, monitor tiles, staleness detail | Freshness timestamp always visible | score fixation → sentence leads, number follows | ring values as text; charts have AX descriptors (exists) |
| Score detail + anatomy (extend) | Explainability / both | See anatomy · History | Med/High | Band + sentence | Formula, weights, inputs, versions, confidence | "Computed on your device. Formula published." | math intimidation → progressive disclosure (exists pattern) | formula alt-text |
| Calibration state view ● | Cold-start honesty / both | — · Learn more | Low | "Day 9 of 14" | + thresholds, n | "We don't guess before we know you" | impatience → show what already works | progress semantics |
| Health Monitor ● | Vitals at a glance / both | Tile → metric detail | Med | Tiles + calm chips | + bands, source quality | "Typical-range notices are not medical evaluations" | alarm misread → calm amber only (existing rule) | tile grid nav order |
| Journal ● | Behavior tags / both | Log today · Edit yesterday | Low | Chips only | + quantities, custom tags | "Used only on your device to find your patterns" | chore fatigue → 10-second flow, evening prompt opt-in | chip toggles as switches |
| Correlations view ● | Findings / both | Open finding · — | Med | One sentence + confidence word | + n, effect size, CI | "Association, not cause" on every card | overtrust → minimum-n gate copy | numbers spelled out for VO |
| Reports ● | Weekly/monthly review / both | Read · Export PDF | Med | Narrative sections | + tables, evidence links | Every claim links to its records | stale report confusion → regenerate affordance | logical heading order |
| Permission recovery ● | Fix denied/partial | Open Settings/Health app · explain | Low | Same | Same | Explains exactly which family is off and what stops working | deep-link limits on iOS → stepwise instructions | screenshots have alt text |
| No-data / stale / failed-sync states (systematize) | Honesty everywhere | Retry/Connect · Diagnose | Low | Calm, single action | + cause detail (`skippedLocked`, throttled…) | "Your phone limits background work; open BADAN to refresh now" | blame confusion → name the platform behavior neutrally | announce state changes (Announce.swift exists) |

Existing surfaces (Home, MetricDetail, LogHub, Settings, Sources, Onboarding) evolve in place; the onboarding "connect" step gains the staged-permission narrative and a "what BADAN never does" screen (no selling, no diagnosis, no cloud without your action).

### 16.1 v1.1 surfaces (same column discipline as the table above)

| Surface | Purpose / key rules |
|---|---|
| Hydration today card + custom sheet ● | Favorites with exact volumes; "Added 500 mL" + Undo; no-goal equal-status; hideable without deletion; observational weekly wording |
| Cycle module home ● | Status + next-window + one context sentence; 1-tap period start; confidence band + method label + "why this estimate?" anatomy; anomaly cards passive by default; RTL-mirrored calendars; neutral "cycle" vs direct "period" language choice |
| Cycle power detail ● | Full history, per-cycle stats, phase bands, confidence shifts per input, Correlation Lab (n/coverage/CI always visible) |
| Pregnancy mode surfaces ● | Due-date card with always-visible source label + 1-tap source change; weekly content card with permanent disclaimer footer; kick/contraction stopwatch tools with persistent safety footer; **"log a loss" persistently discoverable from first entry, 1–2 taps from anywhere** |
| Loss flow ● | Minimal fields, no justification, immediate suppression, keep/archive/delete (revisitable), resources in-flow, warm non-euphemistic copy |
| Lab Notebook home + marker detail + report viewer + OCR review + visit-prep ● | Calm cards (changes since last time, out-of-interval count); marker page = one sentence → chart → details; side-by-side OCR correction; source-document viewer with extraction highlights; question/packet builder; anti-panic palette (no red-per-out-of-range) |
| Workout home + live screens + post-workout notebook ● | Start Walk/Run/Strength/Workout always visible; readiness traffic-light (Ready/Limited/Missing-critical); large-type live default + compact mode; end-confirmation against accidental stops; provenance badges; quality notes; "back to simple" escape hatch everywhere |
| Strength logger ● | One-handed steppers, repeat-last, rest auto-start, superset jumps; ≤30s to log a 5×5; bilingual exercise library |
| Device Hub + Source Priority Editor + troubleshooting ● | Healthy/needs-attention/disconnected cards; "why am I seeing this value?"; disconnect vs disconnect-and-delete as separate acts; "may be connected to another app"; first-sync honesty ("pulling your last 30 days…") |
| Ambient privacy settings ● | Global high/normal/verbose + per-surface + per-metric; lock-screen redaction non-overridable for sensitive-plus; quick-mask affordance |

---

## 17. Privacy, permissions, and App Store safety plan

**Consent design**
- Per-family consent explainers before every HK/HC prompt (13.1/14); families: vitals, activity, sleep, body, workouts, **routes (own toggle)**, **cycle (own toggle + I7)**, clinical pass-through (Phase 3+).
- Consent state changes are journaled locally (extends `permission_states`) so the recovery screen can say what changed when.

**Export privacy controls**
- Local-only mode: a master switch disabling all non-`shareSheet`/`fileFolder` destinations (hides REST/cloud config entirely) — default ON until the user creates a network destination deliberately.
- Sensitive namespaces: existing `includeSensitive` + passphrase flow retained everywhere; routes and cycle get parallel independent toggles; Quick Export permanently excludes all three.
- Destination credentials: Keychain/Keystore only (§9.4); never logged, never exported, redacted in diagnostics.
- Delete/export rights: purge flows exist (I7, `purgeIngestedData`, `resetAll`); this plan adds per-batch import undo (EPIC-18 restore path) and documents rights in the policy.

**Wording guardrails (extends D-11 lint)**
- Banned register: diagnose/detect disease/treat/medical-grade/accuracy claims/"your body is stressed" as fact. Required register: "typical range," "may," "pattern," "estimated," "association." New lint terms added with EPIC-24/25/26/27/29 strings.
- AI guardrails (Phase 4): response templates for sensitive intents; refusal library; no dosing, no diagnosis, no emergency guidance (always route to local emergency norms); red-team suite in CI.

**Store review risk register**
| Risk | Exposure | Mitigation |
|---|---|---|
| App Review 1.4.1 (health harm) | Scores read as medical | Published formulas, wellness copy, "not a medical device" surfaces; no BP estimation, no age claims |
| HealthKit data misuse suspicion | New background entitlement + destinations | Review notes document on-device processing; destinations are user-configured; privacy manifest stays "no collection" |
| Background entitlement justification | Rejection risk | Concrete user-facing feature (fresh scores + scheduled exports) demonstrated in review notes |
| Play Data Safety accuracy | Widened HC permissions | Data Safety form updated in the same PR as manifest changes; rationale strings per permission |
| Policy drift | "Zero network calls" claim vs destinations | Policy rewrite (one precise amendment §8.3) **before** first destination ships; legal review item |

**Needs legal/product approval:** policy amendment text; route/cycle consent copy; Phase-4 backend DPA + policy overhaul (with A4); AI disclosure copy (with A9).

### 17.1 v1.1 sensitivity governance (reproductive, pregnancy, labs, glucose, devices)

- **Reproductive-data threat model.** The period/pregnancy research documents the post-*Dobbs* pattern (subpoenaed cycle data, Flo/FTC signal-sharing, broker sales) and BADAN's answer: local-first by default (**local data needs a warrant; cloud data a subpoena**), zero ad/analytics SDK exposure to reproductive fields (enforced as the §41 data-access boundary, not policy prose), separate consent stacks (platform → module → sync → cloud-AI → sub-features), default-off never-sticky exports, and the blueprint-required **jurisdictional reproductive threat-model document** — written before EPIC-39 ships, covering law-enforcement request handling, residency, processor exposure, and **Oman/GCC-specific legal and cultural context** (explicitly not assumed equivalent to US/EU norms).
- **Trust wording is precise, never absolute:** "stored on this device by default," "excluded from cloud AI unless you turn that on" — never "fully private"/"unhackable."
- **Pregnancy-specific:** distinct consent screen (never bundled); no third-party SDK signal *even pseudonymized*; single-action module deletion; elevated export confirmation (friction, never a gate that can fail closed or track subscription state); loss records separately confirmed and independently deletable.
- **Lab tiers:** standard / high / very-high sensitivity with per-category **local-only storage override that survives a global sync setting**; screenshot/share warnings on exported clinical PDFs; deletion cascades re-evaluate derived trends.
- **Glucose/CGM:** most conservatively gated category — A21 legal review before any build; "personal awareness only, never treatment decisions" on every surface.
- **Clinical/legal sign-off gates (non-engineering critical path):** pregnancy content + due-date conventions + loss copy (clinical+legal+leadership); kick/contraction copy (clinical+legal); BP/SpO2/thermometer BLE copy (clinical+legal); glucose anywhere (highest scrutiny); clinical-records display (legal); cycle anomaly copy (product); the §44 safety-language matrix and §45 per-category ship checklist are imported as release-gate artifacts (§27 G8).
- **Store risk additions:** reproductive-health app scrutiny (both stores), Bluetooth permission justifications, foreground-service type declarations (Android 14+), Live Activities review notes, clinical-records entitlement justification. Data Safety / privacy-nutrition updates ride each ingestion epic as before.

---

## 18. Data science, scores, baselines, and interpretation plan

- **Baseline creation:** per-metric window + method table (published): HRV 60d trailing median/MAD (log-transformed RMSSD/SDNN before banding); RHR/RR/temp 14d; sleep-need inputs 28d. All appended `Baseline` rows; `covariateContext` reserved for cycle (EPIC-30) — additive, never retroactive rewriting.
- **Cold start:** nothing renders as a score until `provisional` clears (n≥7 and ≥half the window); calibration UI (§16) carries the wait; reduced-input variants labeled distinctly, never silently degraded.
- **Historical backfill:** on first connect, 90-day backfill (existing) feeds baselines immediately — many users get non-provisional baselines on day 1 for vitals; import (Phase 3) extends further; backfilled scores computed retroactively are labeled "computed later from history" via existing quality-flag machinery (`estimate` flag or a new `retroactive` flag — decide in EPIC-23).
- **Confidence levels:** every derived score row uses the existing `confidence` column: input completeness × baseline maturity × source quality; surfaced as words (casual: "early estimate" / "established") and numbers (power).
- **Missing data:** explicit input-completeness rules per engine (EPIC-25 pattern); no imputation of physiological inputs, ever; missing-input days render as gaps, not zeros (charts already handle gaps).
- **Source conflicts:** existing priority + dedup; per-family priority editor (§16); conflicting HRV same-night → priority source wins, loser retained + journaled (I3), anatomy sheet shows which device fed the score.
- **Personalization:** all bands personal (never population norms in v1); population context ("typical for adults") appears only in education pages, clearly separated from the user's own band.
- **Transparency & versioning:** `AlgorithmVersion` registry (§8.2); every param change = version bump + in-app changelog entry ("Readiness v1.2: respiratory-rate weighting adjusted — here's why"); old rows keep old version ids (I2 gives free auditability); `docs/algorithms/*.md` published per engine.
- **Correlation vs causation:** EPIC-29 statistical rules (min-n, effect size + CI, null reporting) + locked language.
- **Cross-metric context:** engines consume, in defined order: sleep → readiness → effort guidance; `ContextStatus` and cycle context annotate confidence and copy ("computed while you were travelling") — they modify *interpretation framing*, never the stored value.

### 18.1 v1.1 analytic systems

- **Cycle prediction:** windows not dates; central estimate = weighted median/robust mean of last 3–6 complete cycles with recency weighting + outlier resistance; interval width from personal spread, widened by context (travel, illness, med change, postpartum); tier gates 0/1–2/3–5/6+ cycles; irregular contexts **pause** prediction rather than degrade silently; UI language mapped to confidence level.
- **Cycle anomalies:** self-referential baselines (medians/IQR/rolling-MAD + persistence checks); min-history gates per class (3 single-cycle, 4–6 pattern); severity down-ranked when contextual disruptors active; severity = surfacing priority only, never clinical weight — enforced on every downstream consumer.
- **Phase-conditioned baselines:** parallel per-phase baselines via `covariateContext`; applied only above a confidence threshold, else unconditioned fallback; the luteal-false-alarm fixture is the acceptance test.
- **Lab baselines/trends:** computed only with configurable minimum points and cross-time comparability (same lab/unit/method awareness); confidence model weighs point count, unit/assay consistency, spacing, amendments, source quality (structured > OCR-reviewed > OCR-unreviewed > manual); personal baseline outside a lab interval is never framed as reassurance; qualitative results never forced onto numeric axes.
- **Workout quality/confidence:** completeness/freshness/continuity/accuracy/consistency dimensions per session; derived metrics (zone minutes, load, e1RM) stamped with formula ids; PR logic refuses partial-data records; training load = 7d/28d EWMA channels per blueprint constants.
- **Hydration insights:** deterministic rules with published min-n thresholds (§7A.1); every insight shows evidence count, coverage, sources, exclusions; AI summarizes deterministic facts only.
- **Reconciliation statistics:** conflicts are data (kept, exportable); AI/analytics must be able to disclose that a conflict existed and how it was resolved — never false unanimity.

---

## 19. Phased roadmap

### Phase 0 — Foundation and architecture hardening
- **Objectives:** every downstream epic's data exists; background substrate exists; parity debts paid.
- **Epics:** EPIC-01 (HK widening), EPIC-02 (HC widening), EPIC-03 (workouts+routes), EPIC-04/05 (background), EPIC-06 (Android encryption), EPIC-07 (ontology v0.2).
- **Excluded:** all scores, all new export UX (existing Export Center keeps working).
- **Dependencies:** A2 approval (entitlements).
- **Risks:** background-delivery behavior surprises (spike task first); permission-prompt fatigue (staged bundles).
- **Success metrics:** ≥25 of 44+ ontology metrics flowing on both platforms; anchored-sync soak green 14 days; background wake p50 latency measured and logged.
- **Exit criteria:** widened ingestion fixtures pass identically both platforms; routes ingested behind consent; `BackgroundRun` log live; Android decrypts iOS containers; migration v4 ships clean on upgrade fixtures.
- **Roles:** mobile (both platforms), QA.

### Phase 1 — Repository, provenance, and export foundation
- **Objectives:** HAE-class core export; trust surfaces; schema v1.0.
- **Epics:** EPIC-08, 09, 10, 11, 13, 14, 16 (v1), 18, 19, 22; EPIC-12 (GPX) starts once route data accumulates.
- **Excluded:** REST/cloud destinations, delta export (needs run history maturity), scheduling UI (substrate ready, honesty copy not yet user-tested).
- **Dependencies:** Phase 0; A1.
- **Risks:** CSV contract change ripples (round-trip tests protect); builder scope creep (presets first).
- **Success metrics:** export usage without support questions; zero silent failures in dogfood.
- **Exit criteria:** quick export ≤3 taps; templates run via Shortcuts; folder destinations survive re-pick cycles; v1.0 goldens byte-identical cross-platform; data dictionary generated in CI.
- **Roles:** mobile, design, QA, docs.

### Phase 2 — WHOOP-equivalent core intelligence
- **Objectives:** the daily loop: sleep suite, Readiness v2, Effort, Health Monitor — all explainable, all calibrated honestly.
- **Epics:** EPIC-23, 24, 25, 26, 27; EPIC-15 (scheduling UI) lands here too (substrate proven by then).
- **Excluded:** journal/correlations, reports, widgets, AI.
- **Dependencies:** Phase 0 data + user history accumulation; A3.
- **Risks:** score credibility (mitigate: ranges, confidence, education pages); WHOOP-number comparison complaints (education page).
- **Success metrics:** D7 retention lift among score users; anatomy-sheet open rate (power users); zero wellness-language lint escapes.
- **Exit criteria:** all four engines golden-tested both platforms; scores render at both altitudes from identical queries (fixture); calibration UX validated with fresh-install cohort; formulas published in `docs/algorithms/`.
- **Roles:** mobile, data/algorithms, design, QA, product copy.

### Phase 3 — Advanced automation and integrations
- **Objectives:** power the ambient layer and the developer path.
- **Epics:** EPIC-17 (delta), EPIC-20 (REST), EPIC-28 (strength/PR), EPIC-29 (journal/correlations), EPIC-30 (cycle), EPIC-31 (reports), EPIC-32 (notifications), EPIC-33 (widgets), EPIC-34 (stress gate), Apple Health ZIP importer; Garmin developer-program application filed.
- **Dependencies:** Phase 1 export machinery, Phase 2 scores.
- **Risks:** notification fatigue (budget invariant); correlation misreading (stats gates).
- **Success metrics:** ≥1 automation active per power user; widget adoption; report opens.
- **Exit criteria:** REST destination round-trips deltas idempotently against a reference server fixture; widgets pass N-1 snapshot tolerance; correlation engine reports null results honestly in fixtures.
- **Roles:** mobile, data, design, QA.

### Phase 4 — Power-user and ecosystem expansion
- **Objectives:** multi-vendor truth + AI leapfrog.
- **Epics:** EPIC-37 (Garmin/Oura via broker — first backend), EPIC-35 (AI coach), EPIC-21 (cloud drives), stress monitor full version.
- **Dependencies:** **A4** (ADR-0002 supersession + policy overhaul), **A9** (AI hosting); Garmin program approval.
- **Risks:** backend security posture for a privacy brand (minimal-footprint design, §15); vendor API churn.
- **Exit criteria:** vendor rows fully provenanced and deduped against platform data in fixtures; token revocation flows tested; AI guardrail suite green; policy/store listings updated.
- **Roles:** mobile, backend, data, legal, design, QA.

### Phase 5 — Future strategic bets
- EPIC-36 (Vitality Trend, A5), Wear OS tiles/companion, MQTT/Home Assistant evaluation, local MCP/TLS server feasibility study, desktop viewer over BADAN's own export/API, SQLite-bundle export format (blueprint §20.4). *(v1.1: watch app moved OUT of this phase to Phase 4 — see below.)*
- Each enters only with its own decision memo; none is assumed.

### 19.1 v1.1 roadmap amendments (domain epics slotted in)

| Phase | v1.1 additions | Rationale / gates |
|---|---|---|
| **Phase 0–1** (unchanged scope) | Only additive prep: ontology v0.2 includes hydration + workout + cycle + lab metric ids; migration planning reserves v5 (hydration, workout-OS, device-ecosystem tables) and sensitive v3 (cycle, pregnancy, labs) | Keeps foundation lean; EPIC-38's ledger (Phase-1 slice) may ride migration v4 if timing aligns |
| **Phase 2** (+EPIC-38 v1, +EPIC-39 baseline hook) | Hydration ledger + quick log + goals + export ships as the first *domain* module (lowest risk, exercises the pattern); `BaselineEngine` v2 lands with `covariateContext` live so cycle conditioning is additive later | Hydration proves module template; cycle hook is near-free inside EPIC-23 |
| **Phase 3** (+EPIC-39 module v1, +EPIC-41 MVP, +EPIC-42 MVP, +EPIC-43 core, +EPIC-44 wave 1, +EPIC-40 foundations) | The domain wave: cycle CYCLE-01…08; lab LAB-01…11; workout-OS MVP (absorbs the EPIC-28 slot); device GATT layer + reconciliation v2 + Device Hub + file/document import; ambient wave-1 + privacy modes; pregnancy PREG-01…06 starts once A18 clears | Heaviest phase — sequenced within-phase: workout OS + device layer first (they feed everything), labs + cycle next, pregnancy last (longest review tail) |
| **Phase 4** (+watch app [was Phase 5], +EPIC-40 completion, +EPIC-41/42/43/44 depth, +vitals BLE, +clinical records, +Garmin/Strava, +Dexcom gate) | Watch app (A22) unlocks: watch-first workouts, complications, glance screen, Smart Stack; Live Activities; kick/contraction tools after copy review; lab AI summaries + HC Medical Records; FTMS + BP/SpO2/thermometer BLE (A25 copy); Garmin API (A20), Strava; Dexcom only if A21 clears | Vendor/broker work already gated on A4; watch investment justified by three consumers (workouts, complications, live surfaces) |
| **Phase 5** (+EPIC-39/40 tail: sharing, mucus, sexual activity; +lab FHIR connectors; +Wear OS; +research-spike vendors) | Highest-sensitivity and lowest-certainty items last | Each behind its own memo |

**Success-metric additions:** Phase 2 — hydration log-to-share funnel <3 taps sustained; Phase 3 — zero lost workouts in crash soak, OCR review-required rate tracked, cycle prediction coverage honesty (share of users in "paused" state who *should* be); Phase 4 — watch-started workout completion rate, conflict-resolution "why" open rate.
**Exit-criteria additions:** Phase 3 gains: luteal-phase fixture passes; workout crash-recovery soak green; lab four-concept range separation fixture; device conflict never-silently-merged fixture; lock-screen redaction non-overridability test. Phase 4 gains: §45 device-category checklist executed for every shipped category; pregnancy copy sign-offs archived.

---

## 20. Epic-by-epic implementation backlog

Conventions for every epic (stated once): **Testing requirements** always include en+ar strings with RTL snapshots for any UI, wellness-language lint for any copy, and both-platform fixture parity for any domain logic; **Privacy requirements** always include "no health values in logs" and provenance stamping (I1); **Definition of done** always includes green CI, docs updated, and the §27 gate checklist rows it feeds. Only epic-specific additions are listed below. Android paths abbreviate `apps/android/app/src/main/java/net/albayyan/badan` as `[android]`.

### EPIC-01 — HealthKit ingestion widening (PERF-181)
- **Objective:** ingest the vitals/activity/body families iOS currently lacks. **User value:** automatic value; every score's raw material. **Feature source:** Both docs + existing gap. **Priority:** P0. **Phase:** 0. **Approval:** No. **Owner:** Mobile-iOS. **Dependencies:** none.
- **Affected files:** `apps/ios/Sources/Platform/Health/HealthKitAdapter.swift`, `HealthStorePort.swift`, `apps/ios/Sources/Domain/Ingestion/IngestionPipeline.swift`, `apps/ios/App/Info.plist` (usage string), `apps/ios/Sources/Features/Onboarding/OnboardingView.swift`, `Features/Body/SourcesScreen.swift`.
- **New files:** `Platform/Health/HKTypeMap.swift` (type↔metric table, data-driven), family-explainer sheets under `Features/Body/`.
- **Tasks:** (1) type map for HRV-SDNN, RR, SpO2, wrist temp, active/basal energy, distance, flights, VO2 max, weight, body fat, lean mass, height; (2) anchored-query paths per discrete type with two-phase anchor commit; (3) statistics-collection paths for cumulative types (energy/distance/flights) mirroring steps; (4) unit normalization additions in `Units.swift` where missing; (5) staged permission bundles + explainer UI; (6) usage-string rewrite en+ar; (7) source-priority defaults for new families; (8) backfill honesty (per-type achievable window surfaced); (9) soak test on device.
- **Acceptance:** each new metric flows fake→pipeline→detail screen; re-ingest idempotent per type; permission matrix honest per family. **Performance:** 90-day backfill of all types <60s on device, chunked; UI never blocked. **Testing (specific):** adapter fixtures per type incl. unit fidelity round-trip; anchor-not-persisted-on-txn-failure test extended to new types. **Risks:** HK type quirks (temp availability, HRV sampling) → per-type spike notes.

### EPIC-02 — Health Connect ingestion widening
- **Objective:** Android parity + its 30-day-window honesty. **Source:** Both. **Priority:** P0. **Phase:** 0. **Approval:** No. **Owner:** Mobile-Android. **Dependencies:** EPIC-07 ids.
- **Affected:** `[android]/platform/health/HealthConnectAdapter.kt`, `AndroidManifest.xml`, onboarding/sources screens.
- **New:** `HcTypeMap.kt`.
- **Tasks:** (1) add record types (§14 list minus cycle); (2) changes-token incremental reads + expiry fallback; (3) permissions + rationale strings; (4) priority defaults incl. multi-writer disambiguation (Samsung/Fit); (5) backfill banner; (6) parity fixtures vs iOS canonical rows.
- **Acceptance:** same fixture set as EPIC-01 passes with identical canonical output. **Performance:** paged reads never OOM at 100k records. **Risks:** writer-app fragmentation → provenance shows package id, priority editable.

### EPIC-03 — Workout + route ingestion (both platforms)
- **Objective:** ingested workout sessions with HR linkage and consent-gated GPS routes. **Source:** Both. **Priority:** P0. **Phase:** 0. **Approval:** route consent copy. **Owner:** Mobile. **Dependencies:** EPIC-01/02 scaffolding, migration v4.
- **Affected:** `HealthKitAdapter.swift`/`HealthConnectAdapter.kt`, `Measurements.swift` (workout detail payload), `Migrations.swift`/`Schema.kt` (v4: `workout_routes`, `route_points`), `MeasurementRepository`, dedup (`DedupLite` — workout overlap rule), `Features/WorkoutNutrition/WorkoutLogView.swift` (unified list).
- **New:** `Platform/Health/WorkoutRouteReader.swift` / route read in adapter; `Storage/Repositories/RouteRepository.swift` (+Kotlin); `Features/Workouts/WorkoutDetailScreen.swift` (+Compose mirror); route consent screen.
- **Tasks:** (1) workout session ingestion with typed detail JSON; (2) `workout.session_overlap.v1` dedup vs manual entries (journaled, reversible); (3) route query + batched point storage behind consent; (4) HR-series linkage by window (no duplication); (5) workout detail UI (summary, HR curve, map preview via MapKit/Maps-compose — offline-tolerant); (6) route consent flow + settings toggle; (7) day-attribution of workouts (existing `DayAttribution`).
- **Acceptance:** watch-recorded workout appears with provenance, stages of consent honored (no route rows without toggle); manual duplicate suppressed with lineage visible. **Performance:** 10k-point route ingest <2s; map preview lazy. **Privacy (specific):** route rows never in snapshots/exports without their own toggle. **Risks:** HK route chunk callbacks (multi-batch) → streamed insert test.

### EPIC-04 — iOS background substrate
- **Objective/scope:** as §12 (EPIC-04 card) and §13.3–13.4. **Priority:** P0. **Phase:** 0. **Approval:** **A2**. **Owner:** Mobile-iOS. **Dependencies:** EPIC-01 (types to observe).
- **Affected:** `apps/ios/App/BADAN.entitlements` (background-delivery), `apps/ios/App/Info.plist` (BGTask ids), `apps/ios/project.yml`, `App/AppEnvironment.swift` (wiring), `Migrations.swift` (v4: `background_runs`).
- **New:** `Sources/Platform/Background/{BackgroundCoordinator,HealthKitObserverRegistrar,BackgroundTaskRegistrar}.swift`, `Storage/Repositories/BackgroundRunRepository.swift`.
- **Tasks:** (1) entitlement + plist changes; (2) observer registration per read type with frequency map; (3) completion-handler-first discipline + re-registration on open; (4) BGAppRefresh/BGProcessing handlers with checkpointing; (5) locked-store detection path; (6) `BackgroundRun` logging + 90-day pruning; (7) Diagnostics screen section; (8) device soak protocol doc (`docs/runbooks/background-soak.md`).
- **Acceptance:** overnight-new-data appears without app open on device soak; 3-strikes never tripped in 14-day soak (handler latency logged <5s p99); expiration resumes cleanly. **Performance:** wake handler <5s to completion call; ingest work chunked. **Risks:** silent OS disablement → re-enable-on-open + soak monitoring.

### EPIC-05 — Android background substrate
- **Objective:** WorkManager periodic sync + automation evaluation. **Priority:** P0. **Phase:** 0. **Approval:** No. **Owner:** Mobile-Android. **Dependencies:** EPIC-02.
- **Affected:** `[android]/app/AppEnvironment.kt`, gradle (work-runtime-ktx), `Schema.kt` (v4 mirror).
- **New:** `[android]/platform/background/{SyncWorker,BackgroundScheduler}.kt`, `BackgroundRunRepository.kt`.
- **Tasks:** (1) periodic worker (1h, constraints) + unique-work policy; (2) expedited one-off path; (3) changes-token sync inside worker; (4) run logging; (5) OEM-throttle guidance surface; (6) boot-completed re-schedule receiver.
- **Acceptance:** device-lab soak shows ≥20 runs/day typical; throttled outcomes logged not errored. **Risks:** OEM kill lists → guidance link, honest copy.

### EPIC-06 — Android export encryption parity
- As §12 card. **Priority:** P0. **Phase:** 0. **Owner:** Mobile-Android. **Dependencies:** none.
- **New:** `[android]/export/ExportEncryptor.kt`; shared container fixtures under `packages/fixtures/encryption/`.
- **Tasks:** (1) BDNX container writer/reader (magic, version, KDF id, iterations, salt, AES-GCM); (2) PBKDF2 600k rounds + perf measurement on mid-tier device; (3) passphrase policy port; (4) cross-platform round-trip fixtures (iOS↔Android); (5) wire into `ExportRunner.kt` sensitive path; (6) typed error parity.
- **Acceptance:** byte-level container interop proven both directions; wrong-passphrase/tamper errors typed identically. **Performance:** 600k-round KDF <3s on Pixel-a-class; show progress if >1s.

### EPIC-07 — Metric ontology v0.2
- **Objective:** registry rows for every new ingested + derived metric. **Priority:** P0. **Phase:** 0. **Approval:** AR names human-reviewed. **Owner:** Shared contracts. **Dependencies:** none (leads Phase 0).
- **Affected:** `packages/metric-ontology/registry.json`, sync scripts (`scripts/sync_ios_resources.sh`, `scripts/sync_android_assets.sh`), `MetricRegistry` floor (40→60).
- **Tasks:** (1) add ingested metrics: `heart.hrv_sdnn` (verify existing `heart.hrv` semantics), `respiratory.rr` (verify), `body.lean_mass`, `body.wrist_temp_deviation`, `activity.active_energy`, `activity.basal_energy`, `activity.distance`, `activity.floors`, `workout.*` family; (2) add derived ids: `sleep.need/performance/debt/consistency/disturbances`, `readiness.score`, `effort.day`, `effort.workout`, `stress.day_trend`, `journal.correlation.*` pattern, strength `workout.strength.e1rm/volume/pr`; (3) chart hints, casual/precise labels en+ar, sensitiveClass per metric (cycle + journal families sensitive-plus); (4) bump registry version + health-check floor.
- **Acceptance:** registry validates; both apps load; search finds new metrics in both languages.

### EPIC-08 — Export schema v1.0 · EPIC-09 — Templates · EPIC-10 — Quick Export · EPIC-11 — Advanced builder · EPIC-12 — GPX · EPIC-13 — Aggregated exporter · EPIC-14 — Destinations v1
Product shape in §12; backlog specifics:
- **EPIC-08** (P0 · Phase 1 · A1 · Owner Shared+Mobile) — Affected: `packages/export-schemas/csv_columns.json`, `CSVWriter.swift`/`CsvWriter.kt`, `JSONBundleWriter.swift`/`JsonBundleWriter.kt`, `ExportRunner.*`, `ExportFixTests`. New: `packages/export-schemas/json_bundle.schema.json`, `CHANGELOG.md`. Tasks: (1) column additions + schemaVersion 1.0.0; (2) ISO-8601 public timestamps; (3) workouts[] parent objects; (4) tagged-union payload docs per type; (5) golden regeneration + round-trip updates; (6) manifest field additions (`export_schema_version`, `granularity` defaults). Acceptance: old-consumer compatibility note verified (columns appended, not reordered); cross-platform byte-identical goldens.
- **EPIC-09** (P0 · Phase 1) — Affected: `Domain/Export.swift`, `Migrations` v4 (`export_templates`), `ExportCenterScreen`. New: `Storage/Repositories/ExportTemplateRepository.*`, `Features/Export/TemplateEditorSheet.*`. Tasks: entity+repo+migration; CRUD UI; run-through; rangeRule evaluation; backup inclusion; seeded read-only presets. Acceptance: template survives restart; sensitive re-confirmation enforced at run.
- **EPIC-10** (P0 · Phase 1) — Tasks: quick card UI; preset templates; row-count preview; zip bundling for CSV; chunked-writer memory test (1M rows <150MB peak). Acceptance: 3 taps to share sheet; sensitive/routes excluded provably.
- **EPIC-11** (P1 · Phase 1) — Tasks: builder UI (scope, granularity, layout); `WideCSVProjector` (+Kotlin); save-as-template; suppressed-rows toggle (exists in scope) surfaced. Acceptance: builder output matches equivalent direct `ExportScope` run byte-for-byte.
- **EPIC-12** (P1 · Phase 1/2 boundary · route consent) — New: `Export/GPXWriter.swift`/`.kt`. Tasks: GPX 1.1 writer + XML escaping; per-run route confirmation; zip multi-route; Strava-import manual verification. Acceptance: exported GPX imports into two mainstream tools; no route file without both toggles.
- **EPIC-13** (P1 · Phase 1) — New: `Export/AggregateExporter.*`. Tasks: GROUP-BY layer honoring `tz_id` day boundaries; method-per-metric map from registry hints; granularity/method stamping; DST fixtures. Acceptance: hourly/daily/weekly goldens incl. DST-transition days.
- **EPIC-14** (P0 · Phase 1) — New: `Export/Destinations/{ExportDestinationPort,FileFolderDestination}.swift` (+Kotlin SAF mirror), `Platform/Secrets/DestinationSecretsStore.*`, `Migrations` v4 (`export_destinations`). Tasks: folder pick + bookmark/URI persistence; verification probe; delivery move-with-manifest; invalidation recovery UX; §8.3 lint split enforced in CI. Acceptance: destination survives device restart & folder rename (iOS bookmark) / SAF persistable permission; generation module still imports no networking.

### EPIC-15 — Scheduling engine · EPIC-16 — Export Health · EPIC-17 — Delta · EPIC-18 — Backup/restore
- **EPIC-15** (P1 · Phase 2 · rides A2) — Affected: `Migrations` v4 (`automation_schedules`), background coordinators (hook). New: `Domain/Automation/{AutomationEngine,ReliabilityTier}.swift` (+Kotlin), wizard UI. Tasks: schedule entity/repo; due-evaluation (cadence, quiet hours, new-data check via cursor); tier labeling; pause-on-3-failures + notification; Shortcuts-tier setup guide. Acceptance: dogfood month with zero *silent* misses (missed runs visible with cause); schedule state machine fixture-tested.
- **EPIC-16** (P1 · Phase 1 v1, Phase 2 full) — Affected: `ExportCenterScreen` (history rows exist → upgrade). New: `Features/Export/ExportHealthScreen.*`. Tasks: `export_runs` migration + repo; dashboard UI; outcome taxonomy + plain-language map; run-now retry; BackgroundRun power section; failure notification class. Acceptance: every `ExportRunner` invocation (all triggers) produces exactly one run row; DiagnosticsTests-style "no health values" test on run rows.
- **EPIC-17** (P1 · Phase 3) — New: `export_cursors` migration, cursor logic in `AutomationEngine`/`ExportRunner`. Tasks: high-watermark on `ingested_at`; manifest chaining (`previous_manifest_sha`); deletions[] section from tombstones; suppression-flip correction records; cursor reset UX. Acceptance: replayed delta run is byte-identical (idempotent); chain verification tool script in `scripts/verify_export_chain.py`.
- **EPIC-18** (P1 · Phase 1 backup, Phase 3 restore) — Affected: `BackupRestoreSettingsScreen`. Tasks: full-bundle scope (all namespaces w/ consent + config + dictionary); whole-bundle encryption option; restore via `import_batches` staged import + preview + undo; credential exclusion. Acceptance: backup→wipe→restore round-trip preserves counts + checksums; sensitive restore requires passphrase.

### EPIC-19 — App Intents · EPIC-20 — REST destination · EPIC-21 — Cloud drives · EPIC-22 — Data dictionary
- **EPIC-19** (P1 · Phase 1) — New: `Sources/Platform/Intents/{RunExportTemplateIntent,GetLatestScoreIntent,LogWaterIntent}.swift`; `[android]` `shortcuts.xml` + `RunTemplateTileService.kt`. Tasks: intents + parameter resolution from templates; result files returned to Shortcuts; in-app Shortcuts setup guide (unlock rule explained); donation; Android tile/shortcuts analog. Acceptance: a user-created 07:30 Shortcuts automation runs the template with device unlocked, writes an `ExportRun(trigger: shortcut)`; guide screenshot-tested en+ar.
- **EPIC-20** (P2 · Phase 3 · consent copy) — New: `Export/Destinations/RestApiDestination.swift` (+Kotlin), destination editor UI. Tasks: request contract (§22.7); Keychain token handling; backoff/idempotency; HTTPS enforcement + LAN developer override; reference-server test fixture (`scripts/dev_export_server.py`); consent screen. Acceptance: delta + full runs against reference server incl. 409-dedupe, 500-retry, timeout paths; token never appears in logs/diagnostics (tested).
- **EPIC-21** (P2 · Phase 4 · token policy) — New: `Export/Destinations/CloudDrive/{CloudDriveDestination,DropboxAdapter,GDriveAdapter}.*`. Tasks: OAuth SDK integration (app-folder scopes); token storage; quota/failure mapping to outcome taxonomy. Acceptance: revoked-token path surfaces `authExpired` + re-auth flow.
- **EPIC-22** (P1 · Phase 1) — New: `scripts/gen_data_dictionary.py`, `docs/export-schema-changelog.md`. Tasks: generator from schemas+registry; CI drift check; optional bundle inclusion flag on templates. Acceptance: dictionary regenerates deterministically; CI fails on schema/dictionary drift.

### EPIC-23 — Baseline engine v2
(§11 card.) **P0 · Phase 2 · Owner Data+Mobile.** Affected: `Domain/Derivation/BaselineEngine.swift` (+Kotlin), `packages/contracts/algorithms/` (new). New: `algorithms.json`, `Ontology/AlgorithmRegistry.swift` (+Kotlin), `docs/algorithms/baselines.md`. Tasks: (1) per-metric window/method table (data-driven from algorithms.json); (2) log-domain HRV banding; (3) outlier rejection; (4) confidence tiers + `retroactive` quality-flag decision; (5) backfill computation job (BGProcessing/Worker); (6) calibration read model for UI; (7) golden numerics both platforms. Acceptance: identical goldens; recompute appends (I2); calibration states render from fixtures. Performance: full recompute (60d × 20 metrics) <5s device.

### EPIC-24 — Sleep intelligence suite
(§11 card.) **P0 · Phase 2.** Affected: `Domain/Derivation/` (new engine), `Features/Home/HomeScreen.swift` (sleep card), `Features/MetricDetail/` (hypnogram). New: `SleepIntelligenceEngine.swift` (+Kotlin), `DesignSystem/Components/Hypnogram.swift` (+Compose), `docs/algorithms/sleep.md`. Tasks: (1) need model (baseline+debt+effort+nap, constants in algorithms.json); (2) debt accumulator w/ decay; (3) consistency score; (4) disturbance counter; (5) performance % + range rendering; (6) derived-id wiring + anatomy sheets; (7) sleep detail UI upgrade; (8) fixture pack: nap day, all-nighter, DST, split night (existing two-half fixture reused), travel tz change. Acceptance: state machine goldens both platforms; no fake-precision minutes (range shown when confidence < established); casual/power equal values.

### EPIC-25 — Readiness engine v2
(§11 card.) **P0 · Phase 2 · A3.** Affected: existing readiness derivation, `ReadinessHeroCard`, anatomy sheet. New: `ReadinessEngine.swift` (+Kotlin), `docs/algorithms/readiness.md`, education page ("why our number differs"). Tasks: (1) input z-position computation vs EPIC-23 baselines; (2) weighted composite + versioned params; (3) input-completeness rules + reduced-input variants; (4) morning compute trigger + late-data append; (5) contribution bars UI; (6) two-source HRV conflict resolution via priority; (7) migration of the existing readiness score id to `readiness.score` v2 (old rows keep old algorithm id — no rewrite). Acceptance: golden composites incl. missing-input matrix; anatomy shows contributions + formula + version; conflict fixture shows priority device in lineage.

### EPIC-26 — Effort engine
(§11 card.) **P0 · Phase 2 · A3.** Affected: profile (`UserProfile` + `ProfileRepository`: hrMax, zone edits), Home card set, workout detail. New: `EffortEngine.swift` (+Kotlin), zone editor UI, `docs/algorithms/effort.md`. Tasks: (1) zone model from profile (default formula, editable); (2) published log curve (params in algorithms.json); (3) intraday incremental compute; (4) workout effort; (5) guidance range from Readiness (copy-linted); (6) HR-max-edit historical backfill (checkpointed BGProcessing job, append+supersede); (7) reduced-input "activity load" variant for sparse-HR users; (8) zone-time bars component. Acceptance: monotonicity property tests; backfill supersession fixture; sparse-HR user sees labeled variant, never zero-score shame.

### EPIC-27 — Health Monitor
(§11 card.) **P0 · Phase 2.** New: `Features/HealthMonitor/HealthMonitorScreen.swift` (+Compose), `DeviationEngine.swift` (+Kotlin), `packages/contracts/sensor_quality.json`. Tasks: (1) deviation read model over baselines; (2) sensor-quality map + Source field; (3) tile grid UI + detail links; (4) temp-deviation metric wiring; (5) calm out-of-band notice class (via EPIC-32); (6) "not a medical evaluation" footer. Acceptance: band classification fixtures; quality labels render per source; empty/stale states.

### EPIC-28 — Strength logging + PR
(§11 card.) **P1 · Phase 3.** Affected: `Domain/Logging.swift` (WorkoutEntry ext), `Migrations` v5 (`strength_sets`), `WorkoutLogView`. New: `Features/Workouts/StrengthLoggingView.*`, `StrengthAnalytics.swift` (+Kotlin), `packages/contracts/dictionaries/movements.json`. Tasks: (1) sets table + repo; (2) movement dictionary en+ar; (3) fast-entry UX (repeat-last, plates math); (4) e1RM (Epley+Brzycki, labeled estimates); (5) PR detection (movement × rep-range) as derived rows; (6) volume trends + muscular-load approximation feeding Effort context; (7) export representation (`strength_sets[]` under workouts). Acceptance: e1RM goldens; PR edge cases (tie, unit switch, deload); logging a 5×5 session ≤30s.

### EPIC-29 — Journal + correlation engine
(§11 card.) **P1 · Phase 3 · stats-copy review.** Affected: sensitive DB v3 (`journal_entries`, `context_statuses`), `LoggingRepository`, Insight templates. New: `Features/Journal/JournalScreen.*`, `CorrelationEngine.swift` (+Kotlin), `packages/contracts/dictionaries/behaviors.json`, correlation insight templates, `docs/algorithms/correlations.md`. Tasks: (1) entities + migration + purge inclusion (I7); (2) behavior dictionary (~25 behaviors en+ar); (3) daily journal UX + yesterday recall; (4) engine (Cliff's delta + bootstrap CI, min-n gates, null reporting); (5) findings as derived rows + templates with n/CI; (6) context statuses + engine-confidence annotation; (7) correlations UI both altitudes. Acceptance: goldens incl. null case ("no clear association" rendered); min-n suppression; sensitive gating in export.

### EPIC-30 — Cycle context
(§11 card.) **P2 · Phase 3 · sensitivity review.** New: sensitive v3 `cycle_contexts`, HK/HC cycle read paths, overlay UI, double-gated consent. Tasks: (1) platform reads + manual entry; (2) phase inference (documented simple rules, `unknown` honest default); (3) chart overlay; (4) covariate baselines after ≥2 cycles; (5) consent + export opt-in; (6) copy review. Acceptance: phase fixtures; consent matrix; export exclusion default proven.

### EPIC-31 — Reports
(§11 card.) **P1 · Phase 3.** New: `Domain/Reports/ReportBuilder.swift` (+Kotlin), `Export/ReportRenderer.*`, `reports` migration, `Features/Reports/ReportsScreen.*`, report-model schema in contracts. Tasks: (1) weekly model (sleep/effort/readiness/adherence/changes + evidence refs); (2) monthly variant; (3) renderer (HTML→PDF); (4) UI + share; (5) generation trigger (Sunday local, via substrate; manual regenerate). Acceptance: model snapshot fixtures (not pixels); empty-week handling; en+ar PDFs render RTL correctly.

### EPIC-32 — Notification decision engine
(§11 card.) **P1 · Phase 3.** Affected: `NotificationScheduler.swift` (extend), `NotificationsSettingsScreen`. New: `NotificationDecisionEngine.swift` (+Kotlin channels). Tasks: (1) class registry (morning summary, wind-down, deviation, export-health, meds[existing]); (2) budget ledger (≤2/day non-med default) + quiet hours; (3) per-class opt-in UI (defaults all-off — existing convention); (4) deep links; (5) 64-cap interplay; (6) Android channels + runtime permission. Acceptance: budget enforcement fixtures; opt-in matrix; med reminders unaffected regression suite.

### EPIC-33 — Widgets
(§11 card.) **P1 · Phase 3.** Affected: `project.yml` (BadanWidgets target + app group), gradle (glance). New: `Sources/Platform/Ambient/AmbientSnapshotWriter.swift` (+Kotlin), `apps/ios/BadanWidgets/{RingSingleWidget,SentenceWidget,MedsDueWidget,SleepCardWidget,Providers/SnapshotTimelineProvider,AmbientSnapshotStore}.swift`, `[android]/widgets/` Glance mirrors. Tasks: (1) snapshot DTO + writer + debounce + locked-redacted variant; (2) 4 widgets + lock-screen variants; (3) reload triggers on derivation events; (4) per-family consent keys; (5) deep links; (6) N-1 schema tolerance. Acceptance: blueprint §24 test set (decoding tolerance, deep-link resolution, theme×RTL renders); no DB access from extension (lint).

### EPIC-34 — Stress gate + trend
(§11 card.) **P2 · Phase 3 (gate/trend), Phase 4 (dense).** New: `StressEngine.swift` (+Kotlin), density detector, surface-state UI. Tasks: (1) density detector (samples/hour trailing 7d); (2) three surface states incl. honest absence; (3) daily trend index (published method); (4) vendor-dense intraday version (Phase 4). Acceptance: gating fixtures; absence copy renders.

### EPIC-35 — AI coach & memory
(§11 card.) **P2 · Phase 4 · A9.** New: `Domain/AI/{CoachService,RetrievalPlanner,GuardrailPolicy}.swift` (+Kotlin), `ai_memory` sensitive migration, coach UI, guardrail templates in contracts, red-team suite. Tasks: (1) structured retrieval layer (SQL feature extraction → context); (2) hosting integration per A9; (3) citation contract (every claim → record ids, rendered as lineage links); (4) memory CRUD (user-visible, assistant-writes audited); (5) refusal/guardrail library en+ar; (6) proactive check-ins via EPIC-32 budget; (7) eval harness (guardrails, citation integrity, Arabic quality). Acceptance: red-team suite green; citation-integrity property test; offline behavior defined (on-device or graceful absence).

### EPIC-36 — Vitality Trend
(§11 card.) **P3 · Phase 5 · A5.** Tasks defined at approval time; pre-conditions tracked: ≥6-month histories, inputs coverage report, MONETIZATION §4 conditions checklist, naming/copy review, citations file. **Not scheduled.**

### EPIC-37 — Vendor platform (Garmin/Oura)
(§11 card.) **P2 · Phase 4 · A4.** Affected: `backend/` activation (supersedes ADR-0002 via new ADR-0009), `Domain/Sources.swift` (vendor type live), ingestion pipeline (vendor DTO path), priority defaults, `docs/PRIVACY_POLICY.md`. New: `backend/api/` (auth broker + batch endpoints), `backend/workers/{garmin_poller,oura_poller}`, `infra/` IaC, `Sources/Platform/Vendors/VendorSourceAdapter.swift` (+Kotlin), connect UI. Tasks: (1) ADR-0009 + policy + store-listing updates; (2) OAuth PKCE flows both vendors; (3) token vault + revocation; (4) pollers → normalized DTO batches (contract in `packages/contracts/ports/vendor_dto.schema.json`); (5) device fetch + ingest with `ingestionPath=vendor`; (6) per-family priority defaults + editor integration; (7) dedup fixtures vendor-vs-platform; (8) broker contract tests + security review. Acceptance: Oura sleep supersedes Watch sleep per priority with journaled decision; disconnect purges tokens server-side and marks source revoked; no durable raw health data server-side (audited).

### EPIC-38 — Hydration module
- **Objective:** §11 card. **User value:** effortless fluid ledger + calm support. **Source:** Hydration research. **Priority:** P1 (module v1 P1-of-Phase-2). **Phase:** 2–3. **Approval:** wording/caps/redaction + Ramadan copy. **Owner:** Mobile + Product. **Dependencies:** EPIC-07, EPIC-32 (reminder classes), EPIC-08 (export). **Affected:** `Domain/Logging.swift`, `LogHubScreen.swift` (water quick-log exists — upgrade), `Migrations` v5, `NotificationDecisionEngine`. **New:** `Domain/Hydration/{HydrationLedger,GoalEngine,ReminderPolicyEngine}.swift` (+Kotlin), `Features/Hydration/*`, `packages/contracts/dictionaries/beverages.json`.
- **Tasks (source ids imported):** HYD-001 canonical ledger (encrypted, revision-safe, migratable) · HYD-002 quick add/presets (≤2 actions, Undo) · HYD-003 goals/summaries (no-goal, tz, snapshots) · HYD-004 notifications (caps/suppressions tested) · HYD-005 HealthKit write (no loops) · HYD-006 HC write (round-trip provenance) · HYD-007 export (stable schema, privacy preview) · HYD-008 widgets/intents · HYD-009 import/reconcile (idempotent, external read-only) · HYD-010 watch/Wear (offline merge) · HYD-011 workout context (opt-in) · HYD-012 fasting/Ramadan (silent in-window) · HYD-013 beverage metadata (no hidden target effect) · HYD-014 insights (n/coverage/no causality) · HYD-015 adaptive experiment (opt-in, stop rules) · HYD-016 smart-bottle adapter (disconnect/delete works).
- **Acceptance:** source ACs adopted verbatim per task. **Testing:** cooldown/cap/suppression matrix; fasting-silence fixture; write-loop prevention; Arabic volume parsing. **Risks:** reminder fatigue → cap invariant. **DoD:** module hideable-without-deletion proven.

### EPIC-39 — Cycle intelligence
- **Objective:** §11 card. **Source:** Period-tracker research. **Priority:** P0-of-Phase-3 (baseline hook P0-of-Phase-2). **Phase:** 2–4. **Approval:** consent+anomaly copy; **A17** (fertile window). **Owner:** Mobile + Data + Product/legal. **Dependencies:** EPIC-23; sensitive migration v3. **Affected:** `BaselineEngine` (covariate contexts), `SymptomEntry` (+cycle linkage), `Features/Settings/PrivacySecuritySettingsScreen`. **New:** `Domain/Cycle/{CyclePredictor,PhaseEstimator,CycleAnomalyEngine}.swift` (+Kotlin), `Features/Cycle/*`, HK/HC cycle read paths, threat-model doc `docs/legal/reproductive-threat-model.md`.
- **Tasks:** CYCLE-01 sensitive schema+repos (arch test blocks main-DB placement) · CYCLE-02 dedicated consent flow (separate sync/cloud-AI/export gates, revocable) · CYCLE-03 period+flow logging (≤3-interaction repeat, backdating) · CYCLE-04 history+window forecast (range/confidence/method label; no single-date states) · CYCLE-05 anomaly engine (top-5 classes, min-history gates, calm phrasing) · CYCLE-06 phase-conditioned baselines (luteal fixture stops false alarms) · CYCLE-07 contraceptive context (predictions pause/broaden) · CYCLE-08 scoped export+purge (default-off every time; purge invalidates derived) · CYCLE-09 symptom overlay+correlation hooks · CYCLE-10 BBT + signal-assisted refinement · CYCLE-11 historical CSV import (review before joining predictions) · CYCLE-12 advanced fertility inputs (A17; disclaimers everywhere) · CYCLE-13 sexual-activity logging (elevated gating, off-by-default) · CYCLE-14 sharing model (per-field, auditable, one-tap revoke).
- **Acceptance/Testing:** prediction-tier goldens; anomaly matrix fixtures incl. escalation; suppression contexts; consent matrix; phrasing-library lint. **Risks:** trust failure > prediction failure — privacy architecture is the feature. **DoD:** hide/pause/purge all verified; V1 recommendation set (10 items) shipped.

### EPIC-40 — Pregnancy calendar
- **Objective:** §11 card. **Source:** Pregnancy research. **Priority:** P1. **Phase:** 3–5. **Approval:** **A18** + per-surface clinical/legal sign-offs (§17.1). **Owner:** Mobile + Product + Clinical advisor + Legal. **Dependencies:** EPIC-39, EPIC-41 (handoff), EPIC-32 (suppression hook). **New:** `Domain/Pregnancy/{PregnancyModeController,DueDateEstimator}.swift` (+Kotlin), `Features/Pregnancy/*`, content bundle `packages/contracts/pregnancy_content/` (versioned, clinically reviewed), `LossDeclaration` suppression hook in `NotificationScheduler`.
- **Tasks:** PREG-01 mode model (7 modes; zero non-user transitions) · PREG-02 due-date model (4-source priority; source always visible; formulas clinically validated) · PREG-03 content shell + disclaimer (renders on 100% of content screens; canonical disclaimer string chosen) · PREG-04 loss declaration + immediate suppression (same-session, zero delay; overrides standing prefs) · PREG-05 local-first storage + separate consent (no data leaves device without explicit consent) · PREG-06 entity reuse (entries in both pregnancy and general history) · PREG-07 kick counter + contraction timer (§8 checklist passes pre-release) · PREG-08 lab-notebook handoff (links, never duplicates) · PREG-09 HealthKit Pregnancy category (one-way, no inference back) · PREG-10 mood check-ins + resources (link on every screen) · PREG-11 postpartum handoff (cycle-return reactivates correctly) · PREG-12 partner sharing (immediate logged revocation).
- **Testing:** mode-transition state machine; suppression latency test (same-session); content-version recalc preserving completed milestones; export-friction flow; deletion completeness. **Risks:** the loss path is the reputational core — built first-class, soak-tested. **DoD:** §8 content/tone checklist + safety-language matrix sign-offs archived.

### EPIC-41 — Lab results notebook
- **Objective:** §11 card. **Source:** Lab research. **Priority:** P1. **Phase:** 3–5. **Approval:** ontology/units/ranges/export (product); **A19**; LAB-14 under A9. **Owner:** Mobile + Data + Design. **Dependencies:** EPIC-08, sensitive migration v3, document vault storage. **New:** `Domain/Labs/*` (entities §9.17), `Storage/Repositories/Lab*Repository`, `Ingest/OCR/*`, `Features/Labs/*` (10 surfaces §16.1), `packages/contracts/analytes/{analytes.json,units.json}` (bilingual, LOINC/UCUM), `Export/Labs*`.
- **Tasks:** LAB-01 canonical schema (report/panel/result/provenance) · LAB-02 source-document vault (hash+metadata, encrypted) · LAB-03 manual entry flows · LAB-04 marker browser/detail (search+trend+raw) · LAB-05 report detail/viewer · LAB-06 OCR pipeline basic (11-step, locale-aware, Arabic+English) · LAB-07 OCR review/correction UI (side-by-side, `review_required` default) · LAB-08 unit normalization (safe conversions only, originals preserved) · LAB-09 reference-range engine (four-concept separation; no invented ranges) · LAB-10 export v1 (CSV/JSON/PDF; raw/normalized/derived/annotations separated) · LAB-11 HealthKit clinical import (raw FHIR preserved) · LAB-12 baselines+trend summaries (confidence model) · LAB-13 HC Medical Records import (verification spike first) · LAB-14 AI summaries (cited, non-diagnostic, JSON schema) · LAB-15 collections+smart filters · LAB-16 duplicate/conflict resolver (never auto-delete) · LAB-17 FHIR bundle import (lossless) · LAB-18 sharing grants (scoped, revocable).
- **Testing:** edge-case inventory (§7A.4 rejects + the 22-row failure table: comparator values, amended reports, mixed-language, decimal misreads, no-interval results…); anti-panic palette snapshots; RTL table audits. **Risks:** over-normalization losing source nuance → preserve-original law tested per field. **DoD:** unknown-marker import never blocks; every displayed insight links to visible source records.

### EPIC-42 — Live exercise monitor / workout OS
- **Objective:** §11 card (absorbs EPIC-28). **Source:** Live-exercise research + blueprint strength SOR. **Priority:** P0-of-Phase-3. **Phase:** 3–5. **Approval:** **A22**; guidance copy review. **Owner:** Mobile + Data + Design. **Dependencies:** EPIC-03/04/05/23; canonical session model blocks everything. **Affected:** `Measurements.swift` (session payload v2), `WorkoutLogView` (superseded by workout home), `Migrations` v5. **New:** `Domain/Workout/{WorkoutStateMachine,StrengthSessionRunner,IntervalEngine,WorkoutQuality}.swift` (+Kotlin runtime with foreground service), `Platform/Health/LiveWorkoutAdapter.swift` (HKWorkoutSession stack), `Features/Workout/*` (home, picker, live default/compact, strength logger, post-workout notebook, PR view, template builder), `packages/contracts/dictionaries/activities.json` (28-modality taxonomy) + `movements.json`.
- **Tasks:** (1) canonical `WorkoutSession` aggregate + child entities + schema versioning · (2) checkpoint store + crash recovery (both platforms; Apple data-source rebuild) · (3) lifecycle state machine (platform-neutral + adapters; all §7A.5 states) · (4) quick-start home + activity picker + readiness check + permissions flow · (5) Apple live runtime (correct end sequence, `prepare()` countdown, locked-device prompt) · (6) Android capture runtime (foreground services, batched idempotent HC writes, HC-absent fallback) · (7) live metric registry + per-modality bundles + casual 2–4-metric cap + estimate labeling · (8) route buffer + low-accuracy filter + privacy clipping · (9) strength runner (set semantics, supersets, swap-preserves-sets, rest timer, exercise library bilingual) · (10) e1RM/volume/PR analytics (formula ids; partial-data PR refusal) · (11) interval/HIIT engine + haptic-first cues + throttling · (12) post-workout notebook (timeline/splits/zones/provenance/quality notes/reflections) · (13) auto-pause heuristics per modality (conservative for cycling) · (14) source badges + merge journal + per-family live priority · (15) export bundle (summary CSV + child files + JSON + GPX; pending-sync indicated) · (16) offline/battery modes + long-session warnings · (17) Live Activities + Siri intents (Phase 4) · (18) watch app runtime + mirroring (Phase 4, A22) · (19) FIT/TCX/GPX import (Phase 4) · (20) AI summaries grounded (Phase 4) · (21) failure-mode test matrix (§7A.5 inventory: midnight crossing, DST, watch disconnect, OEM kill, treadmill mismatch, duplicate 3-source workout…).
- **Acceptance:** zero lost workouts across crash soak; both altitudes render same session; strength 5×5 ≤30s; degraded states honest (no zeros, no fake precision). **Risks:** scope gravity — MVP is walk/run/cycle/strength/open only. **DoD:** ten final recommendations (§7A.5 source) all demonstrably honored.

### EPIC-43 — Device ecosystem & BLE accessory framework
- **Objective:** §11 card. **Source:** Accessories research. **Priority:** P0-of-Phase-3 (core), P1–P2 (depth). **Phase:** 3–5. **Approval:** **A20/A21/A25**; per-category §45 checklist. **Owner:** Mobile (BLE lead) + Data + Legal/clinical for vitals. **Dependencies:** EPIC-01/02; migration v5. **Affected:** `Domain/Sources.swift` (connectionType etc.), `DedupLite`/dedup journal (engine v2), `SourcesScreen` (superseded by Device Hub). **New:** `Platform/BLE/{GattServiceAdapters,AccessorySetupKitBridge}.swift` / `[android]/platform/ble/BleManager.kt`, `Domain/Reconciliation/` v2 (`DataConflict`, `SourcePriorityRule`), `Features/DeviceHub/*`, `ConsentGrant` ledger, SDK-boundary lint.
- **Tasks:** ACC-001 HealthKit connect flow hardening (per-type bundles — merges into EPIC-01 surface) · ACC-002 HC connect flow hardening · ACC-003 GATT abstraction (HR/Power/CSC/RSC/Weight/BodyComp/BP/Thermo/SpO2/FTMS; conforming devices pair with zero device-specific code) · ACC-004 reconciliation engine + conflict detection (never silent merge; decisions exportable) · ACC-005 file import FIT/GPX/TCX/CSV · ACC-006 document import → lab notebook · ACC-007 Device Hub UI (casual+power) · ACC-008 full raw export regardless of subscription · ACC-009 Garmin Connect Health API (post-A20/A4) · ACC-010 Strava OAuth import (provenance preserved) · ACC-011 FTMS support (machine-estimated labels) · ACC-012 BP/thermometer/oximeter BLE + safety copy (A25) · ACC-013 Dexcom CGM (post-A21; separate consent; audit trail) · ACC-014 clinical/medical records bridges (legal review) · ACC-015 Arabic/RTL device-ecosystem pass (bilingual glossary, human-reviewed) · plus: device lifecycle rules (§7A.6), household attribution prompt, troubleshooting flow + SupportDiagnosticBundle, `ConsentGrant` ledger, SDK data-access boundary enforcement, verify-at-build spikes for uncertain vendors.
- **Testing:** conflict fixtures per default rule; contested-sensor handling; clock-drift flagging; disconnect-vs-delete flows; boundary lint red-team. **DoD:** §45 checklist executed per category; "no Measurement without resolvable DataSource" property test.

### EPIC-44 — Ambient surface system v2
- **Objective:** §11 card (extends EPIC-33). **Source:** Widgets/ambient research + blueprint §24. **Priority:** P1. **Phase:** 3–5. **Approval:** **A24**. **Owner:** Mobile + Design + Product. **Dependencies:** EPIC-24/25/27/32/19/33; A22 for watch surfaces. **New:** crosswalk doc `docs/design/ambient-surface-crosswalk.md`, `SummaryEngine` (One True Sentence), widget/complication/tile implementations per wave, `PrivacyConfigModel` (global/surface/metric modes), preset definitions.
- **Tasks:** W-01 One True Sentence pipeline + widgets (tone per A24; correct state + freshness) · W-02 readiness widgets (band thresholds approved) · W-03 sleep widgets + complication (messaging approved) · W-04 activity widgets + tiles (ring semantics) · W-05 hydration logging + metrics surfaces · W-06 health-monitor anomalies + corner complication (copy policy; privacy validated) · W-07 App Intents/App Actions full families (tests pass) · W-08 watch glance screen · W-09 Android/Wear parity (min-parity scope approved) · W-10 Live Activities (flows + risk review) · W-11 privacy modes + sensitive config (**lock screens never show disallowed data — non-overridable for sensitive-plus**) · W-12 export-status + automation-health widgets · plus: WGT-I crosswalk (task 1), freshness-tier system, stale-data scenarios (permission revoked / sync stale / calibrating / absent), preset system + guardrails, N-1 snapshot tolerance, deep-link registry, RTL/theme render matrix.
- **Testing:** per-surface privacy matrix (lock × sensitivity × mode); refresh-honesty copy audit (no deterministic promises); complication stale rules (sleep >2d → no reuse). **DoD:** every shipped surface answers exactly one question and deep-links to evidence (blueprint §24 rule).

**Backlog totals: 44 epics · 353 numbered implementation tasks (sub-tasks not counted). v1.1 added 7 epics and 121 tasks, importing the source backlogs HYD-001…016, CYCLE-01…14, PREG-01…12, LAB-01…18, ACC-001…015, W-01…12 in full.**

---

## 21. File-by-file scaffold and change plan

Real paths only (repo is native-first: there are no `packages/core-*` runtime modules — shared logic lives in `packages/` as specs/data, implemented natively per ADR-0001). `[android]` = `apps/android/app/src/main/java/net/albayyan/badan`. Android mirrors exist for every iOS Domain/Storage/Export/Feature row and are listed once at the bottom rather than per-row.

| Path | Existing/new | Purpose | Required changes | Depends on | Owner | Priority |
|---|---|---|---|---|---|---|
| `packages/metric-ontology/registry.json` | Existing | Metric registry | v0.2: ~20 new metric + derived ids, labels en+ar | — | Contracts | P0 |
| `packages/contracts/algorithms/algorithms.json` | **New** | Versioned algorithm params/methodology refs | Create; consumed by both platforms | EPIC-07 | Contracts | P0 |
| `packages/contracts/sensor_quality.json` | **New** | Per-source-family quality labels | Create | — | Contracts | P0 |
| `packages/contracts/dictionaries/behaviors.json` | **New** | Journal behavior dictionary en+ar | Create | — | Contracts | P1 |
| `packages/contracts/dictionaries/movements.json` | **New** | Strength movement dictionary | Create | — | Contracts | P1 |
| `packages/export-schemas/csv_columns.json` | Existing | Frozen CSV contract | v2: +`granularity`, +`aggregation_method`; schemaVersion 1.0.0 | A1 | Contracts | P0 |
| `packages/export-schemas/json_bundle.schema.json` | **New** | JSON bundle v1.0 schema | Create (formalizes `export_bundle.md`) | A1 | Contracts | P0 |
| `packages/export-schemas/CHANGELOG.md` | **New** | Schema changelog | Create | — | Docs | P0 |
| `packages/fixtures/**` | **New** | Cross-platform conformance fixtures (ingestion, export goldens, encryption containers, engine numerics) | Create (was planned in EXECUTION_PLAN, never built) | — | QA | P0 |
| `apps/ios/project.yml` | Existing | Project spec | BadanWidgets target, app group, BGTask ids, intents | A2 | iOS | P0/P1 |
| `apps/ios/App/BADAN.entitlements` | Existing | Entitlements | +healthkit.background-delivery; +app group (widgets) | A2 | iOS | P0 |
| `apps/ios/App/Info.plist` | Existing | Config | Usage-string rewrite; BGTaskSchedulerPermittedIdentifiers | EPIC-01/04 | iOS | P0 |
| `apps/ios/Sources/Platform/Health/HealthKitAdapter.swift` | Existing | HK boundary | Widen types; workouts; routes; observer hooks | EPIC-01/03/04 | iOS | P0 |
| `apps/ios/Sources/Platform/Health/HKTypeMap.swift` | **New** | Type↔metric mapping table | Create | EPIC-07 | iOS | P0 |
| `apps/ios/Sources/Platform/Health/WorkoutRouteReader.swift` | **New** | Route queries | Create | EPIC-03 | iOS | P0 |
| `apps/ios/Sources/Platform/Background/BackgroundCoordinator.swift` | **New** | Wake orchestration | Create (+ObserverRegistrar, TaskRegistrar siblings) | EPIC-04 | iOS | P0 |
| `apps/ios/Sources/Storage/Migrations.swift` | Existing | DDL | v4: routes, templates, destinations, runs, cursors, schedules, background_runs; v5: strength_sets, reports | §9 | iOS | P0 |
| `apps/ios/Sources/Storage/Repositories/{Route,ExportTemplate,ExportDestination,ExportRun,ExportCursor,AutomationSchedule,BackgroundRun}Repository.swift` | **New** | New-entity persistence | Create | v4 | iOS | P0/P1 |
| `apps/ios/Sources/Domain/Export.swift` | Existing | Export domain | Template/Destination/Run/Cursor types | §9 | iOS | P0 |
| `apps/ios/Sources/Domain/Automation/AutomationEngine.swift` | **New** | Schedule evaluation | Create (+ReliabilityTier) | EPIC-15 | iOS | P1 |
| `apps/ios/Sources/Export/{GPXWriter,AggregateExporter,ReportRenderer}.swift` | **New** | New formats | Create | EPIC-12/13/31 | iOS | P1 |
| `apps/ios/Sources/Export/Destinations/{ExportDestinationPort,FileFolderDestination,RestApiDestination}.swift` | **New** | Delivery layer (lint-isolated) | Create | §8.3 | iOS | P0/P2 |
| `apps/ios/Sources/Platform/Secrets/DestinationSecretsStore.swift` | **New** | Keychain vault | Create | EPIC-14 | iOS | P0 |
| `apps/ios/Sources/Platform/Intents/*.swift` | **New** | App Intents | Create | EPIC-19 | iOS | P1 |
| `apps/ios/Sources/Platform/Ambient/AmbientSnapshotWriter.swift` | **New** | Widget snapshot | Create | EPIC-33 | iOS | P1 |
| `apps/ios/BadanWidgets/**` | **New** | Widget extension | Create per blueprint §24 subset | EPIC-33 | iOS | P1 |
| `apps/ios/Sources/Domain/Derivation/{SleepIntelligenceEngine,ReadinessEngine,EffortEngine,DeviationEngine,CorrelationEngine,StressEngine}.swift` | **New** | Score engines | Create | EPIC-23…34 | iOS+Data | P0–P2 |
| `apps/ios/Sources/Domain/Derivation/BaselineEngine.swift` | Existing | Baselines | v2 windows/confidence/backfill | EPIC-23 | iOS+Data | P0 |
| `apps/ios/Sources/Domain/Reports/ReportBuilder.swift` | **New** | Report model | Create | EPIC-31 | iOS | P1 |
| `apps/ios/Sources/Platform/Notifications/NotificationDecisionEngine.swift` | **New** | Budgeted delivery | Create; `NotificationScheduler` extended | EPIC-32 | iOS | P1 |
| `apps/ios/Sources/Ontology/AlgorithmRegistry.swift` | **New** | algorithms.json loader | Create | EPIC-23 | iOS | P0 |
| `apps/ios/Sources/Features/{Export/*,HealthMonitor/*,Journal/*,Reports/*,Workouts/*}` | Existing+New | Feature surfaces per §16 | Quick card, builder, templates, health dashboard, wizard; new screens | owning epics | iOS+Design | P0–P1 |
| `apps/ios/Sources/App/AppEnvironment.swift` | Existing | DI/lifecycle | Wire background coordinator, engines, snapshot writer | EPIC-04 | iOS | P0 |
| `[android]/platform/health/HealthConnectAdapter.kt` | Existing | HC boundary | Widen types, routes, changes tokens | EPIC-02/03 | Android | P0 |
| `[android]/platform/background/{SyncWorker,BackgroundScheduler}.kt` | **New** | WorkManager substrate | Create | EPIC-05 | Android | P0 |
| `[android]/export/ExportEncryptor.kt` | **New** | BDNX parity | Create | EPIC-06 | Android | P0 |
| `[android]/**` mirrors of every iOS Domain/Storage/Export/Feature row above | Existing+New | Parity | Same logical changes on framework SQLite/Compose | per epic | Android | per epic |
| `backend/api/`, `backend/workers/`, `infra/` | Existing (dormant) | Vendor broker | Activate only under A4/ADR-0009 | EPIC-37 | Backend | P2 |
| `scripts/{gen_data_dictionary.py,verify_export_chain.py,dev_export_server.py}` | **New** | Tooling | Create | EPIC-22/17/20 | Tooling | P1 |
| `docs/algorithms/{baselines,sleep,readiness,effort,correlations}.md` | **New** | Published methodology | Create with owning epics | A3 | Docs | P0 |
| `docs/adr/ADR-0009-backend-broker-supersedes-0002.md` | **New** | Backend decision record | Create at A4 time | A4 | Docs | P2 |
| `docs/PRIVACY_POLICY.md` | Existing (modified in working tree) | Policy | §8.3 amendment before destinations ship; A4 overhaul later | EPIC-14 | Legal | P0 |

### 21.1 v1.1 file/module additions (Android mirrors implied as before)

| Path | Existing/new | Purpose | Depends on | Owner | Priority |
|---|---|---|---|---|---|
| `packages/contracts/dictionaries/{beverages,activities}.json`; `packages/contracts/analytes/{analytes,units}.json`; `packages/contracts/pregnancy_content/` | **New** | Bilingual dictionaries: beverages, 28-modality taxonomy, analyte ontology (LOINC/UCUM), versioned pregnancy content | EPIC-38/41/42/40 | Contracts | P1 |
| `docs/legal/reproductive-threat-model.md`; `docs/design/ambient-surface-crosswalk.md`; `docs/algorithms/{cycle,workout-quality,lab-baselines}.md` | **New** | Threat model (pre-EPIC-39 ship); WGT-I↔W crosswalk; published methods | A18/A24 | Legal/Docs | P1 |
| `apps/ios/Sources/Domain/Hydration/*` · `Domain/Cycle/*` · `Domain/Pregnancy/*` · `Domain/Labs/*` · `Domain/Workout/*` · `Domain/Reconciliation/` (v2) | **New** | Domain engines per EPIC-38…43 | migrations v5 / sensitive v3 | Mobile+Data | P0–P1 |
| `apps/ios/Sources/Platform/BLE/{GattServiceAdapters,AccessorySetupKitBridge}.swift`; `[android]/platform/ble/BleManager.kt` | **New** | Standards-based GATT layer; user-initiated pairing only | EPIC-43 | Mobile | P0-of-Phase-3 |
| `apps/ios/Sources/Platform/Health/LiveWorkoutAdapter.swift`; `[android]/platform/workout/{WorkoutRuntimeService,HcOutbox}.kt` | **New** | Live session runtimes (HKWorkoutSession stack; foreground-service engine + idempotent outbox) | EPIC-42 | Mobile | P0-of-Phase-3 |
| `apps/ios/Sources/Ingest/OCR/*`; `Storage/DocumentVault.swift` | **New** | Lab OCR pipeline + encrypted artifact vault | EPIC-41 | Mobile+Data | P1 |
| `apps/ios/Sources/Features/{Hydration,Cycle,Pregnancy,Labs,Workout,DeviceHub}/*` | **New** | Domain surfaces per §16.1 | owning epics | Mobile+Design | P0–P1 |
| `apps/ios/Sources/Storage/Migrations.swift` | Existing | v5 (hydration, workout-OS, device-ecosystem tables); `badan_sensitive.db` v3 (cycle, pregnancy, labs) | §9.14–9.19 | Mobile | P0 |
| `apps/ios/Sources/Domain/Sources.swift` + `Storage/Repositories/CatalogRepository.swift` | Existing | connectionType, capabilities, pairing state, ConsentGrant ledger | EPIC-43 | Mobile | P0-of-Phase-3 |
| `apps/ios/Sources/Features/Body/SourcesScreen.swift` | Existing → superseded | Evolves into Device Hub (kept as casual projection) | EPIC-43 | Mobile | P1 |
| `apps/ios/Sources/Platform/Notifications/NotificationScheduler.swift` | Existing | Loss-suppression hook; hydration/cycle/pregnancy classes under budget engine | EPIC-32/38/39/40 | Mobile | P1 |
| `apps/ios/BadanWatch/*` (new watchOS target) | **New (Phase 4)** | Watch app: workout runtime, complications, glance, Smart Stack | A22, EPIC-42/44 | Mobile | P1-of-Phase-4 |
| `backend/api/vendors/{garmin,dexcom,strava}/*` | **New (Phase 4)** | Broker additions under A4/A20/A21 | EPIC-37/43 | Backend | P2 |
| CI: SDK data-access boundary lint; wellness-copy lint term packs (cycle/pregnancy/labs/vitals); §45 category checklist automation | **New** | Structural privacy + copy enforcement | EPIC-43/§17.1 | QA | P0-of-Phase-3 |

---

## 22. API, schema, and data-contract plan

### 22.1 Conventions
- **Versioning:** `export_schema_version` semver in every manifest and file header; additive = minor, breaking = major with migration notes in `packages/export-schemas/CHANGELOG.md`. Current: 0.1.0 → **1.0.0** (A1).
- **Naming:** snake_case keys; dot-namespaced metric ids (registry); file naming `BADAN_<template-or-bundle>_<YYYYMMDD>-<YYYYMMDD>[_partN].<ext>`; folders `BADAN/Exports/<year>/<month>/`.
- **Timezones:** all public timestamps ISO-8601 with numeric offset (`2026-07-20T08:00:00+04:00`); every record additionally carries its IANA `timezone`; day/night bucketing computed in record-local tz (existing `DayAttribution` semantics).
- **Units:** `unit` is the registry display token; `canonical_value`/`canonical_unit` (SI) always present in CSV (existing columns); JSON carries both plus the unit-conversion dictionary slice.
- **Provenance:** every record: `source_app`, `source_device`, `ingestion_path`, `source_external_id`, `import_batch_id`, `quality_flags`, `suppressed_by` (existing contract, unchanged).
- **Raw vs aggregated:** `value_type` (`raw|derived|aggregate`) + new `granularity`/`aggregation_method`; raw and derived never share a file (I5, existing).

### 22.2 JSON bundle v1.0 (envelope excerpt)
```json
{
  "export_schema_version": "1.0.0",
  "generated_at": "2026-07-20T18:42:00+04:00",
  "app": {"name": "BADAN", "version": "1.4.0", "platform": "ios"},
  "manifest": { "scope": {...}, "row_counts": {...}, "checksums": {...},
    "dedup_policy_note": "...", "sample_data_row_count": 0,
    "is_delta": false, "previous_manifest_sha": null },
  "dictionaries": { "metrics": [...], "sources": [...], "algorithms": [...], "units": [...] },
  "raw_samples": [ { "record_id": "01J...", "metric_id": "heart.hrv_sdnn",
    "value": 62.1, "unit": "ms", "canonical_value": 0.0621, "canonical_unit": "s",
    "start_at": "2026-07-20T03:12:00+04:00", "end_at": null, "timezone": "Asia/Dubai",
    "granularity": "raw", "aggregation_method": "none",
    "provenance": { "source_app": "com.apple.health", "source_device": "Apple Watch",
      "ingestion_path": "healthkit", "external_id": "...", "quality_flags": [], "suppressed_by": null } } ],
  "interval_records": [...], "sessions": [...],
  "workouts": [ { "id": "01J...", "activity_type": "running",
    "start_at": "2026-07-19T06:30:00+04:00", "end_at": "2026-07-19T07:14:00+04:00",
    "totals": {"energy_kcal": 512, "distance_m": 8300, "avg_hr": 152, "max_hr": 176},
    "hr_series_ref": {"metric_id": "heart.hr", "start_at": "...", "end_at": "..."},
    "route_ref": "route_01J8ZK.gpx", "strength_sets": [], "provenance": {...} } ],
  "derived_values": [...], "baselines": [...],
  "logs": { "symptoms": [...], "adherence": [...], "workouts": [...], "nutrition": [...], "journal": [...] },
  "deletions": [],
  "config": { "export_templates": [...], "customization": {...} }
}
```
Workouts are parent objects with references (never flattened); `hr_series_ref` is a query descriptor into `raw_samples` (no duplication); sensitive/route/cycle arrays appear only under their respective opt-ins.

### 22.3 CSV v1.0
Existing 24 columns **unchanged and un-reordered**, then appended: `granularity`, `aggregation_method`. Tidy-long remains the default; wide layout is a projection (`date` + one column per metric·stat) produced by `WideCSVProjector`, marked in its header comment row with schema version and layout id.

### 22.4 GPX contract
GPX 1.1; `<metadata>` carries export timestamp + BADAN version; one `<trk>` per workout, `<trkseg>` per continuous segment (route gaps >60s split segments), `<trkpt lat lon><ele><time>`; filename `route_<workout-ulid>.gpx`; referenced from workout objects via `route_ref`.

### 22.5 Manifest contract (per artifact)
`export_schema_version`, `generated_at`, scope echo, `row_counts` per array/file, `sha256` per file + bundle, `dedup_policy_note`, `timezone_policy_note`, `sample_data_row_count` (existing honesty field), `is_delta`, `cursor_before/after`, `previous_manifest_sha`, `destination` (name+kind only), `encryption` (`none|badanenc-v1`).

### 22.6 Incremental cursor contract
Cursor = max `ingested_at` exported per (template, destination). Delta run exports rows with `ingested_at > cursor` (captures late-arriving and backfilled data), plus `deletions[]` (record_id, deleted_at) from tombstones, plus correction records for suppression flips (`{record_id, suppressed_by, changed_at}`). Chain verification: `previous_manifest_sha` must equal prior manifest's bundle sha; `scripts/verify_export_chain.py` validates a folder.

### 22.7 REST destination contract
- Request: `POST <user-url>` · headers `Content-Type: application/json` (or `application/x-ndjson` for stream mode), `Authorization: Bearer <token>`, `X-Badan-Schema-Version`, `X-Badan-Manifest-Sha`, `Idempotency-Key: <manifest-sha>`.
- Batching: bundles >8 MB sent as NDJSON parts with `X-Badan-Part: n/of`; each part independently idempotent (`Idempotency-Key: <manifest-sha>:<n>`).
- Responses: 2xx = delivered; 409 = duplicate → treated as delivered; 401/403 → destination `authExpired`; 408/429/5xx/timeout → backoff retry (3 attempts: 30s/5m/30m, jittered), then `failedDelivery`.
- Error record in `ExportRun`: status code + sanitized reason only.

### 22.8 v1.1 contract additions
- **Workout export:** session objects gain `laps[]`, `intervals[]`, `strength_sets[]`, `quality{hr_completeness, route_quality,…}`, `provenance.derived_metrics[{metric, algorithm_id}]`, state history; child CSVs `laps.csv`, `intervals.csv`, `workout_sets.csv` (blueprint-anticipated names); GeoJSON added beside GPX (Phase 4); `pending_sync` flag in manifests when platform write-back incomplete.
- **Hydration export:** tidy CSVs (entries, summaries, goals, rules, sources) + `logs.hydration[]` in JSON; redaction manifest lists excluded fields explicitly.
- **Cycle export:** raw families (`cycle_records`, `flow_logs`, signals, contexts) and derived (`cycle_predictions`, `phase_estimates`, `anomaly_events`) separately toggleable; every derived row carries method + confidence + input manifest.
- **Lab export:** per-analyte field set (§7A.4 export list: canonical + source labels/codes/units, raw value text, comparator, normalized pair, interpretation flags, range low/high/text, organization, document id, import method, review state, correction markers, lineage); original documents exportable as-is; FHIR-shaped export where practical.
- **Device-ecosystem export:** conflicts, reconciliation decisions, priority rules, consent-grant ledger, and audit events are all first-class export arrays — "regardless of subscription status" is a contract clause, not a settings behavior.
- **Sensitivity envelope:** JSON bundle gains per-array `sensitivity_tier`; consumers can filter without parsing payloads.

---

## 23. Testing and QA plan

- **Unit tests:** every engine (goldens per algorithm version, property tests for monotonicity/bounds), cursor math, tier state machines, GPX/XML escaping, wide projection, e1RM, correlation stats incl. null cases.
- **Integration tests:** ingest→derive→export pipelines per family; automation end-to-end with fake clock + fake substrate; restore round-trip.
- **Fixture strategy:** create `packages/fixtures/` at last (it was planned, never built): platform-neutral JSON inputs + expected canonical rows + expected export bytes + expected engine numerics + encryption containers; every domain bug fix adds a fixture (existing convention, now shared).
- **Adapter tests:** per-type HK/HC mapping fixtures; unit-fidelity round-trips; anchor/changes-token continuity across restart; permission matrix (granted/denied/partial/revoked); locked-store path (iOS); token-expiry fallback (Android).
- **Export contract tests:** CSV re-parse diff vs DB (exists — extend to new columns); JSON schema validation against `json_bundle.schema.json`; cross-platform byte-equality goldens; GPX imports verified against two external tools (manual QA script).
- **Snapshot tests:** CSV/JSON goldens per template kind; report-model snapshots; widget snapshot decoding (N-1 tolerance).
- **Background scheduling tests:** simulated wake sequences (fake substrate injecting `hkObserverWake`/worker runs); completion-latency assertions; expiration/resume checkpointing; 3-failure pause behavior.
- **Retry/idempotency:** delta replay byte-identity; REST 409/500/timeout paths against `scripts/dev_export_server.py`; duplicate-run suppression.
- **Sync/dedup:** vendor-vs-platform overlap fixtures (Phase 4); workout manual-vs-ingested suppression + reversal; multi-writer HC fixtures.
- **Privacy/permission-flow tests:** run-log value-free assertions (DiagnosticsTests pattern applied to `export_runs`/`background_runs`); route/cycle/sensitive export-gating matrix; Quick-Export exclusion proof; credential-never-logged test; import-graph lints (generation-no-network; destinations-isolated; widget-no-DB).
- **Accessibility:** VO labels on all new surfaces incl. chart descriptors (pattern exists); not-color-only status chips; Dynamic Type XXL passes on builder/wizard; RTL snapshot lanes for every new screen.
- **Performance (large-data):** 1M-row export memory ceiling; 10k-point route ingest/export; 60d×20-metric recompute budget; KDF timing on low-end Android; widget snapshot write <50ms.
- **Manual QA scripts (per release):** iPhone: overnight background soak, Shortcuts 07:30 automation, folder-destination re-pick, encrypted backup→restore; Android: Samsung + Pixel (HC-via-Samsung-Health path), Doze soak, SAF persistence across reboot, tile-triggered export.
- **Edge-case matrix:** DST 23/25h nights (fixtures exist — extend to need/debt), timezone travel mid-sleep, HR-max edit mid-history, revoked permission mid-automation, storage-full during export, passphrase entry cancel, locked device during scheduled window, cursor reset mid-chain, registry version upgrade with in-flight templates.

- **v1.1 test additions:** workout crash-recovery soak (kill mid-session, both platforms, incl. OEM aggressive-battery devices); midnight/DST/timezone-crossing workout fixtures; BLE contested-sensor + reconnect-gap tests; reconciliation default-rule fixtures (strap-vs-wrist, duplicate 3-source workout, Oura-vs-Watch sleep side-by-side); household misattribution prompt flow; cycle prediction-tier goldens + luteal-baseline fixture + anomaly escalation matrix; pregnancy mode state machine + same-session suppression latency + content-recalc preservation; lab OCR corpus (Arabic+English reports, decimal/unit/range ambiguity, comparators, amended reports) with review-queue routing assertions; four-concept range-separation fixture; hydration cap/cooldown/fasting-silence matrix + write-loop prevention; lock-screen redaction non-overridability; freshness-tier rendering; App Intents test suite; §45 checklist automation per device category.

---

## 24. Observability and operational plan

All local-first (no remote telemetry through Phase 3 — posture unchanged; Phase-4 backend gets standard service observability):

- **Metrics (local, Diagnostics + Export Health surfaces):** export success/failure rates per template/destination/trigger; time-since-last-successful-sync per source (freshness); ingestion lag (measured_at → ingested_at distribution); background wake counts/outcomes/latency (`background_runs`); destination failure rates by taxonomy; file generation latency + bytes; automation pause events.
- **Alert thresholds (user-facing, not ops):** automation 3-failure pause notification; source freshness >48h → stale banner (exists — extend per-source); destination `authExpired`/`unreachable` → Export Health badge + optional notification.
- **Crash/performance:** existing `PerformanceLog` signposts extended to engines and writers; crash reporting remains a deliberate non-integration until the telemetry decision (M4 agenda item, unchanged — re-decide at Phase 2 gate with the same privacy bar).
- **Privacy-preserving debugging:** Diagnostics report gains export/background sections (counts, outcomes, latencies — never values, never destinations' URLs beyond scheme+host hash); support flow = user-initiated Diagnostics share (existing pattern).
- **Backend (Phase 4 only):** broker request metrics, token-refresh failure alerts, vendor API quota dashboards, zero-health-data log policy enforced by log-schema lint.

- **v1.1 observability additions (all local, value-free):** session-finalization failure rate; sensor-disconnect and GPS-gap frequency; duplicate-session and merge/suppression rates; strength set-logging latency (avg seconds/set); OCR import completion + review-required + correction rates; export usage by format; per-source sync-session health (Device Hub feed); reminder dismissal/cooldown stats (hydration/cycle classes); guidance-cue disablement rates; conflict-resolution "why" open rate. All framed "measure usefulness, not surveillance"; ConnectionDiagnostic/SupportDiagnosticBundle remain structurally health-value-free.

---

## 25. Risks, constraints, and decisions requiring approval

| # | Decision | Options | Recommendation | Reason | Approval | Consequence of delay |
|---|---|---|---|---|---|---|
| A1 | CSV contract widening (24→26 cols, v1.0) | freeze forever / append+version / redesign | **Append + version bump** | Closes HAE's granularity ambiguity; additive keeps old consumers working | Yes | Aggregated export ships without self-describing records — permanent ambiguity debt |
| A2 | Background entitlement + BGTask + app group | stay foreground-only / adopt | **Adopt** | Freshness + automation are core to both capability sets | Yes | No automation tier better than "on open"; scores stale until app launch |
| A3 | Score naming + formula publication | opaque scores / published formulas | **Publish** ("Readiness / Effort / Sleep" set) | The strategic differentiator per whoop.md §13 | Yes | Blocks EPIC-25/26 copy, education pages, store-review posture |
| A4 | Backend broker (supersedes ADR-0002) | never / minimal broker Phase 4 / full backend | **Minimal broker, Phase 4, ADR-0009** | Only path to Garmin/Oura; scoped to tokens+cursors | Yes (deferred to Phase-2 exit) | Vendor integrations impossible; acceptable through Phase 3 |
| A5 | Vitality Trend (healthspan-equiv) | build / build-reframed / reject | **Defer; only reframed per MONETIZATION §4** | Highest false-precision + review risk in the plan | Yes | None — deliberately last |
| A6 | iOS-first vs lockstep sequencing | lockstep / iOS-first with fixture gates | **iOS-first, parity-gated phases** (per ADR-0006) | Single-dev throughput; fixtures prevent drift | Yes | Parallel-everything halves velocity |
| A7 | Local-only vs backend export scheduling | device-only honesty / server-assisted true cron | **Device-only Phases 1–3; server tier optional under A4** | Honesty first; server tier is additive later | With A4 | Users wanting exact-time unattended exports wait for Phase 4+ |
| A8 | Broker vs direct vendor integrations | direct-embedded secrets / broker | **Broker** | Client-embedded OAuth secrets are unacceptable | With A4 | — |
| A9 | AI hosting model | on-device / hosted stateless / hybrid | **Hybrid: on-device retrieval + hosted stateless inference; on-device model where quality allows** | Privacy posture + Arabic quality tension | Yes (Phase-3 exit) | EPIC-35 blocked |
| A10 | Data retention / decimation | keep all raw (status quo) / decimation tiers | **Keep all raw; revisit at DB >2GB telemetry** | Repository-first promise; volumes manageable | No (monitor) | Storage growth on CGM-class data later |
| A11 | Monetization boundary for new features | — | Free: all raw, all export formats/destinations-basic, scores. Premium candidates: trend/correlation depth, scheduling convenience, personalized weighting (per MONETIZATION) | Consistent with "raw is free" line | Yes (pricing later) | None for build order |
| A12 | Social/team features | build / reject | **Reject this horizon** | Requires accounts+moderation; off-thesis | No | — |
| A13 | Medical-adjacent boundaries (BP est., clinician/EHR, diagnosis-adjacent AI) | — | **Reject** (pass-through of device-cleared Afib only, Phase 3+) | Regulatory + trust | Yes (confirm once) | — |
| A14 | MQTT/Home Assistant | build Phase 3 / evaluate Phase 5 / reject | **Evaluate Phase 5** | Audience mismatch per HAE.md §8; REST covers integrators | No | — |
| A15 | Local MCP/TCP server | build / study Phase 5 / reject | **Feasibility study Phase 5; TLS+auth mandatory if built** | AI-agent audience is real but security bar is high | Yes (if built) | — |
| A16 | SQLCipher for sensitive DB | adopt before automation / keep OS encryption | Re-decide at Phase-1 gate (existing M4 item, urgency raised by unattended background access; v1.1 raises it again — cycle/pregnancy/labs land in this file) | Automation + reproductive/lab data increase unattended surface | Yes | Posture documented either way |
| A17 | Fertile-window estimation feature | never / calendar-broad only / signal-assisted / full three-mode | **Three-mode (calendar/signal/suppressed) with non-contraceptive framing, Phase 3.5–4** | Real user value; heavy disclaiming makes it wellness-safe; suppressed-mode contexts protect the vulnerable cases | **Yes (founder+legal)** | Cycle module ships awareness-only; TTC users underserved |
| A18 | Pregnancy module go/no-go + clinical advisor + GCC/Oman legal review | build / defer indefinitely | **Build, Phase 3 start, contingent on retaining a clinical advisor and completing regional legal review first** | Highest-stakes domain; loss handling + content review cannot be improvised | **Yes (founder+legal+clinical)** | EPIC-40 blocked entirely; period tracker still ships |
| A19 | Lab OCR + AI summarization posture | on-device only / opt-in cloud OCR+LLM with local fallback | **On-device first; opt-in cloud paths later with separate consents and full local fallback** | Preserves local-first claim; complex Arabic tables may eventually need cloud OCR | Yes | LAB-06/14 scope ambiguity |
| A20 | Garmin Connect Health API commercial license | pay / skip (HC subset only) | **Decide at Phase-3 exit against demand data; budget line named now** | License fee is a business decision, not a silent engineering cost | Yes (founder) | Garmin power users capped at partial HC feed |
| A21 | Glucose/CGM integrations (Dexcom, Libre, Lingo) | build / defer | **Defer until dedicated legal+clinical review signs off; platform-written glucose ingestion/export allowed earlier** | Highest regulatory scrutiny in the corpus; "never for treatment decisions" | **Yes (legal+clinical, highest scrutiny)** | CGM users import via platform/files meanwhile |
| A22 | Watch app timing + phone-only live-workout scope | watch Phase 5 (v1.0) / watch Phase 4 + phone-first live now | **Accelerate: phone-first live MVP in Phase 3, watch app Phase 4** | Three consumers justify it (workout fidelity, complications, live surfaces); Apple's watch-first guidance; phone-only degrades honestly | **Yes** | Live monitor stays phone-only-degraded; complications blocked |
| A23 | BLE scope + doctrine | none / GATT-standards-only framework / per-vendor SDKs | **GATT-standards-only framework (10 service families), AccessorySetupKit pairing, foreground-only, no reverse engineering ever** | Best cost-to-coverage; privacy-preserving; vendor SDKs only as documented enrichment | Yes | Long-tail sensors unsupported; strap users blocked |
| A24 | Ambient copy governance: One True Sentence tone, band labels, privacy defaults, hydration/reminder wording | descriptive-only / lightly interpretive | **Lightly interpretive within the wellness-safe register; all band thresholds/labels and privacy defaults approved as one package** | One decision covers the whole ambient + reminder copy surface | **Yes (founder)** | EPIC-38/44 copy blocked |
| A25 | Standing clinical advisor + safety-copy review pipeline | ad-hoc per feature / retained advisor | **Retain a clinical advisor for the §44 safety-language matrix, pregnancy content, vitals copy, and release-gate sign-offs** | Recurring non-engineering critical path across EPIC-40/41/43; ad-hoc review will bottleneck every phase | **Yes (founder)** | Every sensitive-domain ship date slips unpredictably |

---

## 26. Features to delay, approximate, or reject

| Feature | Source | Verdict | Why | Risk if built early | Reconsider when | Lower-risk alternative |
|---|---|---|---|---|---|---|
| Blood-pressure estimation | whoop.md | **Reject** | No trustworthy cuffless consumer method; regulatory + trust hazard | Store rejection; user harm; brand damage | A regulator-cleared API exposes it as pass-through | Cuff-device/manual BP entry (exists) |
| On-demand clinicians / EHR sync | whoop.md | **Reject (indefinite)** | Healthcare-services business, not a data feature | Licensing/liability | Dedicated healthcare partnership | Great export → user shares with their own clinician |
| Teams/leaderboards | whoop.md | Reject this horizon | Accounts+backend+moderation; off-thesis | Privacy posture erosion | Post-sync, post-accounts | Report sharing (user-initiated) |
| Biological-age number | whoop.md | Delay + reframe (A5) | False precision; 1.4.1 exposure | Defines BADAN as "the app that sold a made-up number" | MONETIZATION §4 conditions met | Per-metric long trends (free of the age claim) |
| Real-time stress on Apple-Watch-only | whoop.md | Approximate (gated) | Sparse daytime HRV | Misleading low-confidence readings | Vendor-dense data (Phase 4) | Daily trend + honest absence state |
| Smart/haptic alarms; HR broadcast | whoop.md | Reject (no hardware surface) | Needs wearable presence | — | Watch app phase | Wind-down notification |
| Live intra-workout surfaces | whoop.md | Delay (Phase 5) | Needs watch/Live Activities investment | Thin value on phone-only | Watch app | Post-workout analytics (Phase 2) |
| Calendar destination | HAE.md | Reject | Leaks health events into shared calendars | Silent privacy failure | User demand + redaction design | Files destination |
| MQTT / Home Assistant | HAE.md | Delay (Phase 5 eval) | Audience mismatch; REST suffices | Maintenance drag | Demonstrated demand | REST destination (EPIC-20) |
| Local TCP/MCP server | HAE.md | Delay (Phase 5 study) | HAE ships it unencrypted — BADAN must not; real design cost | LAN exposure of health data | Study proves TLS+auth+battery viable | Delta export to local folder consumed by agents |
| Mac/iPad bespoke peer-sync | HAE.md | Reject as protocol | Desktop should consume BADAN's own files/API | Proprietary sync debt | Desktop companion decision | Folder destination + future viewer |
| Cloud drives (Dropbox/GDrive) | HAE.md | Delay (Phase 4) | Files/iCloud covers most value without OAuth surface | Token handling before vault matures | Phase 4 | iCloud Drive folder (EPIC-14) |
| Multiple simultaneous REST/MQTT fan-out | HAE.md | Delay | One destination per schedule first; fan-out multiplies failure modes | Retry-matrix complexity | Export Health proves single-destination reliability | Multiple schedules |
| Remote config / silent algorithm updates | blueprint §60 | Reject | Transparency brand requires versioned, changelogged app updates | Silent behavior changes | — | algorithms.json shipped in-app |
| Passive pregnancy/fertility inference from cycle gaps, symptoms, or biometrics | Pregnancy research | **Reject (permanent)** | Inaccurate + the exact post-*Dobbs* legal-exposure pattern | Catastrophic trust/legal failure | Never | User-declared modes only |
| Numeric clinical thresholds as app-native facts (kick counts, BP cutoffs, weight-gain ranges, "normal" labels) | Pregnancy/labs/accessories | **Reject** | Unlicensed clinical judgment | 1.4.1 + real harm | Regulated product path only | Source-provided flags labeled as such; baseline-relative language |
| Traffic-light health scores over labs; "Normal/Healthy/Danger/Optimal" verdicts | Labs research | **Reject** | Pseudo-diagnosis; erodes the notebook's trust thesis | — | — | Interval status + personal trend + calm palette |
| "Net hydration" caffeine/alcohol multipliers; food-water mixed into logged totals; streak/shame mechanics; dehydration claims | Hydration research | **Reject** | False precision + guilt mechanics | — | — | Annotations without target effects; observational copy |
| Health-portal scraping / credential-based automated retrieval | Labs/accessories | **Reject** | Security + ToS + trust | — | — | User-initiated document import |
| BLE proprietary-protocol reverse engineering; pairing-security bypass; silent background BLE scanning | Accessories research | **Reject** | Legal + privacy + platform policy | — | — | GATT standards + documented SDKs only |
| Weight-range auto-attribution on shared devices | Accessories research | **Reject** | Silent misattribution of health data | — | — | "Who is this reading for?" prompt |
| Autonomous training coach; prescriptive phase-based training rules ("don't train in luteal") | Live-exercise/period research | **Reject** | Overclaims evidence; essentialist framing | — | — | Observational personal-trend context |
| Auto-rep detection as core strength capture | Live-exercise research | Delay (annotation-only if ever) | Wearable rep detection unreliable; manual SOR is the trust anchor | False records | Proven accuracy + user demand | Optional annotations, never silent replacement |
| Emergency-access / medical-monitoring affordances in workouts | Live-exercise research | Delay behind legal review | Implies monitoring BADAN cannot guarantee | Liability + false reassurance | Product/legal review | Clear pause/end + honest non-medical framing |
| Cheerful/celebratory content without a loss-suppression path | Pregnancy research | **Reject (inverse requirement)** | The documented category failure | Real harm to grieving users | — | Loss handling first-class (EPIC-40) |
| Sensitive lab/reproductive/weight/glucose values on lock screens or ambient surfaces | Widgets research | **Reject by default (non-overridable for sensitive-plus)** | Semi-public surfaces | Bystander disclosure | — | Generic status words + masked modes |

---

## 27. Definition of done and release gates

Every gate requires, beyond its specific rows: green CI (schema validation, lints: wellness-language, no-network-in-generation, no-health-values-in-logs, AR-strings), RTL/en+ar snapshots for shipped surfaces, and updated docs (`architecture.md`, data model, changelog).

| Gate | Functional | Performance | Reliability | Privacy | Store safety | UX | Observability |
|---|---|---|---|---|---|---|---|
| **G1 Foundation** (Phase 0 exit) | ≥25 metrics both platforms; workouts+routes behind consent; migration v4 upgrades cleanly | 90d backfill <60s; wake handler <5s | 14-day background soak, zero 3-strikes; anchor continuity across restarts | Route consent enforced; usage strings honest; Android decrypts iOS containers | Entitlement justification drafted | Staged prompts + explainers shipped | `background_runs` live in Diagnostics |
| **G2 Export beta** (Phase 1 exit) | Quick export ≤3 taps; templates + folder destinations + Shortcuts run; v1.0 schema + dictionary | 1M-row export within memory ceiling | Zero silent failures in 30-day dogfood; every run logged | Quick Export excludes sensitive/routes provably; policy amendment live | Destinations described accurately in review notes | Builder + wizard usability-tested | Export Health v1 live |
| **G3 Intelligence beta** (Phase 2 exit) | 4 engines live both platforms; anatomy sheets complete; calibration honest | Recompute budget met; morning score by first open | Late-data append correctness; HR-max backfill resumable | Formulas published; confidence surfaced; no diagnosis register (lint) | 1.4.1 review-note pack prepared | Both altitudes fixture-equal; education pages live | Engine latency signposts |
| **G4 Public beta** (mid-Phase 3) | Notifications budgeted; widgets wave 1; reports; journal | Widget snapshot <50ms; report gen <5s | Automation pause-on-failure verified in the wild | Widget redaction-when-locked; per-class opt-ins default off | Play Data Safety + App privacy labels re-verified | No-data/stale/failed states systematized | Freshness metrics user-visible |
| **G5 Store submission** (per release) | Release-scoped checklist | Cold launch unregressed | Crash-free dogfood week | Privacy manifest + policy consistency audit | Review-notes pack; wellness-copy sweep | Store screenshots/UI truthfulness check | Diagnostics complete for support |
| **G6 Cross-platform parity** (each phase) | Phase fixtures identical both platforms | Same budgets both | Same soak protocol both | Same gating both | Both stores' declarations updated | Feature-list parity or labeled variance (Shortcuts) | Same local metrics |
| **G7 Power-user readiness** (Phase 3 exit) | REST + delta chain verifiable; dictionary in bundles; correlation stats honest | Delta run <10s typical | Chain integrity over 30-day dogfood | Local-only mode default; token vault audited | — | Export Health answers "did it run" in one glance | Chain-verification script documented |
| **G8 Sensitive-domain gate** (v1.1; per module: cycle, pregnancy, labs, vitals-BLE, glucose) | Module's source acceptance criteria met; hide/pause/purge verified; consent stack functions and revokes | — | Suppression/purge latency verified (pregnancy loss = same-session) | Threat-model doc current; SDK boundary lint green; export default-off proven; local-only overrides work | Clinical + legal sign-offs archived (§17.1 list); safety-language matrix strings verbatim in copy lint | Trauma-aware flows usability-reviewed; disclaimer footers on 100% of required screens | Zero health values in any diagnostic/telemetry path (property-tested) |
| **G9 Device-category gate** (v1.1; per new device class) | §45 ten-item checklist executed (legal/clinical where flagged, provenance end-to-end, reconciliation rules tested, export path complete, RTL pass, SDK boundary, household risk, deletion flow) | Pairing <60s for supported devices | Contested-sensor + reconnect handling verified | ConsentGrant recorded; disconnect-vs-delete distinct | Non-diagnostic audit of every displaying screen | "Not supported yet" honesty for out-of-scope devices | Sync-session accounting visible in Device Hub |

---

## 28. Final recommended sequence

### First 10 implementation actions
1. Approve A1–A3 (schema widening, background entitlement, score naming/publication) — everything below assumes them.
2. Ship EPIC-07: registry v0.2 (+ `algorithms.json`, `sensor_quality.json` scaffolds) and re-sync platform resource mirrors.
3. Build `HKTypeMap.swift` + first widened batch on iOS (HRV, RR, SpO2, active energy, distance, weight) with staged permissions and usage-string rewrite.
4. Mirror on Android (`HealthConnectAdapter` additional record types + changes-token hardening).
5. Land migration v4 (routes, templates, destinations, runs, cursors, schedules, background_runs) on both platforms with upgrade-fixture tests.
6. Build EPIC-04 background substrate (entitlement, observers, BGTasks, run log) and start the 14-day device soak immediately — its findings tune everything later.
7. Build EPIC-05 (WorkManager substrate) + EPIC-06 (Android `ExportEncryptor` with cross-platform container fixtures).
8. Ship EPIC-03 workouts + routes (consent flow first, ingestion second, detail UI third).
9. Ship EPIC-08 export schema v1.0 (CSV columns, JSON bundle schema, goldens, changelog) — the contract every later epic writes against.
10. Ship EPIC-09/10/14: templates, Quick Export, folder destinations — the visible HAE-class beachhead — then EPIC-16 v1 (Export Health) before any scheduling UI exists.

### First 5 files/modules to create or modify
1. `packages/metric-ontology/registry.json` (+ new `packages/contracts/algorithms/algorithms.json`)
2. `apps/ios/Sources/Platform/Health/HealthKitAdapter.swift` + new `HKTypeMap.swift`
3. `apps/ios/Sources/Storage/Migrations.swift` (v4) + `[android]/storage/Schema.kt` mirror
4. `apps/ios/Sources/Platform/Background/BackgroundCoordinator.swift` (new module, with entitlement edits in `App/BADAN.entitlements`/`Info.plist`/`project.yml`)
5. `packages/export-schemas/csv_columns.json` (v1.0) + new `json_bundle.schema.json`

### First 5 product/design decisions requiring approval
1. **A3** — score names, scales (Effort 0–21 vs 0–100), and the formula-publication commitment.
2. **A1** — the CSV contract widening (it is the one "frozen" artifact this plan touches).
3. **A2** — background entitlement + the freshness/automation privacy story that goes with it.
4. Route + cycle consent copy and their independent export toggles (Phase 0/3 blockers with legal review).
5. **A16** — SQLCipher posture re-decision before automation increases unattended data handling.

### What not to build in the next 90 days
Vendor integrations or any backend code; AI coach; Vitality Trend; stress monitor beyond the density gate design; MQTT/Home Assistant/MCP server; cloud-drive OAuth destinations; watch app/Live Activities; social features; REST destination (design its contract, build after export foundation is proven); reports/widgets (they consume Phase-2 scores that won't exist yet).

### Why this sequence protects BADAN's long-term architecture
Every later capability — scores, automation, AI, vendors — is a *consumer* of the same three assets this sequence builds first: a wide, provenance-stamped canonical store; a background substrate with honest reliability accounting; and a versioned export contract. Building consumers first (scores on 4 metrics, automations with no run ledger, AI on a thin store) would force each to be rebuilt when the foundation arrived, and would push BADAN toward exactly the opaque, over-promising patterns — black-box scores, silent automation failure, unversioned schemas — that WHOOP and HAE users already complain about and that BADAN's invariants exist to prevent. The sequence also keeps ADR-0002 (no backend) true for three full phases, so the privacy posture that differentiates BADAN is never traded away by accident — only, if ever, by explicit decision (A4) with its own ADR.

### 28.1 v1.1 sequence amendments

The v1.0 first-10 actions and first-5 files stand unchanged — the seven domain programs all consume the same Phase-0/1 foundation. Amendments:

**Additional immediate actions (11–15):**
11. Decide **A17–A25** in one founder review session (they gate Phase-3 planning); start the clinical-advisor search (A25) and the Garmin developer + license inquiry (A20) now — both have the longest lead times.
12. Extend ontology v0.2 (action 2) to include hydration, workout, cycle, and lab metric/dictionary ids so no second registry pass is needed.
13. Commission `docs/legal/reproductive-threat-model.md` and the GCC/Oman legal review scope — prerequisite for EPIC-39/40, independent of engineering.
14. Write the ambient-surface crosswalk (blueprint WGT-I ↔ research W-ids) while both documents are fresh — it is a half-day task that prevents a Phase-3 architecture argument.
15. Add the SDK data-access boundary lint to CI **before** any new module lands — cheapest now, structural forever.

**First domain module:** hydration (EPIC-38 ledger slice) ships with Phase 2 as the template for every later domain module — it exercises sensitive-adjacent consent, reminder budgeting, platform write-back, and export redaction at the lowest stakes.

**What not to build in the next 90 days (v1.1 additions):** any pregnancy surface (until A18 + advisor retained); fertile-window estimates (until A17); glucose/CGM integrations (until A21); vitals-BLE copy surfaces (until A25); watch app (until Phase 4 per A22 — but design the watch-ready snapshot/read APIs now, which the repo already does by convention); Wear OS; lab FHIR connectors; partner/caregiver sharing of any kind.

**Why the amended sequence still holds:** the seven domains quadruple BADAN's surface area but change nothing about what must exist first. Hydration needs the ledger conventions; cycle needs the baseline engine; labs need the export contracts and document vault; the workout OS needs the session model and checkpointing; devices need the provenance chain; ambient needs the scores. The foundation-first order is not just preserved by v1.1 — it is vindicated by it: every one of the seven research documents independently concludes that its domain's trust depends on canonical modeling, provenance, honest degradation, and export — which is the foundation this plan builds before anything wears a feature name.







