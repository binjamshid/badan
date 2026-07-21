package net.albayyan.badan.platform.notifications

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import net.albayyan.badan.MainActivity
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.automation.AutomationPauseNotifier

/**
 * The copy for the "an automation was paused" notification (EPIC-15 failure budget). Generic on
 * purpose: it names no template and no destination, so nothing a user chose to label revealingly
 * leaks onto a lock screen, and the tone is calm — a paused automation is a thing to review, not an
 * emergency. Mirror of iOS `AutomationPausedCopy`.
 */
object AutomationPausedCopy {
    val title = LocalizedString(en = "BADAN", ar = "بدن")
    val body = LocalizedString(
        en = "An automatic export was paused after a few failed attempts. Open BADAN to review it.",
        ar = "أُوقف تصدير تلقائي مؤقتاً بعد عدّة محاولات فاشلة. افتح «بدن» لمراجعته.",
    )
    val channelName = LocalizedString(en = "Automations", ar = "الأتمتة")
    const val CHANNEL_ID = "badan.automation.paused"
}

/**
 * The real [AutomationPauseNotifier], over `NotificationManagerCompat`.
 *
 * Best-effort by design: the load-bearing honesty guarantee is the VISIBLE pause (stored in
 * `automation_schedules`, which the UI shows), and that holds with no notification permission at
 * all. On API 33+ the notification is displayed only once `POST_NOTIFICATIONS` is granted; EPIC-32
 * declared that permission and put its request behind the Settings → "Summaries & reminders"
 * toggles, so a user who has opted into any decision class has already granted it and this notice
 * now arrives on modern devices too. A user who has granted nothing still gets the visible pause —
 * this notice is the nudge on top, never the guarantee. The whole post is wrapped so a permission or
 * channel failure can never propagate into a wake.
 *
 * Deliberately NOT routed through [NotificationDecisionEngine]: a pause is the direct consequence of
 * the user's own three failed runs, not an ambient nudge, so it is not budgeted and does not consume
 * a ≤2/day slot. It does share the decision engine's deep-link contract, landing the tap on the same
 * evidence surface [NotificationClass.EXPORT_HEALTH_ALERT] uses.
 */
class AndroidAutomationPauseNotifier(context: Context) : AutomationPauseNotifier {
    private val appContext = context.applicationContext

    // The `notify` below is guarded by the `canPostNotifications` check on the first line (shared
    // with `AndroidNotificationScheduler`), which checks POST_NOTIFICATIONS on API 33+; lint cannot
    // follow the call, and the body is additionally wrapped in `runCatching` so a permission revoked
    // mid-flight can never propagate into a background wake.
    @SuppressLint("MissingPermission")
    override fun automationPaused(scheduleId: String, language: AppLanguage) {
        // EPIC-32 declared POST_NOTIFICATIONS, so there is finally something to check here: before
        // that this posted unconditionally and the OS dropped it on API 33+. The VISIBLE pause in
        // `automation_schedules` remains the guarantee either way — this notice is the nudge on top.
        if (!canPostNotifications(appContext)) return
        runCatching {
            ensureChannel(language)
            val notification = NotificationCompat.Builder(appContext, AutomationPausedCopy.CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(AutomationPausedCopy.title.resolved(language))
                .setContentText(AutomationPausedCopy.body.resolved(language))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setContentIntent(deepLinkIntent())
                .build()
            // Tag = schedule id, so re-pausing the same schedule replaces its notice rather than
            // stacking a second one.
            NotificationManagerCompat.from(appContext).notify(scheduleId, NOTIFICATION_ID, notification)
        }
    }

    /**
     * EPIC-32 deep link: a tap opens BADAN on the export-health surface — the screen that shows the
     * pause and its failure history — rather than wherever the app happened to be. `FLAG_IMMUTABLE`
     * because nothing downstream may rewrite this intent (and it is mandatory from API 31).
     */
    private fun deepLinkIntent(): PendingIntent {
        val intent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(NotificationDeepLink.EXTRA, NotificationDeepLink.EXPORT_HEALTH.code)
        }
        return PendingIntent.getActivity(
            appContext,
            PENDING_INTENT_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel(language: AppLanguage) {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(AutomationPausedCopy.CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                AutomationPausedCopy.CHANNEL_ID,
                AutomationPausedCopy.channelName.resolved(language),
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }

    private companion object {
        const val NOTIFICATION_ID = 0xBADA

        /**
         * Distinct from every `AndroidNotificationScheduler` request code (which are class
         * ordinals), so the two never overwrite each other's `PendingIntent`.
         */
        const val PENDING_INTENT_REQUEST_CODE = 0xBADA
    }
}
