package net.albayyan.badan

import net.albayyan.badan.platform.shortcuts.ShortcutActions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * EPIC-19 — the launcher-shortcut / QS-tile action mapping.
 *
 * `RunExportTileService` and `res/xml/shortcuts.xml` reach `MainActivity` through custom intent
 * actions (a static shortcut can carry no extras), and `MainActivity.handleShortcutIntent` routes
 * on `ShortcutActions.destination(...)`. That mapping is the one piece of this feature with
 * branching logic worth pinning; the tile itself is Android-framework glue with no Robolectric
 * harness in this module (see `FoundationTest`'s honesty note about the missing instrumented set).
 *
 * The load-bearing assertion is `unknownActionMapsToNull`: an unrecognised action must fall
 * through to no navigation rather than defaulting to some screen, so a stray or spoofed intent
 * can't silently drop the user somewhere they didn't ask for.
 */
class ShortcutActionsTest {

    @Test fun runExportActionOpensExport() {
        assertEquals(ShortcutActions.Destination.EXPORT,
            ShortcutActions.destination(ShortcutActions.RUN_EXPORT))
    }

    @Test fun todayActionOpensToday() {
        assertEquals(ShortcutActions.Destination.TODAY,
            ShortcutActions.destination(ShortcutActions.TODAY))
    }

    @Test fun logActionOpensLog() {
        assertEquals(ShortcutActions.Destination.LOG,
            ShortcutActions.destination(ShortcutActions.LOG))
    }

    @Test fun unknownActionMapsToNull() {
        assertNull(ShortcutActions.destination("android.intent.action.MAIN"))
        assertNull(ShortcutActions.destination(null))
        assertNull(ShortcutActions.destination(""))
    }

    /**
     * The action constants are duplicated verbatim in `res/xml/shortcuts.xml` and referenced from
     * the AndroidManifest. This freezes their exact spelling so an accidental rename here (which
     * would leave the XML pointing at a dead action and the shortcut silently opening nothing) is
     * caught by a failing test rather than by a user tapping a launcher shortcut that does nothing.
     */
    @Test fun actionStringsAreStable() {
        assertEquals("net.albayyan.badan.action.RUN_EXPORT", ShortcutActions.RUN_EXPORT)
        assertEquals("net.albayyan.badan.action.TODAY", ShortcutActions.TODAY)
        assertEquals("net.albayyan.badan.action.LOG", ShortcutActions.LOG)
    }
}
