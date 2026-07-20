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
    // decided portfolio namespace (2026-07-20, see PHASE-Z-PENDING.md Z6
    // resolution): Android has never shipped, so this is a safe rename.
    namespace = "net.albayyan.badan"
    compileSdk = 36

    defaultConfig {
        applicationId = "net.binjamshid.badan"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // BADAN ships English + Arabic; keep both in the built resources.
        resourceConfigurations += listOf("en", "ar")
    }

    buildTypes {
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
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
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

    testImplementation(libs.junit)
}
