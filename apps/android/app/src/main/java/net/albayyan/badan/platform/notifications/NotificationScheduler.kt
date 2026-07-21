package net.albayyan.badan.platform.notifications

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit
import net.albayyan.badan.MainActivity
import net.albayyan.badan.core.AppLanguage

/**
 * Whether BADAN may actually post a notification right now. Two different questions on either side of
 * API 33, and both matter: from Tiramisu on, `POST_NOTIFICATIONS` is a runtime permission that starts
 * denied; before it, there is no permission but the user can still switch the app's notifications off
 * in system settings. Either answer of "no" means a posted notification is silently dropped.
 *
 * A package-level function rather than a method so BOTH notification posters share one definition:
 * [AndroidNotificationScheduler] (the decision classes) and [AndroidAutomationPauseNotifier] (the
 * EPIC-15 pause notice). Before EPIC-32 declared `POST_NOTIFICATIONS` in the manifest, neither
 * checked it — there was nothing to check, so a post was simply a no-op on API 33+. Now that the
 * permission exists and is requested, every `notify()` call site guards on this first.
 */
internal fun canPostNotifications(context: Context): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return false
    }
    return NotificationManagerCompat.from(context).areNotificationsEnabled()
}

/**
 * EPIC-32's Android I/O shell: channels, the `POST_NOTIFICATIONS` permission check, posting a
 * decision notification, and scheduling the time-based ones through WorkManager. Every *decision* —
 * opt-in, quiet hours, the ≤2/day budget, the shared pending ceiling — belongs to
 * [NotificationDecisionEngine] and is made before anything here is called; this class deliberately
 * does no gating of its own, mirroring the iOS split between the pure engine and
 * `NotificationScheduler`.
 *
 * Two platform truths stated plainly rather than papered over:
 *
 *  1. **Android has no medication-reminder delivery.** iOS's `NotificationScheduler` schedules med
 *     reminders and EPIC-32 extends it; here there is nothing to extend — med reminders are standing
 *     Android parity debt. Nothing in this file schedules or posts a [NotificationClass.MEDS]
 *     notification, and the settings surface offers no toggle that would suggest otherwise.
 *  2. **Timed delivery is best-effort.** WorkManager's initial delay is a *minimum*, and Doze can
 *     push a wake later; no exact-alarm permission is requested for a wellness nudge. Plan §4 rule
 *     10 requires that be said out loud, so the settings screen says it
 *     ([NotificationClassCopy.schedulingHonestyNote]) instead of implying a wall-clock promise.
 */
class AndroidNotificationScheduler(context: Context) {
    private val appContext: Context = context.applicationContext

    // MARK: - Permission

    /**
     * Whether BADAN may actually post a notification right now — see [canPostNotifications], which
     * this shares with the EPIC-15 pause notifier. A `false` here is exactly the failure the settings
     * screen surfaces rather than leaving the user to discover it.
     */
    fun canPost(): Boolean = canPostNotifications(appContext)

    // MARK: - Channels

    /**
     * Create one channel per registered class, plus the EPIC-15 automation-pause channel. Idempotent
     * — `createNotificationChannel` on an existing id updates only the name/description, never the
     * importance or sound the user may have changed, which is why re-running this at every launch is
     * safe and why channel ids must stay stable ([NotificationClass.channelId]).
     *
     * A channel per class is the point: it is Android's own per-category mute, so a user who finds
     * the water reminders chatty can silence exactly those without losing an export-health alert.
     * [NotificationClass.MEDS] gets no channel — nothing posts it (see the class doc).
     *
     * Scoped to [NotificationClass.userFacing] on purpose: a channel is itself a user-visible
     * promise (it appears in Android's own notification settings), so a class with no producer must
     * not materialise one. [post] ensures the single channel it is about to use, so a class that
     * gains a producer later still gets its channel at the moment it first posts.
     */
    fun ensureChannels(language: AppLanguage) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        for (cls in NotificationClass.userFacing) ensureChannel(cls, language)
    }

    /** Create (or refresh) the channel for exactly one class. See [ensureChannels] for the contract. */
    private fun ensureChannel(cls: NotificationClass, language: AppLanguage) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                cls.channelId,
                NotificationClassCopy.channelName(cls).resolved(language),
                // DEFAULT, never HIGH: none of these is urgent, and a wellness nudge that
                // interrupts with a heads-up banner is the fatigue the budget exists to prevent.
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = NotificationClassCopy.settingsRow(cls).second.resolved(language)
            },
        )
    }

    // MARK: - Posting

    /**
     * Post the notification for [cls] now. Content is generic and value-free
     * ([NotificationClassCopy]) so nothing about the user's body is legible on a lock screen, and
     * the tap carries the class's deep link so it lands on the evidence surface.
     *
     * Returns whether the post was actually handed to the system: `false` when notifications are off
     * or the permission is not granted, so a caller can record the honest outcome instead of a
     * `delivered` row for something the user never saw. The whole body is wrapped because a channel
     * or permission failure must never propagate into a background wake.
     */
    // The `notify` below is guarded by the `canPost()` on the first line, which checks
    // POST_NOTIFICATIONS on API 33+; lint cannot follow the call, and the whole body is additionally
    // wrapped in `runCatching` so even a revoked-mid-flight permission returns false rather than
    // throwing into a background wake.
    @SuppressLint("MissingPermission")
    fun post(cls: NotificationClass, language: AppLanguage): Boolean {
        if (!canPost()) return false
        return runCatching {
            // The channel for THIS class, not just the offered set — a class that gains a producer
            // before it gains a Settings row must still land on a real channel rather than be
            // dropped by the OS.
            ensureChannel(cls, language)
            val (title, body) = NotificationClassCopy.content(cls)
            val notification = NotificationCompat.Builder(appContext, cls.channelId)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title.resolved(language))
                .setContentText(body.resolved(language))
                .setStyle(NotificationCompat.BigTextStyle().bigText(body.resolved(language)))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setContentIntent(deepLinkIntent(cls.deepLink, requestCode = cls.ordinal))
                .build()
            // One id per class, so a second notice of the same class replaces the first rather than
            // stacking — the same "never pile up" discipline the ≤2/day budget enforces upstream.
            NotificationManagerCompat.from(appContext).notify(notificationId(cls), notification)
            true
        }.getOrDefault(false)
    }

    /**
     * The `PendingIntent` a tap follows: MainActivity with the deep-link code as an extra
     * ([NotificationDeepLink.EXTRA]), which `MainActivity.handleRouteIntent` maps to a tab/route.
     * `FLAG_IMMUTABLE` because nothing downstream may rewrite this intent, and it is mandatory from
     * API 31 anyway; `SINGLE_TOP` + `CLEAR_TOP` so a tap resumes the running app rather than
     * stacking a second copy of the activity.
     */
    private fun deepLinkIntent(link: NotificationDeepLink, requestCode: Int): PendingIntent {
        val intent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(NotificationDeepLink.EXTRA, link.code)
        }
        return PendingIntent.getActivity(
            appContext,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // MARK: - Scheduling (time-based classes)

    /**
     * Enqueue [cls]'s next notification for [fireAt] (epoch millis). Unique work keyed by the class,
     * with `REPLACE`, so re-reconciling on a second app open moves the pending one rather than
     * queueing a duplicate — the WorkManager half of the ledger's per-class-per-day idempotency.
     *
     * A fire time already in the past runs immediately (delay clamps to zero) rather than being
     * dropped: the caller has already decided this notification is due.
     */
    fun schedule(cls: NotificationClass, fireAt: Long, language: AppLanguage, now: Long) {
        val delayMs = maxOf(0L, fireAt - now)
        val request = OneTimeWorkRequest.Builder(DecisionNotificationWorker::class.java)
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .addTag(cls.workTag)
            .setInputData(
                Data.Builder()
                    .putString(DecisionNotificationWorker.KEY_CLASS, cls.code)
                    .putString(DecisionNotificationWorker.KEY_LANGUAGE, language.code)
                    .build(),
            )
            .build()
        runCatching {
            WorkManager.getInstance(appContext)
                .enqueueUniqueWork(cls.workTag, ExistingWorkPolicy.REPLACE, request)
        }
    }

    /**
     * Cancel [cls]'s pending work and clear any notification of that class already on screen — what
     * "the user turned this class off" means at the OS level. Scoped by the class's own work name
     * and notification id, so it never touches another class, the EPIC-15 automation-pause notice,
     * or the sync work.
     */
    fun cancel(cls: NotificationClass) {
        runCatching { WorkManager.getInstance(appContext).cancelUniqueWork(cls.workTag) }
        runCatching { NotificationManagerCompat.from(appContext).cancel(notificationId(cls)) }
    }

    /**
     * Cancel every budgeted class — used when notifications become unavailable altogether. Iterates
     * the budgeted set rather than [NotificationClass.userFacing]: "cancel everything this engine
     * could have scheduled" must not shrink just because a class stopped being offered in Settings,
     * or a previously-scheduled request would be stranded with no way to clear it.
     */
    fun cancelAll() {
        for (cls in NotificationClass.entries.filter { it.countsAgainstDailyBudget }) cancel(cls)
    }

    private fun notificationId(cls: NotificationClass): Int = NOTIFICATION_ID_BASE + cls.ordinal

    private companion object {
        /**
         * Notification ids are per-app integers; this base keeps the decision classes clear of
         * [AutomationPausedCopy]'s own id, which is allocated separately.
         */
        const val NOTIFICATION_ID_BASE = 0xBAD0
    }
}
