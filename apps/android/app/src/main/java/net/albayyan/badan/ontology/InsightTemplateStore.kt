package net.albayyan.badan.ontology

import android.content.res.AssetManager
import kotlinx.serialization.Serializable
import net.albayyan.badan.domain.InsightTemplate

/**
 * Loads the wellness-safe insight templates (insight_templates.json). The insight engine selects
 * a template by condition and fills `{metric}`/`{value}`/`{baseline}` in both languages.
 * Wellness-language rules are carried for reference and lint tooling. Mirror of the iOS
 * `InsightTemplateStore`.
 */
class InsightTemplateStore(assets: AssetManager) {

    val templates: List<InsightTemplate>
    val wellnessRules: List<String>
    private val byId: Map<String, InsightTemplate>

    @Serializable
    private data class InsightFile(
        val templates: List<InsightTemplate> = emptyList(),
        val wellnessRules: List<String>? = null,
    )

    init {
        val file = BundleJson.load<InsightFile>(assets, "insight_templates")
        templates = file?.templates ?: emptyList()
        wellnessRules = file?.wellnessRules ?: emptyList()
        byId = templates.keyedFirst { it.templateId }
    }

    fun template(id: String): InsightTemplate? = byId[id]
}
