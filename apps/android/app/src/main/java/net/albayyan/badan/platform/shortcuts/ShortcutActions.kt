package net.albayyan.badan.platform.shortcuts

/**
 * EPIC-19 — the custom intent actions BADAN's launcher shortcuts (res/xml/shortcuts.xml) and the
 * quick-settings tile use to tell [net.albayyan.badan.MainActivity] which screen to open.
 *
 * Actions rather than string extras because a static shortcut's `<intent>` in shortcuts.xml cannot
 * carry `<extra>` values — the action name is the whole payload. These strings are duplicated in
 * shortcuts.xml (res XML has no way to reference Kotlin constants); the file's header comment names
 * this file so the two are edited together.
 *
 * There is no Shortcuts-app equivalent on Android, so this small surface is the honest Approximate
 * parity to iOS's App Intents (plan §14): a way to jump straight to running an export, seeing
 * today's readiness, or logging water, without a full automation framework Android does not have.
 */
object ShortcutActions {
    const val RUN_EXPORT = "net.albayyan.badan.action.RUN_EXPORT"
    const val TODAY = "net.albayyan.badan.action.TODAY"
    const val LOG = "net.albayyan.badan.action.LOG"

    /** Where a shortcut/tile action lands. Kept as an enum so `MainActivity` maps once, in one
     *  `when`, rather than string-matching actions inline. */
    enum class Destination { EXPORT, TODAY, LOG }

    /** The destination for an intent action, or `null` for anything not one of ours. */
    fun destination(action: String?): Destination? = when (action) {
        RUN_EXPORT -> Destination.EXPORT
        TODAY -> Destination.TODAY
        LOG -> Destination.LOG
        else -> null
    }
}
