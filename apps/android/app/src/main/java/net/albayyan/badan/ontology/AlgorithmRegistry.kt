package net.albayyan.badan.ontology

import android.content.res.AssetManager
import android.util.Log
import kotlinx.serialization.Serializable
import net.albayyan.badan.domain.AlgorithmVersion

/**
 * The compiled algorithm contract (`algorithms.json` -> [AlgorithmDefinition]). Algorithm
 * identities, semvers, and tuning constants as data rather than code, so both platforms read the
 * same numbers from one file (plan §9, §15). Mirror of the iOS `AlgorithmRegistry`.
 *
 * **Why this type exists at all — audit finding #5.** The contract's own `note` claimed "both
 * platforms load this file ... the loading path is fixed in Phase 0". Neither platform had a
 * loader: nothing anywhere referenced `algorithms.json`, while `scripts/sync_android_assets.sh`
 * mirrored it into `assets/` and CI gated the mirror for drift. The file therefore *looked*
 * load-bearing at review — mirrored, gated, documented — and was inert. Deleting this class (or
 * leaving it unreferenced by any test) puts the claim back into that state. The Phase-2 score
 * engines are the real consumers; what Phase 0 owes them is a path proven to resolve an id and a
 * param, which `AlgorithmRegistryTest` asserts against the bundled asset rather than a fixture.
 *
 * The primary constructor takes an already-decoded file (mirrors iOS `init(file:)`, and is what
 * JVM unit tests use since they have no [AssetManager]); the [AssetManager] secondary constructor
 * loads `algorithms.json`.
 */
class AlgorithmRegistry(file: AlgorithmFile?) {

    /**
     * The contract file's own `version`, carried so a diagnostic can state which revision of the
     * constants produced a number. Not the semver of any one algorithm — that lives per entry, and
     * it is the per-entry semver that is written onto a `DerivedValue`.
     */
    val version: String = file?.version ?: MISSING_VERSION
    val all: List<AlgorithmDefinition> = (file?.algorithms ?: emptyList()).sortedBy { it.algorithmId }
    private val byId: Map<String, AlgorithmDefinition> = all.keyedFirst { it.algorithmId }

    constructor(assets: AssetManager) : this(load(assets))

    init {
        if (all.isEmpty()) {
            // Mirrors the iOS `Logger.fault` on the same condition, and `MetricRegistry`'s
            // version warning: a broken `scripts/sync_android_assets.sh` mirror would otherwise
            // ship an empty registry, every param() lookup would return null, and an engine
            // falling back to a hardcoded default is exactly the two-drifting-constant-tables
            // outcome this contract exists to prevent.
            Log.e(TAG, "AlgorithmRegistry loaded no algorithms — bundled algorithms.json may be missing or corrupted")
        }
    }

    fun definition(algorithmId: String): AlgorithmDefinition? = byId[algorithmId]

    /**
     * The frozen [AlgorithmVersion] a derived value should be stamped with. Deliberately nullable:
     * an engine asking for an id the contract does not carry is a bug in the engine, and inventing
     * an [AlgorithmVersion] with empty params here would let it compute a number from defaults and
     * stamp it with a version that never described those defaults (I2 makes that row permanent).
     */
    fun algorithmVersion(algorithmId: String): AlgorithmVersion? = byId[algorithmId]?.algorithmVersion

    /**
     * One tuning constant. Returns null rather than a fallback for the same reason as above — a
     * silent default is indistinguishable, on the stored row, from an authored constant.
     */
    fun param(algorithmId: String, name: String): Double? = byId[algorithmId]?.params?.get(name)

    /**
     * Algorithms that claim to produce [metricId]. `producesMetricIds: ["*"]` (the baseline
     * algorithm, which runs over every baseline-eligible metric) matches everything.
     */
    fun producers(metricId: String): List<AlgorithmDefinition> =
        all.filter { it.producesMetricIds.contains("*") || it.producesMetricIds.contains(metricId) }

    companion object {
        private const val TAG = "AlgorithmRegistry"

        /** Sentinel for "the file did not load", matching iOS's `version` fallback of "0". */
        const val MISSING_VERSION: String = "0"

        private fun load(assets: AssetManager): AlgorithmFile? =
            BundleJson.load<AlgorithmFile>(assets, "algorithms")
    }
}

/** The whole contract file. Public so JVM unit tests can decode the asset without an AssetManager. */
@Serializable
data class AlgorithmFile(
    val version: String = "",
    val algorithms: List<AlgorithmDefinition> = emptyList(),
)

/**
 * One entry in the algorithm contract.
 *
 * [params] is `Map<String, Double>` on purpose and the contract says so: `AlgorithmVersion.params`
 * is numeric-only on both platforms, so a non-numeric constant has nowhere to live and must be
 * expressed numerically (`includeWarmupSets: 0.0`) or moved to a sibling field. Decoding into
 * `Double` is what enforces that claim — a string smuggled into `params` fails the decode here
 * rather than diverging silently from Swift's `[String: Double]`.
 *
 * The descriptive fields default so an entry may omit them (`composite.sleep_efficiency` carries no
 * [paramNotes] because it has no params to annotate). The identity fields — [algorithmId],
 * [semver], [introducedIn], [params] — carry no defaults: an entry missing one of those cannot
 * stamp a `DerivedValue`, and accepting it with a placeholder would produce rows claiming a
 * provenance they do not have (I1).
 */
@Serializable
data class AlgorithmDefinition(
    val algorithmId: String,
    val semver: String,
    val introducedIn: String,
    val params: Map<String, Double>,
    /**
     * True while the constants are a stated default that has not been validated against data.
     * Carried through onto `DerivedValue.provisional` by the engines, so the surface can say so.
     *
     * Defaults to `true`, not `false`: an entry that forgot the flag must not be presented to a
     * user as a settled number.
     */
    val provisional: Boolean = true,
    val producesMetricIds: List<String> = emptyList(),
    val inputMetricIds: List<String> = emptyList(),
    val methodologyUrl: String = "",
    val summaryEn: String = "",
    /**
     * English-only prose about individual constants, for `docs/algorithms/` and review — never
     * rendered to a user, which is why it has no Arabic counterpart (the same rule
     * `SensorQualityMap` applies to the contract's `familyNotes`).
     */
    val paramNotes: Map<String, String> = emptyMap(),
) {
    val algorithmVersion: AlgorithmVersion
        get() = AlgorithmVersion(
            algorithmId = algorithmId,
            semver = semver,
            params = params,
            introducedIn = introducedIn,
        )
}
