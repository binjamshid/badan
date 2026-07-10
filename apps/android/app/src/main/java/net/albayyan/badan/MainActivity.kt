package net.albayyan.badan

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import net.albayyan.badan.app.Route
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Navigator
import net.albayyan.badan.app.RootScreen
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.domain.AppTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val env = AppEnvironment(this)
        env.applyLaunchOverrides(intent.extras)

        setContent {
            val navigator = remember { Navigator() }
            // Demo/screenshot deep-link: SIMCTL-style extra to open a route directly.
            LaunchedEffect(Unit) {
                when (intent.getStringExtra("badan_route")) {
                    "sources" -> { navigator.selectTab(1); navigator.push(Route.Sources) }
                    "export" -> navigator.push(Route.Export)
                    "timeline" -> navigator.push(Route.Timeline)
                    "insights" -> navigator.selectTab(3)
                }
            }
            val dark = when (env.profile.theme) {
                AppTheme.DARK -> true
                AppTheme.LIGHT -> false
                AppTheme.SYSTEM -> isSystemInDarkTheme()
            }
            val direction = if (env.language.isRtl) LayoutDirection.Rtl else LayoutDirection.Ltr

            CompositionLocalProvider(
                LocalAppEnvironment provides env,
                LocalNavigator provides navigator,
                LocalLayoutDirection provides direction,
            ) {
                BadanTheme(dark = dark) {
                    RootScreen()
                }
            }
        }

        lifecycleScope.launch { env.bootstrap() }
    }
}
