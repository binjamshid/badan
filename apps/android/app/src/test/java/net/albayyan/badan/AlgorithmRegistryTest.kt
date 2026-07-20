package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.ontology.AlgorithmFile
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The algorithm contract loader (`packages/contracts/algorithms/algorithms.json`, plan §9/§15).
 * Mirror of the iOS `AlgorithmRegistryTests`.
 *
 * This suite is the Android half of the answer to audit finding #5. The contract claimed "both
 * platforms load this file ... the loading path is fixed in Phase 0" while no loader existed on
 * either platform; the file was mirrored into `assets/` and CI-gated for drift, so it read as
 * load-bearing and was inert. Asserting the path here is what makes the claim true — if
 * `AlgorithmRegistry` is deleted or stops resolving ids, this fails instead of the claim rotting
 * unnoticed until a Phase-2 engine needs it.
 *
 * Reads the real bundled asset rather than a fixture, for the same reason `UnitsRegistryParityTest`
 * and `MetricFamilyParityTest` do: a fixture is one more thing that can drift from the contract it
 * is supposed to police, and a broken `scripts/sync_android_assets.sh` mirror is otherwise silent.
 */
class AlgorithmRegistryTest {

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val assetFile = File("src/main/assets/algorithms.json")

    /**
     * Decodes through the same `JsonCoding.json` the app uses, so this exercises the real decode
     * path (`ignoreUnknownKeys`, the constructor defaults) rather than a test-local parser. Only
     * the `AssetManager` open() call is substituted — there is no AssetManager on the JVM.
     */
    private fun registry(): AlgorithmRegistry {
        assertTrue("algorithms.json must be readable at ${assetFile.absolutePath}", assetFile.exists())
        return AlgorithmRegistry(JsonCoding.json.decodeFromString<AlgorithmFile>(assetFile.readText()))
    }

    // MARK: - Loading

    /** Catches a broken/missing `sync_android_assets.sh` mirror. */
    @Test fun contractLoads() {
        val registry = registry()
        assertFalse("algorithms.json failed to load or is empty", registry.all.isEmpty())
        assertNotEquals(
            "contract version fell back to the missing-file placeholder",
            AlgorithmRegistry.MISSING_VERSION, registry.version,
        )
    }

    /**
     * The specific thing finding #5 says Phase 0 owes Phase 2: a known id and a known param resolve
     * through the bundled file.
     */
    @Test fun knownAlgorithmAndParamResolve() {
        val registry = registry()
        val baseline = registry.definition("baseline.rolling_median_mad")!!
        assertEquals("1.0.0", baseline.semver)
        assertFalse(baseline.provisional)
        assertEquals(28.0, baseline.params["windowDays"]!!, 1e-9)
        assertEquals(7.0, baseline.params["minPoints"]!!, 1e-9)
        // The MAD->sigma consistency constant. Not tunable — the contract's own paramNote says
        // changing it changes what the band means, so it is worth pinning here too.
        assertEquals(1.4826, registry.param("baseline.rolling_median_mad", "madToSigma")!!, 1e-9)
    }

    /**
     * The registry hands an engine a frozen `AlgorithmVersion` to stamp onto a `DerivedValue`,
     * which is the whole reason the constants are data rather than code: the row records the exact
     * numbers that produced it, and I2 keeps that row forever.
     */
    @Test fun algorithmVersionCarriesTheContractsParams() {
        val version = registry().algorithmVersion("effort.day")!!
        assertEquals("effort.day@0.1.0", version.id)
        assertEquals("0.2.0", version.introducedIn)
        assertEquals(0.045, version.params["logCurveK"]!!, 1e-9)
        assertEquals(6.8, version.params["zone5Weight"]!!, 1e-9)
    }

    @Test fun unknownAlgorithmResolvesToNullRatherThanAnEmptyVersion() {
        val registry = registry()
        assertNull(registry.definition("not.a.real.algorithm"))
        assertNull(registry.algorithmVersion("not.a.real.algorithm"))
        assertNull(registry.param("not.a.real.algorithm", "windowDays"))
        // A present algorithm with an absent param must also be null, never 0.0 — 0 is a
        // legitimate value in this file (`includeWarmupSets`), so "missing" and "zero" cannot
        // share a return.
        assertNull(registry.param("baseline.rolling_median_mad", "notAParam"))
        assertEquals(0.0, registry.param("workout.strength.volume", "includeWarmupSets")!!, 1e-9)
    }

    @Test fun algorithmIdsAreUnique() {
        val ids = registry().all.map { it.algorithmId }
        assertEquals("duplicate algorithmId in algorithms.json", ids.toSet().size, ids.size)
    }

    // MARK: - Cross-platform and cross-contract integrity

    /**
     * The constants Android reads are byte-identical to the ones iOS reads.
     *
     * CI already compares both mirrors against `packages/contracts/`, but that check lives in a
     * workflow file; this one fails in the unit-test run a developer actually watches, and it is
     * the claim the contract's note makes ("never two hand-copied constant tables that silently
     * drift"). Compared as parsed JSON so formatting is not mistaken for drift.
     */
    @Test fun androidAssetMatchesTheCanonicalContract() {
        val canonical = File("../../../packages/contracts/algorithms/algorithms.json")
        assertTrue(
            "canonical algorithms.json must be readable at ${canonical.absolutePath}",
            canonical.exists(),
        )
        assertEquals(
            "assets/algorithms.json has drifted from packages/contracts/algorithms/algorithms.json " +
                "— run scripts/sync_android_assets.sh",
            Json.parseToJsonElement(canonical.readText()),
            Json.parseToJsonElement(assetFile.readText()),
        )
    }

    /**
     * Every metric id the algorithm contract names must exist in the metric ontology.
     *
     * These are two separately-authored files that CI only checks for *mirror* drift, not for
     * agreement with each other. A typo'd or renamed metric id here produces an engine that
     * computes a value and files it under an id no surface can render — a number that exists in
     * the database and nowhere on screen. `"*"` is the baseline algorithm's wildcard (it runs over
     * every baseline-eligible metric) and is the one legitimate non-id.
     */
    @Test fun everyMetricIdNamedByAnAlgorithmExistsInTheRegistry() {
        val registryFile = File("src/main/assets/registry.json")
        assertTrue("registry.json must be readable", registryFile.exists())
        val known = Json.parseToJsonElement(registryFile.readText())
            .jsonObject["metrics"]!!.jsonArray
            .map { it.jsonObject["metricId"]!!.jsonPrimitive.content }
            .toSet()

        val unknown = registry().all.flatMap { algorithm ->
            (algorithm.producesMetricIds + algorithm.inputMetricIds)
                .filter { it != "*" && it !in known }
                .map { "${algorithm.algorithmId} -> $it" }
        }.sorted()

        assertEquals(
            "algorithms.json names metric ids that registry.json does not define: $unknown. Add " +
                "the metric to the ontology or fix the id — an engine writing to an undefined id " +
                "produces values no surface can show.",
            emptyList<String>(), unknown,
        )
    }

    @Test fun producersLookupFindsTheBaselineWildcardAndTheSpecificEntry() {
        val producers = registry().producers("sleep.performance").map { it.algorithmId }
        assertTrue(producers.contains("sleep.performance"))
        assertTrue(
            "the wildcard baseline entry must match every metric",
            producers.contains("baseline.rolling_median_mad"),
        )
    }

    // MARK: - Contract shape

    /**
     * The scope gate the cycle entry's own `paramNotes` describes: no fertile-window, ovulation, or
     * next-period prediction algorithm may appear in this file without its own review (plan
     * A17/A18, and a retained clinical advisor per A25). The note says adding one quietly "would be
     * the whole gate failing quietly" — this is the check that makes it loud.
     *
     * Matches on ids only, never on prose: `cycle.descriptive`'s summary contains the word
     * "prediction" precisely because it promises not to emit one, and a lint that fired on that
     * sentence would push authors to stop writing the disclaimer rather than stop writing the
     * algorithm.
     */
    @Test fun noPredictiveCycleAlgorithmHasBeenAdded() {
        val banned = listOf("fertile", "ovulation", "predict", "forecast")
        for (algorithm in registry().all) {
            val ids = (listOf(algorithm.algorithmId) + algorithm.producesMetricIds).map { it.lowercase() }
            for (word in banned) {
                assertFalse(
                    "${algorithm.algorithmId} declares a predictive id ('$word'). Cycle prediction " +
                        "is gated behind plan A17/A18 + A25 and must arrive as its own reviewed " +
                        "entry, never as a params tweak to an existing one.",
                    ids.any { it.contains(word) },
                )
            }
        }
    }

    /**
     * Every entry can stamp a row: an algorithm with no semver or no `introducedIn` would write a
     * `DerivedValue` whose provenance cannot be traced back to a method (I1).
     */
    @Test fun everyEntryCanStampADerivedValue() {
        for (algorithm in registry().all) {
            assertFalse(algorithm.algorithmId.isEmpty())
            assertFalse("${algorithm.algorithmId} has no semver", algorithm.semver.isEmpty())
            assertFalse("${algorithm.algorithmId} has no introducedIn", algorithm.introducedIn.isEmpty())
            assertFalse(algorithm.algorithmVersion.id.startsWith("@"))
        }
    }

    /**
     * A missing `provisional` flag reads as provisional, never as validated — an entry that forgot
     * the flag must not be presented to a user as a settled number. Same default as iOS.
     */
    @Test fun missingProvisionalFlagDefaultsToProvisional() {
        val json = """
        {
          "version": "test",
          "algorithms": [
            {"algorithmId": "test.entry", "semver": "0.1.0", "introducedIn": "0.1.0",
             "params": {"k": 1.5}}
          ]
        }
        """.trimIndent()

        val parsed = AlgorithmRegistry(JsonCoding.json.decodeFromString<AlgorithmFile>(json))
        val entry = parsed.definition("test.entry")!!
        assertTrue(entry.provisional)
        assertEquals(1.5, entry.params["k"]!!, 1e-9)
        assertTrue(entry.paramNotes.isEmpty())
    }

    /** A missing/unreadable file yields an empty registry and the sentinel version, not a crash. */
    @Test fun absentContractYieldsAnEmptyRegistry() {
        val empty = AlgorithmRegistry(file = null)
        assertTrue(empty.all.isEmpty())
        assertEquals(AlgorithmRegistry.MISSING_VERSION, empty.version)
        assertNull(empty.algorithmVersion("baseline.rolling_median_mad"))
    }
}
