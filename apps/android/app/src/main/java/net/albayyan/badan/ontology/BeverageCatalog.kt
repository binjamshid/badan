package net.albayyan.badan.ontology

import android.content.res.AssetManager
import kotlinx.serialization.Serializable
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.hydration.HydrationFluidType

/**
 * A built-in beverage the user can pick from in the hydration custom-log sheet (`beverages.json`).
 * Same dictionary-vs-custom split as [SymptomDictionary]: the curated set ships as an asset,
 * user-added beverages live in the `beverage_definitions` table (`domain.hydration.BeverageDefinition`).
 *
 * `caffeineMgPer100ml` / `alcoholPct` / `electrolyte` are DISPLAY METADATA ONLY — carried so a later
 * phase can surface them, never read into a hydration total or a "net hydration" multiplier (a §7A.1
 * Reject item). This phase does not even show them; the fields exist so the loader round-trips the
 * whole asset rather than silently dropping columns the schema and iOS both keep.
 */
@Serializable
data class BuiltinBeverage(
    val id: String,
    val nameEn: String,
    val nameAr: String,
    val fluidType: String,
    val defaultVolumeMl: Double? = null,
    val caffeineMgPer100ml: Double? = null,   // display metadata only — never a hydration weight
    val alcoholPct: Double? = null,           // display metadata only — never a hydration weight
    val electrolyte: Boolean = false,         // display metadata only — never a hydration weight
) {
    val displayName: LocalizedString get() = LocalizedString(en = nameEn, ar = nameAr)

    /** The known display category, folding an unrecognized `fluidType` to water (never rejected). */
    val category: HydrationFluidType get() = HydrationFluidType.known(fluidType)
}

/**
 * The curated bilingual beverage vocabulary (`beverages.json`). The custom-log sheet's drink picker
 * draws from this; free-text / user beverages are still allowed for anything not listed. Byte-for-byte
 * the same asset iOS reads, so a beverage id logged on one platform resolves to the same name on the
 * other. Constructed once and shared off `AppEnvironment`, exactly like [SymptomDictionary].
 */
class BeverageCatalog(beverages: List<BuiltinBeverage>) {

    val all: List<BuiltinBeverage> = beverages
    private val byId: Map<String, BuiltinBeverage> = beverages.keyedFirst { it.id }

    @Serializable
    private data class BeveragesFile(val beverages: List<BuiltinBeverage> = emptyList())

    constructor(assets: AssetManager) :
        this(BundleJson.load<BeveragesFile>(assets, "beverages")?.beverages ?: emptyList())

    fun beverage(id: String?): BuiltinBeverage? = id?.let { byId[it] }

    /** Plain water, the safe default drink for the quick-log path; falls back to a synthesized row. */
    val water: BuiltinBeverage
        get() = byId["water"] ?: BuiltinBeverage(
            id = "water", nameEn = "Water", nameAr = "ماء", fluidType = "water", defaultVolumeMl = 250.0,
        )

    /**
     * The display name for a logged entry's `beverageId`. A null id — the quick-log water path — is
     * plain water; an unknown id (a beverage the user later deleted) falls back to the fluid-type
     * label rather than an empty string, so an old entry never renders nameless.
     */
    fun displayName(beverageId: String?, fluidType: String): LocalizedString {
        beverage(beverageId)?.let { return it.displayName }
        return HydrationFluidType.known(fluidType).displayLabel
    }

    /** Case- and diacritic-insensitive search over both languages, for the drink picker's filter. */
    fun search(query: String): List<BuiltinBeverage> {
        val q = query.trim()
        if (q.isEmpty()) return all
        val folded = q.foldedForSearch()
        return all.filter { it.nameEn.foldedForSearch().contains(folded) || it.nameAr.contains(q) }
    }
}
