package net.albayyan.badan.export.destinations

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException

/**
 * The narrow set of Storage Access Framework operations a folder destination needs, behind an
 * interface so the delivery logic in [FileFolderDestination] is testable.
 *
 * The JVM unit test source set has no `Context` and no ContentResolver (see the scope note on
 * `ExportTemplateSystemTest`), so the real implementation here is exercised only on device, while
 * `FileFolderDestination`'s orchestration and its failure classification run against
 * [FakeTreeDocumentGateway]. The division is deliberate: everything with a decision in it
 * (find-or-create, read-back, which exception means what) lives above this seam; everything below is
 * a thin, untestable-in-JVM call into the framework.
 *
 * Methods throw the *natural* exceptions the framework raises — [SecurityException] when a grant was
 * revoked, [FileNotFoundException] when a document is gone, [IOException] otherwise — rather than a
 * bespoke error type, so [FileFolderDestination.classify] maps them the same way whether they came
 * from a real provider or from a fake configured to throw them.
 */
interface TreeDocumentGateway {
    /**
     * Whether a persisted read+write grant for [treeUri] is currently held.
     *
     * This is the SAF analogue of iOS resolving a security-scoped bookmark: the honest first check
     * before any I/O, because the user or the system can revoke a persisted permission at any time
     * and the URI string alone carries no access. A `false` here is §12 EPIC-14's "URI invalidation"
     * — status `unreachable`, offer a re-pick — reached without a failed write to discover it.
     */
    fun hasPersistedWriteGrant(treeUri: String): Boolean

    /**
     * Take a persistable read+write grant on a freshly-picked [treeUri] so it survives a reboot.
     *
     * The picker's own grant is process-scoped and evaporates when the app is next launched; this is
     * what makes the folder usable from a background export tomorrow. Throws [SecurityException] if
     * the URI was not handed over with persistable flags — which is enrollment's signal that the pick
     * cannot be trusted, not something to swallow.
     */
    fun takePersistableGrant(treeUri: String)

    /**
     * Release a persisted grant. For the delete flow — the standing filesystem access a destination
     * referenced should not outlive the destination row. Best-effort: a grant already gone is not an
     * error worth surfacing.
     */
    fun releasePersistableGrant(treeUri: String)

    /**
     * Ensure the folder path [components] exists beneath [treeUri], creating each missing level, and
     * return the leaf directory's document URI. Idempotent: an existing level is reused, never
     * duplicated. Throws if a level cannot be created.
     */
    fun ensureFolder(treeUri: String, components: List<String>): String

    /**
     * Create-or-truncate a document named [name] under [folderDocUri] and write [bytes]. If a
     * document with that name already exists it is overwritten in place (not left to become
     * `name (1)`, which is SAF's default on a name collision). Throws on failure.
     */
    fun putBytes(folderDocUri: String, name: String, bytes: ByteArray)

    /** Read the bytes of the document named [name] under [folderDocUri], or null if it is absent. */
    fun getBytes(folderDocUri: String, name: String): ByteArray?

    /** Delete the document named [name] under [folderDocUri]. Returns false if there was nothing to delete. */
    fun delete(folderDocUri: String, name: String): Boolean
}

/**
 * Real [TreeDocumentGateway] over [ContentResolver] + [DocumentsContract].
 *
 * No `androidx.documentfile` dependency: `DocumentFile` is a convenience wrapper over exactly these
 * SDK calls, and pulling a library in for it would bundle a dependency bump into a feature change —
 * the pattern EPIC-05's WorkManager note warns against. The operations here are few and stable.
 */
class ContentResolverTreeDocumentGateway(context: Context) : TreeDocumentGateway {
    private val resolver: ContentResolver = context.applicationContext.contentResolver

    override fun hasPersistedWriteGrant(treeUri: String): Boolean {
        val target = Uri.parse(treeUri)
        return resolver.persistedUriPermissions.any {
            it.uri == target && it.isWritePermission && it.isReadPermission
        }
    }

    override fun takePersistableGrant(treeUri: String) {
        resolver.takePersistableUriPermission(Uri.parse(treeUri), PERSISTABLE_FLAGS)
    }

    override fun releasePersistableGrant(treeUri: String) {
        try {
            resolver.releasePersistableUriPermission(Uri.parse(treeUri), PERSISTABLE_FLAGS)
        } catch (_: SecurityException) {
            // Already released, or never held. Nothing to undo.
        }
    }

    override fun ensureFolder(treeUri: String, components: List<String>): String {
        val tree = Uri.parse(treeUri)
        val rootDocId = DocumentsContract.getTreeDocumentId(tree)
        var parentDocUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootDocId)
        for (name in components) {
            parentDocUri = findChild(tree, parentDocUri, name, dirsOnly = true)
                ?: createDirectory(parentDocUri, name)
                ?: throw IOException("could not create folder segment")
        }
        return parentDocUri.toString()
    }

    override fun putBytes(folderDocUri: String, name: String, bytes: ByteArray) {
        val folder = Uri.parse(folderDocUri)
        val tree = folder // buildChildDocumentsUriUsingTree accepts any tree-derived doc uri
        val existing = findChild(tree, folder, name, dirsOnly = false)
        val docUri = existing ?: DocumentsContract.createDocument(
            resolver, folder, mimeFor(name), name,
        ) ?: throw IOException("createDocument returned null for $name")
        // "wt" truncates, so overwriting an existing document from a previous run leaves no tail of
        // stale bytes behind a shorter new file.
        val stream = resolver.openOutputStream(docUri, "wt")
            ?: throw FileNotFoundException("no output stream for $name")
        stream.use { it.write(bytes) }
    }

    override fun getBytes(folderDocUri: String, name: String): ByteArray? {
        val folder = Uri.parse(folderDocUri)
        val docUri = findChild(folder, folder, name, dirsOnly = false) ?: return null
        return resolver.openInputStream(docUri)?.use { it.readBytes() }
    }

    override fun delete(folderDocUri: String, name: String): Boolean {
        val folder = Uri.parse(folderDocUri)
        val docUri = findChild(folder, folder, name, dirsOnly = false) ?: return false
        return DocumentsContract.deleteDocument(resolver, docUri)
    }

    /**
     * Find a direct child of [parentDocUri] whose display name equals [name]. When [dirsOnly], only
     * a directory matches (so a file and a folder of the same name never collide during folder
     * creation). Returns the child's document URI, or null.
     */
    private fun findChild(tree: Uri, parentDocUri: Uri, name: String, dirsOnly: Boolean): Uri? {
        val parentDocId = DocumentsContract.getDocumentId(parentDocUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocId)
        resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(1)
                if (displayName != name) continue
                val isDir = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                if (dirsOnly && !isDir) continue
                return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
            }
        }
        return null
    }

    private fun createDirectory(parentDocUri: Uri, name: String): Uri? =
        DocumentsContract.createDocument(
            resolver, parentDocUri, DocumentsContract.Document.MIME_TYPE_DIR, name,
        )

    private fun mimeFor(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "csv" -> "text/csv"
        "json" -> "application/json"
        "zip", "badan" -> "application/octet-stream"
        else -> "application/octet-stream"
    }

    companion object {
        /** The flags a picked tree URI must be granted with, and taken with, to survive a reboot. */
        const val PERSISTABLE_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }
}
