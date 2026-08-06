package net.albayyan.badan.platform.widgets

import android.appwidget.AppWidgetProvider

/**
 * EPIC-33 — the five home-screen widget receivers, declared up front so no later feature task has
 * to edit `AndroidManifest.xml`.
 *
 * ## Why these are stubs, and why that is not a placeholder in the usual sense
 *
 * A manifest `<receiver>` must name a class that exists, or the app fails to install. Declaring
 * every widget the port will need therefore requires a class per widget *now* — the alternative is
 * five separate later tasks each editing the same manifest, which is exactly the collision this
 * batch exists to prevent.
 *
 * ## Why [AppWidgetProvider] and not `GlanceAppWidgetReceiver`
 *
 * `androidx.glance.appwidget.GlanceAppWidgetReceiver` **is** an [AppWidgetProvider] — Glance's
 * receiver extends the framework class rather than replacing it. The Glance artifacts are on
 * `:app`'s classpath, so the swap is available; it is not made here because
 * `GlanceAppWidgetReceiver` requires an override returning a real `GlanceAppWidget` — an actual
 * composable widget UI, reading real data — and a stub cannot supply one without either inventing
 * a layout or rendering a fabricated number.
 *
 * So each class below extends the framework base today and changes its superclass to
 * `GlanceAppWidgetReceiver` (plus an override of `glanceAppWidget`) in the task that builds the
 * widget's UI. Nothing outside this file moves when that happens: the manifest element, the class
 * name, the `android:label` and the `res/xml` widget-info metadata are identical for both
 * superclasses. That
 * substitutability is the reason this shape was chosen over, say, an `object` placeholder — a stub
 * that has to be *replaced* rather than *extended* would drag the manifest along with it.
 *
 * ## Kind strings
 *
 * Each receiver carries iOS's own widget kind string (`AmbientSnapshotWriter.widgetKinds`, plus
 * `effort_ring`) so the two platforms' widget sets can be diffed by name rather than by reading
 * both UIs. These are not persisted anywhere on Android — Android identifies a widget by its
 * provider `ComponentName`, not by a kind string — so they are parity anchors and nothing more.
 * They must not become a second identity scheme for the same widget.
 *
 * ## What a real implementation still owes
 *
 * The receivers do not override `onUpdate`, which means a dropped widget currently draws
 * `@layout/widget_initial_loading` (deliberately empty) and never fills in. That is correct for a
 * stub — a widget that renders a fabricated or zeroed reading would be worse than a blank one —
 * but it is also why these must not ship to a user in this state. Either they gain a real
 * implementation, or Batch 4 sweeps them, their `res/xml` widget-info files and their strings back
 * out together.
 *
 * (Both references above avoid writing the literal resource glob: Kotlin block comments NEST, so a
 * slash-star sequence inside a KDoc opens a comment that the closing delimiter then fails to
 * close, and the file stops compiling at EOF with an error pointing nowhere near the cause.)
 */
class RingSingleWidgetReceiver : AppWidgetProvider() {
    companion object {
        /** iOS: `RingSingleWidget.kind`. */
        const val KIND = "ring_single"
    }
}

/** `one_true_sentence` — the day's single calm summary sentence. See [RingSingleWidgetReceiver]. */
class OneTrueSentenceWidgetReceiver : AppWidgetProvider() {
    companion object {
        const val KIND = "one_true_sentence"
    }
}

/** `meds_due` — medications due soon, empty until the user opts in. See [RingSingleWidgetReceiver]. */
class MedsDueWidgetReceiver : AppWidgetProvider() {
    companion object {
        const val KIND = "meds_due"
    }
}

/** `sleep_last_night` — last night's duration and score. See [RingSingleWidgetReceiver]. */
class SleepLastNightWidgetReceiver : AppWidgetProvider() {
    companion object {
        const val KIND = "sleep_last_night"
    }
}

/** `effort_ring` — today's effort. See [RingSingleWidgetReceiver]. */
class EffortRingWidgetReceiver : AppWidgetProvider() {
    companion object {
        const val KIND = "effort_ring"
    }
}
