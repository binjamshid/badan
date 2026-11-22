# Badan Android

The Kotlin and Jetpack Compose app supports Health Connect reads, local logs, Readiness and scoped exports. Its health adapter, storage, derivation and export layers use the project's shared contracts. The Wear OS project provides a scaffold for future companions. [Technical blueprint](../../docs/TECHNICAL_BLUEPRINT.md), [Wear module](wear/src/main/java/net/albayyan/badan/wear/WearModule.kt)

## Run the phone app

Open this directory in Android Studio with Android SDK Platform 36. Choose the **app** debug configuration and an available emulator. Choose **Explore with sample data** in onboarding, open **Today**, and switch to Arabic in Settings to try the right-to-left layout. [Development guide](../../docs/DEVELOPMENT.md), [user guide](../../docs/USER_GUIDE.md)

For command-line installation with one emulator already running, use the checked-in Gradle wrapper from this directory. The application ID is `net.binjamshid.badan` and the activity class is in the `net.albayyan.badan` namespace. [Phone build configuration](app/build.gradle.kts), [MainActivity](app/src/main/java/net/albayyan/badan/MainActivity.kt)

```bash
./gradlew :app:installDebug
adb shell am start -n net.binjamshid.badan/net.albayyan.badan.MainActivity
```

The phone targets API 36 with a minimum of API 26. Health Connect availability and the supported permission families depend on the Android environment. Use a representative low-spec device when qualifying performance near the supported floor.

## Source and tests

- `app` is the phone application. The feature screens call domain services backed by app-local repositories. Both the main and the separate sensitive file use framework SQLite in this revision. [Database](app/src/main/java/net/albayyan/badan/storage/Database.kt)
- The [resource sync script](../../scripts/sync_android_assets.sh) copies the canonical contracts into the app's assets and the algorithm parameters onto its JVM classpath.
- The CI configuration uses JDK 17 and the wrapper downloads Gradle 8.11.1. The [development guide](../../docs/DEVELOPMENT.md#android) lists focused unit tests for canonicalization, Readiness and serialization. Framework-dependent tests use Robolectric or the Android instrumentation source set. [Android CI](../../.github/workflows/ci.yml)
- `:wear` may depend on the pure Kotlin `:contracts` module for the phone-snapshot protocol. The Wear build defines the dependency check `:wear:checkWearDependencyBoundary`. [Gradle settings](settings.gradle.kts), [Wear build configuration](wear/build.gradle.kts)
