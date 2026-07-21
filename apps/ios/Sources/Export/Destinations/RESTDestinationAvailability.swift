import Foundation

/// The single gate that decides whether EPIC-20's REST destination is part of a build.
///
/// **Why a gate exists at all.** `RESTDestination` is finished and tested (`RESTDestinationTests`,
/// `RestDestinationTest.kt`), but a finished deliverer is not a shipped feature. Before an export
/// can leave the device three things have to be true at once, and only the first is code:
///
///  1. the deliverer is registered at the composition root (this flag),
///  2. a surface exists that lets a user *create* a `restApi` destination row — enter their own
///     server address, save a bearer token to the Keychain/Keystore, read the §22.7 consent
///     sentence (`DestinationMessages.restConsent`) and run a verification ping — and a way to
///     point a template at it,
///  3. the published privacy documents and the store data-safety declarations say that BADAN can
///     transmit data, because today they say the opposite.
///
/// (3) is not a detail. `docs/PRIVACY_POLICY.md` and `docs/legal/privacy.html` currently state, in
/// the present tense and as a promise, that there is "no way to point an export at a server" and
/// that the app "transmits nothing off the device". Registering this deliverer while those
/// sentences stand would make the app's own published privacy policy false — a worse defect than
/// the dark code it would be fixing. So the flag is `false`, Android's manifest carries no
/// `INTERNET` permission, and the three changes are required to land together.
///
/// **What this flag does NOT do:** it is not a runtime toggle, not a user setting, and not a
/// remote-config value. It is a build-time constant a developer edits deliberately, in a diff a
/// reviewer sees, alongside the rest of the checklist above.
enum RESTDestinationAvailability {

    /// `false`: no `restApi` deliverer is registered, so a `restApi` destination row — if one could
    /// be created, which no surface allows — would fail delivery loudly with
    /// `.destinationUnreachable` rather than silently writing nowhere (the no-deliverer branch of
    /// `ExportRunner`'s delivery step). Flip only with items (2) and (3) above in the same change.
    static let isEnabled = false

    /// The deliverers a build registers, in the order `ExportRunner` searches them (first match on
    /// `kind` wins). Assembled here rather than inline at the composition root so the gate and the
    /// registration cannot drift apart: there is exactly one list, and reading it answers "what can
    /// this build deliver to?" without cross-referencing a flag somewhere else.
    ///
    /// The share sheet is deliberately absent — it is delivered in-process by the UI handing the
    /// runner's temp files to `UIActivityViewController`, never by a deliverer (see the share-sheet
    /// branch of `ExportRunner`'s delivery step).
    static func deliverers(folderBookmarks: FolderBookmarkStoring) -> [ExportDestinationDelivering] {
        var deliverers: [ExportDestinationDelivering] = [
            FileFolderDestination(bookmarks: folderBookmarks),
        ]
        if isEnabled {
            deliverers.append(RESTDestination(transport: URLSessionRESTTransport(),
                                              credentials: KeychainRESTCredentialStore()))
        }
        return deliverers
    }
}
