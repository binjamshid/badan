package net.albayyan.badan.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * The app's pushable destinations. The five tabs (Today / Body / Log / Insights / Settings) are
 * the top-level IA and are addressed by [Navigator.selectedTab], not by [Route] — [Route] models
 * only the detail screens pushed onto the per-app detail stack (metric detail, sources, export,
 * and the four log editors). Mirror of the iOS navigation surface.
 */
sealed interface Route {
    // Detail destinations
    data object Timeline : Route
    data object Sources : Route

    /**
     * The Health Monitor vitals dashboard (EPIC-27). A pushed detail under Body/Today rather than a
     * top-level tab: it is a focused read over the same canonical vitals the metric detail shows, and
     * every tile deep-links onward to `MetricDetail`, so it lives on the detail stack beside them.
     */
    data object HealthMonitor : Route

    data object Export : Route
    data object SymptomLog : Route
    data object MedicationLog : Route
    data object WorkoutLog : Route
    data object NutritionLog : Route

    // Export surfaces (EPIC-10/11/09/16). The Export Center ([Export]) is the hub; these are the
    // three pushed screens it links to. Quick Export is a card inside the hub, not a route — §16
    // places it "at top of Export Center", so it never gets a destination of its own.

    /**
     * The advanced export builder (EPIC-11). [templateId] is the one piece of navigation state:
     * null opens a blank ad-hoc builder, a non-null id opens the same screen pre-filled to edit
     * that saved user template. Presets are never edited here (the repository refuses it and the
     * template manager never offers the affordance), so a preset id would only ever arrive from a
     * bug — the screen loads it read-only rather than crashing.
     */
    data class ExportBuilder(val templateId: String? = null) : Route

    /** Saved export configurations — presets (read-only) plus the user's own (EPIC-09). */
    data object ExportTemplates : Route

    /** The trust ledger: did my exports actually run? (EPIC-16). */
    data object ExportHealth : Route

    /**
     * The GPS-route consent surface (EPIC-03). A destination rather than a Settings row: it is the
     * single place `AppEnvironment.isRouteCaptureEnabled` is written, and being addressable means
     * every screen that has to explain a missing route — the workout detail today, export scope
     * later — can send the user to the explanation rather than restate it badly.
     */
    data object RouteConsent : Route

    data class MetricDetail(val metricId: String) : Route

    /**
     * One ingested workout session, keyed by its BADAN session ULID (not the upstream record id):
     * the route has to survive a re-sync that re-reads the same workout, and the session row's id
     * is stable across that where the platform's own identity is only stable per source.
     *
     * Manual `workout_entries` deliberately have no detail route. They have no session row, no HR
     * linkage and no lineage to show, so a detail screen for one would be a page of empty sections;
     * they stay expanded in place in the unified list instead.
     */
    data class WorkoutDetail(val sessionId: String) : Route
}

/**
 * Holds the selected tab, its visit history, and a single detail-navigation stack. Screens push
 * detail routes (metric detail, sources, export, log editors) and pop back; the shell renders the
 * top of the stack over the current tab. Compose-observable so pushes/pops re-render.
 */
class Navigator {
    val detailStack = mutableStateListOf<Route>()
    var selectedTab by mutableStateOf(0)

    /** Tab-visit order (oldest first); lets system back retrace tabs before exiting the app. */
    val tabHistory = mutableStateListOf(0)

    fun push(route: Route) {
        // Guard against a double-tap pushing the same detail route twice.
        if (detailStack.lastOrNull() == route) return
        detailStack.add(route)
    }

    fun pop() {
        if (detailStack.isNotEmpty()) detailStack.removeAt(detailStack.lastIndex)
    }

    val current: Route? get() = detailStack.lastOrNull()

    fun selectTab(i: Int) {
        if (i == selectedTab) return
        selectedTab = i
        tabHistory.add(i)
    }

    /** Retrace to the previously visited tab. Returns false when history is exhausted, so the
     *  caller can fall through to default back behavior (exiting the app). */
    fun popTabHistory(): Boolean {
        if (tabHistory.size <= 1) return false
        tabHistory.removeAt(tabHistory.lastIndex)
        selectedTab = tabHistory.last()
        return true
    }
}

val LocalNavigator = staticCompositionLocalOf<Navigator> {
    error("Navigator not provided")
}
