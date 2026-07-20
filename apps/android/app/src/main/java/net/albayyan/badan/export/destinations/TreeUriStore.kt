package net.albayyan.badan.export.destinations

import android.content.Context
import android.content.SharedPreferences

/**
 * Where a folder destination's SAF tree URI string actually lives.
 *
 * `ExportDestinationConfig.folderBookmarkRef` is a *key*, never the URI — its doc comment says so
 * ("a persisted URI permission is standing filesystem access and belongs with the other protected
 * material"). This interface is the other half of that sentence, and it is an interface so the
 * destination logic can be tested against an in-memory store: the JVM unit tests have no `Context`,
 * and a `FileFolderDestination` that reached for `SharedPreferences` directly would be untestable
 * end to end (the same androidTest/Robolectric gap `ExportTemplateSystemTest` documents).
 *
 * Note the split from the *grant*: taking the persistable permission on the ContentResolver (see
 * [TreeDocumentGateway.hasPersistedWriteGrant]) is what makes the URI usable across reboots — the
 * system persists that. This store only remembers *which* tree URI belongs to *which* destination,
 * so a resolve can look up the URI and then ask the resolver whether the grant still stands.
 */
interface TreeUriStore {
    fun treeUri(ref: String): String?
    fun store(ref: String, treeUri: String)
    fun remove(ref: String)
}

/**
 * `SharedPreferences`-backed store, one private file.
 *
 * Not encrypted: a SAF tree URI is not a secret. It names a folder the user themselves chose in the
 * system picker; the *access* it grants is held by the framework's persisted-permission table keyed
 * on the URI, not by possession of the string — copying this string to another app grants that app
 * nothing. That is the load-bearing difference from iOS's security-scoped bookmark, which *is*
 * capability-bearing bytes and therefore lives in the Keychain there.
 */
class SharedPrefsTreeUriStore(context: Context) : TreeUriStore {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun treeUri(ref: String): String? = prefs.getString(ref, null)

    override fun store(ref: String, treeUri: String) {
        prefs.edit().putString(ref, treeUri).apply()
    }

    override fun remove(ref: String) {
        prefs.edit().remove(ref).apply()
    }

    companion object {
        const val PREFS = "badan.export.folder_destinations"
    }
}

/** Test double, and the reason [TreeUriStore] is an interface. */
class InMemoryTreeUriStore(initial: Map<String, String> = emptyMap()) : TreeUriStore {
    private val items = initial.toMutableMap()

    override fun treeUri(ref: String): String? = items[ref]
    override fun store(ref: String, treeUri: String) { items[ref] = treeUri }
    override fun remove(ref: String) { items.remove(ref) }
}
