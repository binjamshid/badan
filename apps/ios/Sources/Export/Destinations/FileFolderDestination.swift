import Foundation

/// EPIC-14 — delivery into a folder the user picked with `UIDocumentPickerViewController`
/// (iCloud Drive, On My iPhone, or any third-party file provider), reached through a
/// security-scoped bookmark.
///
/// Foundation only. This file sits under `apps/ios/Sources/Export/`, which CI asserts is free of
/// any networking-API import (ADR D-8) — the Phase-3 REST destination named in §9.4 is a
/// *different* implementation of `ExportDestinationDelivering` that will live outside this module
/// for exactly that reason. Nothing here should ever need to reach the network: a file provider
/// that syncs to iCloud does that itself, below us, which is the whole point of going through the
/// provider instead of an API.
///
/// The failure model §12 EPIC-14 specifies is implemented in `classify(_:)` and
/// `resolveFolder(_:)`: a bookmark that has gone stale beyond recovery, or a folder whose access
/// the system no longer grants, produces `ExportDestinationStatus.unreachable` and
/// `needsRepick = true` — never a silent no-op, and never a crash.
struct FileFolderDestination: ExportDestinationDelivering {

    let kind: ExportDestinationKind = .fileFolder

    private let bookmarks: FolderBookmarkStoring
    private let fileManager: FileManager

    /// The fixed name of the verification probe file.
    ///
    /// Fixed rather than per-run so a probe that writes successfully and then fails to delete
    /// leaves exactly one stray file forever instead of one per check — the next probe overwrites
    /// it. Leading dot so it stays out of the user's way in Files.app if that ever happens.
    static let probeFileName = ".BADAN-write-probe"

    init(bookmarks: FolderBookmarkStoring, fileManager: FileManager = .default) {
        self.bookmarks = bookmarks
        self.fileManager = fileManager
    }

    // MARK: - Verification ping (§12 EPIC-14)

    func verify(_ destination: ExportDestination, now: Date) async -> ExportDestinationProbe {
        if destination.status == .disabled {
            return ExportDestinationProbe(status: .disabled, checkedAt: now,
                                          errorCode: .destinationDisabled,
                                          message: DestinationMessages.destinationDisabled)
        }

        let folder: ResolvedFolder
        switch resolveFolder(destination) {
        case .failure(let failure):
            return failure.probe(at: now)
        case .success(let resolved):
            folder = resolved
        }
        defer { folder.relinquish() }

        // Probe the real write target — the `<year>/<month>` leaf, not the picked root — because
        // creating the subdirectories is itself a thing that can fail on a provider that grants
        // read-write on a folder but refuses `createDirectory`. Verifying the root would report a
        // destination "ready" that fails on its first actual export.
        let target = folder.url.appending(components: ExportArtifactNaming.folderComponents(
            runDate: now, timeZone: .current))
        do {
            try createDirectoryIdempotently(at: target)
        } catch {
            return classify(error).probe(at: now)
        }

        // Write, read back, compare, delete. Reading back is not paranoia about our own `write`
        // call: some file providers accept a write, return success, and drop the bytes when they
        // cannot reach their backing store. A probe that only checked for a thrown error would
        // certify exactly the destination most likely to lose the user's export.
        let probeURL = target.appendingPathComponent(Self.probeFileName, isDirectory: false)
        let payload = Data("BADAN write probe".utf8)
        do {
            try payload.write(to: probeURL, options: [.atomic, .completeFileProtection])
            let readBack = try Data(contentsOf: probeURL)
            guard readBack == payload else {
                try? fileManager.removeItem(at: probeURL)
                return ExportDestinationProbe(status: .unreachable, checkedAt: now,
                                              errorCode: .writeFailed,
                                              message: DestinationMessages.probeWriteFailed)
            }
        } catch {
            return classify(error).probe(at: now)
        }

        // A probe file we could not remove does not make the folder unwritable — writability is
        // exactly what we just proved — so this is best-effort and the result stays `ok`. Saying
        // otherwise would send the user into a re-pick that fixes nothing.
        try? fileManager.removeItem(at: probeURL)

        folder.persistRefreshedBookmarkIfNeeded(into: bookmarks)
        return ExportDestinationProbe(status: .ok, checkedAt: now,
                                      message: DestinationMessages.probeWritable)
    }

    // MARK: - Delivery

    func deliver(_ request: ExportDeliveryRequest, now: Date) async -> ExportDeliveryReceipt {
        let expected = request.artifacts.count

        if request.destination.status == .disabled {
            return refusal(.destinationDisabled, status: .disabled, expected: expected,
                           message: DestinationMessages.destinationDisabled)
        }
        guard !request.artifacts.isEmpty else {
            // `skippedNoData`, not `success`: §9.5 wants "there was nothing to send" recorded as
            // its own answer, so an automation that legitimately had nothing to do is
            // distinguishable in Export Health from one that quietly did nothing.
            return ExportDeliveryReceipt(outcome: .skippedNoData, errorDetail:
                                            ExportErrorDetail(stage: .delivering, filesExpected: 0),
                                         bytesDelivered: 0, destinationStatus: .ok,
                                         message: DestinationMessages.nothingToDeliver)
        }

        let folder: ResolvedFolder
        switch resolveFolder(request.destination) {
        case .failure(let failure):
            return failure.receipt(expected: expected)
        case .success(let resolved):
            folder = resolved
        }
        defer { folder.relinquish() }

        let components = ExportArtifactNaming.folderComponents(runDate: request.runDate,
                                                              timeZone: request.timeZone)
        let relativePath = components.joined(separator: "/")
        let target = folder.url.appending(components: components)
        do {
            try createDirectoryIdempotently(at: target)
        } catch {
            return classify(error).receipt(expected: expected)
        }

        var written = 0
        var bytes = 0
        for artifact in request.artifacts {
            // Read the source and write to the destination as two separate steps, because they
            // fail for unrelated reasons and must be classified differently: a missing source
            // artifact is a staging bug (the destination is fine, re-picking would not help),
            // while a failed write is what §12 EPIC-14's failure model is actually about.
            let data: Data
            do {
                // `.mappedIfSafe` so a large export is not fully resident on its way through — the
                // runner already wrote these bytes once, and paging a multi-megabyte CSV into
                // memory to copy it is how a background export gets jetsammed.
                data = try Data(contentsOf: artifact.sourceURL, options: .mappedIfSafe)
            } catch {
                return sourceReadReceipt(written: written, bytes: bytes, expected: expected,
                                         now: now, relativePath: relativePath)
            }
            do {
                let dest = target.appendingPathComponent(artifact.fileName, isDirectory: false)
                // `.atomic` so a delivery interrupted mid-write leaves no truncated file wearing a
                // real export's name.
                try data.write(to: dest, options: [.atomic, .completeFileProtection])
                written += 1
                bytes += artifact.byteCount
            } catch {
                // Stop at the first failure rather than pushing on. The remaining artifacts belong
                // to the same export, whatever stopped this one (no space, revoked access) will
                // almost certainly stop them too, and a receipt saying "3 of 5" is more useful than
                // five identical errors. The artifacts stay in the runner's temp folder either way,
                // so `failedDelivery`'s retry can re-send without regenerating.
                let failure = classify(error)
                return ExportDeliveryReceipt(
                    outcome: written > 0 ? .partial : .failedDelivery,
                    errorCode: failure.errorCode,
                    errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: written,
                                                   filesExpected: expected),
                    bytesDelivered: bytes,
                    deliveredAt: written > 0 ? now : nil,
                    destinationStatus: failure.destinationStatus,
                    relativePath: written > 0 ? relativePath : nil,
                    message: written > 0
                        ? DestinationMessages.partiallyDelivered(written: written, expected: expected)
                        : failure.message,
                    needsRepick: failure.needsRepick)
            }
        }

        folder.persistRefreshedBookmarkIfNeeded(into: bookmarks)
        return ExportDeliveryReceipt(
            outcome: .success,
            errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: written,
                                           filesExpected: expected),
            bytesDelivered: bytes, deliveredAt: now, destinationStatus: .ok,
            relativePath: relativePath,
            message: DestinationMessages.delivered(to: relativePath))
    }

    /// A source artifact could not be read — a staging problem, not the destination's fault, so the
    /// destination stays `.ok` and re-picking would not help. `.partial` if earlier files did land.
    private func sourceReadReceipt(written: Int, bytes: Int, expected: Int, now: Date,
                                   relativePath: String) -> ExportDeliveryReceipt {
        ExportDeliveryReceipt(
            outcome: written > 0 ? .partial : .failedDelivery,
            errorCode: .writeFailed,
            errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: written,
                                           filesExpected: expected),
            bytesDelivered: bytes,
            deliveredAt: written > 0 ? now : nil,
            destinationStatus: .ok,
            relativePath: written > 0 ? relativePath : nil,
            message: written > 0
                ? DestinationMessages.partiallyDelivered(written: written, expected: expected)
                : DestinationMessages.probeWriteFailed,
            needsRepick: false)
    }

    // MARK: - Bookmark resolution

    /// A folder we currently hold access to, plus whatever bookmark maintenance that cost.
    ///
    /// `relinquish` is not optional bookkeeping: security-scoped access is a per-process resource
    /// with a hard limit, and a delivery path that leaks one on every run eventually stops being
    /// able to open anything at all. Every caller pairs this with `defer`.
    private struct ResolvedFolder {
        let url: URL
        let scoped: Bool
        let refreshedBookmark: Data?
        let bookmarkRef: String

        func relinquish() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        /// Written only after the folder has demonstrably worked. Replacing a stored bookmark with
        /// a freshly-minted one *before* proving the new one resolves would let a single bad
        /// refresh permanently orphan a destination that was fine.
        func persistRefreshedBookmarkIfNeeded(into store: FolderBookmarkStoring) {
            guard let refreshedBookmark else { return }
            store.store(refreshedBookmark, for: bookmarkRef)
        }
    }

    private func resolveFolder(_ destination: ExportDestination) -> Result<ResolvedFolder, Failure> {
        guard destination.kind == .fileFolder else {
            // A dispatcher handed this destination to the wrong deliverer. Reported rather than
            // asserted: an `unknown` row in the ledger is recoverable, a trap in a background
            // export is a crash the user cannot see the cause of.
            return .failure(Failure(errorCode: .unknown, destinationStatus: destination.status,
                                    message: DestinationMessages.destinationNotConfigured))
        }
        guard let ref = destination.config.folderBookmarkRef else {
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                                    message: DestinationMessages.destinationNotConfigured,
                                    needsRepick: true))
        }
        guard let data = bookmarks.bookmark(for: ref) else {
            // The row survived but the protected bytes did not — a restore onto a new device
            // (`ThisDeviceOnly`), or a Keychain the user reset. Same remedy as a stale bookmark.
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                                    message: DestinationMessages.probeNeedsRepick, needsRepick: true))
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            // The documented end of the line for a bookmark: the volume is gone, the folder was
            // deleted, or the file provider was uninstalled. §12 EPIC-14's failure model names
            // exactly this — `unreachable` plus a re-pick, never a silent skip.
            return .failure(Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                                    message: DestinationMessages.probeNeedsRepick, needsRepick: true))
        }

        // `startAccessingSecurityScopedResource()` returning false is **not** a denial. It also
        // returns false for a URL that is not security-scoped in the first place, where access
        // simply needs no bracketing — treating false as fatal is the classic bug here, and it
        // would reject perfectly good `On My iPhone` folders. So: remember whether we took the
        // scope (to know whether to release it), and let the actual write decide reachability.
        let scoped = url.startAccessingSecurityScopedResource()

        // A stale bookmark still resolved, which means the URL is usually usable and the right move
        // is to mint a replacement — not to fail. If minting throws we carry on with the URL we
        // have and leave the stale bytes in place: costing the user this export over bookkeeping
        // they cannot see would be the wrong trade, and the next run simply tries again.
        var refreshed: Data?
        if isStale {
            refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
        }
        return .success(ResolvedFolder(url: url, scoped: scoped, refreshedBookmark: refreshed,
                                       bookmarkRef: ref))
    }

    // MARK: - Writing

    /// Idempotent by construction: `withIntermediateDirectories: true` succeeds when the directory
    /// already exists, so a second export in the same month is not a special case anyone has to
    /// remember to handle.
    ///
    /// The `.complete` protection class is a **request**. Inside the app container it is honored;
    /// on a third-party file provider the provider decides, and BADAN cannot promise a protection
    /// class for a directory it does not own. When the attribute is what the call objected to, we
    /// retry without it rather than refusing to export into a folder the user explicitly chose —
    /// and say so here rather than in a UI string implying protection we do not control.
    private func createDirectoryIdempotently(at url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Failure classification

    /// One failure, in the four vocabularies the rest of the system speaks. Conforms to `Error`
    /// only so it can be a `Result` failure type in `resolveFolder`; it is never thrown.
    private struct Failure: Error {
        let errorCode: ExportErrorCode
        let destinationStatus: ExportDestinationStatus
        let message: LocalizedString
        var needsRepick: Bool = false

        func probe(at now: Date) -> ExportDestinationProbe {
            ExportDestinationProbe(status: destinationStatus, checkedAt: now, errorCode: errorCode,
                                   message: message, needsRepick: needsRepick)
        }

        func receipt(expected: Int) -> ExportDeliveryReceipt {
            ExportDeliveryReceipt(outcome: .failedDelivery, errorCode: errorCode,
                                  errorDetail: ExportErrorDetail(stage: .delivering, filesWritten: 0,
                                                                 filesExpected: expected),
                                  bytesDelivered: 0, destinationStatus: destinationStatus,
                                  message: message, needsRepick: needsRepick)
        }
    }

    private func refusal(_ code: ExportErrorCode, status: ExportDestinationStatus,
                         expected: Int, message: LocalizedString) -> ExportDeliveryReceipt {
        Failure(errorCode: code, destinationStatus: status, message: message).receipt(expected: expected)
    }

    /// Map a Foundation file error onto the closed `ExportErrorCode` vocabulary.
    ///
    /// The distinction that matters most is "the destination is broken" versus "this attempt was".
    /// Only the former moves the destination to `unreachable`: marking a good folder unreachable
    /// because the user's disk filled up sends them into a re-pick that cannot help, and it
    /// disables their schedule for a reason that will resolve itself.
    private func classify(_ error: Error) -> Failure {
        let nsError = error as NSError

        // POSIX codes arrive either directly or wrapped under `NSUnderlyingErrorKey`; a Cocoa
        // `NSFileWriteUnknownError` with an ENOSPC underneath is common enough that only looking at
        // the outer code would classify a full disk as a mystery.
        let posix: Int32? = {
            if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if underlying?.domain == NSPOSIXErrorDomain, let code = underlying?.code {
                return Int32(code)
            }
            return nil
        }()

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError
            || posix == ENOSPC || posix == EDQUOT {
            return Failure(errorCode: .storageFull, destinationStatus: .ok,
                           message: DestinationMessages.probeStorageFull)
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                // Access we used to have and no longer do — the grant side of §12 EPIC-14's
                // "bookmark/URI invalidation". Re-picking is what restores it.
                return Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                               message: DestinationMessages.probePermissionWithdrawn, needsRepick: true)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileWriteInvalidFileNameError:
                // The folder itself is gone from under the bookmark.
                return Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                               message: DestinationMessages.probeNeedsRepick, needsRepick: true)
            case NSFileWriteVolumeReadOnlyError, NSFileReadUnsupportedSchemeError:
                return Failure(errorCode: .storageUnavailable, destinationStatus: .ok,
                               message: DestinationMessages.probeStorageUnavailable)
            case NSUbiquitousFileUnavailableError, NSUbiquitousFileNotUploadedDueToQuotaError,
                 NSUbiquitousFileUbiquityServerNotAvailable:
                // iCloud specifically: the folder is real and the grant is fine, the service is
                // not answering. A retry later is the right remedy, so the status stays `ok`.
                return Failure(errorCode: .storageUnavailable, destinationStatus: .ok,
                               message: DestinationMessages.probeStorageUnavailable)
            default:
                break
            }
        }

        if posix == EACCES || posix == EPERM {
            return Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                           message: DestinationMessages.probePermissionWithdrawn, needsRepick: true)
        }
        if posix == ENOENT || posix == ENODEV || posix == ENXIO {
            return Failure(errorCode: .destinationUnreachable, destinationStatus: .unreachable,
                           message: DestinationMessages.probeNeedsRepick, needsRepick: true)
        }
        if posix == EROFS || posix == EIO {
            return Failure(errorCode: .storageUnavailable, destinationStatus: .ok,
                           message: DestinationMessages.probeStorageUnavailable)
        }

        // Everything else is `writeFailed` with the destination left alone. An unrecognized error
        // is not evidence the folder is broken, and `unknown` would tell Export Health nothing
        // about which stage to retry.
        return Failure(errorCode: .writeFailed, destinationStatus: .ok,
                       message: DestinationMessages.probeWriteFailed)
    }
}

private extension URL {
    /// `appending(components:)` for a `[String]`, which the variadic stdlib version cannot take.
    func appending(components: [String]) -> URL {
        components.reduce(self) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
