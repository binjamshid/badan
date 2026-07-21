package net.albayyan.badan

import net.albayyan.badan.ontology.AlgorithmFile
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * `algorithms.json` lives in TWO places in the Android module: `src/main/assets` (loaded via an
 * AssetManager, the historical path + what `AlgorithmRegistryTest` covers) and `src/main/resources`
 * (the JVM-classpath copy `BaselineEngine`'s default spec loads with no Context — see
 * `AlgorithmRegistry.fromClasspath`). Both are mirrored from the same canonical
 * `packages/contracts/algorithms/algorithms.json` by `scripts/sync_android_assets.sh` in one run,
 * so they cannot drift from canonical independently — but a hand-edit of one, or a half-run of the
 * sync, could. This asserts the two copies decode to the same contract, so the app and the goldens
 * can never read different constants.
 */
class AlgorithmResourceMirrorTest {

    /** Unit tests run with the module dir (`apps/android/app`) as the working directory. */
    private val assetFile = File("src/main/assets/algorithms.json")

    @Test fun classpathResourceMatchesAssetsCopy() {
        assertTrue("assets/algorithms.json must exist at ${assetFile.absolutePath}", assetFile.exists())
        val fromAssets = JsonCoding.json.decodeFromString<AlgorithmFile>(assetFile.readText())
        val classpathText = javaClass.getResourceAsStream("/algorithms.json")
            ?.bufferedReader()?.use { it.readText() }
        assertTrue("resources/algorithms.json must be on the classpath", classpathText != null)
        val fromClasspath = JsonCoding.json.decodeFromString<AlgorithmFile>(classpathText!!)

        assertEquals("contract version drifted between the assets and resources mirrors",
            fromAssets.version, fromClasspath.version)
        assertEquals("the algorithm id set drifted between mirrors",
            fromAssets.algorithms.map { it.algorithmId }.sorted(),
            fromClasspath.algorithms.map { it.algorithmId }.sorted())

        // Spot-check the baseline entry both mirrors feed BaselineEngine — params and the window table.
        val a = AlgorithmRegistry(fromAssets).definition("baseline.rolling_median_mad")!!
        val c = AlgorithmRegistry(fromClasspath).definition("baseline.rolling_median_mad")!!
        assertEquals(a.semver, c.semver)
        assertEquals(a.params, c.params)
        assertEquals(a.windowTable, c.windowTable)
    }
}
