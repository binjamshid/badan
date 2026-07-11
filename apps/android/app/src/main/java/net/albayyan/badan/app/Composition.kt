package net.albayyan.badan.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import net.albayyan.badan.core.LocalizedString

/**
 * Compose glue for the app layer. [LocalAppEnvironment] threads the composition-root
 * [AppEnvironment] to every screen; [locStr] is the bilingual sugar screens reach for so no
 * literal English string ever lands in the tree. Mirror of the iOS `UISupport`/environment glue.
 */
val LocalAppEnvironment = staticCompositionLocalOf<AppEnvironment> {
    error("AppEnvironment not provided")
}

/** The current app environment. */
@Composable
fun appEnv(): AppEnvironment = LocalAppEnvironment.current

/** Resolve a [LocalizedString] against the live app language. */
@Composable
fun locStr(ls: LocalizedString): String = LocalAppEnvironment.current.s(ls)

/** The shared value formatter bound to the live profile. */
@Composable
fun rememberFormatter(): ValueFormatter = LocalAppEnvironment.current.format
