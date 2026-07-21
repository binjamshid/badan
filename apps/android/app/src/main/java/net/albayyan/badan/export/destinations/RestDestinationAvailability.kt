package net.albayyan.badan.export.destinations

import android.content.Context

/**
 * The single gate that decides whether EPIC-20's REST destination is part of a build. Mirror of iOS
 * `Export/Destinations/RESTDestinationAvailability.swift`, decision for decision.
 *
 * **Why a gate exists at all.** [RestDestination] is finished and tested (`RestDestinationTest`),
 * but a finished deliverer is not a shipped feature. Before an export can leave the device four
 * things have to be true at once, and only the first is code:
 *
 *  1. the deliverer is registered at the composition root (this flag),
 *  2. `android.permission.INTERNET` is back in `AndroidManifest.xml` — it is deliberately absent
 *     today, and without it every socket this code opens throws `SecurityException`,
 *  3. a surface exists that lets a user *create* a `restApi` destination row — enter their own
 *     server address, save a bearer token to the Keystore, read the §22.7 consent sentence
 *     ([DestinationMessages.restConsent]) and run a verification ping — and a way to point a
 *     template at it,
 *  4. the published privacy documents and the Play Data Safety declaration say that BADAN can
 *     transmit data, because today they say the opposite.
 *
 * (4) is not a detail. `docs/PRIVACY_POLICY.md` and `docs/legal/privacy.html` currently state, in
 * the present tense and as a promise, that there is "no way to point an export at a server" and
 * that the app "transmits nothing off the device". Registering this deliverer while those sentences
 * stand would make the app's own published privacy policy false — a worse defect than the dark code
 * it would be fixing. So the flag is `false`, the manifest carries no `INTERNET` permission, and
 * the four changes are required to land together.
 *
 * **What this flag does NOT do:** it is not a runtime toggle, not a user setting, and not a
 * remote-config value. It is a build-time constant a developer edits deliberately, in a diff a
 * reviewer sees, alongside the rest of the checklist above.
 */
object RestDestinationAvailability {

    /**
     * `false`: no `restApi` deliverer is registered, so a `restApi` destination row — if one could
     * be created, which no surface allows — would fail delivery loudly with
     * `DESTINATION_UNREACHABLE` rather than silently writing nowhere (`ExportRunner`'s
     * no-deliverer branch). Flip only with items (2), (3) and (4) above in the same change.
     *
     * A `val`, not a `const val`, on purpose: a compile-time constant would let the compiler fold
     * the branch in [deliverers] away and warn the registration line is unreachable, which is
     * noise about a line that is supposed to stay compiled and reviewable.
     */
    val ENABLED: Boolean = false

    /**
     * The deliverers a build registers, in the order `ExportRunner` searches them (first match on
     * `kind` wins). Assembled here rather than inline at the composition root so the gate and the
     * registration cannot drift apart: there is exactly one list, and reading it answers "what can
     * this build deliver to?" without cross-referencing a flag somewhere else.
     *
     * The share sheet is deliberately absent — it is delivered in-process by the UI handing the
     * runner's cache files to an `ACTION_SEND` chooser, never by a deliverer.
     */
    fun deliverers(context: Context): List<ExportDestinationDelivering> = buildList {
        add(
            FileFolderDestination(
                SharedPrefsTreeUriStore(context),
                ContentResolverTreeDocumentGateway(context),
            ),
        )
        if (ENABLED) {
            add(
                RestDestination(
                    transport = HttpUrlConnectionRestTransport(),
                    credentials = KeystoreRestCredentialStore(context),
                ),
            )
        }
    }
}
