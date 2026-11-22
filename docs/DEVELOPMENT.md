# Develop Badan locally

Start from the root of a clean checkout. Pick iOS or Android to run the sample-data walkthrough. Both apps can generate sample readings locally, and the walkthrough uses no health permissions, personal exports, backend settings, or store purchases. Initial toolchain and dependency downloads require internet access.

## iOS

Use macOS with Xcode 26.x, an installed iOS simulator runtime, and XcodeGen. CI uses XcodeGen 2.45.4. Install watchOS platform support in Xcode if it is missing because the phone target embeds a watch app. The deployment floors are iOS 17 and watchOS 10. The app resolves its pinned SQLCipher package through Swift Package Manager. [.github/workflows/ci.yml](../.github/workflows/ci.yml), [XcodeGen project](../apps/ios/project.yml)

```bash
brew install xcodegen
cd apps/ios
xcodegen generate
open BADAN.xcodeproj
```

Choose the **BADAN** scheme and an installed iPhone simulator in Xcode, then click Run. The simulator workflow requires no device provisioning or Apple Developer account. Edit `project.yml` for project changes and regenerate the project. On a fresh app launch, use [the sample-data walkthrough](#sample-data-walkthrough).

For a focused check, copy an available iPhone simulator UUID from the first command and replace the placeholder below. Run these commands from `apps/ios` after project generation.

```bash
xcrun simctl list devices available
SIMULATOR_ID='<available iPhone simulator UUID>'
xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:BADANTests/CanonicalizationParityTests test
```

Use `BADANTests/ReadinessEngineTests` for readiness or `BADANTests/ExportSchemaParityTests` for export serialization. The `BadanWatch` scheme has separate watchOS simulator tests under `BadanWatchTests`. The iOS workflow runs the phone scheme. For SwiftUI navigation changes, run `python3 scripts/check-reachability.py` from the repository root. This independent CI check looks for source construction sites outside previews. Confirm the affected navigation in the app as well. [iOS test sources](../apps/ios/Tests/), [watchOS test sources](../apps/ios/BadanWatchTests/), [reachability check](../scripts/check-reachability.py)

For physical iOS and watchOS testing, configure signing, bundle identifiers and applicable capabilities for your own team. Use a consented device for real HealthKit data and a paired watch for watch delivery. StoreKit purchases, Sign in with Apple, and App Attest-backed requests have separate platform and service setup.

## Android

Use Android Studio with Android SDK Platform 36 and Platform-Tools. Install an emulator image for your host architecture and create an Android Virtual Device (AVD) if you need one. Use JDK 17 for the focused JVM check below, matching the Android CI configuration at this revision. The checked-in wrapper downloads Gradle 8.11.1. The phone module compiles and targets API 36 with a minimum of API 26. Health Connect availability and permissions depend on the test environment. [Phone build configuration](../apps/android/app/build.gradle.kts), [Gradle wrapper](../apps/android/gradle/wrapper/gradle-wrapper.properties), [Android CI](../.github/workflows/ci.yml)

Open `apps/android` in Android Studio and sync Gradle. Select the **app** debug configuration and your AVD, then click Run. Android Studio uses local debug signing. On a fresh app launch, use [the sample-data walkthrough](#sample-data-walkthrough).

For a focused command-line check, make the Android SDK location available to Gradle through Android Studio's local project configuration or `ANDROID_HOME`. Set `JAVA_HOME` to your JDK 17 installation.

```bash
cd apps/android
./gradlew :app:testDebugUnitTest \
  --tests net.albayyan.badan.HealthConnectCanonicalParityTest
```

Use `net.albayyan.badan.ReadinessEngineGoldenTest` for readiness or `net.albayyan.badan.ExportSchemaParityTest` for export serialization. Use `:app:assembleDebug` to produce a debug APK for local installation. Framework-dependent Robolectric tests and instrumentation on an emulator or device are separate checks. The workflow also checks the merged release manifest for Android's internet permission. Test Health Connect behavior on an environment that supports the relevant data types and permissions. Play distribution requires separate release signing and store configuration. [Android JVM tests](../apps/android/app/src/test/), [Android instrumentation tests](../apps/android/app/src/androidTest/)

## Sample-data walkthrough

1. In onboarding, advance to the data connection step and choose **Explore with sample data**. If offered optional iOS telemetry, leave it off for the walkthrough.
2. Open **Today** and confirm the sample-data banner. Open a metric and inspect the displayed source or provenance. Readiness depends on available inputs and may show a provisional estimate.
3. Change the app language to Arabic in Settings and revisit **Today** to check right-to-left layout. Open Export and create a scoped local CSV or JSON export using the sample data. Keep the Apple Health or Health Connect source disconnected while testing the demo.

The alternative **Start empty** clears the sample store and finishes onboarding. The native sample sources and consent choices are defined in the onboarding code. [iOS onboarding](../apps/ios/Sources/Features/Onboarding/OnboardingView.swift), [Android onboarding](../apps/android/app/src/main/java/net/albayyan/badan/features/onboarding/OnboardingScreen.kt)

## Optional backend

Use Python 3.13, matching CI. The FastAPI service supports optional iOS coach, account and methodology telemetry flows. The focused endpoint test below uses a stubbed upstream provider, a temporary database directory and an in-process client.

```bash
cd backend/api
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt pytest
python -m pytest tests/test_chat.py::test_a_completion_is_returned_to_the_caller -q
```

To check local service startup, use the same directory and virtual environment. The API reads `OPENROUTER_API_KEY` on import. A placeholder is sufficient for the local health endpoint. Point `BADAN_DATA_DIR` at a disposable directory.

```bash
BADAN_DATA_DIR="$(mktemp -d)" OPENROUTER_API_KEY=local-placeholder \
  python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

From a second terminal, run `curl -fsS http://127.0.0.1:8000/health` and look for `"status":"ok"`. Stop the server with Ctrl+C. This check covers the localhost HTTP process. Exercising connected app features requires the relevant provider credentials, signing and platform authentication. Use the stubbed endpoint test for offline coach development. [API entry point](../backend/api/main.py), [backend dependencies](../backend/api/requirements.txt)

## Shared contract changes

Edit the canonical files under `packages/` and regenerate the app resource mirrors. From the repository root, run:

```bash
bash scripts/sync_ios_resources.sh
scripts/sync_android_assets.sh
python3 scripts/gen_data_dictionary.py
python3 scripts/gen_data_dictionary.py --check
scripts/check_fixture_hashes.sh
```

Review the diff and run the focused check for the behavior on each affected platform. If you intentionally revise a synthetic golden, update its checksum with `scripts/check_fixture_hashes.sh --update` after reviewing the fixture diff. Keep personal exports, local database files and service credentials out of changes and reports. See the [technical blueprint](TECHNICAL_BLUEPRINT.md) for contract ownership, algorithm versioning and parity evidence.
