package net.albayyan.badan.designsystem

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The semantic colour ontology (mirror of iOS `BadanColor`). Each token carries the exact mined
 * light/dark pair from `docs/design/design-tokens.json` so screens reference meaning
 * ("surface", "inBand") rather than raw hex. Dark-first but fully dual-theme from day one.
 *
 * Status colours never moralize: out-of-band above OR below share ONE amber ([outOfBand]);
 * direction is carried by icon + text, never by hue alone.
 */
data class BadanColors(
    val background: Color,
    val surface: Color,
    val surfaceElevated: Color,
    val primary: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val separator: Color,
    val inBand: Color,
    val outOfBand: Color,
    val info: Color,
    val critical: Color,
    /**
     * Text/icon colour for content painted on top of a [primary]-filled surface (e.g. a filled
     * primary button). One shared token instead of re-deriving `if (isDark) ... else ...` at
     * each call site (UIUX-223).
     */
    val onPrimary: Color,
    /** Whether this set is the dark palette — used to derive the Material colour scheme. */
    val isDark: Boolean,
)

/** The light palette — exact mined hex values. */
fun badanLightColors(): BadanColors = BadanColors(
    background = Color(0xFFFAFAF8),
    surface = Color(0xFFFFFFFF),
    surfaceElevated = Color(0xFFF1F1EE),
    primary = Color(0xFF157A6E),
    textPrimary = Color(0xFF17191C),
    textSecondary = Color(0xFF5C636D),
    separator = Color(0xFFE5E5E0),
    inBand = Color(0xFF2E9E63),
    outOfBand = Color(0xFFB97A14),
    info = Color(0xFF2678C4),
    critical = Color(0xFFC9353B),
    onPrimary = Color.White,
    isDark = false,
)

/** The dark palette — exact mined hex values. */
fun badanDarkColors(): BadanColors = BadanColors(
    background = Color(0xFF0C0E11),
    surface = Color(0xFF16191E),
    surfaceElevated = Color(0xFF1E2228),
    primary = Color(0xFF5BC5BA),
    textPrimary = Color(0xFFF2F3F5),
    textSecondary = Color(0xFF9AA1AB),
    separator = Color(0xFF252A31),
    inBand = Color(0xFF57C785),
    outOfBand = Color(0xFFE8A13A),
    info = Color(0xFF4C9FE8),
    critical = Color(0xFFE5484D),
    // Matches the already-tuned dark on-primary value from `OnboardingScreen.kt`'s
    // `PrimaryButton`, reused here as the single source of truth (UIUX-223).
    onPrimary = Color(0xFF08201D),
    isDark = true,
)

/**
 * The active BADAN colour set. Provided app-wide by [BadanTheme]; read anywhere via
 * `BadanTheme.colors`. Defaults to the light palette until a theme wraps the tree.
 */
val LocalBadanColors = staticCompositionLocalOf { badanLightColors() }

/**
 * The 4pt spacing scale plus card padding and the strict minimum touch target (48dp on
 * Android). Mirror of iOS `BadanSpace`.
 */
object BadanSpace {
    val s1 = 4.dp
    val s2 = 8.dp
    val s3 = 12.dp
    val s4 = 16.dp
    val s5 = 20.dp
    val s6 = 24.dp
    val s7 = 32.dp
    val s8 = 40.dp
    val cardPadding = 16.dp
    val touchMin = 48.dp
}

/** Corner radii — soft, tactile, generous by default. Mirror of iOS `BadanRadius`. */
object BadanRadius {
    val chip = 10.dp
    val control = 12.dp
    val card = 20.dp
    val sheet = 24.dp
}

/**
 * The type ramp (mirror of iOS `BadanFont`). Numerals use tabular lining figures via the
 * `"tnum"` OpenType feature so values never jitter as they tick — data-forward typography.
 */
object BadanType {
    /** Ring centres, metric heroes. Tabular numerals. */
    val heroNumeral = TextStyle(
        fontSize = 44.sp,
        fontWeight = FontWeight.SemiBold,
        fontFeatureSettings = "tnum",
    )

    /** Stat cards. Tabular numerals. */
    val numeralM = TextStyle(
        fontSize = 28.sp,
        fontWeight = FontWeight.Medium,
        fontFeatureSettings = "tnum",
    )

    /**
     * Large page titles (Log, Settings, Onboarding-style headers). One shared token instead of
     * three independently hand-rolled "28sp bold" styles at each call site (UIUX-263).
     */
    val pageTitle = TextStyle(
        fontSize = 28.sp,
        fontWeight = FontWeight.Bold,
    )

    /** Card headers. */
    val sectionTitle = TextStyle(
        fontSize = 20.sp,
        fontWeight = FontWeight.Bold,
    )

    /** Narrative, prose. */
    val body = TextStyle(
        fontSize = 16.sp,
        fontWeight = FontWeight.Normal,
    )

    /** Dense power-user tables. */
    val bodyCompact = TextStyle(
        fontSize = 15.sp,
        fontWeight = FontWeight.Normal,
    )

    /** StatusChip, filter chips. */
    val chip = TextStyle(
        fontSize = 13.sp,
        fontWeight = FontWeight.Medium,
    )

    /** Axis labels, provenance lines. */
    val caption = TextStyle(
        fontSize = 13.sp,
        fontWeight = FontWeight.Normal,
    )

    /**
     * A tabular-figures variant of any [TextStyle] — for numerals rendered outside the hero
     * ramp (e.g. dense tables) that must still not jitter as they tick.
     */
    fun monospaceDigits(base: TextStyle): TextStyle = base.copy(fontFeatureSettings = "tnum")
}
