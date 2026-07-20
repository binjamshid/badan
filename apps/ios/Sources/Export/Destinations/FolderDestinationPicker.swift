import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// EPIC-14 — turning a folder the user picked with `UIDocumentPickerViewController` into a
/// persistable `ExportDestination`, and the picker that gets them there.
///
/// The enrollment half is deliberately separate from the SwiftUI half and knows nothing about
/// UIKit: minting a bookmark, choosing its storage key and assembling the destination row are the
/// parts with rules worth testing, and they are testable against a real temp directory only because
/// no view controller is involved. `FolderDestinationPicker` below is the thin part.
///
/// **This file persists nothing to the database.** It returns an `ExportDestination` value; writing
/// it belongs to `ExportDestinationRepository`, which stage 1 owns.
enum FolderDestinationEnrollment {

    /// Namespace for the `ExportDestinationConfig.folderBookmarkRef` key.
    ///
    /// Distinct from `CredentialRef.namespace` and *not* a `CredentialRef`: that type is validated
    /// storage for secrets that authenticate to a remote service, and a bookmark is neither a
    /// secret nor a credential — it is a capability handle for a local folder. Filing it under the
    /// credential namespace would put a non-credential through a validator built to keep bearer
    /// tokens out, which reads as a category error the first time someone audits either type.
    static let bookmarkRefNamespace = "badan.export.folder."

    struct Enrolled: Equatable {
        let destination: ExportDestination
        let bookmarkRef: String
    }

    enum Failure: Error, Equatable {
        /// The picked URL would not yield bookmark data — nothing to persist, so there is no
        /// destination to create. Reported rather than swallowed: a destination row without a
        /// resolvable bookmark is precisely the silent failure §12 EPIC-14 is written against.
        case bookmarkUnavailable
        /// The bookmark was minted but the protected store refused it. Also fatal to enrollment,
        /// for the same reason — the row would outlive the access it describes.
        case bookmarkNotStored
    }

    /// Enroll a picked folder.
    ///
    /// Re-picking is the *same call with the same `destinationId`*: the bookmark ref is derived
    /// from the id, so a re-pick overwrites the stored bookmark in place and every template and
    /// `ExportCursor` pointing at that destination keeps working. Minting a new id on re-pick would
    /// silently reset `sinceLastRun` to zero and re-export the user's entire history — see
    /// `ExportCursor`'s doc for why that watermark must survive.
    static func enroll(pickedURL: URL, destinationId: String, displayName: String? = nil,
                       now: Date, originDeviceId: String,
                       into store: FolderBookmarkStoring) -> Result<Enrolled, Failure> {
        // The picker hands back a security-scoped URL and the scope must be held while the bookmark
        // is minted; see `FileFolderDestination.resolveFolder` for why `false` is not treated as a
        // denial here either.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? pickedURL.bookmarkData(options: [],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) else {
            return .failure(.bookmarkUnavailable)
        }

        let ref = bookmarkRef(for: destinationId)
        guard store.store(data, for: ref) else { return .failure(.bookmarkNotStored) }

        let destination = ExportDestination(
            id: destinationId, kind: .fileFolder,
            displayName: displayName ?? pickedURL.lastPathComponent,
            config: ExportDestinationConfig(folderBookmarkRef: ref),
            // No `credentialRef`, and `tlsPolicy` resolves to `notApplicable` from the kind: a
            // folder write has no transport and claiming one would be the small lie
            // `ExportTlsPolicy` documents.
            createdAt: now,
            // `lastVerifiedAt` stays nil until a probe actually passes. Stamping it here would
            // mean "verified" recorded the moment a folder was picked, before anything had ever
            // been written to it — which is the claim the verification ping exists to earn.
            lastVerifiedAt: nil, status: .ok, updatedAt: now, originDeviceId: originDeviceId)
        return .success(Enrolled(destination: destination, bookmarkRef: ref))
    }

    /// Derived from the destination id, never random — see `enroll` for why re-pick stability
    /// matters. Lowercased for the same reason `CredentialRef.forDestination` does it: ULIDs are
    /// case-insensitive, and a key that varies by case is a key that sometimes misses.
    static func bookmarkRef(for destinationId: String) -> String {
        bookmarkRefNamespace + destinationId.lowercased()
    }

    /// Drop a destination's bookmark. For the delete flow — the row is soft-deleted by
    /// `ExportDestinationRepository`, and the standing filesystem access it referenced should not
    /// outlive it in the Keychain.
    static func forget(destinationId: String, in store: FolderBookmarkStoring) {
        store.remove(ref: bookmarkRef(for: destinationId))
    }
}

/// `UIDocumentPickerViewController` in folder-picking mode, as a SwiftUI view.
///
/// `asCopy: false` is the load-bearing argument: the copy variant hands back a URL inside our own
/// container, which would bookmark fine and then write every export into a sandbox the user cannot
/// see. Folders cannot be copied anyway, so the wrong value here fails at runtime rather than at
/// compile time — hence the note.
///
/// Not yet presented from any screen. The Export Center surface that offers "choose a folder" is
/// not this stage's to build; this is the component it will use, and the enrollment call above is
/// what it should invoke from `onPick`.
struct FolderDestinationPicker: UIViewControllerRepresentable {
    /// Called with the picked folder URL, still security-scoped. Hand it straight to
    /// `FolderDestinationEnrollment.enroll` — the URL is only guaranteed usable during this call.
    let onPick: (URL) -> Void
    /// Called when the user backed out. Distinguished from a failed pick so the UI can leave the
    /// existing destination alone instead of reporting a problem the user did not have.
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: FolderDestinationPicker
        init(_ parent: FolderDestinationPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return parent.onCancel() }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
