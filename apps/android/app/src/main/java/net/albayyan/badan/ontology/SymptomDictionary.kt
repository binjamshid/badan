package net.albayyan.badan.ontology

import android.content.res.AssetManager
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString

/**
 * A canonical, localized symptom entry (symptoms.json). Mirror of the iOS `SymptomDefinition`.
 */
@Serializable
data class SymptomDefinition(
    val id: String,
    val nameEn: String,
    val nameAr: String,
    val category: String,
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)
}

/**
 * The canonical, localized symptom vocabulary (symptoms.json). Chip-first logging draws from
 * this; free-text custom labels are still allowed for anything not listed. Mirror of the iOS
 * `SymptomDictionary`.
 */
class SymptomDictionary(symptoms: List<SymptomDefinition>) {

    val all: List<SymptomDefinition> = symptoms
    private val byId: Map<String, SymptomDefinition> = symptoms.keyedFirst { it.id }

    @Serializable
    private data class SymptomsFile(val symptoms: List<SymptomDefinition> = emptyList())

    constructor(assets: AssetManager) :
        this(BundleJson.load<SymptomsFile>(assets, "symptoms")?.symptoms ?: emptyList())

    fun definition(id: String): SymptomDefinition? = byId[id]

    fun displayName(forId: String?, customLabel: String?): LocalizedString {
        if (forId != null) {
            val def = byId[forId]
            if (def != null) return def.displayName
        }
        if (customLabel != null) return LocalizedString(en = customLabel, ar = customLabel)
        return LocalizedString(en = "Symptom", ar = "عرض")
    }

    val categories: List<String>
        get() {
            val ordered = LinkedHashSet<String>()
            for (s in all) ordered.add(s.category)
            return ordered.toList()
        }

    fun inCategory(category: String): List<SymptomDefinition> = all.filter { it.category == category }

    fun search(query: String): List<SymptomDefinition> {
        val q = query.foldedForSearch()
        if (q.isEmpty()) return all
        return all.filter {
            it.nameEn.foldedForSearch().contains(q) || it.nameAr.contains(query)
        }
    }
}
