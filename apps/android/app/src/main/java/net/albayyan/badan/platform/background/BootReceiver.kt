package net.albayyan.badan.platform.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import net.albayyan.badan.app.AppEnvironment

/**
 * EPIC-05 task 6 — re-establish the hourly sync after a reboot.
 *
 * **This is defence in depth, not the primary mechanism.** WorkManager persists its own schedule
 * and reschedules it after boot through its internal `RescheduleReceiver`, so on a well-behaved
 * device the periodic work returns without this class existing. It is here because "well-behaved"
 * is exactly what §14 says not to assume of the OEM skins BADAN has to run on, and because losing
 * the schedule fails silently: background sync simply stops until the user next opens the app, with
 * no error anywhere. Removing this because "WorkManager already handles it" removes the belt and
 * keeps only the braces.
 *
 * **Requires a manifest registration that this stage does not add.** `RECEIVE_BOOT_COMPLETED` is
 * already declared in `AndroidManifest.xml`, but a boot receiver cannot be registered at runtime —
 * the process is not alive to register it — so until the corresponding `<receiver>` element exists
 * this class is inert:
 *
 * ```xml
 * <receiver
 *     android:name=".platform.background.BootReceiver"
 *     android:exported="false"
 *     android:enabled="true">
 *     <intent-filter>
 *         <action android:name="android.intent.action.BOOT_COMPLETED" />
 *     </intent-filter>
 * </receiver>
 * ```
 *
 * `exported="false"` is correct despite the intent filter: `BOOT_COMPLETED` is a protected
 * broadcast that only the system can send, so the receiver needs no external visibility and an
 * exported one would let any app on the device trigger a sync schedule.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // Receivers are addressed by intent filter, but the filter is data supplied by the manifest
        // and a receiver is also directly invocable; check rather than trust.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        // `onReceive` runs on the main thread with a short deadline, and constructing
        // `AppEnvironment` opens and migrates two SQLite databases. Reading eligibility from
        // SharedPreferences instead keeps this to the microseconds a boot receiver is entitled to;
        // `SyncWorker` re-checks the real state (including the Health Connect permission rows) on
        // its own thread before it does any work, so a stale preference here can at worst schedule
        // work that immediately no-ops.
        if (!AppEnvironment.isBackgroundSyncEnabledPreference(context)) return

        // Idempotent by `BackgroundScheduler.periodicPolicy` — if WorkManager already restored the
        // schedule itself a moment ago, this updates it in place rather than stacking a second one.
        runCatching { BackgroundScheduler.schedulePeriodic(context) }
    }
}
