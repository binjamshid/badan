package net.albayyan.badan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Every class named in `AndroidManifest.xml` must actually exist.
 *
 * ## Why this needs a test at all
 *
 * A manifest component name is a string. Nothing in the Kotlin build checks it: the compiler never
 * reads the manifest, and the manifest merger only checks XML shape, not that
 * `.platform.workout.LiveWorkoutService` resolves to anything. A typo, a package move, or a
 * deleted class produces a build that compiles cleanly and then either fails to install or
 * throws `ClassNotFoundException` at the moment the system tries to start the component —
 * which for a boot receiver or a widget provider means *on a user's device, in the background,
 * with no visible error*.
 *
 * The inverse bug is the one that actually happened here and is worth naming, because this test
 * does **not** catch it: `platform/background/BootReceiver.kt` existed for an entire epic with no
 * manifest `<receiver>` pointing at it, so it was dead code that failed by doing nothing at all.
 * A class-resolves check cannot see a class nobody declared. [bootReceiverIsRegistered] below
 * pins that one specifically, since it is the regression this batch fixed.
 *
 * ## Reading the real file
 *
 * Unit tests run with the module dir (`apps/android/app`) as the working directory, which is what
 * lets this read the same `src/main/AndroidManifest.xml` the build consumes rather than a copy
 * that could drift from the thing it polices — the same approach `HcTypeMapTest` already takes for
 * the permission set.
 */
class ManifestDeclarationTest {

    @Test fun everyDeclaredComponentClassResolves() {
        val components = declaredComponents()
        assertTrue("sanity: the manifest must declare some components", components.size >= 8)

        val unresolved = components.filterNot { (_, className) ->
            runCatching {
                // initialize = false: resolving the name is the whole question. Running a class
                // initializer under a JVM unit test would drag in Android framework state that has
                // nothing to do with whether the manifest points at a real class.
                Class.forName(className, false, javaClass.classLoader)
            }.isSuccess
        }.map { (tag, className) -> "<$tag> -> $className" }.sorted()

        assertTrue(
            "AndroidManifest.xml names classes that do not exist. The build will still compile and " +
                "the app will still install; the component simply throws ClassNotFoundException " +
                "the first time the system tries to start it: $unresolved",
            unresolved.isEmpty(),
        )
    }

    /**
     * The bug this batch fixed. `BootReceiver` re-establishes the periodic Health Connect sync
     * after a reboot (D-42), and a boot receiver is the one kind that cannot be registered at
     * runtime — the process is not alive to register it — so without this element the class is
     * inert and background sync silently stops until the user next opens the app.
     */
    @Test fun bootReceiverIsRegistered() {
        val body = manifestBody()
        assertTrue(
            "the <receiver> for BootReceiver is missing — the class is dead code without it, and " +
                "its failure mode is silence, not an error",
            body.contains("android:name=\".platform.background.BootReceiver\""),
        )
        assertTrue(
            "BootReceiver needs the BOOT_COMPLETED intent filter it is registered for",
            body.contains("android.intent.action.BOOT_COMPLETED"),
        )
        // exported="false" is correct despite the intent filter: BOOT_COMPLETED is a protected
        // broadcast only the system can send, and an exported receiver would let any app on the
        // device poke BADAN's sync schedule.
        val element = Regex("""(?s)<receiver[^>]*\.platform\.background\.BootReceiver.*?</receiver>""")
            .find(body)
        assertTrue("could not isolate the BootReceiver element", element != null)
        assertTrue(
            "BootReceiver must not be exported",
            element!!.value.contains("android:exported=\"false\""),
        )
    }

    /**
     * The widget set is declared once, here, so that five later widget tasks do not each reopen the
     * manifest. Each receiver needs three things to be a widget rather than an ordinary broadcast
     * receiver, and any one of them missing fails at a different, later, less obvious moment: no
     * APPWIDGET_UPDATE filter means the host never updates it, no `android.appwidget.provider`
     * meta-data means it does not appear in the picker at all, and a missing info file means the
     * resource reference fails at build time.
     */
    @Test fun everyWidgetReceiverHasAFilterAndAnInfoResource() {
        val body = manifestBody()
        val kinds = mapOf(
            ".platform.widgets.RingSingleWidgetReceiver" to "ring_single_widget_info",
            ".platform.widgets.OneTrueSentenceWidgetReceiver" to "one_true_sentence_widget_info",
            ".platform.widgets.MedsDueWidgetReceiver" to "meds_due_widget_info",
            ".platform.widgets.SleepLastNightWidgetReceiver" to "sleep_last_night_widget_info",
            ".platform.widgets.EffortRingWidgetReceiver" to "effort_ring_widget_info",
        )
        for ((className, infoRes) in kinds) {
            val element = Regex("""(?s)<receiver[^>]*${Regex.escape(className)}.*?</receiver>""")
                .find(body)?.value
            assertTrue("$className is not declared as a <receiver>", element != null)
            assertTrue(
                "$className has no APPWIDGET_UPDATE filter, so the host will never update it",
                element!!.contains("android.appwidget.action.APPWIDGET_UPDATE"),
            )
            assertTrue(
                "$className has no android.appwidget.provider meta-data, so it never appears in " +
                    "the widget picker",
                element.contains("android:name=\"android.appwidget.provider\""),
            )
            assertTrue(
                "$className must point at @xml/$infoRes",
                element.contains("@xml/$infoRes"),
            )
            // A widget receiver the system cannot reach receives nothing at all.
            assertTrue(
                "$className must be exported — the launcher and the AppWidget host broadcast to " +
                    "it from outside the app",
                element.contains("android:exported=\"true\""),
            )
            val info = File("src/main/res/xml/$infoRes.xml")
            assertTrue("missing ${info.path} referenced by $className", info.exists())
            // initialLayout is a required attribute; without it the host draws nothing between the
            // drop and the first update, which reads as a broken widget rather than a loading one.
            assertTrue(
                "${info.path} must declare android:initialLayout",
                info.readText().contains("android:initialLayout"),
            )
        }
    }

    /**
     * The live-workout service is the one component whose manifest attributes are load-bearing at
     * runtime: `foregroundServiceType="health"` is what `startForeground` is checked against from
     * API 34, and `specialUse` — the tempting escape hatch when a type does not fit — requires a
     * written justification reviewed by Google Play. A workout recorder fits `health` exactly, so
     * drifting to `specialUse` would buy a review cycle for nothing.
     */
    @Test fun liveWorkoutServiceIsAHealthForegroundService() {
        val element = Regex("""(?s)<service[^>]*\.platform\.workout\.LiveWorkoutService[^>]*>""")
            .find(manifestBody())?.value
        assertTrue("the live-workout <service> is not declared", element != null)
        assertTrue(
            "the live-workout service must declare foregroundServiceType=\"health\"",
            element!!.contains("android:foregroundServiceType=\"health\""),
        )
        assertTrue(
            "nothing outside the app may start or bind a recording session",
            element.contains("android:exported=\"false\""),
        )
    }

    /**
     * Every string the manifest and the widget-info files reference must exist in **both** locales.
     *
     * `LocalizedString(en, ar)` in `core/Strings.kt` cannot be constructed with one language — a
     * screen structurally cannot ship English-only. The XML side has no such compiler guarantee:
     * a `@string/` with no `values-ar/` entry builds fine and simply shows English on an Arabic
     * device. Arabic/RTL is a first-order concern in this product, so the guarantee is restored
     * here as a test rather than left to review.
     */
    @Test fun everyReferencedStringExistsInBothLocales() {
        val referencing = buildList {
            add(File("src/main/AndroidManifest.xml"))
            add(File("src/main/res/xml/shortcuts.xml"))
            File("src/main/res/xml").listFiles()?.filter { it.name.endsWith("_widget_info.xml") }
                ?.let { addAll(it) }
        }
        val referenced = referencing.flatMap { file ->
            assertTrue("expected ${file.path} to exist", file.exists())
            Regex("""@string/([a-z0-9_]+)""")
                .findAll(file.readText().replace(Regex("""(?s)<!--.*?-->"""), ""))
                .map { it.groupValues[1] }
                .toList()
        }.toSortedSet()
        assertTrue("sanity: the manifest and res/xml reference some strings", referenced.isNotEmpty())

        val en = declaredStrings("src/main/res/values/strings.xml")
        val ar = declaredStrings("src/main/res/values-ar/strings.xml")

        assertTrue("referenced but absent from values/strings.xml: ${referenced - en}", (referenced - en).isEmpty())
        assertTrue("referenced but absent from values-ar/strings.xml: ${referenced - ar}", (referenced - ar).isEmpty())
    }

    /**
     * The stronger form of the check above, and the one that catches the real failure: a string
     * added to `values/` with its Arabic counterpart "to follow". The two files must hold exactly
     * the same key set, always — a monolingual addition is a silent Arabic regression, and silence
     * is why it needs a test rather than a convention.
     */
    @Test fun theTwoLocalesDeclareExactlyTheSameKeys() {
        val en = declaredStrings("src/main/res/values/strings.xml")
        val ar = declaredStrings("src/main/res/values-ar/strings.xml")
        assertEquals("English strings with no Arabic counterpart", emptySet<String>(), en - ar)
        assertEquals("Arabic strings with no English counterpart", emptySet<String>(), ar - en)
    }

    // --- helpers ---

    /**
     * Comment bodies are stripped before anything is matched. The manifest explains at length why
     * certain permissions and components are absent, naming them as it does so; a name inside a
     * `<!-- -->` must never read as a declaration. `HcTypeMapTest` strips comments for exactly the
     * same reason.
     */
    private fun manifestBody(): String {
        val manifest = File("src/main/AndroidManifest.xml")
        assertTrue("manifest must be readable at ${manifest.absolutePath}", manifest.exists())
        return manifest.readText().replace(Regex("""(?s)<!--.*?-->"""), "")
    }

    private fun declaredStrings(path: String): Set<String> {
        val file = File(path)
        assertTrue("expected ${file.absolutePath} to exist", file.exists())
        val body = file.readText().replace(Regex("""(?s)<!--.*?-->"""), "")
        return Regex("""<string\s+name="([a-z0-9_]+)"""").findAll(body).map { it.groupValues[1] }.toSet()
    }

    /**
     * Pairs of (tag, fully-qualified class name) for every component element.
     *
     * Only the four element types that name a class are matched — `<uses-permission>`,
     * `<uses-feature>`, `<action>`, `<category>`, `<meta-data>` and `<package>` all carry an
     * `android:name` too, and none of them is a class.
     *
     * `<activity-alias>` is handled separately and on purpose: its own `android:name` is an alias
     * label, NOT a class (`ViewPermissionUsageActivity` is not a Kotlin file anywhere), and the
     * class it stands for is in `android:targetActivity`. Resolving the alias name would fail
     * against a manifest that is entirely correct.
     */
    private fun declaredComponents(): List<Pair<String, String>> {
        val body = manifestBody()
        val namespace = "net.albayyan.badan"

        fun qualify(name: String) = when {
            name.startsWith(".") -> namespace + name
            !name.contains('.') -> "$namespace.$name"
            else -> name
        }

        // The negative lookahead is not decoration: `\b` alone would let `<activity-alias ...>`
        // match as `<activity`, and the alias's own android:name is a label rather than a class —
        // so a perfectly correct manifest would fail this test.
        val plain = Regex("""<(activity|service|receiver|provider)(?![\w-])([^>]*)>""")
            .findAll(body)
            .mapNotNull { match ->
                val tag = match.groupValues[1]
                Regex("""android:name="([^"]+)"""").find(match.groupValues[2])
                    ?.let { tag to qualify(it.groupValues[1]) }
            }

        val aliases = Regex("""<activity-alias\b([^>]*)>""")
            .findAll(body)
            .mapNotNull { match ->
                Regex("""android:targetActivity="([^"]+)"""").find(match.groupValues[1])
                    ?.let { "activity-alias" to qualify(it.groupValues[1]) }
            }

        return (plain + aliases).toList()
    }
}
