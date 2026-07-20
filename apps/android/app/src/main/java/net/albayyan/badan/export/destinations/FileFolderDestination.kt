package net.albayyan.badan.export.destinations

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportOutcome
import java.io.FileNotFoundException
import java.io.IOException

/**
 * EPIC-14 — delivery into a folder the user picked with `ACTION_OPEN_DOCUMENT_TREE`, reached through
 * a persisted SAF tree-URI grant.
 *
 * The mirror of iOS `Export/Destinations/FileFolderDestination.swift`. Pure of Android framework
 * types except through [TreeDocumentGateway] and [TreeUriStore], which is what lets its orchestration
 * and — more importantly — its failure classification be unit-tested with fakes, despite the module
 * having no androidTest/Robolectric coverage.
 *
 * Network-free by construction (ADR D-8): there is no HTTP client here and a SAF provider that syncs
 * to a cloud does that itself, below us. The Phase-3 REST destination named in §9.4 is a *different*
 * implementation of [ExportDestinationDelivering] living outside this module for exactly that reason.
 *
 * The failure model §12 EPIC-14 specifies lives in [classify] and [resolveTree]: a grant revoked, or
 * a folder deleted out from under a still-persisted permission, produces
 * `ExportDestinationStatus.UNREACHABLE` and `needsRepick = true` — never a silent no-op, never a
 * crash.
 */
class FileFolderDestination(
    private val treeUris: TreeUriStore,
    private val gateway: TreeDocumentGateway,
) : ExportDestinationDelivering {

    override val kind: ExportDestinationKind = ExportDestinationKind.FILE_FOLDER

    // -- Verification ping (§12 EPIC-14) --

    override suspend fun verify(destination: ExportDestination, now: Long): ExportDestinationProbe {
        if (destination.status == ExportDestinationStatus.DISABLED) {
            return ExportDestinationProbe(
                status = ExportDestinationStatus.DISABLED, checkedAt = now,
                errorCode = ExportErrorCode.DESTINATION_DISABLED,
                message = DestinationMessages.destinationDisabled,
            )
        }

        val treeUri = when (val r = resolveTree(destination)) {
            is Resolution.Failure -> return r.failure.probe(now)
            is Resolution.Ok -> r.treeUri
        }

        // Probe the real write target — the <year>/<month> leaf, not the picked root — because
        // creating the subdirectories is itself a thing that can fail on a provider that grants
        // read-write on a tree but refuses createDocument. Verifying the root would report a
        // destination "ready" that fails on its first actual export.
        val components = ExportArtifactNaming.folderComponents(now, java.util.TimeZone.getDefault())
        val folderDocUri = try {
            gateway.ensureFolder(treeUri, components)
        } catch (e: Exception) {
            return classify(e).probe(now)
        }

        // Write, read back, compare, delete. Reading back is not paranoia about our own write: some
        // providers accept a write, report success, and drop the bytes when they cannot reach their
        // backing store. A probe that only checked for a thrown error would certify exactly the
        // destination most likely to lose the user's export.
        val payload = PROBE_PAYLOAD.toByteArray(Charsets.UTF_8)
        try {
            gateway.putBytes(folderDocUri, PROBE_FILE_NAME, payload)
            val readBack = gateway.getBytes(folderDocUri, PROBE_FILE_NAME)
            if (readBack == null || !readBack.contentEquals(payload)) {
                gateway.delete(folderDocUri, PROBE_FILE_NAME)
                return ExportDestinationProbe(
                    status = ExportDestinationStatus.UNREACHABLE, checkedAt = now,
                    errorCode = ExportErrorCode.WRITE_FAILED,
                    message = DestinationMessages.probeWriteFailed,
                )
            }
        } catch (e: Exception) {
            return classify(e).probe(now)
        }

        // A probe file we could not remove does not make the folder unwritable — writability is
        // exactly what we just proved — so this is best-effort and the result stays OK.
        try { gateway.delete(folderDocUri, PROBE_FILE_NAME) } catch (_: Exception) { }

        return ExportDestinationProbe(
            status = ExportDestinationStatus.OK, checkedAt = now,
            message = DestinationMessages.probeWritable,
        )
    }

    // -- Delivery --

    override suspend fun deliver(request: ExportDeliveryRequest, now: Long): ExportDeliveryReceipt {
        val expected = request.artifacts.size

        if (request.destination.status == ExportDestinationStatus.DISABLED) {
            return Failure(
                ExportErrorCode.DESTINATION_DISABLED, ExportDestinationStatus.DISABLED,
                DestinationMessages.destinationDisabled,
            ).receipt(expected)
        }
        if (request.artifacts.isEmpty()) {
            // SKIPPED_NO_DATA, not SUCCESS: §9.5 wants "there was nothing to send" recorded as its
            // own answer, so an automation that legitimately had nothing to do is distinguishable in
            // Export Health from one that quietly did nothing.
            return ExportDeliveryReceipt(
                outcome = ExportOutcome.SKIPPED_NO_DATA,
                errorDetail = deliveringDetail(filesExpected = 0),
                bytesDelivered = 0L, destinationStatus = ExportDestinationStatus.OK,
                message = DestinationMessages.nothingToDeliver,
            )
        }

        val treeUri = when (val r = resolveTree(request.destination)) {
            is Resolution.Failure -> return r.failure.receipt(expected)
            is Resolution.Ok -> r.treeUri
        }

        val components = ExportArtifactNaming.folderComponents(request.runDate, request.timeZone)
        val relativePath = components.joinToString("/")
        val folderDocUri = try {
            gateway.ensureFolder(treeUri, components)
        } catch (e: Exception) {
            return classify(e).receipt(expected)
        }

        var written = 0
        var bytes = 0L
        for (artifact in request.artifacts) {
            // Read the source and write to the destination as two separate steps, because they fail
            // for unrelated reasons and must be classified differently: a missing source artifact is
            // a staging bug (the destination is fine, re-picking would not help), while a failed
            // write is what §12 EPIC-14's failure model is actually about.
            val data = try {
                artifact.source.readBytes()
            } catch (e: Exception) {
                return sourceReadReceipt(written, bytes, expected, now, relativePath)
            }
            try {
                gateway.putBytes(folderDocUri, artifact.fileName, data)
                written += 1
                bytes += artifact.byteCount
            } catch (e: Exception) {
                // Stop at the first failure rather than pushing on. The remaining artifacts belong to
                // the same export, whatever stopped this one (no space, revoked grant) will almost
                // certainly stop them too, and a receipt saying "3 of 5" is more useful than five
                // identical errors. The artifacts stay in the runner's temp folder either way, so
                // FAILED_DELIVERY's retry can re-send without regenerating.
                val failure = classify(e)
                return ExportDeliveryReceipt(
                    outcome = if (written > 0) ExportOutcome.PARTIAL else ExportOutcome.FAILED_DELIVERY,
                    errorCode = failure.errorCode,
                    errorDetail = deliveringDetail(filesWritten = written, filesExpected = expected),
                    bytesDelivered = bytes,
                    deliveredAt = if (written > 0) now else null,
                    destinationStatus = failure.destinationStatus,
                    relativePath = if (written > 0) relativePath else null,
                    message = if (written > 0) {
                        DestinationMessages.partiallyDelivered(written, expected)
                    } else {
                        failure.message
                    },
                    needsRepick = failure.needsRepick,
                )
            }
        }

        return ExportDeliveryReceipt(
            outcome = ExportOutcome.SUCCESS,
            errorDetail = deliveringDetail(filesWritten = written, filesExpected = expected),
            bytesDelivered = bytes, deliveredAt = now,
            destinationStatus = ExportDestinationStatus.OK, relativePath = relativePath,
            message = DestinationMessages.delivered(relativePath),
        )
    }

    /**
     * A source artifact could not be read — a staging problem, not the destination's fault, so the
     * destination stays OK and re-picking would not help. PARTIAL if earlier files did land.
     */
    private fun sourceReadReceipt(
        written: Int,
        bytes: Long,
        expected: Int,
        now: Long,
        relativePath: String,
    ): ExportDeliveryReceipt = ExportDeliveryReceipt(
        outcome = if (written > 0) ExportOutcome.PARTIAL else ExportOutcome.FAILED_DELIVERY,
        errorCode = ExportErrorCode.WRITE_FAILED,
        errorDetail = deliveringDetail(filesWritten = written, filesExpected = expected),
        bytesDelivered = bytes,
        deliveredAt = if (written > 0) now else null,
        destinationStatus = ExportDestinationStatus.OK,
        relativePath = if (written > 0) relativePath else null,
        message = if (written > 0) {
            DestinationMessages.partiallyDelivered(written, expected)
        } else {
            DestinationMessages.probeWriteFailed
        },
        needsRepick = false,
    )

    // -- Tree resolution --

    private sealed class Resolution {
        data class Ok(val treeUri: String) : Resolution()
        data class Failure(val failure: FileFolderDestination.Failure) : Resolution()
    }

    private fun resolveTree(destination: ExportDestination): Resolution {
        if (destination.kind != ExportDestinationKind.FILE_FOLDER) {
            // A dispatcher handed this destination to the wrong deliverer. Reported rather than
            // asserted: an `unknown` row in the ledger is recoverable, a crash in a background export
            // is one the user cannot see the cause of.
            return Resolution.Failure(
                Failure(ExportErrorCode.UNKNOWN, destination.status,
                    DestinationMessages.destinationNotConfigured),
            )
        }
        val ref = destination.config.folderBookmarkRef
            ?: return Resolution.Failure(
                Failure(ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.UNREACHABLE,
                    DestinationMessages.destinationNotConfigured, needsRepick = true),
            )
        val treeUri = treeUris.treeUri(ref)
            ?: return Resolution.Failure(
                // The row survived but the stored URI did not — a reinstall that cleared prefs, or a
                // store that was never written. Same remedy as a revoked grant.
                Failure(ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.UNREACHABLE,
                    DestinationMessages.probeNeedsRepick, needsRepick = true),
            )
        if (!gateway.hasPersistedWriteGrant(treeUri)) {
            // The honest first check: the user or the system revoked the persisted permission. §12
            // EPIC-14's "URI invalidation" — reached without a failed write to discover it.
            return Resolution.Failure(
                Failure(ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.UNREACHABLE,
                    DestinationMessages.probePermissionWithdrawn, needsRepick = true),
            )
        }
        return Resolution.Ok(treeUri)
    }

    // -- Failure classification --

    /** One failure, in the vocabularies the rest of the system speaks. */
    private data class Failure(
        val errorCode: ExportErrorCode,
        val destinationStatus: ExportDestinationStatus,
        val message: LocalizedString,
        val needsRepick: Boolean = false,
    ) {
        fun probe(now: Long): ExportDestinationProbe = ExportDestinationProbe(
            status = destinationStatus, checkedAt = now, errorCode = errorCode,
            message = message, needsRepick = needsRepick,
        )

        fun receipt(expected: Int): ExportDeliveryReceipt = ExportDeliveryReceipt(
            outcome = ExportOutcome.FAILED_DELIVERY, errorCode = errorCode,
            errorDetail = deliveringDetail(filesWritten = 0, filesExpected = expected),
            bytesDelivered = 0L, destinationStatus = destinationStatus,
            message = message, needsRepick = needsRepick,
        )
    }

    /**
     * Map a framework exception onto the closed [ExportErrorCode] vocabulary. Internal so the test
     * can assert the mapping directly rather than only through a full deliver call.
     *
     * The distinction that matters most is "the destination is broken" versus "this attempt was".
     * Only the former moves the destination to UNREACHABLE: marking a good folder unreachable
     * because the disk filled up sends the user into a re-pick that cannot help, and disables their
     * schedule for a reason that will resolve itself.
     */
    internal fun classify(error: Throwable): FailureView {
        // A revoked grant surfaces as SecurityException the moment we touch the provider — the
        // grant side of §12 EPIC-14's "URI invalidation". Re-picking restores it.
        if (error is SecurityException) {
            return FailureView(ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.UNREACHABLE,
                DestinationMessages.probePermissionWithdrawn, needsRepick = true)
        }
        // The folder document is gone from under the grant.
        if (error is FileNotFoundException) {
            return FailureView(ExportErrorCode.DESTINATION_UNREACHABLE, ExportDestinationStatus.UNREACHABLE,
                DestinationMessages.probeNeedsRepick, needsRepick = true)
        }
        if (error is IOException) {
            // SAF gives no ENOSPC code — the provider raises a plain IOException — so a full disk is
            // recognizable only by message. Best-effort: a missed match falls through to writeFailed,
            // which is honest (we could not write) even if it misses the reason.
            val text = (error.message ?: "").lowercase()
            val outOfSpace = listOf("space", "enospc", "storage is full", "no space", "disk full", "quota")
                .any { it in text }
            if (outOfSpace) {
                return FailureView(ExportErrorCode.STORAGE_FULL, ExportDestinationStatus.OK,
                    DestinationMessages.probeStorageFull)
            }
            return FailureView(ExportErrorCode.WRITE_FAILED, ExportDestinationStatus.OK,
                DestinationMessages.probeWriteFailed)
        }
        // Everything else: the folder is not proven broken, so leave the destination alone. `unknown`
        // would tell Export Health nothing about which stage to retry, so this stays writeFailed.
        return FailureView(ExportErrorCode.WRITE_FAILED, ExportDestinationStatus.OK,
            DestinationMessages.probeWriteFailed)
    }

    /** Public-to-the-module view of a classified failure, so [classify] can be asserted in tests. */
    internal data class FailureView(
        val errorCode: ExportErrorCode,
        val destinationStatus: ExportDestinationStatus,
        val message: LocalizedString,
        val needsRepick: Boolean = false,
    )

    private fun FailureView.probe(now: Long): ExportDestinationProbe =
        Failure(errorCode, destinationStatus, message, needsRepick).probe(now)

    private fun FailureView.receipt(expected: Int): ExportDeliveryReceipt =
        Failure(errorCode, destinationStatus, message, needsRepick).receipt(expected)

    companion object {
        /**
         * Fixed rather than per-run so a probe that writes and then fails to delete leaves exactly
         * one stray file forever instead of one per check — the next probe overwrites it. Leading dot
         * to stay out of the user's way in a file browser if that ever happens.
         */
        const val PROBE_FILE_NAME = ".BADAN-write-probe"
        private const val PROBE_PAYLOAD = "BADAN write probe"
    }
}
