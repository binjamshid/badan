import Foundation

/// EPIC-14 — the delivery seam between "artifacts exist on disk" and "artifacts arrived somewhere".
///
/// `ExportRunner` (stage 3 wires it) ends its job at a temp folder full of checksummed files. This
/// protocol is everything that happens after that, and it is deliberately the *narrowest* interface
/// that both a folder copy and a Phase-3 REST POST can satisfy without either one distorting it:
///
///  - Artifacts are `(bytes on disk, the name they should have, how big they are)` — **not a
///    folder**. A folder destination copies them; a REST destination reads and posts them. Handing
///    a delivery a directory URL instead would have made the folder case trivial and the REST case
///    impossible to implement without re-listing a directory it has no business knowing about.
///  - Nothing here throws. A delivery that moves four files and fails on the fifth is `.partial`
///    (§9.5), and a `throws` signature can only express all-or-nothing — the receipt below is what
///    makes "some of it arrived" a first-class, recordable answer instead of an exception that
///    loses the count.
///  - Both methods are `async`. Folder delivery never actually suspends, and paying an `async`
///    keyword for that costs nothing; the alternative is that Phase 3's REST destination cannot
///    implement a synchronous protocol and the whole seam gets reshaped — precisely what §12
///    EPIC-14 asks this file to avoid. Stage 3 calls these from an async context.
///
/// **Nothing in this file or its implementations persists anything.** Probes and receipts carry the
/// `ExportDestinationStatus` they concluded; writing it to `export_destinations`, and writing the
/// `ExportRun` row, belong to the runner (stage 3). Keeping those separate is what lets a probe run
/// from a settings screen without inventing a run row.
protocol ExportDestinationDelivering {
    /// Which `ExportDestination.kind` this implementation handles. A dispatcher matches on it, so
    /// a destination row whose kind has no registered deliverer fails loudly rather than falling
    /// through to some default that writes the user's data somewhere they did not choose.
    var kind: ExportDestinationKind { get }

    /// The §12 EPIC-14 verification ping: prove the destination is **actually writable** before the
    /// user relies on it.
    ///
    /// A real write+delete probe, never a "does this path look plausible" check. The failure this
    /// exists to catch — an iCloud folder whose bookmark still resolves but whose provider will
    /// reject the write — is invisible to every cheaper test.
    func verify(_ destination: ExportDestination, now: Date) async -> ExportDestinationProbe

    /// Deliver one run's artifacts. See `ExportDeliveryReceipt` for how the result maps onto the
    /// `ExportRun` columns stage 1 defined.
    func deliver(_ request: ExportDeliveryRequest, now: Date) async -> ExportDeliveryReceipt
}

/// One generated file awaiting delivery.
///
/// `fileName` is the name the artifact should carry **at the destination**, which is not the name
/// it has in the runner's temp folder: the runner writes `raw.csv`, and what lands in the user's
/// folder is `BADAN_weekly-vitals_20260701-20260707.csv` (see `ExportArtifactNaming`). Keeping both
/// on the struct means the rename is data the caller decided, not string surgery a destination
/// performs on a path it was handed.
struct ExportArtifact: Equatable {
    /// Where the runner wrote it. Read-only as far as any destination is concerned — a delivery
    /// copies out of the temp folder and never mutates or removes it, because a failed delivery
    /// must leave the artifact on disk for `ExportOutcome.failedDelivery`'s retry to re-send
    /// without regenerating (see that case's doc).
    let sourceURL: URL
    let fileName: String
    let byteCount: Int

    init(sourceURL: URL, fileName: String, byteCount: Int) {
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

/// Everything a delivery needs, and nothing about *why* the export ran.
///
/// No `ExportScope`, no template, no row counts: a destination that could see the scope could
/// branch on `includeSensitive`, and the moment one does, "routes and sensitive namespaces are
/// excluded from Quick Export" stops being a property of the preset and becomes a property of
/// wherever the file happened to be going. The gate belongs upstream (`QuickExportPreset`,
/// `ExportTemplate.scopeForRun`); by the time bytes reach here the decision is already made and a
/// destination has no business re-litigating it.
struct ExportDeliveryRequest {
    let destination: ExportDestination
    let artifacts: [ExportArtifact]
    /// Drives the `BADAN/Exports/<year>/<month>/` folder — see `ExportArtifactNaming.folderPath`
    /// for why this is the run instant rather than anything about the data's date range.
    let runDate: Date
    /// The zone the year/month folder is computed in. Explicit rather than `.current` at the point
    /// of use so a background run at 23:50 local files under the month the *user* is in, and so
    /// the choice is visible to a fixture instead of being read off the device.
    let timeZone: TimeZone

    init(destination: ExportDestination, artifacts: [ExportArtifact],
         runDate: Date, timeZone: TimeZone = .current) {
        self.destination = destination
        self.artifacts = artifacts
        self.runDate = runDate
        self.timeZone = timeZone
    }
}

/// The result of a verification ping.
///
/// `status` is what stage 3 hands `ExportDestinationRepository.updateStatus`; `message` is what the
/// user reads. Both are always populated, including on success — §12 EPIC-14 asks for the result
/// "reported plainly", and a probe that returns a bare `Bool` forces every call site to invent its
/// own wording for what happened.
struct ExportDestinationProbe {
    let status: ExportDestinationStatus
    let checkedAt: Date
    /// `nil` on success. Present otherwise so Export Health can classify the failure without
    /// parsing `message` — the same reason `ExportRun.errorCode` is a closed vocabulary.
    let errorCode: ExportErrorCode?
    let message: LocalizedString
    /// True when the honest remedy is "pick the folder again", not "try later". Drives whether the
    /// UI offers a re-pick button or a retry button; guessing from `status` alone would be wrong,
    /// because a full disk is also `unreachable`-adjacent and re-picking would not help it.
    let needsRepick: Bool

    var isWritable: Bool { status == .ok }

    init(status: ExportDestinationStatus, checkedAt: Date, errorCode: ExportErrorCode? = nil,
         message: LocalizedString, needsRepick: Bool = false) {
        self.status = status
        self.checkedAt = checkedAt
        self.errorCode = errorCode
        self.message = message
        self.needsRepick = needsRepick
    }
}

/// What a delivery concluded, shaped so every field maps onto a column stage 1 already defined.
///
/// The mapping is one-to-one on purpose — `outcome` → `export_runs.outcome`, `errorCode` →
/// `error_code`, `errorDetail` → `error_detail`, `bytesDelivered` → `bytes_written`, `deliveredAt`
/// → `delivered_at`. Stage 3 copies fields across; it never has to interpret a delivery result into
/// a ledger vocabulary, which is where the two would drift.
///
/// Every failure path a file destination can reach is representable in the existing enums. For the
/// record, since "if it is not, say so" was the instruction:
///   bookmark stale / tree-URI grant revoked → `.failedDelivery` + `.destinationUnreachable`
///   disk or provider full                   → `.failedDelivery` + `.storageFull`
///   volume unmounted / provider absent      → `.failedDelivery` + `.storageUnavailable`
///   source artifact unreadable (staging)    → `.failedDelivery` + `.writeFailed` (destination OK)
///   some files copied, some not             → `.partial`       + the code that stopped it
///   destination row is `disabled`           → `.failedDelivery` + `.destinationDisabled`
/// No new enum case was needed and none was invented.
struct ExportDeliveryReceipt {
    let outcome: ExportOutcome
    let errorCode: ExportErrorCode?
    let errorDetail: ExportErrorDetail
    /// Sum of the artifacts that actually landed — not the sum of what was offered. On `.partial`
    /// these differ, and the difference is the point: a ledger row claiming the full byte count for
    /// a half-finished delivery is the "it said it exported" failure this table exists to catch.
    let bytesDelivered: Int
    /// `nil` unless something arrived. Set on `.partial` too — files did arrive, just not all of
    /// them, and `deliveredAt == nil` would read as "nothing left the device".
    let deliveredAt: Date?
    /// What the destination's status should now be recorded as. Usually `.ok` even on failure: a
    /// full disk says nothing bad about the folder, and marking a perfectly good destination
    /// `unreachable` because the user ran out of space would send them into a pointless re-pick.
    let destinationStatus: ExportDestinationStatus
    /// Where the files went, relative to the destination root (`BADAN/Exports/2026/07`). For the
    /// UI to tell the user where to look. Never an absolute path — those leak the container UUID
    /// and the user's file-provider layout into a string that ends up in screenshots.
    let relativePath: String?
    let message: LocalizedString
    let needsRepick: Bool

    init(outcome: ExportOutcome, errorCode: ExportErrorCode? = nil, errorDetail: ExportErrorDetail,
         bytesDelivered: Int, deliveredAt: Date? = nil,
         destinationStatus: ExportDestinationStatus, relativePath: String? = nil,
         message: LocalizedString, needsRepick: Bool = false) {
        self.outcome = outcome
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.bytesDelivered = bytesDelivered
        self.deliveredAt = deliveredAt
        self.destinationStatus = destinationStatus
        self.relativePath = relativePath
        self.message = message
        self.needsRepick = needsRepick
    }
}
