package net.albayyan.badan.ontology

import android.content.res.AssetManager
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.SensitiveClass
import net.albayyan.badan.domain.journal.BehaviorValueKind

/**
 * One curated behavior a user can tap on the journal screen (`behaviors.json`). Mirror of the iOS
 * `BehaviorDefinition`. Same dictionary-vs-custom split as [SymptomDictionary]: the curated set
 * ships as an asset, anything else is a free-text `customLabel` on the journal entry itself.
 *
 * `sensitiveClass` is carried per behavior rather than assumed for the whole family, so the data
 * file states the I7 classification for each row instead of it living only in code — and so a
 * future entry cannot be quietly added at a lower class. Every entry today is `sensitivePlus`;
 * [BehaviorDictionary.allAreSensitivePlus] is what a test asserts against.
 */
@Serializable
data class BehaviorDefinition(
    val id: String,
    val nameEn: String,
    val nameAr: String,
    val valueKind: BehaviorValueKind,
    /** Canonical unit — present only for a `quantity` behavior. */
    val unit: String? = null,
    val category: String,
    val sensitiveClass: SensitiveClass,
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)
}

/**
 * The canonical, localized behavior vocabulary (`behaviors.json`) — the tags the daily journal
 * offers. Byte-for-byte the same asset iOS reads, so a behavior id logged on one platform resolves
 * to the same name (and the same value kind) on the other, which is what lets a correlation
 * computed on one device be read on the other. Constructed once and shared off `AppEnvironment`,
 * exactly like [SymptomDictionary] and [BeverageCatalog].
 */
class BehaviorDictionary(behaviors: List<BehaviorDefinition>) {

    val all: List<BehaviorDefinition> = behaviors
    private val byId: Map<String, BehaviorDefinition> = behaviors.keyedFirst { it.id }

    @Serializable
    private data class BehaviorsFile(val behaviors: List<BehaviorDefinition> = emptyList())

    constructor(assets: AssetManager) :
        this(BundleJson.load<BehaviorsFile>(assets, "behaviors")?.behaviors ?: emptyList())

    fun definition(id: String?): BehaviorDefinition? = id?.let { byId[it] }

    /**
     * Display name for a logged entry. An unknown id (a dictionary row removed in a later version,
     * read back from an old journal row) falls back to the id itself rather than an empty string,
     * so a historical entry never renders nameless.
     */
    fun displayName(id: String?, customLabel: String?): LocalizedString {
        definition(id)?.let { return it.displayName }
        if (!customLabel.isNullOrEmpty()) return LocalizedString(en = customLabel, ar = customLabel)
        if (!id.isNullOrEmpty()) return LocalizedString(en = id, ar = id)
        return LocalizedString(en = "Behavior", ar = "سلوك")
    }

    /**
     * The value shape a chip should collect for [id], defaulting to boolean for an id the dictionary
     * doesn't know — the safest shape, since it asks for no number the app would then have to
     * invent a unit for.
     */
    fun valueKind(id: String?): BehaviorValueKind = definition(id)?.valueKind ?: BehaviorValueKind.BOOLEAN

    /**
     * Every behavior is sensitive-plus (I7). Exposed rather than assumed so the invariant is
     * checkable from the loaded data, not just asserted in a comment.
     */
    val allAreSensitivePlus: Boolean get() = all.all { it.sensitiveClass == SensitiveClass.SENSITIVE_PLUS }

    /** Categories in file order — the chip-group order the journal screen renders. */
    val categories: List<String> get() = all.map { it.category }.distinct()

    fun inCategory(category: String): List<BehaviorDefinition> = all.filter { it.category == category }

    /** Case- and diacritic-insensitive search over both languages, for the chip picker's filter. */
    fun search(query: String): List<BehaviorDefinition> {
        val q = query.trim()
        if (q.isEmpty()) return all
        val folded = q.foldedForSearch()
        return all.filter { it.nameEn.foldedForSearch().contains(folded) || it.nameAr.contains(q) }
    }
}
