package net.albayyan.badan.platform.notifications

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.core.AppLanguage

/**
 * Posts one time-based decision notification when its scheduled moment arrives — the delivery half
 * of [AndroidNotificationScheduler.schedule].
 *
 * It is deliberately dumb. The decision (opt-in, quiet hours, ≤2/day budget, shared ceiling) was
 * made when the work was enqueued and is already written to the `notification_deliveries` ledger, so
 * this worker re-checks only the two things that can have changed since: whether the user has since
 * turned the class off, and whether notifications are still permitted. Re-running the full engine
 * here would double-count the ledger row this notification already owns.
 *
 * A worker that cannot open the environment retries rather than dropping the notice silently — same
 * reasoning as `SyncWorker`, where the store may be locked before first unlock.
 */
class DecisionNotificationWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val cls = NotificationClass.fromCode(inputData.getString(KEY_CLASS))
            // Not a retry: an unparseable class is a bug in the enqueue site, and retrying it would
            // just fail again on a schedule the user never asked for.
            ?: return Result.failure()
        val language = AppLanguage.fromCode(inputData.getString(KEY_LANGUAGE))

        val env = runCatching { AppEnvironment.shared(applicationContext) }.getOrNull()
            ?: return Result.retry()

        // The user may have switched the class off between enqueue and fire. The engine's cancel
        // path already cancels this work, but a race (a toggle mid-flight) must not deliver anyway.
        if (!env.isNotificationClassEnabled(cls)) return Result.success()

        val posted = runCatching { env.notificationScheduler.post(cls, language) }.getOrDefault(false)
        // Record what actually happened. `posted == false` means the system refused (permission
        // revoked, notifications switched off), so the row stays `scheduled` rather than claiming a
        // delivery the user never saw — the ledger must never assert more than the OS did.
        if (posted) {
            runCatching { env.markNotificationDelivered(cls, at = env.clock.now()) }
        }
        // Deliberately does NOT re-arm its own next occurrence here. The work this runs on is
        // unique-by-class, so enqueuing the next one from inside it would REPLACE — that is,
        // cancel — the very run doing the enqueuing, which is a race to rely on for a daily cadence.
        // Re-arming is instead the job of `AppEnvironment.reconcileDecisionNotifications`, which runs
        // on every launch and on every periodic `SyncWorker` wake; both are idempotent per class+day.
        return Result.success()
    }

    companion object {
        const val KEY_CLASS = "badan.notif.class"
        const val KEY_LANGUAGE = "badan.notif.language"
    }
}
