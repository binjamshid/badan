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
class InsightTemplateStore internal constructor(
    val templates: List<InsightTemplate>,
    val wellnessRules: List<String> = emptyList(),
) {
    private val byId: Map<String, InsightTemplate> = templates.keyedFirst { it.templateId }

    /**
     * The shipped path: templates from the bundled asset.
     *
     * The primary constructor above takes the parsed lists instead, mirroring the iOS
     * `init(templates:wellnessRules:)` injection point. That exists so a pure-JVM unit test can
     * render against the canonical `packages/contracts/insights/templates.json` without an
     * [AssetManager] — the correlation goldens need the real authored copy, and a hand-written
     * fixture of the templates would be one more thing that can drift from the contract it is
     * supposed to police.
     */
    constructor(assets: AssetManager) : this(BundleJson.load<InsightFile>(assets, "insight_templates") ?: InsightFile())

    internal constructor(file: InsightFile) : this(file.templates, file.wellnessRules ?: emptyList())

    fun template(id: String): InsightTemplate? = byId[id]

    @Serializable
    internal data class InsightFile(
        val templates: List<InsightTemplate> = emptyList(),
        val wellnessRules: List<String>? = null,
    )
}
