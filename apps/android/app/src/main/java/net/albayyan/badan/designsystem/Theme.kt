package net.albayyan.badan.designsystem

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

/**
 * Applies BADAN's colour system as environment. Provides [LocalBadanColors] for BADAN
 * components and maps the same tokens onto a Material3 `ColorScheme` so any Material3
 * component (buttons, switches, text fields) inherits the calm palette automatically.
 *
 * RTL/language direction is provided app-wide from `env.language` at a higher level — this
 * modifier is purely the colour altitude.
 */
@Composable
fun BadanTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors = if (dark) badanDarkColors() else badanLightColors()
    CompositionLocalProvider(LocalBadanColors provides colors) {
        MaterialTheme(
            colorScheme = colors.toMaterialColorScheme(),
            content = content,
        )
    }
}

/**
 * Accessor object so screens can read the active BADAN colours with `BadanTheme.colors`
 * (parallels Material3's `MaterialTheme.colorScheme`). A function and an object may share the
 * name — they live in separate namespaces, exactly like Material3's own `MaterialTheme`.
 */
object BadanTheme {
    val colors: BadanColors
        @Composable get() = LocalBadanColors.current
}

/** Map the BADAN token set onto a Material3 colour scheme so Material components inherit it. */
private fun BadanColors.toMaterialColorScheme() = if (isDark) {
    darkColorScheme(
        primary = primary,
        onPrimary = background,
        secondary = primary,
        onSecondary = background,
        background = background,
        onBackground = textPrimary,
        surface = surface,
        onSurface = textPrimary,
        surfaceVariant = surfaceElevated,
        onSurfaceVariant = textSecondary,
        outline = separator,
        outlineVariant = separator,
        error = critical,
        onError = Color.White,
    )
} else {
    lightColorScheme(
        primary = primary,
        onPrimary = Color.White,
        secondary = primary,
        onSecondary = Color.White,
        background = background,
        onBackground = textPrimary,
        surface = surface,
        onSurface = textPrimary,
        surfaceVariant = surfaceElevated,
        onSurfaceVariant = textSecondary,
        outline = separator,
        outlineVariant = separator,
        error = critical,
        onError = Color.White,
    )
}
