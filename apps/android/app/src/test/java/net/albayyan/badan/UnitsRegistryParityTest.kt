package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.Units
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The guard `Units.kt`'s KDoc always claimed to have and never did.
 *
 * `Units` is deliberately duplicated across iOS and Android (D-4), and the doc asserted it was
 * "fixture-guarded so it cannot drift from iOS". Nothing enforced that, and it had drifted: 20 of
 * the registry's 40 units were absent from the Kotlin table. The failure was silent by
 * construction — `ValueFormatter` catches `UnknownUnit` and renders the raw canonical value under
 * the display unit's label, so a 1.5 m/s walking speed was shown as "1.5 km/h" with no error
 * logged and no test failing.
 *
 * Reads the real contract file rather than a copied fixture: a fixture would be one more thing
 * that can drift from the registry it is supposed to police.
 */
class UnitsRegistryParityTest {

    private fun registryUnits(): Set<String> {
        // Unit tests run with the module dir (`apps/android/app`) as the working directory; this
        // is the same file the app bundles as an asset, kept in sync with
        // packages/metric-ontology/registry.json by CI's contract-mirror check.
        val file = File("src/main/assets/registry.json")
        assertTrue("registry.json must be readable at ${file.absolutePath}", file.exists())

        val metrics = Json.parseToJsonElement(file.readText()).jsonObject["metrics"]!!.jsonArray
        val units = mutableSetOf<String>()
        for (metric in metrics) {
            val obj = metric.jsonObject
            obj["canonicalUnit"]?.jsonPrimitive?.content?.let { units.add(it) }
            for (key in listOf("displayUnits", "allowedUnits")) {
                obj[key]?.jsonArray?.forEach { units.add(it.jsonPrimitive.content) }
            }
        }
        return units
    }

    @Test fun everyRegistryUnitResolves() {
        val missing = registryUnits().filter { unit ->
            runCatching { Units.convert(1.0, unit, unit) }.isFailure
        }.sorted()

        assertEquals(
            "Units.kt is missing ${missing.size} unit(s) present in registry.json: $missing — " +
                "each one silently renders the raw canonical value under the wrong label",
            emptyList<String>(), missing,
        )
    }

    /** The registry is the reason this table exists; an empty read would make the test vacuous. */
    @Test fun theRegistryActuallyDeclaresUnits() {
        assertTrue("sanity: registry.json declared no units at all", registryUnits().size > 20)
    }

    /**
     * Each metric's own canonical -> display conversion must work, which is the conversion the app
     * actually performs. Resolving both units is not enough: they must also share a base, or the
     * conversion throws `Incompatible` and hits the same silent fallback.
     */
    @Test fun everyMetricCanConvertItsCanonicalToItsDisplayUnits() {
        val metrics = Json.parseToJsonElement(File("src/main/assets/registry.json").readText())
            .jsonObject["metrics"]!!.jsonArray

        val broken = mutableListOf<String>()
        for (metric in metrics) {
            val obj = metric.jsonObject
            val id = obj["metricId"]?.jsonPrimitive?.content ?: continue
            val canonical = obj["canonicalUnit"]?.jsonPrimitive?.content ?: continue
            val displays = obj["displayUnits"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()
            for (display in displays) {
                if (runCatching { Units.convert(1.0, canonical, display) }.isFailure) {
                    broken.add("$id: $canonical -> $display")
                }
            }
        }
        assertEquals("metrics whose display conversion fails: $broken", emptyList<String>(), broken)
    }

    /** Spot-check the drift that was actually shipping: speed was the worst of it. */
    @Test fun walkingSpeedCanonicalConvertsToDisplayUnitsCorrectly() {
        assertEquals(3.6, Units.convert(1.0, "m/s", "km/h"), 0.0001)
        assertEquals(1.0, Units.convert(Units.convert(1.5, "m/s", "mph"), "mph", "m/s") / 1.5, 0.0001)
    }

    /** (DATA-02) Registry canonicals spell this "percent"; adapters emit "%". */
    @Test fun percentAndPercentSignShareABase() {
        assertEquals(0.97, Units.toCanonical(97.0, "percent", "fraction"), 0.0001)
        assertEquals(97.0, Units.convert(97.0, "percent", "%"), 0.0001)
    }
}
