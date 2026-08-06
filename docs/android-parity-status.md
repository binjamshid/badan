# Android Parity Status

> Tracks the Android app's parity with the working iOS flagship. Reference truth: the shipped
> iOS implementation (`apps/ios/`), `packages/` contracts, and the blueprint. Updated as the
> Android milestone progresses. Legend: ✅ done · 🟡 partial · ⏸ intentionally deferred · ⛔ blocked.
>
> **Verification note:** an Android CI job exists — `android-build-test`
> (`.github/workflows/ci.yml`), running `testDebugUnitTest`, `assembleDebug` and a non-blocking
> lint pass on every push/PR. But it declares `needs: data-contracts`, and `data-contracts` fails
> shut the instant any iOS or Android resource mirror (`apps/*/…/assets|Resources/*.json`) drifts
> from its `packages/*.json` source. When that gate is red, `android-build-test` does not run and
> does not fail — it simply never executes, so no Android CI result is produced at all until the
> drift is fixed. Treat "green ✅" below as what was verified locally
> (`assembleDebug`/`./gradlew test`/manual emulator run); CI coverage of Android is structurally
> intermittent, gated on contract sync, not a standing regression net yet.

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
| Export (CSV/JSON/manifest) | ✅ | 26-column CSV contract, JSON bundle, SHA-256 manifest |
| FakeHealthStore (deterministic seed) | ✅ | 90-day two-source generator (dedup demo) — identical values to iOS |
| Health Connect integration | ✅ | real paged `readRecords` → DTOs for 16 record types; availability states; staged permission request + denial retry; sync through the ingestion pipeline; UI card in Sources (`HealthConnectCard`). Manifest: 17 `permission.health.READ_*` entries — 16 are record-type reads, the 17th is `READ_HEALTH_DATA_IN_BACKGROUND` (a capability permission, not a record type) — plus provider `<queries>` + rationale filters |
| Design system (Compose) | ✅ | tokens (light/dark), theme, Card/StatusChip/StatBox/MetricChart(Canvas)/State/Provenance/Pills |
| Screens (27) | ✅ | 27 `*Screen.kt` files under `app/src/main/java/`: nav root, onboarding, home, body+sources, metric detail+anatomy, timeline, log hub, symptom/medication/workout/nutrition logging, export family (basic/advanced/health/template manager/automation setup), settings, insights+correlations, journal+context status, health monitor, reports (list+detail), workout detail, route consent |
| App shell + nav + seed | ✅ | AppEnvironment DI (Compose state), hand-rolled nav, seed on first launch (WAL-fast) |
| en/ar + RTL | ✅ | structural; Arabic RTL Home verified (full mirroring + Arabic duration) |
| Unit tests (pure logic) | ✅ | 10 JVM parity tests: units, dedup overlap/reconcile, ULID, median/MAD |
| DB-backed pipeline tests | 🟡 | validated at runtime; automated instrumented/Robolectric suite is a follow-up |
| Emulator run + screenshots | ✅ | `assembleDebug` + Medium_Phone: Home (EN/AR), Body, Log — `docs/screenshots/android/` |

## Intentional divergences (product truth preserved)

- **Persistence engine** (framework SQLite vs Room) and **instant type** (`Long` vs `Date`) — ADR-0007.
- **Icons**: Material icon keys instead of SF Symbols (UI concern; family/meaning identical).
- **Compose layout / Material motion / file-share** idioms are Android-native (allowed divergence).
- **Export byte-identical-with-iOS** is enforced today, not a later goal: `ExportSchemaParityTest`,
  `GpxAggregationParityTest` and `ExportEncryptorTest`
  (`apps/android/app/src/test/java/net/albayyan/badan/`) assert byte-for-byte equality against the
  shared goldens in `packages/fixtures/`, read from disk rather than copied into either platform's
  source. `ExportEncryptorTest.iosWrittenContainerDecryptsOnAndroid` decrypts an export container
  `apps/ios/Sources/Export/ExportEncryption.swift` actually produced — proven interop, not just
  parallel construction. Android export follows the same 26-column contract
  (`packages/export-schemas/csv_columns.json`).

### Health Connect note

Reads are **real** (`HealthConnectAdapter` maps 16 record types via paged `readRecords`) and wired
end-to-end: availability → staged permission request → sync through the ingestion pipeline, with a
`HealthConnectCard` in Data Sources. On a stock emulator with no Health Connect provider set up,
the card honestly shows the "Set up Health Connect" path (verified); on a device with Health
Connect + data it shows "Connect Health Connect" → the OS permission sheet → imported readings.
Timezone attribution uses the device's current zone (HC stores offsets, not IANA names).

## Deferred (non-blocking, smaller than what's done)

Health Connect **background delivery** (the OS passive-push API; change-token incremental sync on
the foreground/periodic pull path shipped — EPIC-02, see the header comment in
`platform/background/SyncWorker.kt`) · multi-device sync · vendor integrations · widgets/Wear ·
LLM insights · automated instrumented/Robolectric DB-pipeline tests (validated at runtime) ·
screenshot/AR-snapshot CI lane.

**Notifications shipped, one gap remains (EPIC-32):** channels, `POST_NOTIFICATIONS`, a
WorkManager-scheduled decision engine, and a durable `notification_deliveries` ledger are all in
(`platform/notifications/`). The standing gap is medication reminders: unlike iOS's
`NotificationScheduler` + `MedicationReminderPlan`, **Android has no medication-reminder delivery
at all** — no `meds` row is ever written and the Notifications settings surface offers no
medication toggle (see the doc comment on `NotificationClass` in `NotificationDecisionEngine.kt`).

**File-import gap (Apple Health ZIP importer, plan §19):** iOS ships an `export.zip` importer
(`apps/ios/Sources/Platform/Import/`) that streams Apple's `export.xml` through the ordinary
`IngestionPipeline`, so imported rows are deduped and provenanced exactly as live sync's are and
the whole import is one-tap undoable through `import_batches`. **Android has no counterpart, by
scope, not by oversight:** an Apple Health archive is an Apple-platform artifact, and Android's
equivalent history path is Health Connect live sync, which is done. What Android is genuinely
missing is a *generic* file importer (CSV/JSON, and a BADAN backup bundle) — a later item with its
own design, not a port of this one. The reusable half of the iOS work is the pipeline seam
(`IngestionPipeline.IngestOrigin.fileImport(batchId:)`) plus the `ImportBatchRepository` lineage/undo
layer; both have direct Android equivalents to write when that item is scheduled, and the
`import_batches` table already exists in the shared DDL on both platforms.

**Screenshot coverage gap:** `docs/screenshots/android/` currently has 5 images covering Home
(light + Arabic/RTL), Body, Log hub, and Data Sources only — Metric Detail, Anatomy sheet,
Timeline, Symptom/Medication/Workout/Nutrition logging, Export, Insights, Onboarding, and Settings
have no screenshot yet, and none of the 5 existing images is dark-mode. Capturing these is a
manual, same-day QA task (use the `badan_route` deep-link extras in `MainActivity.kt` for fast
navigation to each screen) — not something to synthesize.

**Instrumented-test gap (the module's largest standing test debt):** `apps/android/app/src/`
has exactly two source sets, `main` and `test` — there is **no `androidTest` source set at all**.
Yet `app/build.gradle.kts` still declares
`testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"` in `defaultConfig`, which
is dead configuration: there is no instrumented source set for a runner to execute. 20 files under
`app/src/test/java/net/albayyan/badan/` (`BackgroundSubstrateTest`, `BaselineAppendOnlyMigrationTest`,
`ContextAnnotationWiringTest`, `ExportDeltaBundleTest`, `ExportDeltaCsvTest`, `ExportDestinationsTest`,
`ExportRunnerTemplateTest`, `ExportSurfacesTest`, `ExportTemplateSystemTest`,
`HydrationExportInclusionTest`, `HydrationSurfacePresentationTest`, `HydrationTest`,
`JournalSurfacePresentationTest`, `JournalTest`, `NotificationDecisionEngineTest`,
`ProfileHRZonesTest`, `ReportBuilderTest`, `ReportRendererTest`, `ReportsNotificationsMigrationTest`,
`ShortcutActionsTest`) carry an explicit doc-comment caveat naming what they cannot verify because
there is no androidTest/Robolectric run — real SQLite behavior, `ContentResolver`/`Context`-backed
paths, and other framework-dependent code covered only by JVM-reachable proxies (writer-layer
assertions, in-memory fakes) instead of the real Android runtime. The "DB-backed pipeline tests 🟡"
row in the table above is the tip of this: the debt is systemic across roughly a third of the JVM
test suite, not confined to the database layer, and closing it means adding an actual
`androidTest` source set (or Robolectric) — not just writing more JVM tests.

## ADR-0014 / D-44 — accounts, cross-platform entitlement sync, referrals: **iOS only**

Shipped on iOS in the 1.2 branch; **not started on Android**, and deliberately so — the founder
scoped this build to iOS. Recorded here rather than left to be discovered, because the feature is
*named* for crossing platforms and half of it does not exist yet.

What iOS has: Sign in with Apple, `AccountClient` against `/v1/account/*`, `EntitlementMerge`
(remote may grant, never revoke), referrals, in-app account deletion.

What Android needs before the sync is real in both directions:

| Piece | Status | Note |
|---|---|---|
| Play Billing integration | **absent** | D-40 specified the product-id space (`badan_pro` + base plans, `pro.lifetime` as a one-time product). Nothing is built against it. Until this exists Android has no `localEntitlement` to report, so the *sending* direction is impossible. |
| Domain mirror (`EntitlementMerge`, `ReferralPolicy`, `SyncedEntitlement`) | **absent** | Kotlin port of `apps/ios/Sources/Domain/{Subscription,Referral}/`. Pure, no framework — the cheapest piece and the one to do first. Mirror the constants literally; the server (`backend/api/accounts.py`) is authoritative and a drift is a code one platform mints and another refuses. |
| Account client | **absent** | Would be Android's **first** network client for a BADAN-owned service. `apps/android/.../export/destinations/RestDestination.kt` is currently the only networking file in the module, and CI's `AND_NET_API` scan is repo-wide — adding one means widening that allowlist, exactly as `.github/workflows/ci.yml` was widened for the iOS `AccountClient`. |
| Sign in with Apple | **absent, and blocked on credentials** | Android has no native SIWA. It needs the **web** OAuth flow: an Apple **Services ID**, a **Key ID + .p8 private key** for the ES256 client-secret JWT, and a registered return URL on `badan.binjamshid.com` — none of which exist in the Apple Developer account yet, and none of which can be created from the repository. A backend callback route (`/v1/account/apple/web/*`) and a Custom Tabs launcher are the code half; the portal configuration is a prerequisite, not a follow-up. |

The backend already speaks Android's half of the wire: `PLATFORMS` includes `"android"`,
`account_entitlements` is keyed by `(account_id, platform)`, and `test_accounts.py` exercises an
Android entitlement being pushed and read back. So an Android install that could sign in would work
today — the gap is entirely client-side plus the Apple portal setup above.
