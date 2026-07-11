package net.albayyan.badan.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WbSunny
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

private data class Tab(val label: net.albayyan.badan.core.LocalizedString, val icon: ImageVector)

@Composable
private fun MainShell() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val detail = nav.current

    if (detail != null) BackHandler(enabled = true) { nav.pop() }

    val tabs = listOf(
        Tab(Loc.tabToday, Icons.Filled.WbSunny),
        Tab(Loc.tabBody, Icons.Filled.Person),
        Tab(Loc.tabLog, Icons.Filled.AddCircle),
        Tab(Loc.tabInsights, Icons.Filled.AutoAwesome),
        Tab(Loc.tabSettings, Icons.Filled.Settings),
    )

    Scaffold(
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = detail == null && nav.selectedTab == index,
                        onClick = { nav.detailStack.clear(); nav.selectTab(index) },
                        icon = { Icon(tab.icon, contentDescription = env.s(tab.label)) },
                        label = { Text(env.s(tab.label)) },
                    )
                }
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (detail != null) {
                DetailContent(detail)
            } else {
                when (nav.selectedTab) {
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
        else -> {} // tab routes are rendered by the shell, not as pushed detail
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
