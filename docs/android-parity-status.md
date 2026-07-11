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
| Canonical domain entities | ✅ | ported from iOS `Domain/*` (same names, enum codes, invariants) |
| Migration 001 DDL | ✅ | same table/column names + indexes as iOS |
| Ontology loaders | ✅ | MetricRegistry / SymptomDictionary / InsightTemplateStore from assets |
| Repositories | ✅ | mirror of iOS repos (idempotent upsert, suppression, append-only) |
| Ingestion + dedup | ✅ | normalize → tz/day attribution → sleep dedup + reversible journal (verified at runtime) |
| Baselines + insights | ✅ | 14-day median/MAD, wellness-safe templates (en+ar) — same numbers as iOS |
| Export (CSV/JSON/manifest) | ✅ | 24-column CSV contract, JSON bundle, SHA-256 manifest |
| FakeHealthStore (deterministic seed) | ✅ | 90-day two-source generator (dedup demo) — identical values to iOS |
| Health Connect integration | ✅ | real paged `readRecords` → DTOs for 9 record types; availability states; staged permission request + denial retry; sync through the ingestion pipeline; UI card in Sources (`HealthConnectCard`). Manifest: 9 `READ_*` perms + provider `<queries>` + rationale filters |
| Design system (Compose) | ✅ | tokens (light/dark), theme, Card/StatusChip/StatBox/MetricChart(Canvas)/State/Provenance/Pills |
| Screens (15) | ✅ | onboarding, home, body+sources, metric detail+anatomy, timeline, log hub, symptom/med/workout/nutrition, export, settings, insights |
| App shell + nav + seed | ✅ | AppEnvironment DI (Compose state), hand-rolled nav, seed on first launch (WAL-fast) |
| en/ar + RTL | ✅ | structural; Arabic RTL Home verified (full mirroring + Arabic duration) |
| Unit tests (pure logic) | ✅ | 10 JVM parity tests: units, dedup overlap/reconcile, ULID, median/MAD |
| DB-backed pipeline tests | 🟡 | validated at runtime; automated instrumented/Robolectric suite is a follow-up |
| Emulator run + screenshots | ✅ | `assembleDebug` + Medium_Phone: Home (EN/AR), Body, Log — `docs/screenshots/android/` |

## Intentional divergences (product truth preserved)

- **Persistence engine** (framework SQLite vs Room) and **instant type** (`Long` vs `Date`) — ADR-0007.
- **Icons**: Material icon keys instead of SF Symbols (UI concern; family/meaning identical).
- **Compose layout / Material motion / file-share** idioms are Android-native (allowed divergence).
- **Export byte-identical-with-iOS** is a later conformance goal; Android export is structurally
  correct and follows the same 24-column contract now.

### Health Connect note

Reads are **real** (`HealthConnectAdapter` maps 9 record types via paged `readRecords`) and wired
end-to-end: availability → staged permission request → sync through the ingestion pipeline, with a
`HealthConnectCard` in Data Sources. On a stock emulator with no Health Connect provider set up,
the card honestly shows the "Set up Health Connect" path (verified); on a device with Health
Connect + data it shows "Connect Health Connect" → the OS permission sheet → imported readings.
Timezone attribution uses the device's current zone (HC stores offsets, not IANA names).

## Deferred (non-blocking, smaller than what's done)

Health Connect **background delivery / change-token incremental sync** (foreground pull is done) ·
multi-device sync · vendor integrations · notifications · widgets/Wear · LLM insights · automated
instrumented/Robolectric DB-pipeline tests (validated at runtime) · screenshot/AR-snapshot CI lane.
