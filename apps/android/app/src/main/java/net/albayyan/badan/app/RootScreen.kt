package net.albayyan.badan.app

import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.outlined.AddCircle
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import net.albayyan.badan.core.Loc
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.components.SampleDataBanner
import net.albayyan.badan.features.body.BodyScreen
import net.albayyan.badan.features.body.SourcesScreen
import net.albayyan.badan.features.export.ExportScreen
import net.albayyan.badan.features.home.HomeScreen
import net.albayyan.badan.features.insights.InsightsScreen
import net.albayyan.badan.features.loghub.LogHubScreen
import net.albayyan.badan.features.medication.MedicationLogScreen
import net.albayyan.badan.features.metricdetail.MetricDetailScreen
import net.albayyan.badan.features.onboarding.OnboardingScreen
import net.albayyan.badan.features.settings.SettingsScreen
import net.albayyan.badan.features.symptom.SymptomLogScreen
import net.albayyan.badan.features.timeline.TimelineScreen
import net.albayyan.badan.features.workoutnutrition.NutritionLogScreen
import net.albayyan.badan.features.workoutnutrition.WorkoutLogScreen
import net.albayyan.badan.features.workouts.RouteConsentScreen
import net.albayyan.badan.features.workouts.WorkoutDetailScreen

/**
 * The app's top-level gate (mirror of the iOS `RootView`): a calm splash while the store seeds,
 * then onboarding on first run, then the five-destination tab shell. Theme + RTL are applied by
 * MainActivity, so a language/theme change re-skins instantly.
 */
@Composable
fun RootScreen() {
    val env = LocalAppEnvironment.current
    when {
        !env.isReady -> SplashScreen()
        !env.onboardingComplete -> OnboardingScreen()
        else -> MainShell()
    }
}

private data class Tab(
    val label: net.albayyan.badan.core.LocalizedString,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
)

@Composable
private fun MainShell() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val detail = nav.current

    if (detail != null) {
        BackHandler(enabled = true) { nav.pop() }
    } else {
        // Retrace tab history before falling through to the platform's default exit behavior.
        BackHandler(enabled = nav.tabHistory.size > 1) { nav.popTabHistory() }
    }

    val tabs = listOf(
        Tab(Loc.tabToday, Icons.Filled.WbSunny, Icons.Outlined.WbSunny),
        Tab(Loc.tabBody, Icons.Filled.Person, Icons.Outlined.Person),
        Tab(Loc.tabLog, Icons.Filled.AddCircle, Icons.Outlined.AddCircle),
        Tab(Loc.tabInsights, Icons.Filled.AutoAwesome, Icons.Outlined.AutoAwesome),
        Tab(Loc.tabSettings, Icons.Filled.Settings, Icons.Outlined.Settings),
    )

    Scaffold(
        bottomBar = {
            // The banner sits directly above the navigation bar, inside `bottomBar`, so the
            // Scaffold reserves space for it and it never floats over tab content — the same
            // placement decision iOS makes with `safeAreaInset(edge: .bottom)` on its TabView.
            // Column so it applies to every tab at once: sample data is a fact about the whole
            // app's state, not about one screen.
            Column {
                if (env.isDemoDataActive) SampleDataBanner(language = env.language)
                NavigationBar {
                    tabs.forEachIndexed { index, tab ->
                        val selected = detail == null && nav.selectedTab == index
                        NavigationBarItem(
                            selected = selected,
                            onClick = { nav.detailStack.clear(); nav.selectTab(index) },
                            icon = {
                                Icon(
                                    if (selected) tab.selectedIcon else tab.unselectedIcon,
                                    contentDescription = env.s(tab.label),
                                )
                            },
                            label = { Text(env.s(tab.label)) },
                        )
                    }
                }
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (detail != null) {
                // Crossfade between pushed detail screens; the tab content below is left mounted
                // (see the `else` branch) so it isn't disposed while a detail is on screen.
                Crossfade(targetState = detail, label = "detail") { route -> DetailContent(route) }
            } else {
                // Keep every tab composed (collapsed to zero size when not selected) instead of
                // switching on a bare `when`, so revisiting a tab doesn't re-run its loaders.
                tabs.indices.forEach { index ->
                    val visible = nav.selectedTab == index
                    Box(if (visible) Modifier.fillMaxSize() else Modifier.size(0.dp)) {
                        when (index) {
                            0 -> HomeScreen()
                            1 -> BodyScreen()
                            2 -> LogHubScreen()
                            3 -> InsightsScreen()
                            else -> SettingsScreen()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailContent(route: Route) {
    when (route) {
        is Route.MetricDetail -> MetricDetailScreen(route.metricId)
        Route.Timeline -> TimelineScreen()
        Route.Sources -> SourcesScreen()
        Route.Export -> ExportScreen()
        Route.SymptomLog -> SymptomLogScreen()
        Route.MedicationLog -> MedicationLogScreen()
        Route.WorkoutLog -> WorkoutLogScreen()
        Route.NutritionLog -> NutritionLogScreen()
        Route.RouteConsent -> RouteConsentScreen()
        is Route.WorkoutDetail -> WorkoutDetailScreen(route.sessionId)
    }
}

@Composable
private fun SplashScreen() {
    val colors = BadanTheme.colors
    Box(Modifier.fillMaxSize().background(colors.background), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "BADAN",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = colors.textPrimary,
            )
            Spacer(Modifier.height(24.dp))
            CircularProgressIndicator(color = colors.primary)
        }
    }
}
