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
    data object Export : Route
    data object SymptomLog : Route
    data object MedicationLog : Route
    data object WorkoutLog : Route
    data object NutritionLog : Route

    data class MetricDetail(val metricId: String) : Route
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
