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

## Phase E — Services
- [x] FakeHealthStore (deterministic 90-day seed source) + HealthKitAdapter (integration boundary)
- [x] Ingestion pipeline + dedup-lite (reversible decision journal, idempotent re-ingest)
- [x] BaselineEngine (median/MAD) + InsightEngine (template, en+ar)
- [x] Export engine (CSV/JSON/manifest, checksums, offline)
- [x] Design system (tokens, theme, components)

## Phase F — App shell & screens
- [x] AppEnvironment (DI) + SeedController + RootView/5-tab navigation
- [x] Onboarding (live EN/AR + depth preset)
- [x] Home (Today) — casual + power (dual-altitude proven)
- [x] Body list + all-metrics browser + metric detail + anatomy sheet
- [x] Timeline (unified event stream)
- [x] Log hub + Symptom / Medication / Workout / Nutrition logging
- [x] Export center (CSV/JSON + share sheet)
- [x] Settings / customization (live theme/language/depth/units/modules + sensitive purge)
- [x] Provenance / Source detail (Sources screen + lineage in metric detail)
- [x] Insights / reports (feedback + evidence links)

## Phase G — Verification & docs
- [x] Unit tests: dedup, baseline numerics, export round-trip, unit conversion, ULID, repositories (20 tests)
- [x] `xcodebuild test` green; build clean (0 warnings)
- [x] Boot simulator, launch app, screenshot the real flows (docs/screenshots/)
- [x] README, architecture, data-model, module READMEs, ADRs finalized
- [x] Commits in coherent units
- [ ] AR snapshot CI lane (visually verified; automated lane is a follow-up)

## Vertical slices (proven on iOS; Android mirrors next)
- [x] VS-1 "Last night, truthfully" — ingestion, provenance, dedup (one source/night, reversible), dual rendering
- [x] VS-2 "Take it with you" — export CSV/JSON/manifest, raw/derived separation, offline (round-trip tested)
- [x] VS-3 "Log what matters" — event logging, sensitive namespace, RTL forms, non-punitive meds
- [x] VS-4 "Why is it saying that?" — 14-day baselines, anatomy sheet, append-only derived values
- [x] VS-5 "Arabic is not a locale file" — structural i18n + full RTL mirroring (screenshot verified)

## Explicitly deferred (per plan scope rule)
Sync service · vendor/broker integrations · notifications/reminders · watch/widgets · AI/LLM ·
labs/biology · cycle engine · full ~300-metric coverage.
