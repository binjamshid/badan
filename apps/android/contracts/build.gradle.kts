// :contracts — the phone↔watch wire contract, and nothing else.
//
// ADR-0012 makes this the first Android module with a hard, compiler-enforced boundary. It is a
// pure `kotlin("jvm")` module: the Android Gradle plugin is deliberately NOT applied, so
// `android.content.Context`, `android.database.sqlite.*` and `androidx.health.connect.*` are not
// on this module's compile classpath at all. A DTO that cannot see a Context cannot grow a path
// to a repository, and a wire format that cannot see SQLite cannot start carrying rows.
//
// What belongs here (Batch 2 fills it; this file is only the skeleton):
//   - the ambient-snapshot DTO tree (the Kotlin analogue of iOS's AmbientSnapshotDto)
//   - its @Serializable annotations
//   - the snapshot `schemaVersion`
//   - the Wear DataClient path constants and message keys :app and :wear must both agree on
//
// What does NOT belong here: anything that reads, writes, derives or scores. If a change to this
// module needs an Android type, that is the signal that the change belongs in :app.
//
// NOTE on the plugin ids below. `org.jetbrains.kotlin.jvm` is applied WITHOUT a version, while
// `kotlin.serialization` uses its catalog alias. That asymmetry is forced, not sloppy: the root
// build file already declares `kotlin.android` (which ships the JVM plugin in the same artifact)
// with `apply false`, so the JVM plugin is already on the build classpath "with an unknown
// version" and Gradle refuses a second, versioned request for it. The serialization plugin is
// declared `apply false` at the root too, which is exactly the case the alias form is designed
// for. The version is still pinned — by `libs.plugins.kotlin.android` in the root build file —
// and `libs.plugins.kotlin.jvm` exists in the catalog so a future root-file edit can declare it
// `apply false` alongside the others and switch this line to the alias form.
plugins {
    id("org.jetbrains.kotlin.jvm")
    alias(libs.plugins.kotlin.serialization)
}

java {
    // Matches :app's compileOptions/kotlinOptions (Java 17) so the jar is loadable by both the
    // phone and the watch APK without a desugaring surprise.
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // kotlinx-serialization-json is the ONLY dependency this module is permitted. Adding anything
    // else here — especially anything androidx — silently reopens the boundary that ADR-0012 made
    // this module exist to close, because whatever :contracts can see, :wear can see too.
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
}
