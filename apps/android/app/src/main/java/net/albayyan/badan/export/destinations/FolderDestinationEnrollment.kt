package net.albayyan.badan.export.destinations

import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus

/**
 * EPIC-14 — turning a tree URI the user picked with `ACTION_OPEN_DOCUMENT_TREE` into a persistable
 * [ExportDestination].
 *
 * The mirror of iOS `FolderDestinationEnrollment`. Framework-free except through
 * [TreeDocumentGateway] (to take the persistable grant) and [TreeUriStore] (to remember the URI), so
 * enrollment's rules — ref derivation, re-pick stability, the order of grant-then-store — are
 * unit-testable with fakes.
 *
 * **This object persists nothing to the database.** It returns an [ExportDestination] value; writing
 * it belongs to `ExportDestinationRepository`, which stage 1 owns.
 */
object FolderDestinationEnrollment {

    /**
     * Namespace for the `ExportDestinationConfig.folderBookmarkRef` key.
     *
     * Distinct from `CredentialRef.NAMESPACE` and *not* a `CredentialRef`: that type is validated
     * storage for secrets that authenticate to a remote service, and a tree URI is neither a secret
     * nor a credential — it names a folder the user chose, and the access rides on the framework's
     * persisted-permission table, not on the string. Filing it under the credential namespace would
     * put a non-credential through a validator built to keep bearer tokens out, a category error the
     * first time someone audits either type. Kept identical to iOS's `bookmarkRefNamespace`.
     */
    const val BOOKMARK_REF_NAMESPACE = "badan.export.folder."

    data class Enrolled(val destination: ExportDestination, val bookmarkRef: String)

    sealed class Failure : Exception() {
        /**
         * The pick did not carry a persistable grant, so nothing usable across a reboot can be
         * stored. Reported rather than swallowed: a destination row without a persistable grant is
         * precisely the silent failure §12 EPIC-14 is written against.
         */
        object GrantNotPersistable : Failure()
    }

    /**
     * Enroll a picked folder.
     *
     * Re-picking is the *same call with the same [destinationId]*: the ref is derived from the id, so
     * a re-pick overwrites the stored URI in place and every template and `ExportCursor` pointing at
     * that destination keeps working. Minting a new id on re-pick would silently reset `sinceLastRun`
     * to zero and re-export the user's entire history — see `ExportCursor`'s doc for why that
     * watermark must survive.
     *
     * Order is load-bearing: take the persistable grant first, and only store the URI if that
     * succeeded. Storing first would leave a mapping to a URI we cannot actually use — the row would
     * outlive its access, the silent-failure shape again.
     */
    fun enroll(
        pickedTreeUri: String,
        destinationId: String,
        displayName: String,
        now: Long,
        originDeviceId: String,
        gateway: TreeDocumentGateway,
        store: TreeUriStore,
    ): Result<Enrolled> {
        try {
            gateway.takePersistableGrant(pickedTreeUri)
        } catch (_: SecurityException) {
            return Result.failure(Failure.GrantNotPersistable)
        }

        val ref = bookmarkRef(destinationId)
        store.store(ref, pickedTreeUri)

        val destination = ExportDestination(
            id = destinationId, kind = ExportDestinationKind.FILE_FOLDER,
            displayName = displayName,
            config = ExportDestinationConfig(folderBookmarkRef = ref),
            // No credentialRef, and tlsPolicy resolves to NOT_APPLICABLE from the kind: a folder
            // write has no transport and claiming one would be the small lie `ExportTlsPolicy`
            // documents.
            createdAt = now,
            // lastVerifiedAt stays null until a probe actually passes. Stamping it here would record
            // "verified" the moment a folder was picked, before anything had ever been written to it
            // — the claim the verification ping exists to earn.
            lastVerifiedAt = null, status = ExportDestinationStatus.OK,
            updatedAt = now, originDeviceId = originDeviceId,
        )
        return Result.success(Enrolled(destination, ref))
    }

    /**
     * Derived from the destination id, never random — see [enroll] for why re-pick stability matters.
     * Lowercased for the same reason `CredentialRef.forDestination` does it: ULIDs are
     * case-insensitive, and a key that varies by case is a key that sometimes misses.
     */
    fun bookmarkRef(destinationId: String): String =
        BOOKMARK_REF_NAMESPACE + destinationId.lowercase()

    /**
     * Drop a destination's stored URI and release its persisted grant. For the delete flow — the row
     * is soft-deleted by `ExportDestinationRepository`, and the standing filesystem access it
     * referenced should not outlive it.
     */
    fun forget(destinationId: String, gateway: TreeDocumentGateway, store: TreeUriStore) {
        val ref = bookmarkRef(destinationId)
        store.treeUri(ref)?.let { gateway.releasePersistableGrant(it) }
        store.remove(ref)
    }
}
