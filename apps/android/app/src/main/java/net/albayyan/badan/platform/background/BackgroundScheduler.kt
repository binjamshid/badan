package net.albayyan.badan.platform.background

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import net.albayyan.badan.core.LocalizedString
import java.util.concurrent.TimeUnit

/**
 * EPIC-05 — the Android background substrate's scheduling half. Owns every decision about *when*
 * [SyncWorker] runs; the worker owns what happens once it does.
 *
 * All request-shaping is exposed as pure builders ([periodicRequest], [oneOffRequest],
 * [shouldMarkExpedited]) with the `WorkManager.getInstance` calls kept to thin wrappers, because
 * this module has no instrumented test source set: anything that can only be checked with a live
 * `WorkManager` is, in practice, checked by nobody. `BackgroundSubstrateTest` covers the builders.
 */
object BackgroundScheduler {

    /**
     * The unique-work name for the periodic sync. A *constant*, and the only one — unique work is
     * keyed by this string, so a caller that passes a computed or per-feature name (say, one per
     * enabled metric family) would enqueue parallel periodic chains that each wake the device
     * hourly. That is the duplicate-stacking failure §12 EPIC-05 task 1 asks us to prevent, and the
     * name is what prevents it.
     */
    const val PERIODIC_WORK_NAME = "badan.sync.periodic"

    /** Unique-work name for the user-triggered "sync now" path. */
    const val ONE_OFF_WORK_NAME = "badan.sync.runNow"

    /** Tag on both request kinds, so diagnostics can query all BADAN sync work in one call. */
    const val WORK_TAG = "badan.sync"

    /** Set on the one-off request's input data; read by [SyncWorker] to pick the run kind. */
    const val KEY_USER_TRIGGERED = "badan.userTriggered"

    /** §12 EPIC-05 / §14: one hour. */
    val periodMillis: Long = TimeUnit.HOURS.toMillis(1)

    /**
     * `UPDATE`, and the two rejected alternatives are both real bugs rather than style choices:
     *
     *  - `REPLACE` cancels and re-enqueues, which resets the period. This is called on every app
     *    open and on boot, so a user who opens BADAN a few times an hour would reset the timer
     *    before it ever elapsed and the periodic sync would never fire at all — the classic
     *    WorkManager footgun, and it presents as "background sync silently does nothing".
     *  - `KEEP` preserves the existing schedule *and its old spec*, so a shipped change to the
     *    period or the constraints would never reach an install that already scheduled work. The
     *    fix would have to be a one-shot migration, which is worse.
     *
     * `UPDATE` (WorkManager 2.8+) applies the new spec while preserving the next run time — the
     * only policy that is both idempotent under repeated calls and upgradeable.
     */
    val periodicPolicy: ExistingPeriodicWorkPolicy = ExistingPeriodicWorkPolicy.UPDATE

    /**
     * `KEEP` for "sync now": if a run is already enqueued or in flight, a second tap should join it
     * rather than queue a duplicate pass over the same Health Connect window. `REPLACE` would
     * cancel work that is already reading and start over, which makes an impatient double-tap
     * strictly slower than a single one.
     */
    val oneOffPolicy: ExistingWorkPolicy = ExistingWorkPolicy.KEEP

    // MARK: - Scheduling

    /**
     * Ensure the hourly sync is scheduled. Safe to call on every app open, on permission changes,
     * and from [BootReceiver] — [periodicPolicy] makes repeated calls idempotent.
     */
    fun schedulePeriodic(context: Context) {
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(PERIODIC_WORK_NAME, periodicPolicy, periodicRequest())
    }

    /** Stop the hourly sync (background sync turned off, or Health Connect disconnected). */
    fun cancelPeriodic(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(PERIODIC_WORK_NAME)
    }

    /** The user-triggered "sync now" path. */
    fun runNow(context: Context) {
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(ONE_OFF_WORK_NAME, oneOffPolicy, oneOffRequest())
    }

    // MARK: - Request builders (pure)

    /**
     * `setRequiresBatteryNotLow(true)` per §14, and deliberately nothing else. In particular there
     * is no `NetworkType` constraint: Health Connect is a local content provider, so requiring
     * connectivity would block a sync that needs no network — and no `setRequiresDeviceIdle`, which
     * would confine syncing to the small hours.
     */
    fun constraints(): Constraints =
        Constraints.Builder()
            .setRequiresBatteryNotLow(true)
            .build()

    /**
     * No explicit flex window. The two-argument `PeriodicWorkRequest.Builder` gives a flex equal to
     * the period, meaning the run may happen anywhere inside each hour; a narrow flex (say the last
     * 15 minutes) sounds more precise but makes a Doze deferral overshoot the window and drop the
     * *entire* period, which is the opposite of what we want on exactly the OEM devices §14 warns
     * about.
     *
     * The five-minute backoff floor replaces WorkManager's 30-second default: a transient Health
     * Connect provider failure is not worth three rapid retries on battery, and the next period is
     * only an hour out regardless.
     */
    fun periodicRequest(): PeriodicWorkRequest =
        PeriodicWorkRequest.Builder(SyncWorker::class.java, periodMillis, TimeUnit.MILLISECONDS)
            .setConstraints(constraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
            .addTag(WORK_TAG)
            .build()

    fun oneOffRequest(sdkInt: Int = Build.VERSION.SDK_INT): OneTimeWorkRequest {
        val builder = OneTimeWorkRequest.Builder(SyncWorker::class.java)
            .setConstraints(constraints())
            .setInputData(Data.Builder().putBoolean(KEY_USER_TRIGGERED, true).build())
            .addTag(WORK_TAG)
        if (shouldMarkExpedited(sdkInt)) {
            // If the app is out of expedited quota, run this as ordinary work rather than dropping
            // it: the user asked for a sync, and a late sync is a far better answer than none.
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        return builder.build()
    }

    /**
     * Expedited work is requested only on API 31+, and this is a correctness guard rather than a
     * conservatism: below 31 WorkManager implements "expedited" by promoting the worker to a
     * foreground service, which means it calls `getForegroundInfo()`. [SyncWorker] does not
     * override it (`CoroutineWorker`'s default throws), so marking the request expedited on API
     * 26–30 would make every "sync now" tap fail with `IllegalStateException` on those devices.
     *
     * Overriding `getForegroundInfo()` is not the fix. It would require posting a user-visible
     * notification — a notification channel and, on API 33+, the `POST_NOTIFICATIONS` runtime
     * permission (EPIC-32, not this epic) — to show a persistent "syncing" notice for work that
     * takes a couple of seconds. A plain unique one-off already starts promptly when the app is in
     * the foreground, which is the only situation "sync now" happens in.
     */
    fun shouldMarkExpedited(sdkInt: Int): Boolean = sdkInt >= Build.VERSION_CODES.S
}

/**
 * User-facing copy for the background substrate, bilingual at the point of definition (an
 * English-only string is unrepresentable — `LocalizedString` has no single-argument constructor).
 * Lives here rather than in `core.Loc` because it is substrate copy consumed by one surface;
 * `Strings.kt` explicitly permits inline `LocalizedString`s for this.
 *
 * **The parity label is honest in both directions (§12 EPIC-05 task 7).** WorkManager genuinely is
 * more reliable than iOS background delivery — it survives process death and reboot — so Android is
 * allowed to say "usually within the hour" where iOS says "best-effort", and flattening Android
 * down to iOS's weaker promise would be its own kind of dishonesty. Equally, WorkManager has no
 * wall clock: §4.10 bans "every day at" and "guaranteed" un-caveated, so "usually" and "not an
 * exact time" carry real weight and are not hedging boilerplate. Do not tighten either direction.
 */
object BackgroundCopy {

    val scheduledLabel = LocalizedString(
        en = "Scheduled — usually within the hour",
        ar = "مجدولة — عادةً خلال الساعة",
    )

    val scheduledDetail = LocalizedString(
        en = "Android runs this when the system allows. That is usually within the hour, but it is not an exact time.",
        ar = "يشغّل أندرويد هذا عندما يسمح النظام. عادةً خلال الساعة، لكنه ليس وقتاً محدداً بدقة.",
    )

    val runNow = LocalizedString(en = "Sync now", ar = "المزامنة الآن")

    val backgroundSyncTitle = LocalizedString(en = "Background sync", ar = "المزامنة في الخلفية")

    val throttleGuidanceTitle = LocalizedString(
        en = "Some phones delay background work",
        ar = "بعض الهواتف تؤخّر العمل في الخلفية",
    )

    /**
     * Names the OEMs §14 names, states the cause as battery saving (which is true and reassuring),
     * and gives one concrete action. No "failed", no "error", no urgency.
     */
    val throttleGuidanceBody = LocalizedString(
        en = "To save battery, some phones — Samsung, Xiaomi, Huawei and others — pause apps that " +
            "are not open. If your readings look behind, allowing BADAN to run in the background " +
            "in your phone's battery settings usually helps.",
        ar = "لتوفير البطارية، توقف بعض الهواتف — سامسونج وشاومي وهواوي وغيرها — التطبيقات غير " +
            "المفتوحة مؤقتاً. إذا بدت قراءاتك متأخرة، فعادةً ما يساعد السماح لـ«بدن» بالعمل في " +
            "الخلفية من إعدادات البطارية في هاتفك.",
    )

    val openBatterySettings = LocalizedString(
        en = "Open battery settings",
        ar = "فتح إعدادات البطارية",
    )

    val neverSyncedInBackground = LocalizedString(
        en = "No background syncs recorded yet",
        ar = "لم تُسجَّل أي مزامنة في الخلفية بعد",
    )

    /**
     * Best available deep link to where the user can let BADAN run in the background, or null when
     * nothing resolves (in which case the caller should show [throttleGuidanceBody] as text only
     * and not a dead button).
     *
     * Every candidate is resolved before it is returned — an unresolvable explicit component throws
     * `ActivityNotFoundException` at `startActivity`, and handing the UI an intent that crashes on
     * tap is worse than handing it nothing.
     *
     * Two things a future editor should know:
     *
     *  1. `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (opens the list) is used, never
     *     `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (prompts for an exemption). The latter is
     *     restricted by Play policy to a short list of app categories that BADAN is not in, and
     *     shipping it risks a rejection for a banner that only needs to point somewhere.
     *  2. From API 30 the OEM component candidates below will usually fail to resolve, because
     *     package visibility hides those packages unless they are declared in a manifest
     *     `<queries>` block. This stage does not touch `AndroidManifest.xml`, so the OEM deep links
     *     are effectively a pre-API-30 nicety and the platform battery screen is the real path.
     *     Adding the `<queries>` entries is the follow-up that makes them work again.
     */
    fun batterySettingsIntent(context: Context): Intent? {
        val pm = context.packageManager
        val candidates = buildList {
            for ((pkg, cls) in OEM_BATTERY_COMPONENTS) {
                add(Intent().setClassName(pkg, cls))
            }
            add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            add(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", context.packageName, null))
            )
        }
        return candidates.firstOrNull { pm.resolveActivity(it, 0) != null }
    }

    /**
     * OEM auto-start / background-management screens, most-restrictive vendors first. Component
     * names are vendor-private and do move between skin versions; that is tolerable precisely
     * because [batterySettingsIntent] resolves before returning, so a renamed activity degrades to
     * the platform battery screen instead of crashing.
     */
    private val OEM_BATTERY_COMPONENTS: List<Pair<String, String>> = listOf(
        // Xiaomi / MIUI — auto-start management.
        "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
        // Huawei / EMUI — protected apps.
        "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
        "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
        // Samsung — device care battery panel.
        "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
        // Oppo / ColorOS and Realme.
        "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
        // Vivo / FuntouchOS.
        "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
        // OnePlus / OxygenOS.
        "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
    )
}
