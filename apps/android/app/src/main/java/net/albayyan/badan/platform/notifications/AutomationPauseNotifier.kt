package net.albayyan.badan.platform.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
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
 * all. On API 33+ the notification is displayed only once `POST_NOTIFICATIONS` is granted — EPIC-32
 * owns that runtime-permission request flow, so until it lands this notice is silently dropped on
 * newer devices while still appearing on API 26–32 and while the pause remains visible everywhere.
 * The whole post is wrapped so a permission or channel failure can never propagate into a wake.
 */
class AndroidAutomationPauseNotifier(context: Context) : AutomationPauseNotifier {
    private val appContext = context.applicationContext

    override fun automationPaused(scheduleId: String, language: AppLanguage) {
        runCatching {
            ensureChannel(language)
            val notification = NotificationCompat.Builder(appContext, AutomationPausedCopy.CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(AutomationPausedCopy.title.resolved(language))
                .setContentText(AutomationPausedCopy.body.resolved(language))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .build()
            // Tag = schedule id, so re-pausing the same schedule replaces its notice rather than
            // stacking a second one.
            NotificationManagerCompat.from(appContext).notify(scheduleId, NOTIFICATION_ID, notification)
        }
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
    }
}
