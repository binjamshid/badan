package net.albayyan.badan.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * The app's destinations. The five tabs are the top-level IA (Today / Body / Log / Insights /
 * Settings); everything else is a detail route pushed onto a per-app detail stack (metric detail,
 * sources, export, and the four log editors). Mirror of the iOS navigation surface.
 */
sealed interface Route {
    // Tabs
    data object Home : Route
    data object Body : Route
    data object Log : Route
    data object Insights : Route
    data object Settings : Route

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
 * Holds the selected tab and a single detail-navigation stack. Screens push detail routes
 * (metric detail, sources, export, log editors) and pop back; the shell renders the top of the
 * stack over the current tab. Compose-observable so pushes/pops re-render.
 */
class Navigator {
    val detailStack = mutableStateListOf<Route>()
    var selectedTab by mutableStateOf(0)

    fun push(route: Route) {
        detailStack.add(route)
    }

    fun pop() {
        if (detailStack.isNotEmpty()) detailStack.removeAt(detailStack.lastIndex)
    }

    val current: Route? get() = detailStack.lastOrNull()

    fun selectTab(i: Int) {
        selectedTab = i
    }
}

val LocalNavigator = staticCompositionLocalOf<Navigator> {
    error("Navigator not provided")
}
