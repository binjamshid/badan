package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.CredentialRef
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportTlsPolicy
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * `export_destinations` (migration v4, plan §9.4) — where artifacts go.
 *
 * **No secret ever passes through this repository.** The only credential-shaped thing it writes is
 * [ExportDestination.credentialRef], which is a validated Keystore key (see [CredentialRef]); the
 * secret itself is written by whatever owns Keystore-backed storage, and this file deliberately has
 * no import, parameter or column for it. The `config` column takes [ExportDestinationConfig], whose
 * fields are references and routing details rather than a `Map<String, String>` bag — the shape
 * that would otherwise make this the easiest place in the codebase to stash a bearer token.
 */
class ExportDestinationRepository(private val db: SqliteConnection) {

    // MARK: - Writes

    fun upsert(destination: ExportDestination) = write(destination)

    /**
     * Seed the share-sheet destination, returning true if it was created by this call.
     *
     * Quick Export needs a destination row to exist before its first run, because
     * `export_cursors.destination_id` is NOT NULL and `shareSheet` is a destination kind rather than
     * the absence of one (v4 comment). Fixed id, so this is idempotent.
     */
    fun seedShareSheet(now: Long, originDeviceId: String): Boolean {
        val existed = destination(ExportDestination.SHARE_SHEET_ID) != null
        write(ExportDestination.shareSheet(now, originDeviceId), conflictPolicy = "OR IGNORE")
        return !existed
    }

    /**
     * Record the result of a reachability/auth check.
     *
     * `last_verified_at` is only advanced on [ExportDestinationStatus.OK]: it means "last known
     * good", and stamping it on a failed check would make a destination that has been broken for a
     * week look freshly verified in the Export Health dashboard.
     */
    fun updateStatus(id: String, status: ExportDestinationStatus, checkedAt: Long) {
        if (status == ExportDestinationStatus.OK) {
            db.run(
                """
                UPDATE export_destinations SET status = ?, last_verified_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """,
                listOf(status.code, checkedAt, checkedAt, id),
            )
        } else {
            db.run(
                "UPDATE export_destinations SET status = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
                listOf(status.code, checkedAt, id),
            )
        }
    }

    /**
     * Tombstone a destination. Templates pointing at it keep their `destination_id`: a run against a
     * deleted destination should fail loudly with evidence in the ledger, not silently redirect
     * somewhere the user did not choose.
     */
    fun softDelete(id: String, at: Long) {
        db.run(
            "UPDATE export_destinations SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(at, at, id),
        )
    }

    private fun write(d: ExportDestination, conflictPolicy: String = "OR REPLACE") {
        db.run(
            """
            INSERT $conflictPolicy INTO export_destinations
              (id, kind, display_name, config, credential_ref, tls_policy, created_at,
               last_verified_at, status, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                d.id, d.kind.code, d.displayName, JsonCoding.encode(d.config),
                d.credentialRef?.key, d.tlsPolicy.code, d.createdAt, d.lastVerifiedAt, d.status.code,
            ) + Rows.convParams(d.updatedAt, d.originDeviceId, d.deletedAt),
        )
    }

    // MARK: - Reads

    fun all(): List<ExportDestination> =
        db.query("SELECT * FROM export_destinations WHERE deleted_at IS NULL ORDER BY created_at ASC;")
            .map { read(it) }

    fun destination(id: String): ExportDestination? =
        db.query("SELECT * FROM export_destinations WHERE id = ? AND deleted_at IS NULL;", listOf(id))
            .firstOrNull()?.let { read(it) }

    companion object {
        fun read(r: Row): ExportDestination {
            val kind = ExportDestinationKind.fromCode(r.getString("kind"))
            return ExportDestination(
                id = r.requireString("id"),
                kind = kind,
                displayName = r.requireString("display_name"),
                config = JsonCoding.decodeOrNull<ExportDestinationConfig>(r.getString("config"))
                    ?: ExportDestinationConfig(),
                // A stored value that no longer validates as a `CredentialRef` reads back as null
                // rather than as a string. The consequence is honest: the secret becomes
                // unreachable and the destination will report `authExpired` on its next check,
                // which is the truth — BADAN has lost the handle to it. The alternative, widening
                // the type to carry arbitrary text back out of the database, is the leak this
                // guards.
                credentialRef = CredentialRef.of(r.getString("credential_ref")),
                tlsPolicy = ExportTlsPolicy.fromCode(r.getString("tls_policy"))
                    ?: if (kind.leavesDevice) ExportTlsPolicy.HTTPS_ONLY else ExportTlsPolicy.NOT_APPLICABLE,
                createdAt = r.requireDate("created_at"),
                lastVerifiedAt = r.getDate("last_verified_at"),
                status = ExportDestinationStatus.fromCode(r.getString("status")),
                updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )
        }
    }
}
