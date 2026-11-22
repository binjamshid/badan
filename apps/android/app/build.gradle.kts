plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    // `namespace` (R-class/manifest package, and the Kotlin package every source
    // file under app/src/main/java/net/albayyan/badan/ already declares) is left
    // as `net.albayyan.badan` intentionally — it is independent of
    // `applicationId` (below), and changing it would require moving ~80 Kotlin
    // source files' package directories. Only `applicationId` (the Play Store /
    // deep-link / Health Connect / Firebase identity) was updated to match the
    // decided portfolio namespace (2026-07-20): Android has never shipped, so
    // this is a safe rename.
    namespace = "net.albayyan.badan"
    compileSdk = 36

    defaultConfig {
        applicationId = "net.binjamshid.badan"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // Backed by a real `app/src/androidTest` source set as of B1-1. Before that this line was
        // dead config: the runner was named but there was nothing for it to run, which is why ~20
        // unit-test files carry an explicit "untested on Android, no androidTest/Robolectric"
        // caveat.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // BADAN ships English + Arabic; keep both in the built resources.
        resourceConfigurations += listOf("en", "ar")

        // --- Native ABIs -----------------------------------------------------------------
        // SQLCipher (D-39, `net.zetetic:sqlcipher-android`) ships a native `.so` per ABI —
        // roughly 10 MB across the four ABIs a minSdk-26 app could theoretically serve. D-39
        // requires that trade-off be made explicitly rather than inherited, and the choice here
        // is `abiFilters`, not `splits { abi { … } }`:
        //
        //   - BADAN ships through Play as an App Bundle, and Play already splits per-ABI at
        //     delivery. `splits { abi }` only changes what a *standalone APK* set looks like, so
        //     it would buy nothing on the distribution path actually in use.
        //   - `abiFilters`, by contrast, shrinks the bundle itself AND every local build — which
        //     includes the debug APK that `connectedDebugAndroidTest` installs on an emulator.
        //
        // `x86` (32-bit Intel) is dropped outright: no current device and no current emulator
        // system image uses it. `armeabi-v7a` is KEPT — Play still serves 32-bit-only ARM devices
        // from it, and minSdk 26 (Android 8.0) genuinely reaches such devices. Dropping it would
        // be an install-eligibility decision, not a size optimisation, and it is not one this
        // task is entitled to make.
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        debug {
            // AGP intersects buildType abiFilters with defaultConfig's, so debug builds carry only
            // arm64-v8a (Apple-silicon and modern ARM emulators, plus every physical test device)
            // and x86_64 (Intel emulators, ChromeOS). Nothing is ever installed on an armeabi-v7a
            // device from a debug build, so shipping that `.so` locally is pure build time and
            // pure disk.
            ndk {
                abiFilters.clear()
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
        release {
            // isMinifyEnabled stays false for now, so no proguard-rules.pro is referenced here —
            // referencing a keep-rules file that doesn't exist yet would be a landmine for the
            // day minification is turned on. Add the file (kotlinx.serialization + Health
            // Connect keep rules) in the same change that flips isMinifyEnabled to true.
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
        // Robolectric needs the merged resources, the merged manifest and the packaged assets to
        // exist on the unit-test classpath; without this it fails at runtime with a missing
        // `com/android/tools/test_config.properties` rather than with anything that names the
        // real cause. `isReturnDefaultValues` above stays on for the ~700 plain-JVM tests that
        // touch android.jar stubs without a Robolectric sandbox.
        unitTests.isIncludeAndroidResources = true
    }
}

composeCompiler {
    // Build-verified visibility into which composables/state holders the Compose compiler
    // considers unstable or non-skippable, so recomposition claims can be checked against real
    // data instead of static analysis alone.
    reportsDestination = layout.buildDirectory.dir("compose_reports")
    metricsDestination = layout.buildDirectory.dir("compose_metrics")
}

dependencies {
    // --- kotlin-stdlib guard -------------------------------------------------------------------
    // A third-party AAR compiled with a newer Kotlin drags kotlin-stdlib forward transitively, and
    // the Kotlin 2.0.21 compiler then refuses to read that stdlib's metadata. What you SEE when
    // that happens is not a version message — it is:
    //
    //   e: … FileAnalysisException: While analysing …/MainActivity.kt:40:5:
    //        java.lang.IllegalArgumentException: source must not be null
    //   > Internal compiler error. See log for more details
    //
    // i.e. a compiler crash naming a source file that has nothing to do with the cause. This
    // happened for real while declaring these dependencies (Play Billing 9.1.0 → stdlib 2.2.10).
    //
    // `strictly` converts that into an ordinary, legible dependency-conflict failure that names
    // both the offending module and the pin. When it fires, the fix is either to pick an older
    // version of the offending library or to bump `kotlin` in the version catalog — NOT to delete
    // this constraint, which would only restore the confusing crash.
    constraints {
        val kotlinVersion = libs.versions.kotlin.get()
        listOf("implementation", "testImplementation", "androidTestImplementation").forEach { conf ->
            add(conf, "org.jetbrains.kotlin:kotlin-stdlib") {
                version { strictly(kotlinVersion) }
                because("must match the Kotlin compiler ($kotlinVersion); see the note above")
            }
        }
    }

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    debugImplementation(libs.androidx.ui.tooling)

    implementation(libs.health.connect.client)
    implementation(libs.kotlinx.serialization.json)
    // EPIC-05 background sync. Android's answer to iOS A2: WorkManager periodic work is the only
    // scheduler that survives process death and reboot, which is what makes the Android UI able
    // to say "usually within the hour" where iOS can only promise "best-effort" (plan §14).
    // Pulled in at the platform-config layer so the worker implementation lands against a
    // dependency that is already resolving, rather than bundling a dependency bump into a
    // feature PR.
    implementation(libs.androidx.work.runtime.ktx)

    // -----------------------------------------------------------------------------------------
    // Everything below was declared in one pass (B1-1) so that no later parity-port task has to
    // edit this file, `settings.gradle.kts` or `libs.versions.toml` again — two concurrent agents
    // editing a version catalog costs a batch barrier; an unused declared dependency costs a few
    // seconds of resolution. Each line says what it is FOR, so a later reader can tell a
    // deliberate forward declaration from a leftover.
    // -----------------------------------------------------------------------------------------

    // The phone↔watch wire contract. Pure kotlin("jvm") — no Android types (ADR-0012).
    implementation(project(":contracts"))
    // Phone end of the DataClient/MessageClient transport; :wear declares the same library.
    implementation(libs.play.services.wearable)

    // Glance home-screen widgets. These live in :app, NOT a separate module: a
    // GlanceAppWidgetReceiver is an ordinary BroadcastReceiver in the same process and the same
    // APK, so it calls straight back into the app's own repositories — exactly the shape
    // platform/shortcuts/RunExportTileService.kt already proves for Quick Settings tiles. iOS's
    // hand-duplicated AmbientSnapshotDto exists because an iOS widget is a separate App Extension
    // process; that is Apple's constraint, not a design for Android to re-derive (ADR-0012).
    implementation(libs.androidx.glance.appwidget)
    implementation(libs.androidx.glance.material3)

    // Attestation (D-41): Play Integrity stands in for App Attest, which has no Android
    // equivalent. D-41 is explicit that this is NOT a like-for-like swap — a Play Integrity
    // verdict classically requires a network round trip to Google, which is a new dependency at
    // the attestation layer itself. It also means the manifest's current
    // "android.permission.INTERNET is DELIBERATELY ABSENT" note stops being true the day this is
    // wired up; the merged-manifest CI gate and the Play Data Safety copy must move in the same
    // change, not after.
    implementation(libs.play.integrity)

    // Storage. D-39 substitutes `net.zetetic:sqlcipher-android` for the archived
    // `net.zetetic:android-database-sqlcipher` that ADR-0010 §A16 names — scoped to
    // badan_sensitive.db only, with the key Android-Keystore-derived and never user-typed.
    // security-crypto is what derives/wraps that key. See the ndk { abiFilters } block above for
    // the native-payload trade-off this dependency forces.
    implementation(libs.sqlcipher.android)
    implementation(libs.androidx.security.crypto)

    // OCR for the lab notebook. IMPORTANT, and not a detail to discover later: ML Kit Text
    // Recognition v2's base artifact is the LATIN-script model, and Google publishes no Arabic
    // script model at any version (only -chinese, -devanagari, -japanese, -korean exist).
    // iOS reads Arabic lab reports through Vision — Ingest/OCR/LabDocumentOCR.swift handles
    // Arabic letters, tashkeel, Arabic-Indic digits and RTL reading order explicitly. Declaring
    // this dependency does NOT close that gap; whoever ports the lab notebook must either bring a
    // different engine or record a G6 variance, and must not ship a Latin-only Android OCR path
    // as if it were parity.
    implementation(libs.mlkit.text.recognition)

    // --- Unit tests (JVM, incl. Robolectric) --------------------------------------------------
    testImplementation(libs.junit)
    // Robolectric retires the largest standing debt in this module: before B1-1 there was no way
    // to exercise a single line of Android-framework-touching Kotlin, and ~20 test files say so
    // in a comment. Robolectric 4.16.1 supports Android 16 / API 36, so tests run at this
    // module's real targetSdk rather than pinned below it.
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    // WorkManager's TestDriver / WorkManagerTestInitHelper, for the D-42 background substrate
    // (periodic worker + expedited one-off + boot receiver). Version-locked to `work` on purpose.
    testImplementation(libs.androidx.work.testing)

    // --- Instrumented tests (app/src/androidTest, on a device or emulator) ---------------------
    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.core.ktx)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.ui.test.junit4)
    // ui-test-manifest supplies the empty activity ComposeTestRule launches into. It must be a
    // debugImplementation, not an androidTestImplementation — it contributes a manifest entry to
    // the *app under test*, not to the test APK.
    debugImplementation(libs.androidx.ui.test.manifest)
}
