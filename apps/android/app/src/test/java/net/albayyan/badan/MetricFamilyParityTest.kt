package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.ontology.MetricRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The guard that would have caught the v0.2.0 family drift on arrival.
 *
 * `MetricFamily.fromRawOrOther` falls back to `OTHER` for an unrecognised family string, which is
 * the right *runtime* behaviour — the registry is allowed to describe families a given build has
 * not enumerated yet, and an unknown family must never crash a browse screen. But the fallback is
 * silent, and it hid a real regression: registry v0.2.0 introduced seven families at once
 * (workout, readiness, effort, hydration, stress, cycle, lab) and 22 of the 72 metrics — a third
 * of the catalogue — rendered under a single "Other" pillar with the generic grid glyph. Nothing
 * failed. The build was green, the app launched, and the only symptom was on screen.
 *
 * So the fallback stays, and this test asserts separately that nothing is *currently* using it.
 * The distinction matters: this is a contract-mirror check, not a behavioural one. When the
 * registry next adds a family, this test fails and names it, instead of the app quietly filing it
 * under "Other" until somebody happens to look at the Body screen.
 *
 * Reads the real bundled asset for the same reason `UnitsRegistryParityTest` does — a fixture
 * would be one more thing that can drift from the registry it is supposed to police.
 */
class MetricFamilyParityTest {

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private fun registryFamilies(): Set<String> {
        val file = File("src/main/assets/registry.json")
        assertTrue("registry.json must be readable at ${file.absolutePath}", file.exists())

        val metrics = Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
        return metrics.mapNotNull { it.jsonObject["family"]?.jsonPrimitive?.content }.toSet()
    }

    @Test fun everyRegistryFamilyHasAnEnumCase() {
        val unmapped = registryFamilies()
            .filter { MetricFamily.fromRawOrOther(it) == MetricFamily.OTHER && it != "other" }
            .sorted()

        assertEquals(
            "registry.json declares ${unmapped.size} family/families with no MetricFamily entry: " +
                "$unmapped — each one's metrics collapse into the 'Other' pillar with a generic " +
                "icon. Add the entry (name in en AND ar, plus an icon key mapped in Icons.kt) " +
                "rather than deleting this assertion.",
            emptyList<String>(), unmapped,
        )
    }

    /** The registry is the reason the enum exists; an empty read would make the test vacuous. */
    @Test fun theRegistryActuallyDeclaresFamilies() {
        assertTrue("sanity: registry.json declared no families at all", registryFamilies().size > 5)
    }

    /**
     * `MetricRegistry.EXPECTED_VERSION` must match the asset it is checking.
     *
     * It didn't: the asset was synced to 0.2.0 and the constant stayed at 0.1.0, so `loadMetrics`
     * logged a mismatch warning on every launch. The registry still loaded — the check is a
     * `Log.w`, not a gate — which is why nothing caught it. Housed here rather than in a registry
     * test of its own because it is the same class of defect as the family drift above: a Kotlin
     * constant mirroring a JSON contract, with nothing asserting the two agree.
     */
    @Test fun expectedVersionMatchesTheBundledRegistry() {
        val bundled = Json.parseToJsonElement(File("src/main/assets/registry.json").readText())
            .jsonObject["version"]!!.jsonPrimitive.content

        assertEquals(
            "MetricRegistry.EXPECTED_VERSION is behind the bundled registry.json — bump the " +
                "constant when you sync the asset, or every launch logs a spurious mismatch",
            bundled, MetricRegistry.EXPECTED_VERSION,
        )
    }

    /**
     * An icon key that `iconForKey` does not know falls through to the help glyph. That fallback is
     * deliberate and diagnosable (UIUX-261), but for a *family* it would still be a wrong icon on a
     * real screen, so every family resolves to something specific.
     */
    @Test fun everyFamilyIconKeyIsMapped() {
        val fallback = iconForKey("__deliberately_unmapped_key__")
        val unmapped = MetricFamily.entries
            .filter { iconForKey(it.symbolName) == fallback }
            .map { "${it.code} -> ${it.symbolName}" }
            .sorted()

        assertEquals(
            "families whose icon key is not mapped in Icons.kt: $unmapped", emptyList<String>(), unmapped,
        )
    }

    /**
     * Family labels are group headers on the Body screen, so an untranslated one is visible to an
     * Arabic reader on the first surface they open. Mirrors the completeness bar
     * `WorkoutSurfaceTests.testFamilyExplainersAreCompleteAndBilingual` holds iOS copy to.
     */
    @Test fun everyFamilyNameIsBilingual() {
        for (family in MetricFamily.entries) {
            val name = family.displayName
            assertTrue("${family.code} has no English name", name.en.isNotBlank())
            assertTrue("${family.code} has no Arabic name", name.ar.isNotBlank())
            assertNotEquals("${family.code} is untranslated", name.en, name.ar)
            assertTrue(
                "${family.code}'s Arabic name has no Arabic script",
                name.ar.any { it.code in 0x0600..0x06FF },
            )
        }
    }
}
