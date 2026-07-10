# BADAN Execution Checklist

> Living status of the iOS flagship build. See `docs/EXECUTION_PLAN.md` for the full plan and
> vertical slices (VS-1…VS-5), and `docs/adr/` for decisions. `[x]` done · `[~]` partial · `[ ]` todo.

## Phase A — Foundation
- [x] Repo inspected; blueprint + execution plan read
- [x] Stack locked: native-first Swift/SwiftUI (iOS flagship), Kotlin/Compose (Android next) — ADR-0001/0006
- [x] XcodeGen `project.yml`; verified `xcodegen generate && xcodebuild` builds for the simulator
- [x] `.gitignore` updated (generated `.xcodeproj` ignored)
- [x] ADR-0001…0006 written
- [x] PRD / architecture / project_description present and current

## Phase B — Core domain
- [x] Core: ULID, Clock, Units, Localization (AppLanguage, LocalizedString, Loc catalog, Numerals)
- [x] Canonical entities (§3): provenance, metric, sources, measurements, derivation, insight,
      reconciliation, logging, timeline, export, customization
- [x] Metric-id constants; MetricFamily grouping

## Phase C — Ontology & data
- [x] 44-metric ontology, 47-symptom dictionary, 13 insight templates, 24-col export spec (in `packages/`)
- [x] Registry / SymptomDictionary / InsightTemplateStore loaders (bundled JSON)

## Phase D — Persistence
- [x] SQLite wrapper (system libsqlite3), two DB files, migration 001 DDL, indexes, identity indexes
- [x] Repositories: Measurement, Derivation, Insight, Reconciliation, Catalog, Logging, ExportJob, Profile
- [x] Sensitive-namespace purge; dev reset

## Phase E — Services (parallel build)
- [~] FakeHealthStore (deterministic seed source) + HealthKitAdapter (integration boundary)
- [~] Ingestion pipeline + dedup-lite (reversible decision journal, idempotent re-ingest)
- [~] BaselineEngine (median/MAD) + InsightEngine (template, en+ar)
- [~] Export engine (CSV/JSON/manifest, checksums, offline)
- [~] Design system (tokens, theme, components)

## Phase F — App shell & screens
- [ ] AppEnvironment (DI) + SeedController + RootView/navigation
- [ ] Onboarding
- [ ] Home (Today) — casual + power
- [ ] Body list + metric detail + anatomy sheet
- [ ] Timeline
- [ ] Log hub + Symptom / Medication / Workout / Nutrition logging
- [ ] Export center
- [ ] Settings / customization
- [ ] Provenance / Source detail
- [ ] Insights / reports

## Phase G — Verification & docs
- [ ] Unit tests: dedup, baseline numerics, export round-trip, unit conversion, repositories
- [ ] `xcodebuild test` green
- [ ] Boot simulator, launch app, screenshot the real flows
- [ ] README, architecture, data-model, module READMEs finalized
- [ ] Commits in coherent units

## Vertical slices (from the plan)
- [~] VS-1 "Last night, truthfully" — ingestion, provenance, dedup, dual rendering
- [~] VS-2 "Take it with you" — export architecture, raw/derived separation, offline
- [~] VS-3 "Log what matters" — event logging, sensitive namespace, RTL forms
- [~] VS-4 "Why is it saying that?" — baselines, explainability, append-only
- [~] VS-5 "Arabic is not a locale file" — structural i18n + RTL

## Explicitly deferred (per plan scope rule)
Sync service · vendor/broker integrations · notifications/reminders · watch/widgets · AI/LLM ·
labs/biology · cycle engine · full ~300-metric coverage.
