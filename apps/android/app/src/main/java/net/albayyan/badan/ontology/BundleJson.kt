package net.albayyan.badan.ontology

import android.content.res.AssetManager
import android.util.Log
import net.albayyan.badan.storage.JsonCoding
import java.text.Normalizer

/**
 * Loads bundled JSON data resources (the compiled ontology/dictionaries/templates). Mirror of
 * the iOS `BundleJSON`, but on Android the data lives in `assets/` rather than the main bundle,
 * so every loader is handed an [AssetManager]. The data is authored in `packages/` and mirrored
 * into the app assets by the resource-sync tooling.
 */
object BundleJson {
    @PublishedApi
    internal const val TAG: String = "BundleJson"

    /**
     * Decode `assets/<name>.json` into [T] (the extension is appended, matching iOS which passes
     * bare resource names). Returns null on a missing or malformed file rather than crashing, but
     * logs the specific failure (missing asset vs. malformed JSON) so a packaging regression is
     * discoverable rather than silently masked as "empty by design" by callers.
     */
    inline fun <reified T> load(assets: AssetManager, name: String): T? =
        runCatching {
            val text = assets.open("$name.json").bufferedReader().use { it.readText() }
            JsonCoding.json.decodeFromString<T>(text)
        }.onFailure { e ->
            Log.e(TAG, "Failed to load bundled resource \"$name.json\": ${e::class.simpleName}: ${e.message}", e)
        }.getOrNull()
}

private val DIACRITICS_REGEX = Regex("\\p{Mn}+")

/**
 * Case- and diacritic-insensitive folding for search, mirroring iOS
 * `folding(options: [.caseInsensitive, .diacriticInsensitive])`. Strips combining marks via
 * Unicode NFD decomposition, then lowercases.
 */
internal fun String.foldedForSearch(): String =
    Normalizer.normalize(this, Normalizer.Form.NFD).replace(DIACRITICS_REGEX, "").lowercase()

/**
 * Build an id-keyed map keeping the FIRST occurrence on duplicate keys, mirroring the iOS
 * `Dictionary(_, uniquingKeysWith: { a, _ in a })` idiom used by the ontology loaders.
 */
internal fun <T> List<T>.keyedFirst(key: (T) -> String): Map<String, T> {
    val map = LinkedHashMap<String, T>()
    for (item in this) {
        val k = key(item)
        if (!map.containsKey(k)) map[k] = item
    }
    return map
}
