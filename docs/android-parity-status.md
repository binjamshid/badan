# Android Parity Status

> Tracks the Android app's parity with the working iOS flagship. Reference truth: the shipped
> iOS implementation (`apps/ios/`), `packages/` contracts, and the blueprint. Updated as the
> Android milestone progresses. Legend: ✅ done · 🟡 partial · ⏸ intentionally deferred · ⛔ blocked.

## Stack & bridge decisions

| Area | iOS | Android | Note |
|---|---|---|---|
| Language / UI | Swift / SwiftUI | Kotlin / Jetpack Compose | native each side |
| Build | XcodeGen + xcodebuild | Gradle 8.11.1 + AGP 8.9.1, JBR 21 | compileSdk 36, minSdk 26 |
| Persistence | raw SQLite (`SQLiteConnection`) | framework SQLite (`SqliteConnection`) | **ADR-0007** — same DDL, no Room/KSP |
| Instants | `Date` | `Long` epoch-millis | same UTC meaning; ADR-0007 |
| JSON | `Codable` | kotlinx.serialization | same shapes |
| Shared data | `packages/*.json` → app bundle | same `packages/*.json` → app assets | one source of truth |
| Health | `HealthStorePort` + HealthKit | `HealthStorePort` + Health Connect | same seam |

## Parity by area

| Area | Status | Detail |
|---|---|---|
| Gradle/Compose project | ✅ | builds an APK (`assembleDebug`), Health Connect + Compose + serialization wired |
| Core primitives | ✅ | Ulid, Clock (Long), Units, AppLanguage/LocalizedString/Numerals ported |
| SQLite wrapper + two DB files | ✅ | `SqliteConnection`/`Row`, `Database` (purge/reset preserve connection identity) |
| Canonical domain entities | 🟡 | porting from iOS `Domain/*` (same names, enum codes, invariants) |
| Migration 001 DDL | 🟡 | same table/column names + indexes as iOS |
| Ontology loaders | 🟡 | MetricRegistry / SymptomDictionary / InsightTemplateStore from assets |
| Repositories | 🟡 | mirror of iOS repos (idempotent upsert, suppression, append-only) |
| Ingestion + dedup | 🟡 | normalize → tz/day attribution → sleep dedup + reversible journal |
| Baselines + insights | 🟡 | 14-day median/MAD, wellness-safe templates (en+ar) |
| Export (CSV/JSON/manifest) | 🟡 | 24-column CSV contract, JSON bundle, SHA-256 manifest |
| FakeHealthStore (deterministic seed) | 🟡 | 90-day two-source generator (dedup demo) |
| Health Connect adapter boundary | 🟡 | availability + permission set + descriptors; reads TODO (post-MVP) |
| Design system (Compose) | ⬜ | tokens/theme/components matching iOS |
| Screens (15) | ⬜ | onboarding, home, body, metric detail, timeline, log hub, symptom/med/workout/nutrition, export, settings, sources, insights |
| App shell + nav + seed | ⬜ | AppEnvironment DI, nav, seed on launch |
| en/ar + RTL | ⬜ | structural, same as iOS |
| Tests | ⬜ | dedup/baseline/units/export/repo parity |
| Emulator run + screenshots | ⬜ | assembleDebug + boot + capture |

## Intentional divergences (product truth preserved)

- **Persistence engine** (framework SQLite vs Room) and **instant type** (`Long` vs `Date`) — ADR-0007.
- **Icons**: Material icon keys instead of SF Symbols (UI concern; family/meaning identical).
- **Compose layout / Material motion / file-share** idioms are Android-native (allowed divergence).
- **Export byte-identical-with-iOS** is a later conformance goal; Android export is structurally
  correct and follows the same 24-column contract now.

## Deferred (non-blocking, smaller than what's done)

Real Health Connect record reads (boundary + availability + permissions exist; FakeHealthStore is
the dev source) · background delivery · sync · vendor integrations · notifications · widgets/Wear ·
LLM insights · automated screenshot/AR-snapshot CI lane.
