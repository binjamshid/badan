package net.albayyan.badan.platform.shortcuts

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import net.albayyan.badan.MainActivity

/**
 * EPIC-19 — the "Run export template" quick-settings tile.
 *
 * **This tile opens the Export screen; it does not run an export headlessly, and that is a
 * deliberate honesty decision, not a shortcut taken.** Two constraints make an in-app run the only
 * truthful behaviour:
 *  - A tile has no UI to pick *which* template to run, and picking one silently would run the
 *    wrong export against the user's data.
 *  - BADAN has no notification surface yet (EPIC-32), so a headless run's result — success,
 *    nothing-in-range, or failure — could not be reported. A background export the user is never
 *    told the outcome of is exactly the silent-export failure the whole export subsystem is built
 *    against. Until there is a place to report it, the run belongs in the foreground.
 *
 * So the tile is a fast path *into* the Export Center, where every template runs, writes its
 * `ExportRun`, and shares its file — matching the trailing "…" in the sanctioned label
 * "Run export template…" (plan §14), which by Android convention means "opens further UI".
 *
 * `unlockAndRun` gates the launch on the device being unlocked, so the tile never tries to open an
 * export surface behind the lock screen — the Android counterpart to iOS's unlock requirement for
 * Shortcuts automations, made explicit rather than assumed.
 */
class RunExportTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let { tile ->
            // An action tile, not a toggle: it stays ACTIVE (lit/tappable) rather than modelling
            // an on/off state it does not have.
            tile.state = Tile.STATE_ACTIVE
            tile.label = getString(net.albayyan.badan.R.string.tile_run_export_label)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                tile.subtitle = getString(net.albayyan.badan.R.string.tile_run_export_subtitle)
            }
            tile.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        // Ensure the device is unlocked before opening any screen that shows health data — the tile
        // is reachable from the lock-screen QS panel. `unlockAndRun` prompts for unlock if needed,
        // then invokes the block.
        unlockAndRun {
            val intent = Intent(this, MainActivity::class.java).apply {
                action = ShortcutActions.RUN_EXPORT
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            launchAndCollapse(intent)
        }
    }

    /**
     * `startActivityAndCollapse` split its contract across API levels: API 34 deprecated the
     * `Intent` overload and requires a `PendingIntent`. Both are handled so the tile works on the
     * full `minSdk = 26 … targetSdk = 36` range rather than crashing on one end of it.
     */
    private fun launchAndCollapse(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
