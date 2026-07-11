package net.albayyan.badan

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.StrictMode
import android.util.Log
import android.view.FrameMetrics
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import net.albayyan.badan.app.Route
import androidx.compose.ui.graphics.toArgb
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
    // Owned at the Activity level (not `remember`ed) so a warm-start deep link delivered via
    // onNewIntent can drive navigation without needing to reach into the Compose tree.
    private val navigator = Navigator()
    private lateinit var env: AppEnvironment

    override fun onCreate(savedInstanceState: Bundle?) {
        if (isDebugBuild()) {
            // Surfaces main-thread disk/network violations (e.g. the synchronous DB/asset load
            // in AppEnvironment's constructor) as Logcat warnings only; never crashes a QA build.
            StrictMode.setThreadPolicy(
                StrictMode.ThreadPolicy.Builder()
                    .detectDiskReads()
                    .detectDiskWrites()
                    .detectNetwork()
                    .penaltyLog()
                    .build()
            )
        }

        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        env = AppEnvironment(this)
        env.applyLaunchOverrides(intent.extras)

        setContent {
            // Demo/screenshot deep-link: SIMCTL-style extra to open a route directly. Also
            // re-dispatched from onNewIntent below so a warm start honors the same extra.
            LaunchedEffect(Unit) {
                handleRouteIntent(intent)
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
                    val colors = BadanTheme.colors
                    // Keeps the system bars in step with the current BADAN background so there's
                    // no color seam at the edges (real effect on API 26-34; a harmless no-op on
                    // 35+ where edge-to-edge makes the bars transparent instead).
                    SideEffect {
                        window.statusBarColor = colors.background.toArgb()
                        window.navigationBarColor = colors.background.toArgb()
                    }
                    RootScreen()
                }
            }
        }

        if (isDebugBuild()) {
            val frameHandler = Handler(Looper.getMainLooper())
            window.addOnFrameMetricsAvailableListener(
                { _, frameMetrics, _ ->
                    val totalMs = frameMetrics.getMetric(FrameMetrics.TOTAL_DURATION) / 1_000_000.0
                    if (totalMs > JANK_FRAME_THRESHOLD_MS) {
                        Log.d(JANK_LOG_TAG, "Dropped frame: ${"%.1f".format(totalMs)}ms")
                    }
                },
                frameHandler,
            )
        }

        lifecycleScope.launch { env.bootstrap() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleRouteIntent(intent)
    }

    private fun handleRouteIntent(intent: Intent?) {
        when (intent?.getStringExtra("badan_route")) {
            "sources" -> { navigator.selectTab(1); navigator.push(Route.Sources) }
            "export" -> navigator.push(Route.Export)
            "timeline" -> navigator.push(Route.Timeline)
            "insights" -> navigator.selectTab(3)
        }
    }

    private fun isDebugBuild(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private companion object {
        const val JANK_FRAME_THRESHOLD_MS = 16.67
        const val JANK_LOG_TAG = "BadanJank"
    }
}
