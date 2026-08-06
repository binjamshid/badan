import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.component.ProjectComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedComponentResult
import org.gradle.api.artifacts.result.ResolvedDependencyResult

// :wear — the Wear OS APK (ADR-0012, "Module topology").
//
// Separate APK, separate manifest, separate dependency set: minSdk 30 and
// `<uses-feature android:name="android.hardware.type.watch">`. It mirrors the phone/watch split
// iOS already has between the main app target and its watchOS companion.
//
// `applicationId` matches the phone app exactly. That is a Play requirement for a Wear APK
// distributed alongside a phone app, not a copy-paste slip — the two artifacts are the same
// application to Play, differentiated by the watch uses-feature and the ABI/DPI targeting.
// `namespace` is `.wear` so the two R classes and the two BuildConfigs do not collide.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "net.albayyan.badan.wear"
    compileSdk = 36

    defaultConfig {
        // Same applicationId as :app — see the note above.
        applicationId = "net.binjamshid.badan"
        // Wear OS 3 and later. Wear 2.x (API 25–28) uses a different, effectively dead
        // distribution model; targeting it would mean carrying a second UI toolkit.
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // BADAN ships English + Arabic on the watch too. Arabic/RTL is a first-order concern
        // (CLAUDE.md), and a Wear surface is not exempt from it.
        resourceConfigurations += listOf("en", "ar")
    }

    buildTypes {
        release {
            // Deliberately unminified and unsigned-for-release: release engineering is out of
            // scope for the parity port. Do not add a signingConfig or proguard rules here
            // without the change that turns minification on for :app at the same time.
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
}

dependencies {
    // The ONLY BADAN module :wear is allowed to depend on. Never `project(":app")` —
    // `checkWearDependencyBoundary` below fails the build if that ever appears.
    implementation(project(":contracts"))
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    debugImplementation(libs.androidx.ui.tooling)

    implementation(libs.androidx.wear)
    implementation(libs.androidx.wear.compose.material)
    implementation(libs.androidx.wear.compose.foundation)
    implementation(libs.androidx.wear.compose.navigation)

    // Wear tiles (the watch's glanceable surface) and complications — the Android counterparts
    // to the iOS companion's readiness/sleep/effort complications.
    implementation(libs.androidx.wear.tiles)
    implementation(libs.androidx.wear.tiles.material)
    implementation(libs.androidx.wear.watchface.complications.data.source.ktx)

    // Phone↔watch transport. Declared on both ends; the wire format lives in :contracts.
    implementation(libs.play.services.wearable)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)

    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
}

// ---------------------------------------------------------------------------
// The boundary that makes "the watch is a renderer, not a second scorer" enforceable.
//
// ADR-0012: "CI asserts :wear's resolved dependency graph contains only :contracts plus
// androidx.wear.*/Compose, so the watch module can never grow a path to a repository."
//
// This task resolves :wear's actual runtime graph and fails on two things:
//
//   1. Any *project* dependency other than `:contracts`. This is the one that matters. The
//      moment `project(":app")` appears here, the watch can reach SqliteConnection, the
//      repositories and every derivation engine, and every later "just compute it on the watch"
//      shortcut becomes a code review argument instead of a build failure.
//   2. Any *external* module outside a named allowlist, with an explicit denylist that overrides
//      the allowlist for the androidx groups that ARE a path to a repository (health, sqlite,
//      room, security-crypto, work) — those share the `androidx.` prefix with everything
//      legitimate here, so a prefix allowlist alone would wave them through.
//
// If this task fails on a dependency that is genuinely fine, widen the allowlist WITH a comment
// saying why. Do not delete the task, and do not move a group from the denylist to the allowlist
// — a denylist entry appearing in :wear's graph means someone gave the watch a data path.
// ---------------------------------------------------------------------------
// This list is deliberately the EXACT set of groups :wear's graph resolves to today, not a
// generous forward-looking list. A speculative allowlist entry is a hole that opens silently; a
// too-tight one fails loudly and makes a human look at what was just added, which is the whole
// point. Verified against `./gradlew :wear:dependencies --configuration debugRuntimeClasspath`.
val wearAllowedExternalGroupPrefixes: List<String> = listOf(
    // androidx.wear.*, androidx.compose.*, plus the AndroidX plumbing they drag in (core,
    // activity, lifecycle, annotation, collection, navigation, profileinstaller, …). The
    // denylist below is what keeps the androidx groups that ARE a data path out.
    "androidx.",
    // org.jetbrains (annotations), org.jetbrains.kotlin (stdlib), org.jetbrains.kotlinx
    // (serialization — the watch decodes the snapshot :contracts defines).
    "org.jetbrains",
    // play-services-wearable: the DataClient/MessageClient transport. This is the one non-AndroidX
    // library the watch genuinely needs, and it moves bytes the phone already computed.
    "com.google.android.gms",
    // ListenableFuture, pulled in by wear.tiles / watchface-complications.
    "com.google.guava",
    // Nullness annotations, pulled in by guava.
    "org.jspecify",
)

// Groups that are a path to stored or live health data. These override the allowlist above, and
// several of them start with "androidx." precisely so that the prefix check cannot excuse them.
val wearForbiddenExternalGroups: List<String> = listOf(
    "androidx.health",              // Health Connect — the watch must never read it directly
    "androidx.sqlite",
    "androidx.room",
    "androidx.security",            // security-crypto ⇒ keystore ⇒ the sensitive DB key
    "androidx.work",
    "net.zetetic",                  // SQLCipher
    "com.android.billingclient",
    "com.google.mlkit",
    "com.google.android.play",      // Play Integrity / Play Core
)

// The variant's runtime configuration is read through `androidComponents.onVariants` rather than
// `configurations.named("debugRuntimeClasspath")` — AGP creates the per-variant configurations
// after the build script is evaluated, so looking one up by name at script scope fails outright.
// `rootComponent` is a Provider, which keeps this configuration-cache-compatible: nothing is
// resolved until the task actually runs.
val boundaryCheckTasks = mutableListOf<TaskProvider<*>>()

androidComponents {
    onVariants { variant ->
        val taskName = "check${variant.name.replaceFirstChar { it.uppercase() }}WearDependencyBoundary"
        val rootProvider = variant.runtimeConfiguration.incoming.resolutionResult.rootComponent
        val allowed = wearAllowedExternalGroupPrefixes
        val forbidden = wearForbiddenExternalGroups

        boundaryCheckTasks += tasks.register(taskName) {
            group = "verification"
            description =
                "Fails if :wear's resolved ${variant.name} dependency graph can reach anything but " +
                    ":contracts, androidx.wear/Compose and the Wear transport."

            doLast {
                val offenders = linkedSetOf<String>()
                val visited = mutableSetOf<String>()

                fun walk(component: ResolvedComponentResult) {
                    if (!visited.add(component.id.displayName)) return
                    when (val id = component.id) {
                        is ProjectComponentIdentifier ->
                            if (id.projectPath != ":wear" && id.projectPath != ":contracts") {
                                offenders += "project ${id.projectPath} — :wear may depend on :contracts and nothing else of BADAN's"
                            }

                        is ModuleComponentIdentifier -> {
                            val group = id.group
                            val forbiddenHit = forbidden.firstOrNull { group == it || group.startsWith("$it.") }
                            if (forbiddenHit != null) {
                                offenders += "${id.group}:${id.module} — group '$forbiddenHit' is a data path; the watch renders phone-computed truth"
                            } else if (allowed.none { group.startsWith(it) || group == it.trimEnd('.') }) {
                                offenders += "${id.group}:${id.module} — group not on :wear's allowlist"
                            }
                        }
                    }
                    component.dependencies
                        .filterIsInstance<ResolvedDependencyResult>()
                        .forEach { walk(it.selected) }
                }

                walk(rootProvider.get())

                if (offenders.isNotEmpty()) {
                    throw GradleException(
                        buildString {
                            appendLine(":wear's dependency boundary is violated (ADR-0012). Offending components:")
                            offenders.forEach { appendLine("  - $it") }
                            appendLine()
                            appendLine("The watch is a renderer of phone-computed truth, not a second place any score is computed.")
                            appendLine("If a dependency here is genuinely legitimate, widen wearAllowedExternalGroupPrefixes in")
                            appendLine("wear/build.gradle.kts with a comment saying why — do not delete this check.")
                        }
                    )
                }
            }
        }
    }
}

// An umbrella task so CI (and a human) has one name to run, plus a `check` hook so the boundary is
// verified by any normal verification run rather than only when someone remembers it.
val checkWearDependencyBoundary = tasks.register("checkWearDependencyBoundary") {
    group = "verification"
    description = "Runs the :wear dependency-boundary check for every variant (ADR-0012)."
    dependsOn(boundaryCheckTasks)
}

tasks.named("check") { dependsOn(checkWearDependencyBoundary) }
