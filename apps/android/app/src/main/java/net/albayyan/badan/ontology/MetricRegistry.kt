package net.albayyan.badan.ontology

import android.content.res.AssetManager
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

    constructor(assets: AssetManager) :
        this(BundleJson.load<RegistryFile>(assets, "registry")?.metrics ?: emptyList())

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
                it.nameAr.contains(query) ||
                it.metricId.contains(q) ||
                it.preciseLabel.foldedForSearch().contains(q)
        }
    }
}
