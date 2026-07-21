package net.albayyan.badan.export.destinations

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportErrorDetail
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportStage
import net.albayyan.badan.domain.ManifestDigest
import java.io.File
import java.util.TimeZone

/**
 * EPIC-14 — the delivery seam between "artifacts exist on disk" and "artifacts arrived somewhere".
 *
 * Mirror of iOS `Export/Destinations/ExportDestinationDelivery.swift`, decision for decision.
 * `ExportRunner` (stage 3 wires it) ends its job at a temp folder full of checksummed files; this
 * interface is everything after that, and it is deliberately the *narrowest* one that both a SAF
 * folder copy and a Phase-3 REST POST can satisfy without either distorting it:
 *
 *  - Artifacts are `(a file on disk, the name they should have, how big they are)` — **not a
 *    folder**. A folder destination copies them; a REST destination reads and posts them. Handing a
 *    delivery a directory would make the folder case trivial and the REST case impossible.
 *  - Nothing here throws. A delivery that moves four files and fails on the fifth is [ExportOutcome.PARTIAL]
 *    (§9.5), and a throwing signature can only say all-or-nothing — [ExportDeliveryReceipt] is what
 *    makes "some of it arrived" a first-class, recordable answer.
 *  - Both methods are `suspend`. SAF delivery does real blocking I/O and belongs off the main
 *    thread; a Phase-3 REST destination is inherently suspending. The export module stays
 *    network-free (ADR D-8) — a REST destination is a *different* implementation of this interface
 *    living outside this package, not a writer in here that posts.
 *
 * **Nothing in this file or its implementations persists anything.** Probes and receipts carry the
 * [ExportDestinationStatus] they concluded; writing it to `export_destinations`, and appending the
 * `ExportRun` row, belong to the runner (stage 3).
 */
interface ExportDestinationDelivering {
    /**
     * Which [ExportDestinationKind] this handles. A dispatcher matches on it, so a destination row
     * whose kind has no registered deliverer fails loudly rather than falling through to a default
     * that writes the user's data somewhere they did not choose.
     */
    val kind: ExportDestinationKind

    /**
     * The §12 EPIC-14 verification ping: prove the destination is **actually writable** before the
     * user relies on it. A real write+delete probe, never a "does this URI look plausible" check —
     * the failure this exists to catch (a tree URI whose grant was revoked, or a folder document
     * deleted out from under a still-persisted permission) is invisible to every cheaper test.
     */
    suspend fun verify(destination: ExportDestination, now: Long): ExportDestinationProbe

    /** Deliver one run's artifacts. See [ExportDeliveryReceipt] for the mapping onto `ExportRun`. */
    suspend fun deliver(request: ExportDeliveryRequest, now: Long): ExportDeliveryReceipt
}

/**
 * One generated file awaiting delivery.
 *
 * [fileName] is the name the artifact should carry **at the destination**, which is not the name it
 * has in the runner's temp folder: the runner writes `raw.csv`, and what lands in the user's folder
 * is `BADAN_weekly-vitals_20260701-20260707.csv` (see [ExportArtifactNaming]). Both live on the
 * struct so the rename is data the caller decided, not string surgery a destination performs.
 */
data class ExportArtifact(
    /**
     * Where the runner wrote it. Read-only as far as any destination is concerned — a delivery
     * copies out of the temp folder and never mutates or removes it, because a failed delivery must
     * leave the artifact on disk for [ExportOutcome.FAILED_DELIVERY]'s retry to re-send without
     * regenerating.
     */
    val source: File,
    val fileName: String,
    val byteCount: Long,
)

/**
 * Everything a delivery needs, and nothing about *why* the export ran.
 *
 * No `ExportScope`, no template, no row counts: a destination that could see the scope could branch
 * on `includeSensitive`, and the moment one does, "routes and sensitive namespaces are excluded
 * from Quick Export" stops being a property of the preset and becomes a property of wherever the
 * file happened to go. The gate belongs upstream (`QuickExportPreset`, `ExportTemplate.scopeForRun`);
 * by the time bytes reach here the decision is made and a destination has no business re-litigating.
 */
data class ExportDeliveryRequest(
    val destination: ExportDestination,
    val artifacts: List<ExportArtifact>,
    /**
     * Drives the `BADAN/Exports/<year>/<month>/` folder — see [ExportArtifactNaming.folderPath] for
     * why this is the run instant, not anything about the data's date range.
     */
    val runDate: Long,
    /**
     * The zone the year/month folder is computed in. Explicit rather than the default zone at the
     * point of use so a background run at 23:50 local files under the month the *user* is in, and so
     * the choice is visible to a fixture instead of read off the device.
     */
    val timeZone: TimeZone = TimeZone.getDefault(),
    /**
     * EPIC-20 seam extension — the manifest's SHA-256 as the runner already computed it for the
     * `ExportRun` row. A folder copy leaves it null; a REST destination uses it as the
     * `Idempotency-Key`/`X-Badan-Manifest-Sha` so a retried POST of the *same* bundle replays
     * idempotently (§22.7). It lives on the request rather than being recomputed inside a
     * destination because a destination **must not read a writer's internals** — re-deriving the
     * manifest sha would mean parsing the manifest artifact, exactly the coupling
     * `export/destinations` is kept free of (§8.3). When null, a REST destination falls back to a
     * deterministic digest of the delivered bytes, which has the same idempotency property.
     */
    val manifestSha: ManifestDigest? = null,
    /**
     * EPIC-20 seam extension — the export schema version this bundle was written against, for the
     * `X-Badan-Schema-Version` header (§22.7). Null for a folder copy; a REST destination falls back
     * to `ExportSchema.VERSION` (the single build-wide source of truth CI pins across both platforms)
     * so the header is never silently absent.
     */
    val schemaVersion: String? = null,
)

/**
 * The result of a verification ping.
 *
 * [status] is what stage 3 hands `ExportDestinationRepository.updateStatus`; [message] is what the
 * user reads. Both are always populated, including on success — §12 EPIC-14 asks for the result
 * "reported plainly", and a probe that returns a bare `Boolean` forces every call site to invent
 * its own wording.
 */
data class ExportDestinationProbe(
    val status: ExportDestinationStatus,
    val checkedAt: Long,
    /**
     * null on success. Present otherwise so Export Health can classify the failure without parsing
     * [message] — the same reason `ExportRun.errorCode` is a closed vocabulary.
     */
    val errorCode: ExportErrorCode? = null,
    val message: LocalizedString,
    /**
     * True when the honest remedy is "pick the folder again", not "try later". Drives whether the
     * UI offers a re-pick or a retry; guessing from [status] alone would be wrong, because a full
     * disk is also unreachable-adjacent and re-picking would not help it.
     */
    val needsRepick: Boolean = false,
) {
    val isWritable: Boolean get() = status == ExportDestinationStatus.OK
}

/**
 * What a delivery concluded, shaped so every field maps onto a column stage 1 already defined:
 * [outcome] → `export_runs.outcome`, [errorCode] → `error_code`, [errorDetail] → `error_detail`,
 * [bytesDelivered] → `bytes_written`, [deliveredAt] → `delivered_at`. Stage 3 copies fields across;
 * it never interprets a delivery result into a ledger vocabulary, which is where the two would drift.
 *
 * Every failure path a file destination can reach is representable in the existing enums. For the
 * record, since "if it is not, say so" was the instruction:
 *   tree-URI grant revoked / bookmark stale → FAILED_DELIVERY + DESTINATION_UNREACHABLE
 *   disk or provider full                   → FAILED_DELIVERY + STORAGE_FULL
 *   folder document deleted / provider gone  → FAILED_DELIVERY + STORAGE_UNAVAILABLE|DESTINATION_UNREACHABLE
 *   some files copied, some not             → PARTIAL         + the code that stopped it
 *   destination row is DISABLED             → FAILED_DELIVERY + DESTINATION_DISABLED
 * No new enum case was needed and none was invented.
 */
data class ExportDeliveryReceipt(
    val outcome: ExportOutcome,
    val errorCode: ExportErrorCode? = null,
    val errorDetail: ExportErrorDetail,
    /**
     * Sum of the artifacts that actually landed — not what was offered. On [ExportOutcome.PARTIAL]
     * these differ, and the difference is the point: a ledger row claiming the full byte count for a
     * half-finished delivery is the "it said it exported" failure this table exists to catch.
     */
    val bytesDelivered: Long,
    /**
     * null unless something arrived. Set on PARTIAL too — files did arrive, just not all of them,
     * and a null here would read as "nothing left the device".
     */
    val deliveredAt: Long? = null,
    /**
     * What the destination's status should now be recorded as. Usually OK even on failure: a full
     * disk says nothing bad about the folder, and marking a good destination unreachable because
     * the user ran out of space would send them into a pointless re-pick.
     */
    val destinationStatus: ExportDestinationStatus,
    /**
     * Where the files went, relative to the destination root (`BADAN/Exports/2026/07`). For the UI
     * to tell the user where to look. Never an absolute content URI — those leak the provider's
     * document-id scheme into a string that ends up in screenshots.
     */
    val relativePath: String? = null,
    val message: LocalizedString,
    val needsRepick: Boolean = false,
)

/**
 * Shared constructor for a value-free delivering-stage [ExportErrorDetail].
 *
 * [httpStatus] stays null for every file destination — only a networked one (EPIC-20) has a status
 * code to record, and §22.7 wants exactly that code and nothing else from the response.
 */
internal fun deliveringDetail(
    filesWritten: Int = 0,
    filesExpected: Int = 0,
    httpStatus: Int? = null,
): ExportErrorDetail =
    ExportErrorDetail(stage = ExportStage.DELIVERING, filesWritten = filesWritten,
        filesExpected = filesExpected, httpStatus = httpStatus)
