pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "BADAN"

// Module topology per ADR-0012 ("Module topology: `:app` + `:wear` + `:contracts`").
//
//   :app        the phone APK. Glance home-screen widgets and Quick Settings tiles live
//               HERE, not in a module of their own — a GlanceAppWidgetReceiver is an
//               ordinary BroadcastReceiver in the same process and the same APK, so there
//               is no extension boundary to cross. iOS's hand-duplicated AmbientSnapshotDto
//               exists because an iOS widget is a separate App Extension process; that is a
//               constraint of Apple's extension model, not a shape Android needs to copy.
//   :wear       a separate Wear OS APK (minSdk 30, uses-feature android.hardware.type.watch).
//   :contracts  pure kotlin("jvm"), NO Android dependency at all, so it cannot reach Context,
//               SQLite or Health Connect. Holds only the ambient-snapshot DTO tree, its
//               @Serializable annotations, a schema version, and the DataClient path/message-key
//               constants :app and :wear must agree on.
//
// The ordering constraint that matters: :wear may depend on :contracts and never on :app.
// `:wear:checkWearDependencyBoundary` (see wear/build.gradle.kts) fails the build if that is
// ever violated — "the watch is a renderer of phone-computed truth, not a second place any
// score is computed" is enforced at the build graph, not by convention.
include(":app")
include(":wear")
include(":contracts")
