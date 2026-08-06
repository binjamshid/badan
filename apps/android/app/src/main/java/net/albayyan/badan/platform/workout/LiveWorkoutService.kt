package net.albayyan.badan.platform.workout

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * The live-workout foreground service — Android's counterpart to iOS's `HKWorkoutSession`.
 *
 * **This is a declared-but-unimplemented component.** It exists so that `AndroidManifest.xml` can
 * name every component the port will need in one change, and so that the task which actually
 * records a workout writes Kotlin instead of re-opening the manifest, the permission set and the
 * Play Data Safety answers at the same time.
 *
 * ## Why a foreground service is the only option
 *
 * A workout has to keep sampling while the screen is off and while another app is in front. On
 * Android that is a foreground service or nothing: a plain service is killed by the process
 * lifecycle mid-session, WorkManager's floor is around fifteen minutes for periodic work and it
 * makes no continuity guarantee at all, and an `AlarmManager` wake-up cannot hold a sensor
 * subscription open between fires. There is no lighter substrate that produces a correct workout.
 *
 * ## What the manifest already commits to, and what this class must honour
 *
 * - `android:foregroundServiceType="health"`, matched by `FOREGROUND_SERVICE_HEALTH`. From API 34
 *   a `health` foreground service must ALSO hold one of `ACTIVITY_RECOGNITION` / `BODY_SENSORS` /
 *   `HIGH_SAMPLING_RATE_SENSORS` **granted at runtime** or `startForeground` throws
 *   `SecurityException`. `ACTIVITY_RECOGNITION` is the one declared, so the start path must check
 *   it is granted and refuse to start the session honestly if it is not — never start and silently
 *   record nothing.
 * - No location permission and no `location` service type. v1 mirrors iOS in excluding GPS from
 *   live workouts, so a BADAN-recorded workout has no route and the app's "no location collected"
 *   Data Safety answer stays true. Adding GPS is a product decision, not a switch to flip because
 *   the service type would allow it.
 * - `@string/channel_live_workout_name` / `_description` and
 *   `@string/notification_live_workout_title` / `_text` are already declared in both locales. The
 *   ongoing notification carries no reading: it sits on a lock screen, and no health value ever
 *   appears there.
 *
 * ## The open decision this class must not make on its own
 *
 * The manifest declares `WRITE_EXERCISE` / `WRITE_HEART_RATE` / `WRITE_ACTIVE_CALORIES_BURNED` /
 * `WRITE_DISTANCE` so that a workout recorded here can be written back to Health Connect. That
 * turns BADAN into a writer to the platform store for the first time, which is a posture change
 * with a Data Safety and privacy-copy consequence — see the WRITE block in `AndroidManifest.xml`.
 * Whatever else it writes, it must never write a DERIVED number (readiness, effort, sleep score):
 * those carry provisional constants, an input manifest and a confidence, and the platform store
 * has nowhere to put any of that, so the number would propagate into other apps stripped of
 * everything that makes it honest.
 *
 * Returning `START_NOT_STICKY` below is deliberate even for a stub, because it is the correct
 * final behaviour too: if the process dies mid-workout, the OS must not resurrect this service
 * with a null intent and no session state — a "restarted" workout that silently lost its first
 * forty minutes is worse than one that ended when the process did.
 */
class LiveWorkoutService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // No startForeground() call: a foreground service that posts its notification must also be
        // recording something, and there is nothing to record yet. Starting one that immediately
        // stops itself would put a "Recording your workout" notification in front of a user for a
        // session that does not exist.
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
