package net.albayyan.badan.ontology

import android.content.res.AssetManager
import android.util.Log
import kotlinx.serialization.Serializable
import net.albayyan.badan.domain.ChartHint
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricKind
import net.albayyan.badan.domain.SensitiveClass

/**
 * The compiled metric ontology (registry.json -> MetricDefinition). Single source of every
 * metric's identity, units, names (en+ar), labels, chart hint, baseline eligibility, and
 * sensitivity. Mirror of the iOS `MetricRegistry`.
 *
 * The primary constructor takes an already-decoded list (mirrors iOS `init(metrics:)`, useful
 * for tests); the [AssetManager] secondary constructor loads `registry.json`.
 */
class MetricRegistry(metrics: List<MetricDefinition>) {

    val all: List<MetricDefinition> = metrics.sortedBy { it.metricId }
    private val byId: Map<String, MetricDefinition> = metrics.keyedFirst { it.metricId }

    @Serializable
    private data class RegistryFile(
        val version: String = "",
        val metrics: List<MetricDefinition> = emptyList(),
    )

    constructor(assets: AssetManager) : this(loadMetrics(assets))

    fun definition(metricId: String): MetricDefinition? = byId[metricId]

    /**
     * A definition for an id that might not be in the registry (defensive fallback so an unknown
     * metric still renders a name rather than crashing).
     */
    fun definitionOrFallback(metricId: String): MetricDefinition = byId[metricId] ?: MetricDefinition(
        metricId = metricId,
        family = metricId.split(".").firstOrNull { it.isNotEmpty() } ?: "other",
        kind = MetricKind.RAW_SAMPLE,
        canonicalUnit = "",
        displayUnits = emptyList(),
        nameEn = metricId,
        nameAr = metricId,
        casualLabel = metricId,
        preciseLabel = metricId,
        chartHint = ChartHint.LINE,
        baselineEligible = false,
        sensitiveClass = SensitiveClass.NORMAL,
    )

    fun metrics(family: MetricFamily): List<MetricDefinition> = all.filter { it.familyGroup == family }

    fun metrics(familyStr: String): List<MetricDefinition> = all.filter { it.family == familyStr }

    /** Families present in the registry, in a stable display order. */
    val families: List<MetricFamily>
        get() {
            val present = all.map { it.familyGroup }.toSet()
            return MetricFamily.entries.filter { present.contains(it) }
        }

    val baselineEligible: List<MetricDefinition> get() = all.filter { it.baselineEligible }

    /** Case/diacritic-insensitive search over English + Arabic names and the id. */
    fun search(query: String): List<MetricDefinition> {
        val q = query.foldedForSearch()
        if (q.isEmpty()) return all
        return all.filter {
            it.nameEn.foldedForSearch().contains(q) ||
                it.nameAr.foldedForSearch().contains(q) ||
                it.metricId.contains(q) ||
                it.preciseLabel.foldedForSearch().contains(q)
        }
    }

    companion object {
        private const val TAG = "MetricRegistry"

        /**
         * Expected `registry.json` schema version; mirrors the `packages/metric-ontology` source.
         *
         * Bumped to 0.2.0 with the registry itself. This constant is the kind that goes stale
         * silently — it did: the asset was synced to 0.2.0 while this still said 0.1.0, so every
         * launch logged a version-mismatch warning that was accurate about the mismatch and wrong
         * about the cause (the schema was fine; only this line was behind).
         * `MetricFamilyParityTest.expectedVersionMatchesTheBundledRegistry` now fails on that gap
         * instead of leaving it to a log nobody reads — update both together.
         */
        const val EXPECTED_VERSION = "0.2.2"

        private fun loadMetrics(assets: AssetManager): List<MetricDefinition> {
            val file = BundleJson.load<RegistryFile>(assets, "registry")
            if (file != null && file.version != EXPECTED_VERSION) {
                Log.w(
                    TAG,
                    "registry.json version mismatch: expected $EXPECTED_VERSION, found '${file.version}' " +
                        "— app and ontology schema may be out of sync",
                )
            }
            return file?.metrics ?: emptyList()
        }
    }
}
